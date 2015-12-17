#==============================================================================#
# OCAWS.jl
#
# Copyright Sam O'Connor 2014 - All rights reserved
#==============================================================================#


module OCAWS


typealias StrDict Dict{ASCIIString,ASCIIString}
typealias SymDict Dict{Symbol,Any}

typealias AWSRequest SymDict

symdict(;args...) = SymDict(args)

macro symdict(args...)

    if length(args) == 1
        args = args[1].args
    end

    args = [esc(isa(a, Expr) ? a : :($a=$a)) for a in args]
    for i in 1:length(args)
        args[i].args[1].head = :kw
    end
    :(symdict($(args...)))
end


include("retry.jl")
include("trap.jl")
include("http.jl")
include("xml.jl")
include("AWSException.jl")


import Zlib: crc32


export sqs, sns, ec2, iam, sdb, s3, sign!,
       StrDict, SymDict, symdict, AWSRequest


# Generic POST Query API request.
#
# URL points to service endpoint. Query string is passed as POST data.
# Works for everything except s3...

function post(aws::Dict,
              service::ASCIIString,
              version::ASCIIString,
              query::StrDict)

    resource = get(aws, :resource, "/")
    url = aws_endpoint(service, aws[:region]) * resource
    content = format_query_str(merge(query, "Version" => version))

    merge(aws, @symdict(verb = "POST", service, resource, url, content))
end


# POST API Requests for each AWS servce.

sqs(aws, query)   = do_request(post(aws, "sqs", "2012-11-05", query))
sqs(aws; args...) = sqs(aws, StrDict(args))

ec2(aws; args...) = do_request(post(aws, "ec2", "2014-02-01", StrDict(args)))
sdb(aws; args...) = do_request(post(aws, "sdb", "2009-04-15", StrDict(args)))
iam(aws; args...) = do_request(post(merge(aws, region = "us-east-1"),
                                         "iam", "2010-05-08", StrDict(args)))
sts(aws; args...) = do_request(post(merge(aws, region = "us-east-1"),
                                         "iam", "2011-06-15", StrDict(args)))


# S3 REST API request.
#
# Different to do_request() because: S3 has a differnt endpoint URL scheme;
# action is indicated by HTTP GET/PUT/DELETE; optional parameters are passed
# in the URL query string and or as HTTP headers (e.g. Content-Type).

function s3(aws, verb, bucket="";
            headers=StrDict(), path="", query=StrDict(), version="", content="",
            return_stream=false)

    if version != ""
        query["versionId"] = version
    end
    query = format_query_str(query)

    resource = "/$path$(query == "" ? "" : "?$query")"
    url = s3_endpoint(aws[:region], bucket) * resource

    r = merge(aws, @symdict(service = "s3",
                            verb,
                            url,
                            resource,
                            headers,
                            content))

    do_request(r, return_stream)
end



#------------------------------------------------------------------------------#
# AWSRequest to Request conversion.
#------------------------------------------------------------------------------#


function Request(r::AWSRequest)
    Request(r[:verb], r[:resource], r[:headers], r[:content], URI(r[:url]))
end

http_request(r::AWSRequest, args...) = http_request(Request(r), args...)


include("sign.jl")



#------------------------------------------------------------------------------#
# AWSRequest retry loop
#------------------------------------------------------------------------------#


function do_request(r::AWSRequest, return_stream=false)

    # Try request 3 times to deal with possible Redirect and ExiredToken...
    @max_attempts 3 try 

        if !haskey(r[:creds], :access_key_id)
            update_instance_credentials!(r[:creds])
        end

        if !haskey(r, :headers)
            r[:headers] = StrDict()
        end

        r[:headers]["User-Agent"] = "JuliaAWS.jl/0.0.0"
        r[:headers]["Host"]       = URI(r[:url]).host

        if !haskey(r[:headers], "Content-Type") && r[:verb] == "POST"
            r[:headers]["Content-Type"] = 
                "application/x-www-form-urlencoded; charset=utf-8"
        end

        sign!(r)

        return http_request(r, return_stream)

    catch e

        if typeof(e) == HTTPException

            # Try again on HTTP Redirect...
            if (status(e) in [301, 302, 307]
            &&  haskey(e.response.headers, "Location"))
                r[:url] = e.response.headers["Location"]
                @retry
            end

            e = AWSException(e)

            # Try again on ExpiredToken error...
            if e.code == "ExpiredToken"
                delete(r[:creds], :access_key_id)
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
    if service in ["iam", "sts"]
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


function aws_account_number(aws)

    if !haskey(aws[:creds], :user_arn)
        aws[:creds][:user_arn] = iam_whoami(aws)
    end
    split(aws[:creds][:user_arn], ":")[5]
end


function arn(aws, service, resource, region=get(aws, :region, ""),
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

    if localhost_is_lambda()
        return false
    end

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


function update_ec2_instance_credentials!(aws)

    @assert localhost_is_ec2()

    info  = ec2_metadata("iam/info")
    info  = JSON.parse(info)

    name  = ec2_metadata("iam/security-credentials/")
    creds = ec2_metadata("iam/security-credentials/$name")
    creds = JSON.parse(creds)

    aws[:access_key_id] = creds["AccessKeyId"]
    aws[:secret_key]    = creds["SecretAccessKey"]
    aws[:token]         = creds["Token"]
    aws[:user_arn]      = info["InstanceProfileArn"]
end



#------------------------------------------------------------------------------#
# Lambda Metadata
#------------------------------------------------------------------------------#


localhost_is_lambda() = haskey(ENV, "LAMBDA_TASK_ROOT")



#------------------------------------------------------------------------------#
# Convenience functions
#------------------------------------------------------------------------------#


import Base: readlines, ismatch, merge

StrDict(d::Array{Any,1}) = StrDict([string(k) => string(v) for (k,v) in d])

merge(d::Associative{Symbol,Any}) = d
merge(d::Associative{Symbol,Any}; args...) = merge(d, SymDict(args))
merge{K,V}(d::Dict{K,V}) = d
merge{K,V}(d::Dict{K,V}, p::Pair{K,V}...) = merge(d, Dict{K,V}(p))


function readlines(filename::AbstractString)

    f = open(filename)
    r = readlines(f)
    close(f)
    return r
end


function update_instance_credentials!(aws)

    if localhost_is_ec2()
        update_ec2_instance_credentials!(aws)
    else 
        aws[:access_key_id] = ENV["AWS_ACCESS_KEY_ID"]
        aws[:secret_key]    = ENV["AWS_SECRET_ACCESS_KEY"]
        aws[:token]         = ENV["AWS_SESSION_TOKEN"]
    end
end


ismatch(pattern::AbstractString,s::AbstractString) = ismatch(Regex(pattern), s)


include("s3.jl")
include("sqs.jl")
include("sns.jl")
include("iam.jl")
include("sdb.jl")


end # module



#==============================================================================#
# End of file.
#==============================================================================#
