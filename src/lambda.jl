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
using ZipFile


export list_lambdas, create_lambda, update_lambda, delete_lambda, invoke_lambda,
       create_jl_lambda, @lambda, amap, serialize64, deserialize64



#-------------------------------------------------------------------------------
# AWS Lambda REST API.
#-------------------------------------------------------------------------------


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

    if length(r.data) > 0
        r = JSON.parse(bytestring(r.data))
        if isa(r, Dict)
            r = SymDict(r)
        end
    end

    return r
end


list_lambdas(aws) = [SymDict(f) for f in lambda(aws, "GET")["Functions"]]


function lambda_configuration(aws, name)

    @safe try

        return lambda(aws, "GET", path="$name/configuration")

    catch e
        @trap e if e.code == "404" end
    end

    return nothing
end


lambda_exists(aws, name) = lambda_configuration(aws, name) != nothing


function create_lambda(aws, name, S3Key;
                       S3Bucket=aws[:lambda_bucket],
                       Handler="$name.main",
                       Role=role_arn(aws, "lambda_s3_exec_role"),
                       Runtime="python2.7",
                       Timeout=30,
                       args...)

   query = merge!(SymDict(args),
                 @symdict(FunctionName = name,
                          Code = @symdict(S3Key, S3Bucket),
                          Handler,
                          Role,
                          Runtime,
                          Timeout))

    lambda(aws, "POST", query=query)
end


function update_lambda(aws, name, S3Bucket, S3Key)

    lambda(aws, "PUT", path="$name/code",
                       query=@symdict(S3Key, S3Bucket))
end


function delete_lambda(aws, name)

    @safe try
        lambda(aws, "DELETE", path=name)
    catch e
        @trap e if e.code == "404" end
    end
end


export AWSLambdaException


type AWSLambdaException <: Exception
    name::AbstractString
    message::AbstractString
end


function show(io::IO, e::AWSLambdaException)

    println(io, string("AWSLambdaException \"", e.name, "\":\n", e.message, "\n"))
end


function invoke_lambda(aws, name, args)

    r = lambda(aws, "POST", path="$name/invocations", query=args)

    if isa(r, Dict) && haskey(r, :errorMessage)
        throw(AWSLambdaException(string(name), r[:errorMessage]))
    end
    
    return r
end


invoke_lambda(aws, name; args...) = invoke_lambda(aws, name, SymDict(args))



#-------------------------------------------------------------------------------
# Python Code Support.
#-------------------------------------------------------------------------------


function create_py_lambda(aws, name, py_code)

    delete_lambda(aws, name)

    # Create .ZIP file containing "py_code"...
    zip = zipdict("$name.py" => py_code)

    # Upload .ZIP file to S3...
    zip_filename = "ocaws_lambda_$name.zip"
    s3_put(aws, aws[:lambda_bucket], zip_filename, zip)

    # Create lambda...
    create_lambda(aws, name, zip_filename)
end



#-------------------------------------------------------------------------------
# S3 ZIP File Patching.
#-------------------------------------------------------------------------------

# Add "files" to .ZIP stored under "key" in "aws[:lambda_bucket]".
# Implemented using Python zipfile library running on AWS Lambda
# (to avoid downloading/uploading .ZIP to/from local machine).

function update_lambda_zip(aws, key, files::Dict)

    lambda_name = "ocaws_update_lambda_zip"

    @repeat 2 try

        # Call lambda function to update ZIP stored in S3...
        bucket = aws[:lambda_bucket]
        invoke_lambda(aws, lambda_name, @symdict(bucket, key, files))

    catch e

        # Deploy update_zip lambda function if needed...
        @trap e if e.code == "404"

            create_py_lambda(aws, lambda_name,
            """
            import boto3
            import botocore
            import zipfile

            def main(event, context):

                # Get bucket object...
                bucket = event['bucket']
                region = boto3.client('s3').get_bucket_location(Bucket=bucket)
                region = region['LocationConstraint']
                bucket = boto3.resource('s3', region_name = region).Bucket(bucket)

                # Download zip file...
                bucket.download_file(event['key'], '/tmp/lambda.zip')

                # Patch zip file...
                with zipfile.ZipFile('/tmp/lambda.zip', 'a') as z:
                    for file in event['files']:
                        info = zipfile.ZipInfo(file)
                        info.compress_type = zipfile.ZIP_DEFLATED
                        info.external_attr = 0777 << 16L
                        z.writestr(info, event['files'][file])

                # Re-upload zip file...
                bucket.upload_file('/tmp/lambda.zip', event['key'])
            """)
        end
    end
end



#-------------------------------------------------------------------------------
# Julia Code Support.
#-------------------------------------------------------------------------------


# SHA256 Hash of deployed Julia code is stored in the Description field.

function jl_lambda_hash(aws, name)

    get(lambda_configuration(aws, name), :Description, nothing)
end


# Create an AWS Lambda to run "jl_code".
# The Julia runtime is copied from "aws[:lambda_bucket]/jl_lambda_base.zip".
# "jl_code" is added to the .ZIP as "$name.jl".
# A Python wrapper ("$name.py") is passes the .jl file to bin/julia.

function create_jl_lambda(aws, name, jl_code)

    new_code_hash = hexdigest("sha256", jl_code)
    old_code_hash = jl_lambda_hash(aws, name)

    # Don't create a new lambda one already exists with same code...
    if new_code_hash == old_code_hash
        return
    end

    # Delete old lambda with same name...
    if old_code_hash != nothing
        delete_lambda(aws, name)
    end

    # Wrapper to set up Julia environemnt and run "jl_code"...
    const lambda_py_wrapper =
    """
    from __future__ import print_function
    import subprocess
    import os
    import json

    def main(event, context):

        # Set Julia package directory...
        root = os.environ['LAMBDA_TASK_ROOT']
        os.environ['HOME'] = '/tmp/'
        os.environ['JULIA_PKGDIR'] = root + "/julia"

        # Clean up old return value file...
        if os.path.isfile('/tmp/lambda_out'):
            os.remove('/tmp/lambda_out')

        # Call Julia function...
        proc = subprocess.Popen([root + '/bin/julia', root + "/$name.jl"],
                                stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT)

        # Pass JSON event data on stdin...
        out, err = proc.communicate(json.dumps(event))
        print(out)

        # Check exit status...
        if proc.poll() != 0:
            raise Exception(out)

        # Return content of output file...
        if os.path.isfile('/tmp/lambda_out'):
            with open('/tmp/lambda_out', 'r') as f:
                return {'jl_data': f.read()}

        return {'stdout': out}
    """

    # Make a copy of base Julia system .ZIP file...
    zip_file= "jl_lambda_$(name)_$(new_code_hash).zip"
    s3_copy(aws, aws[:lambda_bucket], "jl_lambda_base.zip", to_path=zip_file)

    # Add python wrapper and julia code to .ZIP file...
    update_lambda_zip(aws, zip_file, Dict("$name.py" => lambda_py_wrapper,
                                          "$name.jl" => jl_code))
    # Deploy the lambda to AWS...
    create_lambda(aws, name, zip_file, MemorySize=1024,
                                       Description=new_code_hash)
end


function serialize64(a)

    buf = IOBuffer()
    b64 = Base64EncodePipe(buf)
    serialize(b64, a)
    close(b64)
    takebuf_string(buf)
end


function deserialize64(a)

    deserialize(Base64DecodePipe(IOBuffer(a)))
end


# Create an AWS Lambda function.
#
# e.g.
#
#   f = @lambda aws function hello(a, b)
#
#       message = "Hello $a$b"
#
#       println("Log: $message")
#
#       return message
#   end
#
#   f("World", "!")
#   Hello World!
#
# @lambda deploys an AWS Lambda that contains the body of the Julia function.
# It then rewrites the local Julia function to call invocke_lambda().


macro lambda(aws::Symbol, f::Expr)

    @assert f.head == :function
    call, body = f.args
    name = call.args[1]
    args = call.args[2:end]

    get_args = join(["""get(args,"$a","")""" for a in args], ", ")
    body = string(eval(Expr(:quote,body)))

    jl_code =
    """
        using JSON

        function $call
            $body
        end

        args = JSON.parse(STDIN)

        out = open("/tmp/lambda_out", "w")

        if haskey(args, "jl_data")

            args = deserialize(Base64DecodePipe(IOBuffer(args["jl_data"])))
            b64_out = Base64EncodePipe(out)
            serialize(b64_out, $name(args...))
            close(b64_out)

        else

            JSON.print(out, $name($get_args))
        end

        close(out)
    """

    f.args[2] = quote
        jl_data = serialize64($(Expr(:tuple, args...)))
        r = invoke_lambda($aws, $name, @symdict(jl_data))
        try 
            return deserialize64(r[:jl_data])
        catch
        end

        return r
    end

    quote
        create_jl_lambda($(esc(aws)), $(string(name)), $jl_code)
        $(esc(f))
    end
end


# Async version of map()
#
# e.g. Execute a lambda 100 times in parallel
#
#   f = @lambda aws function foo(n) "No. $n" end
#
#   amap(f, 1:100)

function amap(f, l)

    count = length(l)

    results = Array{Any,1}(count)
    fill!(results, nothing)

    @sync begin
        for (i,v) in enumerate(l)
            @async begin
                results[i] = f(v...)
            end
        end
    end

    return results
end




#==============================================================================#
# End of file.
#==============================================================================#
