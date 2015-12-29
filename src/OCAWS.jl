#==============================================================================#
# OCAWS.jl
#
# Copyright Sam O'Connor 2014 - All rights reserved
#==============================================================================#


module OCAWS

export sqs, sns, ec2, iam, sdb, s3, AWSConfig, aws_config, AWSRequest


using Retry
using SymDict
using LightXML


include("AWSException.jl")
include("AWSCredentials.jl")
include("names.jl")
include("http.jl")
include("s3.jl")
include("sqs.jl")
include("sns.jl")
include("iam.jl")
include("sdb.jl")
include("ec2.jl")
include("lambda.jl")



#------------------------------------------------------------------------------#
# Configuration.
#------------------------------------------------------------------------------#


function aws_config(;creds=AWSCredentials(), region="us-east-1", args...)

    @SymDict(creds, region, args...)
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
#     :headers  => Dict("Content-Type" =>
#                       "application/x-www-form-urlencoded; charset=utf-8)
#     :content  => "Version=2009-04-15&ContentType=JSON&Action=ListDomains"
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

    merge!(query, "Version" => version, "ContentType" => "JSON")
    headers = Dict("Content-Type" =>
                   "application/x-www-form-urlencoded; charset=utf-8")
    content = format_query_str(query)

    @SymDict(verb = "POST", service, resource, url, headers, query, content,
             aws...)
end


# Convert AWSRequest dictionary into Requests.Request (Requests.jl)

function Request(r::AWSRequest)
    Request(r[:verb], r[:resource], r[:headers], r[:content], URI(r[:url]))
end


# Call http_request for AWSRequest.

function http_request(request::AWSRequest, args...)
    http_request(Request(request), get(request, :return_stream, false))
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

        # Default headers...
        r[:headers]["User-Agent"] = "JuliaAWS.jl/0.0.0"
        r[:headers]["Host"]       = URI(r[:url]).host

        # Load local system credentials if needed...
        if !haskey(r, :creds) || r[:creds].token == "ExpiredToken"
            r[:creds] = AWSCredentials()
        end

        # Use credentials to sign request...
        sign!(r)

        dump_aws_request(r)

        # Send the request...
        response = http_request(r)

    catch e

        # Handle HTTP Redirect...
        @retry if http_status(e) in [301, 302, 307] &&
                  haskey(headers(e), "Location")
            r[:url] = headers(e)["Location"]
        end

        e = AWSException(e)

        # Handle ExpiredToken...
        @retry if e.code == "ExpiredToken"
            r[:creds].token = "ExpiredToken"
        end
    end

    # If there is reponse data check for (and parse) XML or JSON...
    if typeof(response) == Response && length(response.data) > 0

        mime = get(mimetype(response))

        if ismatch(r"/xml$", mime)
            response =  LightXML.parse_string(bytestring(response))
        end

        if ismatch(r"/json$", mime)
            response = JSON.parse(bytestring(response))
            @protected try 
                action = r[:query]["Action"]
                response = response[action * "Response"]
                response = response[action * "Result"]
            catch e
                @ignore if typeof(e) == KeyError end
            end
        end
    end

    return response
end



end # module


#==============================================================================#
# End of file.
#==============================================================================#
