#==============================================================================#
# AWSException.jl
#
# Copyright Sam O'Connor 2014 - All rights reserved
#==============================================================================#


import JSON: json


export AWSException


type AWSException <: Exception
    code::AbstractString
    message::AbstractString
    http::HTTPException
end


function show(io::IO,e::AWSException)
    println(io, string(e.code,
                       e.message == "" ? "" : (" -- " * e.message), "\n",
                       e.http))
end


function AWSException(e::HTTPException)

    code = string(status(e))
    message = "AWSException"

    # Extract API error code from Lambda-style JSON error message...
    if content_type(e) == "application/json"
        json = JSON.parse(http_message(e))
        if haskey(json, "message")
            message = json["message"]
        end
    end

    # Extract API error code from JSON error message...
    if content_type(e) == "application/x-amz-json-1.0"
        json = JSON.parse(http_message(e))
        if haskey(json, "__type")
            code = split(json["__type"], "#")[2]
        end
    end

    # Extract API error code from XML error message...
    if (content_type(e) in ["", "application/xml", "text/xml"]
    &&  length(http_message(e)) > 0)
        xml = XML(http_message(e))
        code = get(xml, "Code", code)
        message = get(xml, "Message", message)
    end

    AWSException(code, message, e)
end



#==============================================================================#
# End of file.
#==============================================================================#

