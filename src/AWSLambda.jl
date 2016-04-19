#==============================================================================#
# AWSLambda.jl
#
# AWS Lambda API.
#
# See http://docs.aws.amazon.com/lambda/latest/dg/API_Reference.html
#
# Copyright Sam O'Connor 2014 - All rights reserved
#==============================================================================#


__precompile__()


module AWSLambda


export list_lambdas, create_lambda, update_lambda, delete_lambda, invoke_lambda,
       async_lambda, create_jl_lambda, invoke_jl_lambda, create_lambda_role,
       @λ, @lambda, serialize64, deserialize64,
       lambda_compilecache,
       create_jl_lambda_base, merge_lambda_zip,
       lambda_configuration,
       lambda_create_alias, lambda_update_alias, lambda_publish_version,
       apigateway, apigateway_restapis, apigateway_create,
       @lambda_eval, @lambda_call, lambda_include, lambda_include_string


using AWSCore
using AWSS3
using AWSEC2
using AWSIAM
using JSON
using InfoZIP
using Retry
using SymDict
using DataStructures
using Glob
using Base.Pkg

import Nettle: hexdigest


# For compatibility with Julia 0.4
using Compat.readstring


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


function lambda_update_configuration(aws, name, options)

    lambda(aws, "PUT", path="$name/configuration", query=options)
end


lambda_exists(aws, name) = lambda_configuration(aws, name) != nothing


function create_lambda(aws, name, S3Key;
                       S3Bucket=aws[:lambda_bucket],
                       Handler="$name.main",
                       Role=create_lambda_role(aws, name),
                       Runtime="python2.7",
                       Timeout=300,
                       args...)

   query = @SymDict(FunctionName = name,
                    Code = @SymDict(S3Key, S3Bucket),
                    Handler,
                    Role,
                    Runtime,
                    Timeout,
                    args...)

    @repeat 5 try

        lambda(aws, "POST", query=query)

    catch e
        # Retry in case Role was just created and is not yet active...
        @delay_retry if e.code == "400" end
    end
end


function update_lambda(aws, name, S3Key;
                       S3Bucket=aws[:lambda_bucket], args...)

    @sync begin

        @async lambda(aws, "PUT", path="$name/code",
                      query=@SymDict(S3Key, S3Bucket))

        @async if !isempty(args)
            lambda(aws, "PUT", path="$name/configuration", query=@SymDict(args...))
        end
    end
end


function lambda_publish_version(aws, name, alias)

    r = lambda(aws, "POST", path="$name/versions")
    @protected try
        lambda_create_alias(aws, name, alias, FunctionVersion=r[:Version])
    catch e
        @ignore if e.code == "409"
            lambda_update_alias(aws, name, alias, FunctionVersion=r[:Version])
        end
    end
end


function lambda_create_alias(aws, name, alias; FunctionVersion="\$LATEST")

    lambda(aws, "POST", path="$name/aliases",
                        query=@SymDict(FunctionVersion, Name=alias))
end


function lambda_update_alias(aws, name, alias; FunctionVersion="\$LATEST")

    lambda(aws, "PUT", path="$name/aliases/$alias",
                       query=@SymDict(FunctionVersion))
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


function create_py_lambda(aws, name, py_code;
                          Role=create_lambda_role(aws, name))

    delete_lambda(aws, name)

    # Create .ZIP file containing "py_code"...
    zip = create_zip("$name.py" => py_code)

    # Upload .ZIP file to S3...
    zip_filename = "ocaws_lambda_$name.zip"
    s3_put(aws, aws[:lambda_bucket], zip_filename, zip)

    # Create lambda...
    create_lambda(aws, name, zip_filename, Role=Role, MemorySize=1024)
end



#-------------------------------------------------------------------------------
# S3 ZIP File Patching.
#-------------------------------------------------------------------------------

# Add "files" to .ZIP stored under "from_key" in "aws[:lambda_bucket]".
# Store result under "to_key".
# Implemented using Python zipfile library running on AWS Lambda
# (to avoid downloading/uploading .ZIP to/from local machine).

function create_lambda_zip(aws, to_key, from_key, files::Associative)

    bucket = aws[:lambda_bucket]
    lambda_name = "ocaws_create_lambda_zip"

#    delete_lambda(aws, lambda_name)

    files = [n => base64encode(v) for (n,v) in files]

    @repeat 2 try

        # Call lambda function to update ZIP stored in S3...
        invoke_lambda(aws, lambda_name,
                      @SymDict(bucket, to_key, from_key, files))

    catch e

        # Deploy create_lambda_zip lambda function if needed...
        @retry if e.code == "404"

            role_name = string(lambda_name, '-', aws[:region])

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
            """;
            Role = create_lambda_role(aws, role_name, """{
                "Version": "2012-10-17",
                "Statement": [
                    {
                        "Effect": "Allow",
                        "Action": [
                            "s3:GetObject",
                            "s3:PutObject",
                            "s3:GetBucketLocation"
                        ],
                        "Resource": "arn:aws:s3:::$bucket*"
                    },
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
            }"""))
        end
    end
end


function merge_lambda_zip(aws, to_key, from_key, new_keys)

    lambda_name = "ocaws_merge_lambda_zip"
    bucket = aws[:lambda_bucket]
#    delete_lambda(aws, lambda_name)

    @repeat 2 try

        # Call lambda function to update ZIP stored in S3...
        invoke_lambda(aws, lambda_name,
                           @SymDict(bucket, to_key, from_key, new_keys))

    catch e

        # Deploy merge_lambda_zip lambda function if needed...
        @retry if e.code == "404"

            role_name = string(lambda_name, '-', aws[:region])

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
            """,
            Role = create_lambda_role(aws, role_name, """{
                "Version": "2012-10-17",
                "Statement": [
                    {
                        "Effect": "Allow",
                        "Action": [
                            "s3:GetObject",
                            "s3:PutObject",
                            "s3:GetBucketLocation"
                        ],
                        "Resource": "arn:aws:s3:::$bucket*"
                    },
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
            }"""))
        end
    end
end



#-------------------------------------------------------------------------------
# Julia Code Support.
#-------------------------------------------------------------------------------


# Create an AWS Lambda to run "jl_code".
# The Julia runtime is copied from "aws[:lambda_bucket]/jl_lambda_base.zip".
# "jl_code" is added to the .ZIP as "$name.jl".
# A Python wrapper ("$name.py") is passes the .jl file to bin/julia.

function create_jl_lambda(aws, name, jl_code,
                          modules=Symbol[], options=SymDict())

    # Find files and load path for required modules...
    load_path, mod_files = module_files(aws, modules)
    py_load_path = "[$(join(["'$d'" for d in load_path], ","))]"

    env = get(options, :env,
          get(aws, :lambda_env, Dict()))
    py_env = join(["os.environ['$n'] = '$v'" for (n,v) in env], "\n")

    error_sns_arn = get(options, :error_sns_arn,
                    get(aws, :lambda_error_sns_arn, ""))

    # Wrapper to set up Julia environemnt and run "jl_code"...
    const lambda_py_wrapper =
    """
    from __future__ import print_function
    import subprocess
    import os
    import json
    import threading
    import time
    import select

    # Set Julia package directory...
    root = os.environ['LAMBDA_TASK_ROOT']
    os.environ['HOME'] = '/tmp/'
    os.environ['JULIA_PKGDIR'] = root + '/julia'
    load_path = ':'.join([root + '/' + d for d in $py_load_path])
    os.environ['JULIA_LOAD_PATH'] = load_path
    $py_env

    julia_proc = None

    # Start Julia interpreter ...
    def start_julia():
        global julia_proc
        julia_proc = subprocess.Popen([root + '/bin/julia', root + "/$name.jl"],
                                      stdin=subprocess.PIPE,
                                      stdout=subprocess.PIPE,
                                      stderr=subprocess.STDOUT)

    # Pass args to Julia as JSON with null,newline terminator...
    def julia_eval(event, context):
        json.dump({'event': event, 'context': context.__dict__},
                  julia_proc.stdin,
                  default=lambda o: '')
        julia_proc.stdin.write('\\0\\n')
        julia_proc.stdin.flush()

    def main(event, context):

        # Clean up old return value file...
        if os.path.isfile('/tmp/lambda_out'):
            os.remove('/tmp/lambda_out')

        if julia_proc is None or julia_proc.poll() is not None:
            start_julia()

        # Pass "event" to Julia...
        threading.Thread(target=julia_eval, args=(event, context)).start()

        # Calcualte execution time limit...
        time_limit = time.time() + context.get_remaining_time_in_millis()/1000.0
        time_limit -= 5.0

        # Wait for output...
        out = ''
        timeout = True
        while time.time() < time_limit:
            ready = select.select([julia_proc.stdout], [], [], time_limit - time.time())
            if julia_proc.stdout in ready[0]:
                line = julia_proc.stdout.readline()
                if line == '\\0\\n' or line == '':
                    timeout = False
                    break
                print(line, end='')
                out += line

        if timeout:
            print('Timeout!')
            out += 'Timeout!\\n'

        # Check exit status...
        if julia_proc.poll() != None or timeout:
            if '$error_sns_arn' != '':
                if timeout:
                    subject = 'Lambda Timeout: $name '
                else:
                    subject = 'Lambda Error: $name '
                subject += json.dumps(event, separators=(',',':'))
                error = '$name\\n' + json.dumps(event) + '\\n\\n' + out
                import boto3
                try:
                    boto3.client('sns').publish(TopicArn='$error_sns_arn',
                                                Message=error,
                                                Subject=subject[:100])
                except Exception:
                    pass

            raise Exception(out)

        # Return content of output file...
        if os.path.isfile('/tmp/lambda_out'):
            with open('/tmp/lambda_out', 'r') as f:
                return {'jl_data': f.read(), 'stdout': out}
        else:
            return {'stdout': out}
    """


    # Start with zipfile from options...
    zipfile = get(options, :zipfile, UInt8[])
    delete!(options, :zipfile)

    # Add lambda source and module files to zip...
    open_zip(zipfile) do z
        merge!(z, mod_files)
        merge!(z, OrderedDict("$name.py" => lambda_py_wrapper,
                              "$name.jl" => jl_code))
    end

    # SHA256 Hash of deployed Julia code is stored in the Description field.
    old_config = lambda_configuration(aws, name)
    new_code_hash = hexdigest("sha256", serialize64(Dict(open_zip(zipfile))))
    old_code_hash = get(old_config, :Description, nothing)

    # Don't create a new lambda if one already exists with same code...
    if new_code_hash == old_code_hash && !get(aws, :lambda_force_update, false)
        return
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
    if old_config == nothing
        r = create_lambda(aws, name, "$lambda_id.zip"; options...)
    else
        r = update_lambda(aws, name, "$lambda_id.zip"; options...)
    end

    if get(aws, :lambda_precompile, true)

        # Download .ji cache from the lambda sandbox.
        r = invoke_lambda(aws, name, jl_precompile = true)
        ji_cache = deserialize64(r[:jl_data])

        if !isempty(ji_cache)

            # Add .ji cache files to .ZIP...
            create_lambda_zip(aws, "$lambda_id.ji.zip",
                              "$lambda_id.zip", ji_cache)

            # Update lambda using new .ZIP...
            update_lambda(aws, name, "$lambda_id.ji.zip")
        end
    end


    @sync begin

        # Update config...
        @async lambda_update_configuration(aws, name, options)

        # Clean up S3 files...
        for z in [".new.zip", ".zip", ".ji.zip"]
            @async s3_delete(aws, aws[:lambda_bucket], "$lambda_id$z")
        end
    end
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


# See https://github.com/JuliaLang/julia/issues/15299#issuecomment-190553775
clean_ex(ex) = ex
function clean_ex(ex::Expr)
    args = map(clean_ex, ex.args)
    if ex.head in [:break, :continue]; return ex.head; end
    if ex.head != :block; return Expr(ex.head, args...); end

    args = collect(filter(ex->(!is_linenumber(ex)), args))
    length(args) == 1 ? args[1] : Expr(ex.head, args...)
end
is_linenumber(ex) = isa(ex, LineNumberNode) || Base.Meta.isexpr(ex, :line)


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

    @assert length(args) <= 3 usage

    aws = args[1]

    f = args[end]
    @assert isa(f, Expr) usage
    @assert f.head == :function usage

    options = length(args) > 2 ? esc(args[2]) : :(Dict())

    call, body = f.args
    name = call.args[1]
    args = call.args[2:end]

    # Split "using module" lines out of body...
    modules = Expr(:block, filter(e->isa(e, Expr) && e.head == :using, body.args)...)

    body.args = filter(e->!isa(e, Expr) || e.head != :using, body.args)

    arg_names = [isa(a, Expr) ? a.args[1] : a for a in args]
    get_args = join(["""get(event,"$a",nothing)""" for a in arg_names], ", ")

    body = clean_ex(body)

    jl_code =
    """
        eval(Base, :(is_interactive = true))

        insert!(Base.LOAD_CACHE_PATH, 1, ENV["LAMBDA_TASK_ROOT"])
        mkpath("/tmp/jl_cache")
        insert!(Base.LOAD_CACHE_PATH, 1, "/tmp/jl_cache")

        using JSON

        $modules

        # Define lambda function...
        function $call
            $body
        end

        # Run lambda function...
        function main(event, context)

            global LAMBDA_CONTEXT = context

            out = open("/tmp/lambda_out", "w")

            if haskey(event, "jl_precompile")

                cd("/tmp/jl_cache")
                b64_out = Base64EncodePipe(out)
                serialize(b64_out, [f => open(readbytes, f) for f in readdir()])
                close(b64_out)

            elseif haskey(event, "jl_data")

                args = deserialize(Base64DecodePipe(IOBuffer(event["jl_data"])))
                b64_out = Base64EncodePipe(out)
                serialize(b64_out, $name(args...))
                close(b64_out)

            else
                JSON.print(out, $name($get_args))
            end

            close(out)
            println("\\0")
        end

        # Read from STDIN into buf...
        buf = UInt8[]
        while true
            chunk = readavailable(STDIN)
            append!(buf, chunk)
            @assert length(chunk) > 0

            # When end of input is found, call main()...
            if length(buf) >  1 && buf[end-1:end] == ['\\0','\\n']
                input = JSON.parse(UTF8String(buf))
                main(input["event"], input["context"])
                empty!(buf)
            end
        end
    """

    # Add "aws" dict as first arg...
    insert!(f.args[1].args, 2, :aws)

    # Replace function body with Lambda invocation...
    f.args[2] = :(invoke_jl_lambda(aws, $name, $(args...)))

    modules = Symbol[m.args[1] for m in modules.args]

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



# Create anonymous function to call "func" in the Lambda sandbox.

macro lambda_call(aws, func)

    func = Expr(:quote, func)

    esc(quote
        (args...) -> begin
            Retry.@repeat 2 try

                invoke_jl_lambda($aws, :jl_lambda_call, $func, args)

            catch e
                @retry if e.code == "404"
                    @λ $aws function jl_lambda_call(func, args)
                        eval(func)(args...)
                    end
                end
            end
        end
    end)
end


function lambda_include_string(aws, code)
    @lambda_call(aws, include_string)(code)
end


function lambda_include(aws, filename)
    code = readstring(filename)
    @lambda_call(aws, include_string)(code, filename)
end


# Evaluate "expr" in the Lambda sandbox.

macro lambda_eval(aws, expr)

    # Separate "using" statements from expression...
    usings = Expr(:block, filter(e->isa(e, Expr) && e.head == :using, expr.args)...)
    expr.args = filter(e->!isa(e, Expr) || e.head != :using, expr.args)

    # Eval "using" statements before rest of expression...
    expr = quote
        eval($(Expr(:quote, usings)))
        eval($(Expr(:quote, expr)))
    end

    esc(quote @lambda_call($aws,()->$expr)() end)
end



# List of modules in the Lambda sandbox ".ji" cache.

function lambda_module_cache(aws)

    if !lambda_exists(aws, "jl_lambda_call")
        return [symbol(p) for p in aws[:lambda_packages]]
    end

    @lambda_eval aws [symbol(splitext(f)[1]) for f in 
                        [[readdir(p) for p in
                            filter(isdir, Base.LOAD_CACHE_PATH)]...;]]
end


# List of modules in local ".ji" cache.

function local_module_cache()

    [symbol(splitext(f)[1]) for f in 
        [[readdir(p) for p in
            filter(isdir, Base.LOAD_CACHE_PATH)]...;]]
end


# List of source files required by "modules".

function precompiled_module_files(aws, modules::Vector{Symbol})

    ex = [lambda_module_cache(aws)..., :Main, :Base, :Core]

    modules = collect(filter(m->!(m in ex), modules))

    return unique([[_precompiled_module_files(i, ex) for i in modules]...;])
end


function _precompiled_module_files(m, exclude_modules)

    # Module must be precompiled...
    @assert m in local_module_cache()

    r = Dict()
    for p in Base.find_all_in_cache_path(m)
        modules, files = Base.cache_dependencies(p)
        for (f,t) in files
            r[f] = nothing
        end
        for (m,t) in modules
            if m in exclude_modules
                continue
            end
            for f in _precompiled_module_files(m, exclude_modules)
                r[f] = nothing
            end
        end
    end
    return collect(keys(r))
end


# Split paths from common prefix...

function path_prefix_split(paths::Vector)

    @assert length(paths) > 0

    # Find longest common prefix...
    i = 1
    for i = 1:length(paths[1])
        if any(f -> length(f) <= i || f[1:i] != paths[1][1:i], paths)
            break
        end
    end

    # Ensure prefix is a dir path...
    while i > 0 && any(f->!isdirpath(f[1:i]), paths)
        i -= 1
    end

    return paths[1][1:i], [p[i+1:end] for p in paths]
end


# Find load path and source files for "modules"...

function module_files(aws, modules::Vector{Symbol})

    if length(modules) == 0
        return [], OrderedDict()
    end

    pkgd = realpath(Pkg.dir())

    # Build a dict of files for each load path location...
    d = Dict()
    for file in precompiled_module_files(aws, modules)
        file = realpath(file)

        for p in filter(isdir, [LOAD_PATH...; pkgd])
            p = realpath(abspath(p))
            if startswith(file, p)
                file = file[length(p)+2:end]
                if !haskey(d, p)
                    d[p] = [file]
                else
                    push!(d[p], file)
                end
            end
        end
    end

    if isempty(d)
        return [], OrderedDict()
    end

    # Remove common prefix from load path locations...
    load_path = collect(filter(p->p != pkgd, keys(d)))
    prefix, short_load_path = path_prefix_split(load_path)

    # Build archive of file content...
    archive = OrderedDict()
    for (p, s) in zip([load_path...; pkgd], [short_load_path...; "julia"])
        for f in get(d,p,[])
            archive[joinpath(s, f)] = open(readbytes, joinpath(p, f))
        end
    end

    return short_load_path, archive
end


#-------------------------------------------------------------------------------
# Julia Runtime Build Script
#-------------------------------------------------------------------------------


# Build the Julia runtime using a temporary EC2 server.
# Takes about 1 hour, (or about 5 minutes if full rebuild is not done).
# Upload the Julia runtime to "aws[:lambda_bucket]/jl_lambda_base.zip".

function create_jl_lambda_base(aws; release = "release-0.4")

    # List of Amazon Linux packages to install...
    yum_list = ["git",
                "cmake",
                "m4",
                "patch",
                "gcc",
                "gcc-c++",
                "gcc-gfortran",
                "libgfortran",
                "openssl-devel"]

    append!(yum_list, get(aws, :lambda_yum_packages, []))


    # List of Julia packages to install...
    pkg_add_list = aws[:lambda_packages]
    pkg_clone_list = get(aws, :lambda_packages_clone, [])

    if !("JSON" in pkg_add_list)
        push!(pkg_add_list, "JSON")
    end


    # FIXME
    # consider downloading base tarball from here:
    # https://github.com/samoconnor/AWSLambda.jl/releases/download/v0.0.10/jl_lambda_base.tgz

    server_config = [(

        "cloud_config.txt", "text/cloud-config",

        "packages:\n$(string([" - $p\n" for p in yum_list]...))"

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
        /var/task/bin/julia -e 'Pkg.init()'
        $(join(["/var/task/bin/julia -e 'Pkg.add(\"$p\")'\n" for p in pkg_add_list]))
        $(join(["/var/task/bin/julia -e 'Pkg.clone(\"$p\")'\n" for p in pkg_clone_list]))
#        /var/task/bin/julia -e 'Pkg.checkout(\"AWSCore\", pull=true)'
#        /var/task/bin/julia -e 'Pkg.checkout(\"AWSSDB\", pull=true)'
#        /var/task/bin/julia -e 'Pkg.checkout(\"AWSLambda\", pull=true)'
        $(join(["/var/task/bin/julia -e 'using $p'\n" for p in pkg_add_list]))
        $(join(["/var/task/bin/julia -e 'using $p'\n" for p in pkg_clone_list]))

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

    # http://docs.aws.amazon.com/lambda/latest/dg/current-supported-versions.html
    ami = ec2(aws, @SymDict(
            Action = "DescribeImages",
            "Filter.1.Name" = "owner-alias",
            "Filter.1.Value" = "amazon",
            "Filter.2.Name" = "name",
            "Filter.2.Value" = "amzn-ami-hvm-2015.09.1.x86_64-gp2"))

    create_ec2(aws, "ocaws_jl_lambda_build_server",
                    ImageId      = ami["imagesSet"]["item"]["imageId"],
                    InstanceType = "c3.large",
                    KeyName      = "ssh-ec2",
                    UserData     = server_config,
                    Policy       = policy)
end



#-------------------------------------------------------------------------------
# API Gateway support http://docs.aws.amazon.com/apigateway/
#-------------------------------------------------------------------------------

hallink(hal, name) = hal["_links"][name]["href"]


function apigateway(aws::SymbolDict, verb, resource; args...)
    apigateway(aws, verb, resource, Dict(args))
end


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
