#==============================================================================#
# AWSLambda.jl
#
# AWS Lambda API.
#
# See http://docs.aws.amazon.com/lambda/latest/dg/API_Reference.html
#
# Copyright Sam O'Connor 2014 - All rights reserved
#==============================================================================#


module AWSLambda

__precompile__()

export list_lambdas, create_lambda, update_lambda, delete_lambda, invoke_lambda,
       async_lambda, create_jl_lambda, invoke_jl_lambda, create_lambda_role,
       @λ, @lambda, amap, serialize64, deserialize64,
       lambda_compilecache,
       create_jl_lambda_base, merge_lambda_zip,
       apigateway, apigateway_restapis, apigateway_create


using AWSCore
using AWSS3
using AWSIAM
using JSON
using InfoZIP
using Retry
using SymDict
using DataStructures
using Glob
using Base.Pkg

import Nettle: hexdigest



#-------------------------------------------------------------------------------
# AWS Lambda REST API.
#-------------------------------------------------------------------------------


function lambda(aws::SymbolDict, verb; path="", query="", headers = Dict())

    resource = "/2015-03-31/functions/$path"

    r = @SymDict(
        service  = "lambda",
        url      = aws_endpoint("lambda", aws[:region]) * resource,
        content  = query == "" ? "" : json(query),
        headers,
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
                       Role=create_lambda_role(aws, name),
                       Runtime="python2.7",
                       Timeout=60,
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


function Base.show(io::IO, e::AWSLambdaException)

    println(io, string("AWSLambdaException \"", e.name, "\":\n", e.message, "\n"))
end


function invoke_lambda(aws, name, args; async=false)


    @protected try

        r = lambda(aws, "POST",
                        path="$name/invocations",
                        headers=Dict("X-Amz-Invocation-Type" =>
                                     async ? "Event" : "RequestResponse"),
                        query=args)

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


async_lambda(aws, name, args) = invoke_lambda(aws, name, args; async=true)


function create_lambda_role(aws, name, policy="")

    name = "$(name)_lambda_role"

    @protected try

        r = AWSIAM.iam(aws, Action = "CreateRole",
                        Path = "/",
                        RoleName = name,
                        AssumeRolePolicyDocument = """{
                            "Version": "2012-10-17",
                            "Statement": [ {
                                "Effect": "Allow",
                                "Principal": {
                                    "Service": "lambda.amazonaws.com"
                                },
                                "Action": "sts:AssumeRole"
                            } ]
                        }""")

    catch e
        @ignore if e.code == "EntityAlreadyExists" end
    end

    if policy == ""
        policy = """{
            "Version": "2012-10-17",
            "Statement": [
                {
                    "Effect": "Allow",
                    "Action": [
                        "logs:CreateLogGroup",
                        "logs:CreateLogStream",
                        "logs:PutLogEvents"
                    ],
                    "Resource": "arn:aws:logs:*:*:*"
                }
            ]
        }"""
    end

    AWSIAM.iam(aws, Action = "PutRolePolicy",
                    RoleName = name,
                    PolicyName = name,
                    PolicyDocument = policy)

    return role_arn(aws, name)
end


#-------------------------------------------------------------------------------
# Python Code Support.
#-------------------------------------------------------------------------------


function create_py_lambda(aws, name, py_code)

    delete_lambda(aws, name)

    # Create .ZIP file containing "py_code"...
    zip = create_zip("$name.py" => py_code)

    # Upload .ZIP file to S3...
    zip_filename = "ocaws_lambda_$name.zip"
    s3_put(aws, aws[:lambda_bucket], zip_filename, zip)

    # Create lambda...
    create_lambda(aws, name, zip_filename)
end



#-------------------------------------------------------------------------------
# S3 ZIP File Patching.
#-------------------------------------------------------------------------------

# Add "files" to .ZIP stored under "from_key" in "aws[:lambda_bucket]".
# Store result under "to_key".
# Implemented using Python zipfile library running on AWS Lambda
# (to avoid downloading/uploading .ZIP to/from local machine).

function create_lambda_zip(aws, to_key, from_key, files::Associative)

    lambda_name = "ocaws_create_lambda_zip"

#    delete_lambda(aws, lambda_name)

    files = [n => base64encode(v) for (n,v) in files]

    @repeat 2 try

        # Call lambda function to update ZIP stored in S3...
        bucket = aws[:lambda_bucket]
        invoke_lambda(aws, lambda_name,
                      @SymDict(bucket, to_key, from_key, files))

    catch e

        # Deploy create_lambda_zip lambda function if needed...
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
                bucket.download_file(event['from_key'], '/tmp/lambda.zip')

                # Patch zip file...
                with zipfile.ZipFile('/tmp/lambda.zip', 'a') as z:
                    for file in event['files']:
                        info = zipfile.ZipInfo(file)
                        info.compress_type = zipfile.ZIP_DEFLATED
                        info.external_attr = 0777 << 16L
                        z.writestr(info, event['files'][file].decode('base64'))

                # Upload updated zip file...
                bucket.upload_file('/tmp/lambda.zip', event['to_key'])
            """)
        end
    end
end


function merge_lambda_zip(aws, to_key, from_key, new_keys)

    lambda_name = "ocaws_merge_lambda_zip"

#    delete_lambda(aws, lambda_name)

    @repeat 2 try

        # Call lambda function to update ZIP stored in S3...
        bucket = aws[:lambda_bucket]
        invoke_lambda(aws, lambda_name,
                           @SymDict(bucket, to_key, from_key, new_keys))

    catch e

        # Deploy merge_lambda_zip lambda function if needed...
        @retry if e.code == "404"

            create_py_lambda(aws, lambda_name,
            """
            import os
            import tempfile
            import zipfile
            import shutil
            import subprocess
            import boto3
            import botocore

            def main(event, context):

                # Create temporary working directory...
                tmpdir = tempfile.mkdtemp()
                os.chdir(tmpdir)

                # Get bucket object...
                bucket = event['bucket']
                region = boto3.client('s3').get_bucket_location(Bucket=bucket)
                region = region['LocationConstraint']
                bucket = boto3.resource('s3', region_name = region).Bucket(bucket)

                # Download base zip file...
                bucket.download_file(event['from_key'], 'base.zip')

                # Download new zip file and merge into base zip file...
                with zipfile.ZipFile('base.zip', 'a') as za:
                    for key in event['new_keys']:
                        bucket.download_file(key, 'new.zip')
                        with zipfile.ZipFile('new.zip', 'r') as zb:
                            for i in zb.infolist():
                                za.writestr(i, zb.open(i.filename).read())

                # Upload new zip file...
                bucket.upload_file('base.zip', event['to_key'])
                os.chdir("..")
                shutil.rmtree(tmpdir)
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


function commondir(dirs::Array)

    @assert length(dirs) > 0

    # Find longest common prefix...
    i = 1
    for i = 1:length(dirs[1])
        if any(f -> length(f) <= i || f[1:i] != dirs[1][1:i], dirs)
            break
        end
    end

    # Ensure prefix is a dir path...
    while i > 0 && any(f->!isdirpath(f[1:i]), dirs)
        i -= 1
    end

    return dirs[1][1:i]
end


function find_module_files(modules)

    # Find subset of LOAD_PATH that contains required "modules"...
    load_path = []
    missing = [m=>nothing for m in modules]

    for d in LOAD_PATH
        for m in modules
            if isfile(joinpath(d, "$m.jl"))
                push!(load_path, abspath(d))
                delete!(missing, m)
                break
            end
        end
    end

    # Trim common path from load_path...
    common = commondir(load_path)
    load_path = [f[length(common)+1:end] for f in load_path]

    # Collect ".jl" files in module directories...
    files = OrderedDict()
    for d in load_path
        for f in filter(f->ismatch(r".jl$", f), readdir(joinpath(common, d)))
            files[joinpath(d, f)] = readall(joinpath(common, d, f))
        end
    end

    # Look in Pkg directories for modules not in LOAD_PATH...
    for m in keys(missing)
        push!(load_path, m)
        d = joinpath(Pkg.dir(m), "src")
        cd(d) do
            for f in glob("*.jl")
                files[joinpath(m, f)] = readall(joinpath(d, f))
            end
        end
        delete!(missing, m)
    end

    if !isempty(missing)
        throw(AWSLambdaException("find_module_files",
                                 "Can't find: $(join(keys(missing), " "))"))
    end

    return load_path, files
end


# Create an AWS Lambda to run "jl_code".
# The Julia runtime is copied from "aws[:lambda_bucket]/jl_lambda_base.zip".
# "jl_code" is added to the .ZIP as "$name.jl".
# A Python wrapper ("$name.py") is passes the .jl file to bin/julia.

function create_jl_lambda(aws, name, jl_code,
                          modules=[], options=SymDict())

    # Collect files for extra modules...
    modules = filter(m -> !(m in aws[:lambda_packages]), modules)
    if modules != []
        load_path, jl_files = find_module_files(modules)
    else
        load_path, jl_files = ("", OrderedDict())
    end
    load_path = "[$(join(["'$d'" for d in load_path], ","))]"

    # Wrapper to set up Julia environemnt and run "jl_code"...
    const lambda_py_wrapper =
    """
    from __future__ import print_function
    import subprocess
    import os
    import json
    import threading
    import Queue

    class OutputThread(threading.Thread):
        def __init__(self, fd):
            threading.Thread.__init__(self)
            self._fd = fd
            self._q = Queue.Queue()
            self.start()


        def run(self):
            for line in iter(self._fd.readline, ''):
                self._q.put(line)
            self._fd.close()
            self._q.put('')

        def get(self):
            return self._q.get()

    def main(event, context):

        # Set Julia package directory...
        root = os.environ['LAMBDA_TASK_ROOT']
        os.environ['HOME'] = '/tmp/'
        os.environ['JULIA_PKGDIR'] = root + '/julia'
        load_path = ':'.join([root + '/' + d for d in $load_path])
        os.environ['JULIA_LOAD_PATH'] = load_path

        # Clean up old return value file...
        if os.path.isfile('/tmp/lambda_out'):
            os.remove('/tmp/lambda_out')

        # Call Julia function...
        proc = subprocess.Popen([root + '/bin/julia', root + "/$name.jl"],
                                stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT)

        # Set up thread to read stdout...
        t = OutputThread(proc.stdout)

        # Write to stdin...
        proc.stdin.write(json.dumps(event))
        proc.stdin.close()

        # Read stdout from queue...
        out = ''
        for line in iter(t.get, ''):
            print(line, end='')
            out += line

        # Check exit status...
        if proc.wait() != 0:
            raise Exception(out)

        # Return content of output file...
        if os.path.isfile('/tmp/lambda_out'):
            with open('/tmp/lambda_out', 'r') as f:
                return {'jl_data': f.read(),
                        'stdout': out}

        return {'stdout': out}
    """


    # Add python wrapper and julia code to .ZIP file...
    zipfile = get(options, :zipfile, UInt8[])
    delete!(options, :zipfile)
    merge!(jl_files, OrderedDict("$name.py" => lambda_py_wrapper,
                                 "$name.jl" => jl_code))
    open_zip(zipfile) do z
        merge!(z, jl_files)
    end

    new_code_hash = hexdigest("sha256", serialize64(Dict(open_zip(zipfile))))
    old_code_hash = jl_lambda_hash(aws, name)

    # Don't create a new lambda if one already exists with same code...
    if new_code_hash == old_code_hash
        return
    end

    # Delete old lambda with same name...
    if old_code_hash != nothing
        delete_lambda(aws, name)
    end

    # Add new files to base Julia system .ZIP file...
    base_file=get(aws, :lambda_base, "jl_lambda_base.zip")
    lambda_id="jl_lambda_$(name)_$(new_code_hash)"
    s3_put(aws, aws[:lambda_bucket], "$lambda_id.new.zip", zipfile)
    merge_lambda_zip(aws, "$lambda_id.zip", base_file, ["$lambda_id.new.zip"])

    options = @SymDict(MemorySize=1024,
                       Description=new_code_hash,
                       options...)

    # Deploy the lambda to AWS...
    r = create_lambda(aws, name, "$lambda_id.zip"; options...)

    if !get(aws, :lambda_precompile, true)
        return
    end

    # Download .ji cache from the lambda sandbox.
    r = invoke_lambda(aws, name, jl_precompile = true)
    ji_cache = deserialize64(r[:jl_data])

    if isempty(ji_cache)
        return r
    end

    # Delete lambda...
    delete_lambda(aws, name)

    # Add .ji cache files to .ZIP...
    create_lambda_zip(aws, "$lambda_id.ji.zip", "$lambda_id.zip", ji_cache)

    # Re-deploy the lambda to AWS with precompile cache...
    create_lambda(aws, name, "$lambda_id.ji.zip"; options...)
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


# Invoke a Julia AWS Lambda function.
# Serialise "args" and deserialise result.

function invoke_jl_lambda(aws, name, args...)

    r = invoke_lambda(aws, name, jl_data = serialize64(args))
    try
        println(r[:stdout])
    end
    try
        return deserialize64(r[:jl_data])
    end
    return r
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

macro lambda(args...)

    usage = "usage: @lambda aws [options::SymDict] function..."

    @assert length(args) <= 3 usage * "A"

    aws = args[1]
    #@assert isa(aws, Symbol) usage * "B"

    f = args[end]
    @assert isa(f, Expr) usage * "C"
    @assert f.head == :function usage * "D"

    options = length(args) > 2 ? esc(args[2]) : :(Dict())

    call, body = f.args
    name = call.args[1]
    args = call.args[2:end]

    # Split "using module" lines out of body...
    modules = Expr(:block, filter(e->isa(e, Expr) && e.head == :using, body.args)...)
    body.args = filter(e->!isa(e, Expr) || e.head != :using, body.args)

    # Fix up LineNumberNodes...
    body = eval(Expr(:quote, body))

    arg_names = [isa(a, Expr) ? a.args[1] : a for a in args]
    get_args = join(["""get(args,"$a",nothing)""" for a in arg_names], ", ")

    jl_code =
    """
        eval(Base, :(is_interactive = true))

        insert!(Base.LOAD_CACHE_PATH, 1, ENV["LAMBDA_TASK_ROOT"])
        mkpath("/tmp/jl_cache")
        insert!(Base.LOAD_CACHE_PATH, 1, "/tmp/jl_cache")

        using JSON

        $modules

        function $call
            $body
        end

        args = JSON.parse(STDIN)

        out = open("/tmp/lambda_out", "w")

        if haskey(args, "jl_precompile")

            cd("/tmp/jl_cache")
            b64_out = Base64EncodePipe(out)
            serialize(b64_out, [f => open(readbytes, f) for f in readdir()])
            close(b64_out)

        elseif haskey(args, "jl_data")

            args = deserialize(Base64DecodePipe(IOBuffer(args["jl_data"])))
            b64_out = Base64EncodePipe(out)
            serialize(b64_out, $name(args...))
            close(b64_out)

        else
            JSON.print(out, $name($get_args))
        end

        close(out)
    """

    # Add "aws" dict as first arg...
    insert!(f.args[1].args, 2, :aws)

    # Replace function body with Lambda invocation...
    f.args[2] = :(invoke_jl_lambda(aws, $name, $(args...)))

    modules = [string(m.args[1]) for m in modules.args]

    quote
        create_jl_lambda($(esc(aws)),
                         $(string(name)), $jl_code, $modules, $options)
        $(esc(f))
        $(Expr(:tuple, args...)) -> $(esc(name))($(esc(aws)), $(args...))
    end
end

macro λ(args...)
    esc(:(@lambda $(args...)))
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

function create_jl_lambda_base(aws; release = "release-0.4")

    pkg_list = aws[:lambda_packages]
    if !("JSON" in pkg_list)
        push!(pkg_list, "JSON")
    end

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



#-------------------------------------------------------------------------------
# API Gateway support http://docs.aws.amazon.com/apigateway/
#-------------------------------------------------------------------------------

hallink(hal, name) = hal["_links"][name]["href"]


function apigateway(aws::SymbolDict, verb, resource="/restapis", query=Dict())

    r = @SymDict(
        service  = "apigateway",
        url      = AWSCore.aws_endpoint("apigateway", aws[:region]) * resource,
        content  = isempty(query) ? "" : json(query),
        headers  = Dict(),
        resource,
        verb,
        aws...
    )

    r = AWSCore.do_request(r)

    return r
end


function apigateway(aws::SymbolDict, verb, resource; args...)
    apigateway(aws, verb, resource, Dict(args))
end


function apigateway_restapis(aws)
    r = apigateway(aws, "GET", "/restapis")
    if haskey(r, "_embedded")
        r = r["_embedded"]
        r = get(r, "item", r)
        if !isa(r, Vector)
            r = [r]
        end
    else
        r = []
    end
    return r
end


function apigateway_lambda_arn(aws, name)
    name = arn(aws, "lambda", "function:$name")
    f = "/2015-03-31/functions/$name/invocations"
    "arn:aws:apigateway:$(aws[:region]):lambda:path$f"
end


function apigateway_create(aws, name, args)

    lambda_arn = apigateway_lambda_arn(aws, name)
    api = apigateway(aws, "POST", "/restapis", name = name)
    id = api["id"]
    method = "$(hallink(api, "resource:create"))/methods/GET"
    params = Dict(["method.request.querystring.$a" => false for a in args])
    map = "{\n$(join(["\"$a\" : \$input.params(\"$a\")" for a in args], ",\n"))\n}"

    apigateway(aws, "PUT", method,
               authorizationType = "NONE",
               requestParameters = params)

    apigateway(aws, "PUT", "$method/responses/200",
               "responseModels" => Dict("application/json" => "Empty"))

    apigateway(aws, "PUT", "$method/integration/", Dict(
               "type" => "AWS", "httpMethod" => "POST", "uri" => lambda_arn,
               "requestTemplates" => Dict("application/json" => map)))

    apigateway(aws, "PUT", "$method/integration/responses/200",
               responseTemplates = Dict("application/json" => nothing))

    lambda(aws, "POST"; path="$name/policy", query=Dict(
           "Action" => "lambda:InvokeFunction",
           "Principal" => "apigateway.amazonaws.com",
           "SourceArn" => arn(aws, "execute-api", "$id/*/GET/"),
           "StatementId" => "apigateway_$(id)_GET"))
end



end # module AWSLambda



#==============================================================================#
# End of file.
#==============================================================================#
