#==============================================================================#
# OCAWS.jl
#
# Copyright Sam O'Connor 2014 - All rights reserved
#==============================================================================#


module OCAWS


include("ocdict.jl")
include("retry.jl")
include("trap.jl")
include("http.jl")
include("xml.jl")
include("AWSException.jl")


export sqs, sns, ec2, iam, sdb, s3,
       AWSRequest


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

function post_request(aws::AWSRequest,
                      service::ASCIIString,
                      version::ASCIIString,
                      query::StrDict)

    resource = get(aws, :resource, "/")
    url = aws_endpoint(service, aws[:region]) * resource
    content = format_query_str(merge(query, "Version" => version))

    merge(aws, @symdict(verb = "POST", service, resource, url, content))
end


# Convert AWSRequet dictionary into Request (Requests.jl)

function Request(r::AWSRequest)
    Request(r[:verb], r[:resource], r[:headers], r[:content], URI(r[:url]))
end

function http_request(r::AWSRequest, args...)

    http_request(Request(r), get(r, :return_stream, false))
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
        if !haskey(r[:creds], :access_key_id)
            update_instance_credentials!(r[:creds])
        end

        # Use credentials to sign request...
        sign!(r)

        return http_request(r)

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


function update_instance_credentials!(aws)

    if localhost_is_ec2()
        update_ec2_instance_credentials!(aws)
    else 
        aws[:access_key_id] = ENV["AWS_ACCESS_KEY_ID"]
        aws[:secret_key]    = ENV["AWS_SECRET_ACCESS_KEY"]
        aws[:token]         = ENV["AWS_SESSION_TOKEN"]
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
include("lambda.jl")



end # module


#==============================================================================#
# End of file.
#==============================================================================#
