#==============================================================================#
# OCAWS.jl
#
# Copyright Sam O'Connor 2014 - All rights reserved
#==============================================================================#


module OCAWS


using Retry
using SymDict
using LightXML


include("http.jl")
include("AWSException.jl")
include("aws_names.jl")
include("AWSCredentials.jl")


export sqs, sns, ec2, iam, sdb, s3,
       AWSConfig, aws_config, AWSRequest


function aws_config(;creds=AWSCredentials(), region="us-east-1", args...)

    @SymDict(creds, region, args...)
end


function arn(aws::SymbolDict, service,
                              resource,
                              region=get(aws, :region, ""),
                              account=aws_account_number(aws[:creds]))

    arn(service, resource, region, account)
end



#------------------------------------------------------------------------------#
# AWSRequest to Request.jl conversion.
#------------------------------------------------------------------------------#


typealias AWSRequest SymbolDict


# Construct a HTTP POST request dictionary for "servce" and "query"...
#
# e.g.
# aws = Dict(:creds  => AWSCredentials(),
#            :region => "ap-southeast-2")
#
# post_request(aws, "sdb", "2009-04-15", StrDict("Action" => "ListDomains"))
#
# Dict{Symbol, Any}(
#     :creds    => creds::AWSCredentials
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
                      query::Dict)

    resource = get(aws, :resource, "/")
    url = aws_endpoint(service, aws[:region]) * resource
    content = format_query_str(merge(query, "Version" => version))

    @SymDict(verb = "POST", service, resource, url, query, content, aws...)
end


# Convert AWSRequest dictionary into Request (Requests.jl)

function Request(r::AWSRequest)
    Request(r[:verb], r[:resource], r[:headers], r[:content], URI(r[:url]))
end


# Call http_request for AWSRequest.

function http_request(r::AWSRequest, args...)

    return_stream = get(r, :return_stream, false)

    r = http_request(Request(r), return_stream)

    if !return_stream && length(r.data) > 0
        t = get(mimetype(r))
        if ismatch(r"/xml$", t)
            r = LightXML.parse_string(bytestring(r))
        end
        if ismatch(r"/json$", t)
            r = JSON.parse(bytestring(r))
        end
    end
    return r
end


# Pretty-print AWSRequest dictionary.

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
            r[:headers] = Dict()
        end
        r[:headers]["User-Agent"] = "JuliaAWS.jl/0.0.0"
        r[:headers]["Host"]       = URI(r[:url]).host
        if !haskey(r[:headers], "Content-Type") && r[:verb] == "POST"
            r[:headers]["Content-Type"] =
                "application/x-www-form-urlencoded; charset=utf-8"
        end

        # Load local system credentials if needed...
        if !haskey(r, :creds) || r[:creds].token == "ExpiredToken"
            r[:creds] = AWSCredentials()
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
            r[:creds].token = "ExpiredToken"
        end
    end

    assert(false) # Unreachable.
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
