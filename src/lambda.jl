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
       create_jl_lambda, @lambda, amap, serialize64, deserialize64,
       create_jl_lambda_base



#-------------------------------------------------------------------------------
# AWS Lambda REST API.
#-------------------------------------------------------------------------------


function lambda(aws, verb; path="", query="")

    resource = "/2015-03-31/functions/$path"

    r = @SymDict(
        service  = "lambda",
        url      = aws_endpoint("lambda", aws[:region]) * resource,
        content  = query == "" ? "" : json(query),
        headers  = Dict(),
        resource,
        verb,
        aws...
    )

    r = do_request(r)

    if isa(r, Dict)
        r = SymbolDict(r)
    end

    return r
end


list_lambdas(aws) = [SymbolDict(f) for f in lambda(aws, "GET")[:Functions]]


function lambda_configuration(aws, name)

    @protected try

        return lambda(aws, "GET", path="$name/configuration")

    catch e
        @ignore if e.code == "404" end
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

   query = @SymDict(FunctionName = name,
                    Code = @SymDict(S3Key, S3Bucket),
                    Handler,
                    Role,
                    Runtime,
                    Timeout,
                    args...)

    lambda(aws, "POST", query=query)
end


function update_lambda(aws, name, S3Bucket, S3Key)

    lambda(aws, "PUT", path="$name/code",
                       query=@SymDict(S3Key, S3Bucket))
end


function delete_lambda(aws, name)

    @protected try
        lambda(aws, "DELETE", path=name)
    catch e
        @ignore if e.code == "404" end
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

    @protected try

        r = lambda(aws, "POST", path="$name/invocations", query=args)

        if isa(r, Dict) && haskey(r, :errorMessage)
            throw(AWSLambdaException(string(name), r[:errorMessage]))
        end

        return r

    catch e
        @ignore if e.code == "429"
            message = "HTTP 429 $(e.message)\nSee " *
                      "http://docs.aws.amazon.com/lambda/latest/dg/limits.html"
            throw(AWSLambdaException(string(name), message))
        end
    end

    @assert false # Unreachable
end


invoke_lambda(aws, name; args...) = invoke_lambda(aws, name, SymbolDict(args))



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
        invoke_lambda(aws, lambda_name, @SymDict(bucket, key, files))

    catch e

        # Deploy update_zip lambda function if needed...
        @retry if e.code == "404"

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

    jl_code =
    """
        using JSON

        function $call
            $(string(eval(Expr(:quote, body))))
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
        r = invoke_lambda($aws, $name, Dict(:jl_data => jl_data))
        dump(r)
        try 
            return deserialize64(r[:jl_data])
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



#-------------------------------------------------------------------------------
# Julia Runtime Build Script
#-------------------------------------------------------------------------------


# Build the Julia runtime using a temporary EC2 server.
# Takes about 1 hour, (or about 5 minutes if full rebuild is not done).
# Upload the Julia runtime to "aws[:lambda_bucket]/jl_lambda_base.zip".

function create_jl_lambda_base(aws; pkg_list = ["JSON"],
                                     release = "release-0.4")
    server_config = [(

        "cloud_config.txt", "text/cloud-config",

        """packages:
         - git
         - cmake
         - m4
         - patch
         - gcc
         - gcc-c++
         - gcc-gfortran
         - libgfortran
         - openssl-devel
        """

    ),(

        "build_julia.sh", "text/x-shellscript",

        """#!/bin/bash

        # Set up /var/task Lambda staging dir...
        mkdir -p /var/task/julia
        export HOME=/var/task
        export JULIA_PKGDIR=/var/task/julia

        cd /
        if aws --region $(aws[:region]) \\
            s3 cp s3://$(aws[:lambda_bucket])/jl_lambda_base.tgz \\
                /jl_lambda_base.tgz
        then
            tar xzf jl_lambda_base.tgz
        else

            # Download Julia source code...
            cd /
            git clone git://github.com/JuliaLang/julia.git
            cd julia
            git checkout $release

            # Configure Julia for the Xeon E5-2680 CPU used by AWS Lambda...
            cp Make.inc Make.inc.orig
            find='OPENBLAS_TARGET_ARCH=.*\$'
            repl='OPENBLAS_TARGET_ARCH=SANDYBRIDGE\\nMARCH=core-avx-i'
            sed s/\$find/\$repl/ < Make.inc.orig > Make.inc

            # Build and install Julia under /var/task...
            make -j2 prefix= DESTDIR=/var/task all
            make prefix= DESTDIR=/var/task install 

            # Save tarball of raw Julia build...
            cd /
            tar czfP jl_lambda_base.tgz var/task
            aws --region $(aws[:region]) \\
                s3 cp /jl_lambda_base.tgz \\
                      s3://$(aws[:lambda_bucket])/jl_lambda_base.tgz
        fi

        # Precompile Julia modules...
        /var/task/bin/julia -e '
            Pkg.init()
            $(join(["Pkg.add(\"$p\")\nusing $p\n" for p in pkg_list]))
        '

        # Copy minimal set of files to /task-staging...
        mkdir -p /task-staging/bin
        mkdir -p /task-staging/lib/julia
        cd /task-staging
        cp /var/task/bin/julia bin/
        cp -a /var/task/lib/julia/*.so* lib/julia
        rm -f lib/julia/*-debug.so
        cp -a /usr/lib64/libgfortran.so* lib/julia
        cp -a /usr/lib64/libquadmath.so* lib/julia

        # Copy pre-compiled modules to /tmp/task...
        cp -a /var/task/julia .
        chmod -R a+r julia/lib/
        find julia -name '.git' \\
                   -o -name '.cache' \\
                   -o -name '.travis.yml' \\
                   -o -name '.gitignore' \\
                   -o -name 'REQUIRE' \\
                   -o -name 'test' \\
                   -o -path '*/deps/downloads' \\
                   -o -path '*/deps/builds' \\
                   -o \\( \\
                        -type f \\
                        -path '*/deps/src/*' \\
                      ! -name '*.so.*' \\
                    \\) \\
                   -o -path '*/deps/usr/include' \\
                   -o -path '*/deps/usr/bin' \\
                   -o -path '*/deps/usr/lib/*.a' \\
                   -o -name 'doc' \\
                   -o -name '*.md' \\
                   -o -name 'METADATA' \\
            | xargs rm -rf

        # Create .zip file...
        zip -u --symlinks -r -9 /jl_lambda_base.zip *

        # Upload .zip file to S3...
        aws --region $(aws[:region]) \\
            s3 cp /jl_lambda_base.zip \\
                  s3://$(aws[:lambda_bucket])/jl_lambda_base.zip

        # Suspend the build server...
        shutdown -h now
        """
    )]

    policy = """{
        "Version": "2012-10-17",
        "Statement": [ {
            "Effect": "Allow",
            "Action": [ "s3:PutObject", "s3:GetObject" ],
            "Resource": [
                "arn:aws:s3:::$(aws[:lambda_bucket])/jl_lambda_base.*"
            ]
        } ]
    }"""

    create_ec2(aws, "ocaws_jl_lambda_build_server",
                    ImageId      = "ami-1ecae776",
                    InstanceType = "c3.large",
                    KeyName      = "ssh-ec2",
                    UserData     = server_config,
                    Policy       = policy)
end



#==============================================================================#
# End of file.
#==============================================================================#
