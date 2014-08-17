#==============================================================================#
# OCAWS.tcl
#
# Copyright Sam O'Connor 2014 - All rights reserved
#==============================================================================#


module OCAWS



#------------------------------------------------------------------------------#
# Retry loop
#------------------------------------------------------------------------------#


# Rewrite "try_expr" to try again "max" times.
#
# e.g.
#
#    @with_retry_limit 4 try 
#
#        http_get(url)
#
#    catch e
#        if (typeof(e) == UVError)
#            @retry
#        end
#    end


macro with_retry_limit(max::Integer, try_expr::Expr)

    @assert string(try_expr.head) == "try"

    # Split try_expr into component parts...
    (try_block, exception, catch_block) = try_expr.args

    # Insert a rethrow() at the end of the catch_block...
    push!(catch_block.args, :($exception == nothing || rethrow($exception)))

    # Build retry expression...
    retry_expr = quote

        # Loop one less than "max" times...
        for i in [1 : $max - 1]

            # Execute the "try_expr"...
            # (It can "continue" if it wants to try again)
            $(esc(try_expr))

            # Only get to here if "try_expr" executed cleanly...
            return
        end

        # On the last of "max" attempts, execute the "try_block" naked
        # so that exceptions get thrown up the stack...
        $(esc(try_block))
    end
end


# Conveniance "@retry" keyword...

macro retry() :(continue) end



#------------------------------------------------------------------------------#
# @safe try and @trap exception handling
#------------------------------------------------------------------------------#


# @safe try... re-writes "try_expr" to automatically rethrow()
# at end of "catch" block (unless exception has been set to nothing).
#
# @trap e if... re-writes "if_expr" to ignore exceptions thrown by the if "condition"
# and to set "exception" = nothing if the "condition" is true.
#
# e.g.
#    
#    @safe try
#
#        return s3_get(url)
#
#    catch e
#        @trap e if e.code in {"NoSuchKey", "AccessDenied"}
#            return nothing
#        end
#    end


macro safe(try_expr::Expr)

    @assert string(try_expr.head) == "try"

    (try_block, exception, catch_block) = try_expr.args

    push!(catch_block.args, :($exception == nothing || rethrow($exception)))

    return esc(try_expr)
end


macro trap(exception::Symbol, if_expr::Expr)

    @assert string(if_expr.head) == "if"

    (condition, action) = if_expr.args

    quote
        if try $(esc(condition)) end
            $(esc(action))
            $(esc(exception)) = nothing
        end
    end
end



#------------------------------------------------------------------------------#
# HTTP Requests
#------------------------------------------------------------------------------#


import URIParser: URI, query_params
import Requests: format_query_str, process_response, open_stream
import HttpCommon: Request, STATUS_CODES
import Base: show, UVError


export HTTPException


type HTTPException <: Exception
    url
    request
    response
end


status(e::HTTPException) = e.response.status
http_message(e::HTTPException) = e.response.data
content_type(e::HTTPException) = e.response.headers["Content-Type"]


function show(io::IO,e::HTTPException)

    println(io, string("HTTP ", status(e), " -- ",
                       e.request.method, " ", e.url, " -- ",
                        http_message(e)))
end


function do_http(uri::URI, request::Request)

    # Do HTTP transaction...
    response = process_response(open_stream(uri, request))

    # Return on success...
    if response.finished && response.status in {200, 201, 204, 206}
        return response
    end

    # Throw error on failure...
    throw(HTTPException(uri, request, response))
end


function http_attempt!(uri::URI, request::Request)

    delay = 0.05

    @with_retry_limit 4 try 

#        println(uri)
#        println(request.headers)
        return do_http(uri, request)

    catch e

        if (typeof(e) == UVError
        ||  typeof(e) == HTTPException && !(200 <= status(e) < 500))

            sleep(delay * (0.8 + (0.4 * rand())))
            delay *= 10

            @retry
        end
    end

    assert(false) # Unreachable.
end


function http_attempt(host, resource)

    http_attempt(URI("http://$host/$resource"),
                 Request("GET", resoure, (String=>String)[], ""))
end



#------------------------------------------------------------------------------#
# XML parsing 
#------------------------------------------------------------------------------#


import LightXML: LightXML, XMLDocument, XMLElement, root, find_element, content,
                 get_elements_by_tagname, child_elements, name

parse_xml(s) = LightXML.parse_string(s)


import Base: get

function get(e::XMLElement, name, default="")

    i = find_element(e, name)
    if i != nothing
        return content(i)
    end
    
    for e in child_elements(e)
        e = get(e, name)
        if e != nothing
            return e
        end
    end

    return default
end


get(d::XMLDocument, name, default="") = get(root(d), name, default)


function list(xdoc::XMLDocument, list_tag, item_tag, subitem_tag)

    result = String[]

    l = find_element(root(xdoc), list_tag)
    for e in get_elements_by_tagname(l, item_tag)

        push!(result, content(find_element(e, subitem_tag))) 
    end

    return result
end


function dict(xdoc::XMLDocument, list_tag, item_tag,
              name_tag = "Name", value_tag = "Value")

    result = Dict()

    l = find_element(root(xdoc), list_tag)
    for e in get_elements_by_tagname(l, item_tag)

        n = content(find_element(e, name_tag))
        v = content(find_element(e, value_tag))
        result[n] = v
    end

    return result
end



#------------------------------------------------------------------------------#
# Exceptions
#------------------------------------------------------------------------------#


import JSON: json


export AWSException


type AWSException <: Exception
    code::String
    message::String
    http::HTTPException
end


function show(io::IO,e::AWSException)
    println(io, string (e.code,
                        e.message == "" ? "" : (" -- " * e.message), "\n",
                        e.http))
end


function AWSException(e::HTTPException)

    code = "Unknown"
    message = ""

    # Extract API error code from JSON error message...
    if content_type(e) == "application/x-amz-json-1.0"
        json = JSON.parse(http_message(e))
        if haskey(json, "__type")
            code = split(json["__type"], "#")[2]
        end
    end

    # Extract API error code from XML error message...
    if content_type(e) in {"application/xml", "text/xml"}
        xml = parse_xml(http_message(e))
        code = get(xml, "Code", code)
        message = get(xml, "Message", message)
    end

    
    AWSException(code, message, e)
end



#------------------------------------------------------------------------------#
# AWS Request type
#------------------------------------------------------------------------------#


type AWSRequest
    aws
    verb
    url
    resource
    headers
    content
end

AWSRequest() = AWSRequest(Dict(),"POST","","",Dict(),"")

Request(r::AWSRequest) = Request(r.verb, r.resource, r.headers, r.content)

http_attempt(r::AWSRequest) = http_attempt!(URI(r.url), Request(r))



#------------------------------------------------------------------------------#
# AWSRequest retry loop
#------------------------------------------------------------------------------#


function aws_attempt(request::AWSRequest)

    # Try request 3 times to deal with possible Redirect and ExiredToken...
    @with_retry_limit 3 try 

        if !haskey(request.aws, "access_key_id")
            request.aws = get_aws_ec2_instance_credentials(request.aws)
        end

        request.headers["User-Agent"] = "JuliaAWS.jl/0.0.0"
        request.headers["Content-Length"] = length(request.content) |> string

        sign_aws_request!(request)

        return http_attempt(request)

    catch e

        if typeof(e) == HTTPException

            # Try again on HTTP Redirect...
            if (status(e) in {301, 302, 307}
            &&  haskey(e.response.headers, "Location"))
                request.url = e.response.headers["Location"]
                @retry
            end

            e = AWSException(e)

            # Try again on ExpiredToken error...
            if e.code == "ExpiredToken"
                delete(request.aws, "access_key_id")
                @retry
            end
        end
    end

    assert(false) # Unreachable.
end



#------------------------------------------------------------------------------#
# AWS Request Signing.
#------------------------------------------------------------------------------#


import Nettle: sha256_hash, sha256_hmac, md5_hash
import Dates: format, DateTime, now


function sign_aws_request!(r::AWSRequest, t = now())

    if r.aws["service"] == "sdb"
        sign_aws2_request!(r)
    else
        sign_aws4_request!(r, t)
    end
end


# Create AWS Signature Version 2 Authentication query parameters.
# http://docs.aws.amazon.com/general/latest/gr/signature-version-2.html

function sign_aws2_request!(r::AWSRequest)

#=
    assign $args url query
    assign [uri::split $url] host path

    set common [subst {
        AWSAccessKeyId    [get $aws AWSAccessKeyId]
        Expires           [aws_iso8601 [expr {[clock seconds] + 120}]]
        SignatureVersion  2
        SignatureMethod   HmacSHA256
    }]
    if {[exists $aws AWSToken]} {
        dset common SecurityToken [get $aws AWSToken]
    }
    set query [merge $common $query]

    foreach key [lsort [keys $query]] {
        dset sorted $key [get $query $key]
    }
    set query $sorted

    set digest "POST\n$host\n/$path\n[qstring $query]"
    dset query Signature [sign_aws_string $aws sha2 $digest]

    return $query
=#

end
    
                                        

# Create AWS Signature Version 4 Authentication Headers.
# http://docs.aws.amazon.com/general/latest/gr/signature-version-4.html

function sign_aws4_request!(r::AWSRequest, t)

    # ISO8601 date/time strings for time of request...
    date = format(t,"yyyymmdd")
    datetime = format(t,"yyyymmddTHHMMSSZ")

    # Authentication scope...
    scope = {date, r.aws["region"], r.aws["service"], "aws4_request"}

    # Signing key generated from today's scope string...
    signing_key = string("AWS4", r.aws["secret_key"])
    for element in scope
        signing_key = sha256_hmac(signing_key, element)
    end

    # Authentication scope string...
    scope = join(scope, "/")

    # SHA256 hash of content...
    content_hash = sha256_hash(r.content) |> bytes2hex

    # HTTP headers...
    delete!(r.headers, "Authorization")
    uri = URI(r.url)
    merge!(r.headers, {
        "x-amz-content-sha256" => content_hash,
        "x-amz-date"           => datetime,
        "Host"                 => uri.host,
        "Content-MD5"          => base64(md5_hash(r.content))
    })
    if !haskey(r.headers, "Content-Type") && r.verb == "POST"
        r.headers["Content-Type"] = 
            "application/x-www-form-urlencoded; charset=utf-8"
    end
    if haskey(r.aws, "AWSToken")
        r.headers["x-amz-security-token"] = r.aws["AWSToken"]
    end

    # Sort and lowercase() Headers to produce canonical form...
    canonical_headers = ["$(lowercase(k)):$(strip(v))" for (k,v) in r.headers]
    signed_headers = join(sort([lowercase(k) for k in keys(r.headers)]), ";")

    # Sort Query String...
    query = query_params(uri)
    query = [(k, query[k]) for k in sort(collect(keys(query)))]

    # Create hash of canonical request...
    canonical_form = string(r.verb, "\n",
                            uri.path, "\n",
                            format_query_str(query), "\n",
                            join(sort(canonical_headers), "\n"), "\n\n",
                            signed_headers, "\n",
                            content_hash)
    canonical_hash = sha256_hash(canonical_form) |> bytes2hex

    # Create and sign "String to Sign"...
    string_to_sign = "AWS4-HMAC-SHA256\n$datetime\n$scope\n$canonical_hash"
    signature = sha256_hmac(signing_key, string_to_sign) |> bytes2hex

    # Append Authorization header...
    r.headers["Authorization"] = string (
        "AWS4-HMAC-SHA256 ",
        "Credential=$(r.aws["access_key_id"])/$scope, ",
        "SignedHeaders=$signed_headers, ",
        "Signature=$signature"
    )
end



#------------------------------------------------------------------------------#
# AWS Endpoints
#------------------------------------------------------------------------------#


function s3_endpoint(region, bucket)

    service = "s3"

    # No region suffix for default region...
    if "$region" != "us-east-1"
        service = "$service-$region"
    end

    # Optional bucket prefix...
    if bucket != ""
        service = "$bucket.$service"
    end

    "http://$service.amazonaws.com"
end


function aws_endpoint(service, region)

    # Use https for Identity and Access Management API...
    protocol = service in {"iam", "sts"} ? "https" : "http"

    # No region sufix for sdb in default region...
    if "$service.$region" != "sdb.us-east-1" && region != ""
        service = "$service.$region"
    end

    "$protocol://$service.amazonaws.com"
end



#------------------------------------------------------------------------------#
# Amazon Resource Names
#------------------------------------------------------------------------------#


export aws_account_number, arn, s3_arn


aws_account_number(aws) = split(aws["user_arn"], ":")[5]


function arn(aws, service, resource, region=get(aws, "region", ""),
                                     account=aws_account_number(aws))

    if service == "s3"
        region = ""
        account = ""
    elseif service == "iam"
        region = ""
    end

    "arn:aws:$service:$region:$account:$resource"
end


s3_arn(resource) = "arn:aws:s3:::$resource"
s3_arn(bucket, path) = s3_arn("$bucket/$path")



#------------------------------------------------------------------------------#
# EC2 Metadata
#------------------------------------------------------------------------------#


# Lookup EC2 meta-data "key".
# Must be called from and EC2 instance.
# http://docs.aws.amazon.com/AWSEC2/latest/UserGuide/AESDG-chapter-instancedata.html

#=
function ec2_metadata(key)

    r = http_attempt ("169.254.169.254", "latest/meta-data/$key")
    return r.data
end

proc get_aws_ec2_instance_credentials {aws {option {}}} {

    if {$option != "-force-refresh"
    && [info exists ::oc_aws_ec2_instance_credentials]} {
        return [merge $aws $::oc_aws_ec2_instance_credentials]
    }

    set info [: [aws_ec2_metadata iam/info] | parse json]
    set name [aws_ec2_metadata iam/security-credentials/]
    set creds [: [aws_ec2_metadata iam/security-credentials/$name] | parse json]

    set ::oc_aws_ec2_instance_credentials \
        [dict create AWSAccessKeyId [get $creds AccessKeyId] \
                     AWSSecretKey   [get $creds SecretAccessKey] \
                     AWSToken       [get $creds Token] \
                     AWSUserArn     [get $info InstanceProfileArn]]
    return [merge $aws $::oc_aws_ec2_instance_credentials]
}
=#



#------------------------------------------------------------------------------#
# AWS Service Requests
#------------------------------------------------------------------------------#


import Zlib: crc32


export sqs, sns, ec2, iam, sdb, s3, dynamodb 


# Generic POST Query API request.
# URL points to service endpoint. Query string is passed as POST data.
# Works for everything except s3...

function aws_request(aws; headers=Dict(),query="")

    path = get(aws, "path", "/")
    url = "$(aws_endpoint(aws["service"], aws["region"]))$path"

    aws_attempt(AWSRequest(aws, "POST", url, path, headers, query))
end

aws_request(aws,query) = aws_request(aws;query=format_query_str(query))



# SQS, EC2, IAM and SDB API Requests.
# Call the genric aws_request() with API Version, and Action in query string

for (service, api_version) in {(:sqs, "2012-11-05"),
                               (:sns, "2010-03-31"),
                               (:ec2, "2014-02-01"),
                               (:iam, "2010-05-08"),
                               (:sdb, "2009-04-15")}
    eval(quote
        function ($service)(aws::Dict, action::String, query::Dict)
            aws_request(merge(aws,   {"service" => string($service)}),
                        merge(query, {"Version" => $api_version,
                                      "Action"  => action}))
        end
    end)
end


# S3 REST API request.
# Different to aws_request() because: S3 has a differnt endpoint URL scheme;
# action is indicated by HTTP GET/PUT/DELETE; optional parameters are passed
# in the URL query string and or as HTTP headers (e.g. Content-Type).

function s3(aws, verb, bucket="";
            headers=Dict(), path="", query=Dict(), version="", content="")

    if version != ""
        query["versionId"] = version
    end
    query = format_query_str(query)
    
    resource = "/$path$(query == "" ? "" : "?$query")"
    url = "$(s3_endpoint(aws["region"], bucket))$resource"

    aws_attempt(AWSRequest(merge(aws, {"service" => "s3"}),
                           verb, url, resource, headers, content))
end


# DynamoDB API request.
# Variation of generic aws_request(). Operation (e.g. PutItem, GetItem) is
# passed in x-amz-target header. API parameters are passed as JSON POST data.
# Response is JSON data.

function dynamodb(aws, operation, json)

    ddb = merge(aws,{"service" => "dynamodb"})

    r = aws_request(ddb, query = json, headers = {
        "x-amz-target" => "DynamoDB_20120810.$operation",
        "Content-Type" => "application/x-amz-json-1.0"
    })

    @assert r.headers["x-amz-crc32"] == string(crc32(r.data))
    JSON.parse(r.data)
end

# SNS API Request for "topic".
# Conveniance method to set SNS topic name query parameters.

function sns(aws::Dict, action::String, topic::String, query=Dict())

    sns(aws, action, merge(query, {"Name"     => topic,
                                   "TopicArn" => arn(aws, "sns", topic)}))
end


#------------------------------------------------------------------------------#
# S3 API. 
#------------------------------------------------------------------------------#


export s3_put, s3_get, s3_exists, s3_delete, s3_copy, s3_create_bucket,
       s3_enable_versioning, s3_delete_bucket, s3_list_buckets,
       s3_list_objects, s3_list_versions, s3_get_meta, s3_purge_versions


function s3_get(aws, bucket, path; version="")

    r = s3(aws, "GET", bucket; path = path, version = version)
    return r.data
end


function s3_exists(aws, bucket, path; version="")

    @safe try

        s3(aws, "GET", bucket; path = path,
                               headers = {"Range" => "bytes=0-0"},
                               version = version)
        return true

    catch e
        @trap e if e.code in {"NoSuchKey", "AccessDenied"}
            return false
        end
    end
end


function s3_delete(aws, bucket, path; version="")

    s3(aws, "DELETE", bucket; path = path, version = version)
end


function s3_copy(aws, bucket, path; to_bucket="", to_path="")

    s3(aws, "PUT", to_bucket; path = to_path,
                              headers = {"x-amz-copy-source" => "/$bucket/$path"})
end


function s3_create_bucket(aws, bucket)

    println("""Creating Bucket "$bucket"...""")

    @safe try

        if aws["region"] == "us-east-1"

            s3(aws, "PUT", bucket)

        else

            s3(aws, "PUT", bucket;
                headers = {"Content-Type" => "text/plain"},
                content = """
                <CreateBucketConfiguration
                             xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
                    <LocationConstraint>$(aws["region"])</LocationConstraint>
                </CreateBucketConfiguration>""")
        end

    catch e
        @trap e if e.code == "BucketAlreadyOwnedByYou" end
    end
end


function s3_enable_versioning(aws, bucket)

    s3(aws, "PUT", bucket;
       query = {"versioning" => ""},
       content = """
       <VersioningConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/"> 
           <Status>Enabled</Status> 
       </VersioningConfiguration>""")
end


s3_delete_bucket(aws, bucket) = s3(aws, "DELETE", bucket)


function s3_list_buckets(aws)

    r = s3(aws,"GET")
    r = parse_xml(r.data)
    list(r, "Buckets", "Bucket", "Name")
end


function s3_list_objects(aws, bucket, path = "")

    more = true
    objects = {}
    marker = ""

    while more

        q = Dict()
        if path != ""
            q["delimiter"] = "/"
            q["prefix"] = path
        end
        if marker != ""
            q["key-marker"] = marker
        end

        r = s3(aws, "GET", bucket; query = q)
        r = parse_xml(r.data)
        more = get(r, "IsTruncated") == "true"
        for e in get_elements_by_tagname(root(r), "Contents")

            o = Dict()
            for field in {"Key", "LastModified", "ETag", "Size"}
                o[field] = content(find_element(e, field))
            end
            push!(objects, o)
            marker = o["Key"]
        end
    end

    return objects
end


function s3_list_versions(aws, bucket, path="")

    more = true
    versions = {}
    marker = ""

    while more

        query = {"versions" => "", "prefix" => path}
        if marker != ""
            query["key-marker"] = marker
        end

        r = s3(aws, "GET", bucket; query = query)
        r = parse_xml(r.data)
        more = get(r, "IsTruncated") == "true"

        for e in child_elements(root(r))

            if name(e) in {"Version", "DeleteMarker"}

                version = {"state" => name(e)}
                for e in child_elements(e)
                    version[name(e)] = content(e)               
                end
                push!(versions, version)
                marker = version["Key"]
            end
        end
    end
    return versions
end


function s3_get_meta(aws, bucket, path; version="")

    res = s3(aws, "GET", bucket;
             path = path,
             headers = {"Range" => "bytes=0-0"},
             version = version)
    return res.headers
end
    

function s3_purge_versions(aws, bucket, path="", pattern="")

    for v in s3_list_versions(aws, bucket, path)
        if pattern == "" || ismatch(pattern, v["Key"])
            if v["IsLatest"] != "true"
                s3_delete(aws, bucket, v["Key"]; version = v["VersionId"])
            end
        end
    end
end


function s3_put(aws, bucket, path, data, data_type="")

    if data_type == ""
        data_type = "application/octet-stream"
        for (e, t) in {
            (".pdf",  "application/pdf"),
            (".csv",  "text/csv"),
            (".txt",  "text/plain"),
            (".log",  "text/plain"),
            (".dat",  "application/octet-stream"),
            (".gz",   "application/octet-stream"),
            (".bz2",  "application/octet-stream"),
        }    
            if ismatch(e * "\$", path)
                data_type = t
                break
            end
        end
    end

    s3(aws, "PUT", bucket;
       path=path,
       headers={"Content-Type" => data_type},
       content=data)
end


#=
proc sign_aws_s3_url {aws bucket path seconds} {
    aws_attempt sign_aws_s3_url_attempt $aws $bucket $path $seconds
}


proc sign_aws_s3_url_attempt {aws bucket path seconds} {
    # Signed URL that grants access to "path" for "seconds".

    dset query AWSAccessKeyId [get $aws AWSAccessKeyId]
    dset query x-amz-security-token [get $aws AWSToken]
    dset query Expires [expr {[clock seconds] + $seconds}]
    dset query response-content-disposition attachment

    set digest "GET\n\n\n[get $query Expires]\n"
    append digest "x-amz-security-token:[get $query x-amz-security-token]\n"
    append digest "/$bucket/$path?response-content-disposition=attachment"
    dset query Signature [sign_aws_string $aws sha1 $digest]

    return [aws_s3_endpoint $bucket]$path?[qstring $query]
}
=#



#------------------------------------------------------------------------------#
# SQS API. See http://aws.amazon.com/documentation/sqs/
#------------------------------------------------------------------------------#

export sqs_get_queue, sqs_create_queue, sqs_delete_queue, 
       sqs_send_message, sqs_send_message_batch, sqs_receive_message,
       sqs_delete_message, sqs_flush, sqs_get_queue_attributes, sqs_count,
       sqs_busy_count


# SQS Queue Lookup.
# Find queue URL, return a revised "aws" dict that captures the URL path.

function sqs_get_queue(aws, name)

    @safe try

        r = sqs(aws,"GetQueueUrl",{"QueueName" => name})

        url = get(parse_xml(r.data), "GetQueueUrlResult")
        return merge(aws, {"path" => URI(url).path})

    catch e
        @trap e if e.code == "AWS.SimpleQueueService.NonExistentQueue"
            return nothing
        end
    end
end


sqs_name(q) = split(q["path"], "/")[3]
sqs_arn(q) = arn(q, "sqs", sqs_name(q))


# Create new queue with "name".
# args: VisibilityTimeout, MessageRetentionPeriod, DelaySeconds etc

function sqs_create_queue(aws, name, options::Dict=Dict())

    println("""Creating SQS Queue "$name"...""")

    attributes = Dict()
    
    for (i, k) in enumerate(keys(options))
        push(attributes, ("Attribute.$i.Name", n))
        push(attributes, ("Attribute.$i.Value", options[n]))
    end

    @with_retry_limit 4 try

        r = sqs(aws, "CreateQueue",
                            merge(attributes, {"QueueName" => name}))
        url = get(parse_xml(r.data), "QueueUrl")
        return merge(aws, {"path" => URI(url).path})

    catch e

        if typeof(e) == AWSException

            if (e.code == "QueueAlreadyExists")
                sqs_delete_queue(aws, name)
                @retry
            end

            if (e.code == "AWS.SimpleQueueService.QueueDeletedRecently")
                println("""Waiting 1 minute to re-create Queue "$name"...""")
                sleep(60)
                @retry
            end
        end
    end

    assert(false) # Unreachable.
end


function sqs_delete_queue(queue)

    @safe try

        println("Deleting SQS Queue $(aws["path"])")
        sqs(aws, "DeleteQueue")

    catch e
        @trap e if e.code == "AWS.SimpleQueueService.NonExistentQueue" end
    end
end


function sqs_send_message(queue, message)

    sqs (queue, "SendMessage", {"MessageBody" => message,
                                "MD5OfMessageBody" => string(md5_hash(message))})
end


function sqs_send_message_batch(queue, messages)

    batch = {}
    
    for (i, message) in enumerate(messages)
        push(batch, ("SendMessageBatchRequestEntry.$i.Id",  i))
        push(batch, ("SendMessageBatchRequestEntry.$i.MessageBody", message))
    end
    sqs(queue, "SendMessageBatch", batch)
end


function sqs_receive_message(queue)

    r = sqs(queue, "ReceiveMessage", {"MaxNumberOfMessages" => "1"})
    xdoc = parse_xml(r.data)

    handle = get(xdoc, "ReceiptHandle")
    if handle == ""
        return nothing
    end

    message = get(xdoc, "Body")
    @assert get(xdoc, "MD5OfBody") == bytes2hex(md5_hash(message))

    return {"message" => message, "handle" => handle}
end
    

function sqs_delete_message(queue, message)

    sqs(queue, "DeleteMessage", {"ReceiptHandle" => message["handle"]})
end


function sqs_flush(queue)

    while (m = sqs_receive_message(queue)) != nothing
        sqs_delete_message(queue, m)
    end
end


function sqs_get_queue_attributes(queue)

    @safe try

        r = sqs(queue, "GetQueueAttributes", {"AttributeName.1" => "All"})

        return dict(parse_xml(r.data), "GetQueueAttributesResult", "Attribute")

    catch e
        @trap e if e.code == "AWS.SimpleQueueService.NonExistentQueue"
            return nothing
        end
    end
end


function sqs_count(queue)
    
    int(sqs_get_queue_attributes(queue)["ApproximateNumberOfMessages"])
end


function sqs_busy_count(queue)
    
    int(sqs_get_queue_attributes(queue)["ApproximateNumberOfMessagesNotVisible"])
end



#------------------------------------------------------------------------------#
# SNS API. See http://aws.amazon.com/documentation/sns/
#------------------------------------------------------------------------------#


export sns_delete_topic, sns_create_topic, sns_subscribe_sqs,
       sns_subscribe_email, sns_publish


sns_arn(aws, topic_name) = arn(aws, "sns", topic_name)


function sns_delete_topic(aws, topic_name)

    sns(aws, "DeleteTopic", topic_name, {"Name" => topic_name})
end


function sns_create_topic(aws, topic_name)

    sns(aws, "CreateTopic", {"Name" => topic_name})
end


function sns_subscribe_sqs(aws, topic_name, queue; raw=flase)

    r = sns(aws, "Subscribe", topic_name, {"Endpoint" => sqs_arn(queue),
                                           "Protocol" => sqs})
    if raw
        sns(aws, "SetSubscriptionAttributes", topic_name, {
            "SubscriptionArn" => get(parse_xml(r.data), "SubscriptionArn"),
            "AttributeName" => "RawMessageDelivery",
            "AttributeValue" => "true"
        })
    end

    sqs(queue, "SetQueueAttributes", {
        "Attribute.Name" => "Policy",
        "Attribute.Value" => """{
          "Version": "2008-10-17",
          "Statement": [
            {
              "Effect": "Allow",
              "Principal": {
                "AWS": "*"
              },
              "Action": "SQS:SendMessage",
              "Resource": "$(sqs_arn(queue))",
              "Condition": {
                "ArnEquals": {
                  "aws:SourceArn": "$(sns_arn(aws, topic_name))"
                }
              }
            }
          ]
        }"""
    })
end


function sns_subscribe_email(aws, topic_name, email)

    sns(aws, topic_name, "Subscribe", {"Endpoint" => email,
                                       "Protocol" => "email"})
end


function sns_publish(aws, topic_name, message, subject="")

    args = {"Message" => message}
    if subject != ""
        args["Subject"] = subject[1:100]
    end
    sns(aws, "Publish", topic_name, args)
end



#------------------------------------------------------------------------------#
# Convenience functions
#------------------------------------------------------------------------------#


import Base: readlines, ismatch


function readlines(filename::String)

    f = open(filename)
    r = readlines(f)
    close(f)
    return r
end


ismatch(pattern::String,s::String) = ismatch(Regex(pattern), s)



end # module



#==============================================================================#
# End of file.
#==============================================================================#

