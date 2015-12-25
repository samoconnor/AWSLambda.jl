#==============================================================================#
# OCAWS.jl
#
# Copyright Sam O'Connor 2014 - All rights reserved
#==============================================================================#


#FIXME depends on URIParser.jl commit 2bc38088257df968e2b7a4e2e14cc8440bf341e1


module OCAWS


using Retry


include("ocdict.jl")
include("http.jl")
include("xml.jl")
include("AWSException.jl")


export sqs, sns, ec2, iam, sdb, s3,
       AWSConfig, aws_config, AWSRequest

typealias AWSConfig SymDict

function aws_config(;access_key_id=nothing,
                     secret_key=nothing,
                     region="us-east-1",
                     args...)

    config = SymDict(args)
    config[:region] = region
    if access_key_id != nothing
        config[:creds] = @symdict(access_key_id, secret_key)
    else
        config[:creds] = SymDict()
    end
    return config
end



#------------------------------------------------------------------------------#
# AWSRequest to Request.jl conversion.
#------------------------------------------------------------------------------#


typealias AWSRequest SymDict


# Construct a HTTP POST request dictionary for "servce" and "query"...
#
# e.g.
# aws = SymDict{:creds => SymDict{:access_key_id => "xx", secret_key => "xx"},
#               :region => "ap-southeast-2"}
#
# post_request(aws, "sdb", "2009-04-15", StrDict("Action" => "ListDomains"))
#
# Dict{Symbol, Any}(
#     :creds    => Dict{Symbol,Any}(:access_key_id=>"xx",:secret_key=>"xx")
#     :verb     => "POST"
#     :url      => "http://sdb.ap-southeast-2.amazonaws.com/"
#     :content  => "Version=2009-04-15&Action=ListDomains"
#     :resource => "/"
#     :region   => "ap-southeast-2"
#     :service  => "sdb"
# )

function post_request(aws::AWSConfig,
                      service::ASCIIString,
                      version::ASCIIString,
                      query::StrDict)

    resource = get(aws, :resource, "/")
    url = aws_endpoint(service, aws[:region]) * resource
    content = format_query_str(merge(query, "Version" => version))

    @symdict(verb = "POST", service, resource, url, query, content, aws...)
end


# Convert AWSRequet dictionary into Request (Requests.jl)

function Request(r::AWSRequest)
    Request(r[:verb], r[:resource], r[:headers], r[:content], URI(r[:url]))
end

function http_request(r::AWSRequest, args...)

    http_request(Request(r), get(r, :return_stream, false))
end


function dump_aws_request(r::AWSRequest)

    action = r[:verb]
    if haskey(r, :query) && haskey(r[:query], "Action")
        action = r[:query]["Action"]
    end
    println("$(r[:service]).$action $(r[:resource])")
end


#------------------------------------------------------------------------------#
# AWSRequest retry loop
#------------------------------------------------------------------------------#


include("sign.jl")


function do_request(r::AWSRequest)

    # Try request 3 times to deal with possible Redirect and ExiredToken...
    @repeat 3 try

        # Configure default headers...
        if !haskey(r, :headers)
            r[:headers] = StrDict()
        end
        r[:headers]["User-Agent"] = "JuliaAWS.jl/0.0.0"
        r[:headers]["Host"]       = URI(r[:url]).host
        if !haskey(r[:headers], "Content-Type") && r[:verb] == "POST"
            r[:headers]["Content-Type"] =
                "application/x-www-form-urlencoded; charset=utf-8"
        end

        # Load local system credentials if needed...
        if !haskey(r, :creds) || !haskey(r[:creds], :access_key_id)
            update_instance_credentials!(r[:creds])
        end

        # Use credentials to sign request...
        sign!(r)

        dump_aws_request(r)

        return http_request(r)

    catch e

        # Handle HTTP Redirect...
        @retry if http_status(e) in [301, 302, 307] && haskey(headers(e),
                                                              "Location")
            r[:url] = headers(e)["Location"]
        end

        e = AWSException(e)

        # Handle ExpiredToken...
        @retry if e.code == "ExpiredToken"
            delete(r[:creds], :access_key_id)
        end
    end

    assert(false) # Unreachable.
end



#------------------------------------------------------------------------------#
# AWS Endpoints
#------------------------------------------------------------------------------#


# e.g.
#
#   aws_endpoint("sqs", "eu-west-1")
#   "http://sqs.eu-west-1.amazonaws.com"

function aws_endpoint(service, region="", prefix="")

    protocol = "http"

    # HTTPS where required...
    if service in ["iam", "sts", "lambda"]
        protocol = "https"
    end

    # Identity and Access Management API has no region suffix...
    if service in ["iam", "sts"]
        region = ""
    end

    # No region sufix for s3 or sdb in default region...
    if region == "us-east-1" && service in ["s3", "sdb"]
        region = ""
    end

    # Append region...
    if region != ""
        if service == "s3"
            service = "$service-$region"
        else
            service = "$service.$region"
        end
    end

    # Optional bucket prefix...
    if prefix != ""
        service = "$prefix.$service"
    end

    "$protocol://$service.amazonaws.com"
end



#------------------------------------------------------------------------------#
# Amazon Resource Names
#------------------------------------------------------------------------------#


export aws_account_number, arn


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



#------------------------------------------------------------------------------#
# EC2 Metadata
#------------------------------------------------------------------------------#


import JSON: JSON, json

export localhost_is_ec2, ec2_metadata, ec2_get_instance_credentials


ec2(aws; args...) = do_request(post(aws, "ec2", "2014-02-01", StrDict(args)))


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


function update_ec2_instance_credentials!(creds)

    @assert localhost_is_ec2()

    info  = ec2_metadata("iam/info")
    info  = JSON.parse(info)

    name  = ec2_metadata("iam/security-credentials/")
    new_creds = ec2_metadata("iam/security-credentials/$name")
    new_creds = JSON.parse(new_creds)

    creds[:access_key_id] = new_creds["AccessKeyId"]
    creds[:secret_key]    = new_creds["SecretAccessKey"]
    creds[:token]         = new_creds["Token"]
    creds[:user_arn]      = info["InstanceProfileArn"]
end



#------------------------------------------------------------------------------#
# Lambda Metadata
#------------------------------------------------------------------------------#

using IniFile

localhost_is_lambda() = haskey(ENV, "LAMBDA_TASK_ROOT")


function update_instance_credentials!(creds)

    if localhost_is_ec2()

        update_ec2_instance_credentials!(aws)

    elseif haskey(ENV, "AWS_ACCESS_KEY_ID")

        creds[:access_key_id] = ENV["AWS_ACCESS_KEY_ID"]
        creds[:secret_key]    = ENV["AWS_SECRET_ACCESS_KEY"]
        creds[:token]         = ENV["AWS_SESSION_TOKEN"]

    elseif isfile("$(ENV["HOME"])/.aws/credentials")

        ini = read(Inifile(), "$(ENV["HOME"])/.aws/credentials")

        creds[:access_key_id] = get(ini, "default", "aws_access_key_id")
        creds[:secret_key]    = get(ini, "default", "aws_secret_access_key")
        delete!(creds, :token)
    end
end



#------------------------------------------------------------------------------#
# Service APIs
#------------------------------------------------------------------------------#


include("s3.jl")
include("sqs.jl")
include("sns.jl")
include("iam.jl")
include("sdb.jl")
include("ec2.jl")
include("lambda.jl")



end # module


#==============================================================================#
# End of file.
#==============================================================================#
