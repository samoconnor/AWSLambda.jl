#==============================================================================#
# http.jl
#
# HTTP Requests with retry/back-off and HTTPException.
#
# Copyright Sam O'Connor 2014 - All rights reserved
#==============================================================================#


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


function http_attempt(uri::URI, request::Request)

    # Do HTTP transaction...
    response = process_response(open_stream(uri, request))

    # Return on success...
    if response.finished && response.status in {200, 201, 204, 206}
        return response
    end

    # Throw error on failure...
    throw(HTTPException(uri, request, response))
end


function http_request(uri::URI, request::Request)

    request.headers["Content-Length"] = length(request.content) |> string

    delay = 0.05

    @with_retry_limit 4 try 

        #println(uri)
        #println(request.headers)
        #println(request.data)
        return http_attempt(uri, request)

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


function http_request(host, resource)

    http_request(URI("http://$host/$resource"),
                 Request("GET", resource, (String=>String)[], ""))
end



#==============================================================================#
# End of file.
#==============================================================================#

