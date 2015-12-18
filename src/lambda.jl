#==============================================================================#
# lambda.jl
#
# AWS Lambda API.
#
# See http://docs.aws.amazon.com/lambda/latest/dg/API_Reference.html
#
# Copyright Sam O'Connor 2014 - All rights reserved
#==============================================================================#

using JSON

export functions, create_function, update_function


parse_json(s::Array{UInt8,1}) = JSON.parse(bytestring(s))


# Lambda REST API request.

function lambda(aws, verb; path="", query="")

    resource = "/2015-03-31/functions/$path"

    r = merge(aws, @symdict(
        service  = "lambda",
        url      = aws_endpoint("lambda", aws[:region]) * resource,
        content  = query == "" ? "" : json(query),
        resource,
        verb
    ))

    r = do_request(r)
    SymDict(parse_json(r.data))
end


functions(aws) = [SymDict(f) for f in lambda(aws, "GET")[:Functions]]


function create_function(aws, name, S3Bucket, S3Key;
                         Handler="main",
                         Role=role_arn(aws, "lambda_basic_execution"),
                         Runtime="python2.7",
                         Timeout=300,
                         args...)

    lambda(aws, "POST",
           query = merge!(SymDict(args),
                         @symdict(FunctionName = name,
                                  Code = @symdict(S3Key, S3Bucket),
                                  Handler,
                                  Role,
                                  Runtime,
                                  Timeout)))
end


function update_function(aws, name, S3Bucket, S3Key)

    lambda(aws, "PUT", path="$name/code",
                      query=@symdict(S3Key, S3Bucket))
end




#==============================================================================#
# End of file.
#==============================================================================#
