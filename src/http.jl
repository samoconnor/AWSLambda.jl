#==============================================================================#
# http.jl
#
# HTTP Requests with retry/back-off and HTTPException.
#
# Copyright Sam O'Connor 2014 - All rights reserved
#==============================================================================#


import URIParser: URI, query_params
import Requests: format_query_str, process_response, open_stream, BodyDone
import HttpCommon: Request, STATUS_CODES
import Base: show, UVError


export HTTPException


type HTTPException <: Exception
    request
    response
end


status(e::HTTPException) = e.response.status
http_message(e::HTTPException) = bytestring(e.response.data)
content_type(e::HTTPException) = e.response.headers["Content-Type"]


function show(io::IO,e::HTTPException)

    println(io, string("HTTP ", status(e), " -- ",
                       e.request.method, " ", e.request.uri, " -- ",
                        http_message(e)))
end


function http_attempt(request::Request, return_stream=false)

#    println(request)
#    println(bytestring(request.data))

    # Do HTTP transaction...
    stream = open_stream(request)
    if length(request.data) > 0
        write(stream, request.data)
    end
    stream = process_response(stream)
    response = stream.response
    if !return_stream
        response.data = readbytes(stream)
    end

    # Return on success...
    if (stream.state == BodyDone
    &&  response.status in [200, 201, 204, 206])
        return return_stream ? stream : response
    end

    # Throw error on failure...
    throw(HTTPException(request, response))
end


function http_request(request::Request, return_stream=false)

    request.headers["Content-Length"] = length(request.data) |> string

    delay = 0.05

    @max_attempts 4 try 

        #println(request.uri)
        #println(request.headers)
        #println(request.data)
        return http_attempt(request, return_stream)

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


function http_request(host::AbstractString, resource::AbstractString)

    http_request(Request("GET", resource,
                         Dict{AbstractString,AbstractString}[], "",
                         URI("http://$host/$resource")))
end



#==============================================================================#
# End of file.
#==============================================================================#

