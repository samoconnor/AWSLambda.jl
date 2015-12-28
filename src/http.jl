#==============================================================================#
# http.jl
#
# HTTP Requests with retry/back-off and HTTPException.
#
# Copyright Sam O'Connor 2014 - All rights reserved
#==============================================================================#


import URIParser: URI, query_params
import Requests: format_query_str, process_response, open_stream, BodyDone,
                 data, mimetype
import HttpCommon: Request, Response, STATUS_CODES
import Base: show, UVError


export HTTPException


type HTTPException <: Exception
    request
    response
end

const http_debug = false


http_status(e::HTTPException) = e.response.status
headers(e::HTTPException) = e.response.headers
http_message(e::HTTPException) = bytestring(e.response.data)
content_type(e::HTTPException) = get(e.response.headers, "Content-Type", "")


function show(io::IO,e::HTTPException)

    println(io, string("HTTP ", http_status(e), " -- ",
                       e.request.method, " ", e.request.uri, " -- ",
                        http_message(e)))
end


function http_attempt(request::Request, return_stream=false)

    if http_debug
        println("$(request.method) $(request.uri)")
        dump(request.headers)
        println(bytestring(request.data))
    end

    # Start HTTP transaction...
    stream = open_stream(request)

    # Send request data...
    if length(request.data) > 0
        write(stream, request.data)
    end

    # Wait for response...
    stream = process_response(stream)
    response = stream.response

    # Read result...
    if !return_stream
        response.data = readbytes(stream)

        if http_debug
            println(response.status)
            dump(response.headers)
            println(bytestring(response.data))
        end
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

    request.headers["Content-Length"] = string(length(request.data))

    @repeat 4 try 

        return http_attempt(request, return_stream)

    catch e
        @delay_retry if typeof(e) == UVError end
        @delay_retry if http_status(e) < 200 &&
                        http_status(e) >= 500 end
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

