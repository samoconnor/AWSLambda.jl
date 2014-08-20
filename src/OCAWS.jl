#==============================================================================#
# OCAWS.jl
#
# Copyright Sam O'Connor 2014 - All rights reserved
#==============================================================================#


module OCAWS


include("retry.jl")
include("trap.jl")
include("http.jl")
include("xml.jl")
include("AWSException.jl")


import Zlib: crc32


export sqs, sns, ec2, iam, sdb, s3, dynamodb 


# Generic POST Query API request.
#
# URL points to service endpoint. Query string is passed as POST data.
# Works for everything except s3...

function aws_request(aws; headers=Dict(), query="")

    path = get(aws, "path", "/")
    url = "$(aws_endpoint(aws["service"], aws["region"]))$path"

    aws_attempt(AWSRequest(aws, "POST", url, path, headers, query))
end

aws_request(aws, query) = aws_request(aws; query = format_query_str(query))



# SQS, SNS, EC2, and SDB API Requests.
#
# Call the genric aws_request() with API Version, and Action in query string

for (service, api_version) in {
    (:sqs, "2012-11-05"),
    (:sns, "2010-03-31"),
    (:ec2, "2014-02-01"),
    (:sdb, "2009-04-15"),
}
    eval(quote

        function ($service)(aws::Dict, action::String, query::Dict)

            aws_request(merge(aws,   {"service" => string($service)}),
                        merge(query, {"Version" => $api_version,
                                      "Action"  => action}))
        end
    end)
end


# IAM and STS API Requests.
#
# Different because region must be overridden to "us-east-1"

for (service, api_version) in {
    (:iam, "2010-05-08"),
    (:sts, "2011-06-15"),
}
    eval(quote

        function ($service)(aws::Dict, action::String, query::Dict)

            aws_request(merge(aws,   {"service" => string($service),
                                      "region" => "us-east-1"}),
                        merge(query, {"Version" => $api_version,
                                      "Action"  => action}))
        end
    end)
end


# S3 REST API request.
#
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
#
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

http_request(r::AWSRequest) = http_request(URI(r.url), Request(r))


include("sign.jl")


#------------------------------------------------------------------------------#
# AWSRequest retry loop
#------------------------------------------------------------------------------#


function aws_attempt(request::AWSRequest)

    # Try request 3 times to deal with possible Redirect and ExiredToken...
    @with_retry_limit 3 try 

        if !haskey(request.aws, "access_key_id") && localhost_is_ec2()
            request.aws = ec2_get_instance_credentials(request.aws)
        end

        request.headers["User-Agent"] = "JuliaAWS.jl/0.0.0"
        request.headers["Host"]       = URI(request.url).host

        if !haskey(request.headers, "Content-Type") && request.verb == "POST"
            request.headers["Content-Type"] = 
                "application/x-www-form-urlencoded; charset=utf-8"
        end

        sign_aws_request!(request)

        request.headers["Content-Length"] = length(request.content) |> string

        return http_request(request)

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

    protocol = "http"

    # Identity and Access Management API: https with no region suffix...
    if service in {"iam", "sts"}
        protocol = "https"
        region = ""
    end

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

import JSON: JSON, json

export localhost_is_ec2, ec2_metadata, ec2_get_instance_credentials

function localhost_is_ec2() 

    host = readall(`hostname -f`)
    return ismatch(r"compute.internal$", host) ||
           ismatch(r"ec2.internal$", host)
end


# Lookup EC2 meta-data "key".
# Must be called from an EC2 instance.
# http://docs.aws.amazon.com/AWSEC2/latest/UserGuide/AESDG-chapter-instancedata.html

function ec2_metadata(key)

    @assert localhost_is_ec2()

    r = http_request("169.254.169.254", "latest/meta-data/$key").data
    return r.data
end


function ec2_get_instance_credentials(aws)

    @assert localhost_is_ec2()

    info = ec2_metadata("iam/info")
    info = JSON.parse(info)

    name = ec2_metadata("iam/security-credentials/")
    creds = ec2_metadata("iam/security-credentials/$name")
    creds = JSON.parse(creds)

    merge(aws, {"access_key_id" => creds["AccessKeyId"],
                "secret_key"    => creds["SecretAccessKey"],
                "token"         => creds["Token"],
                "user_arn"      => info["InstanceProfileArn"]})
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


include("s3.jl")
include("sqs.jl")
include("sns.jl")
include("iam.jl")
include("sdb.jl")


end # module



#==============================================================================#
# End of file.
#==============================================================================#
