#==============================================================================#
# AWSLambda.jl
#
# AWS Lambda API.
#
# See http://docs.aws.amazon.com/lambda/latest/dg/API_Reference.html
#
# Copyright OC Technology Pty Ltd 2014 - All rights reserved
#==============================================================================#

#=
TODO

 - Test on windows.


TODO later:

 - can bindeps be deployed easily from BinaryBuilder/Linux??

 - rename functions to shorter e.g. AWSLambda.create
=#


#FIXME https://github.com/awslabs/serverless-application-model
#FIXME https://github.com/awslabs/aws-sam-local
#FIXME DLQ
#FIXME tagging
#FIXME environment variables

__precompile__()


module AWSLambda

using AWSCore
using AWSIAM
using JSON
using InfoZIP
using Retry
using SymDict
using DataStructures
using Glob
using FNVHash
using Base.Pkg
using HTTP
import HTTP: @require, precondition_error

const jl_version = "JL_$(replace(string(VERSION), ".", "_"))"
const aws_lamabda_jl_version = "0.3.0"



#-------------------------------------------------------------------------------
# AWS Lambda REST API.
#-------------------------------------------------------------------------------


function lambda(aws::AWSConfig, verb; path="", query=[], headers=Dict())

    aws = copy(aws)
    aws[:ordered_json_dict] = false

    resource = HTTP.escapepath("/2015-03-31/functions/$path")

    query = @SymDict(headers, query...)

    r = AWSCore.Services.lambda(aws, verb, resource, query)

    if isa(r, Dict)
        r = symboldict(r)
    end

    return r
end


list_lambdas(aws::AWSConfig) =
    [symboldict(f) for f in lambda(aws, "GET")[:Functions]]

list_lambdas() = list_lambdas(default_aws_config())


function lambda_configuration(aws::AWSConfig, name)

    @protected try

        return lambda(aws, "GET", path="$name/configuration")

    catch e
        @ignore if ecode(e) == "404" end
    end

    return nothing
end

lambda_configuration(name) = lambda_configuration(default_aws_config(), name)


function lambda_update_configuration(aws::AWSConfig, name, options)

    lambda(aws, "PUT", path="$name/configuration", query=options)
end

lambda_update_configuration(name, options) =
    lambda_update_configuration(default_aws_config(), name, options)


lambda_exists(aws::AWSConfig, name) = lambda_configuration(aws, name) != nothing

lambda_exists(name) = lambda_exists(default_aws_config(), name)


function create_lambda(aws::AWSConfig, name;
                       ZipFile=nothing,
                       S3Key="$name.zip",
                       S3Bucket=get(aws, :lambda_bucket, nothing),
                       Handler="lambda_function.lambda_handler",
                       Role=role_arn(aws, "jl_lambda_eval_lambda_role"),
                       Runtime="python2.7",
                       MemorySize = 1536,
                       Timeout=300,
                       args...)

    if ZipFile != nothing
        ZipFile = base64encode(ZipFile)
        Code = @SymDict(ZipFile)
    else
        Code = @SymDict(S3Key, S3Bucket)
    end

    query = @SymDict(FunctionName = name,
                     Code,
                     Handler,
                     Role,
                     Runtime,
                     MemorySize,
                     Timeout,
                     args...)

    @repeat 5 try

        lambda(aws, "POST", query=query)

    catch e
        # Retry in case Role was just created and is not yet active...
        @delay_retry if ecode(e) == "400" end
    end
end

create_lambda(name; kw...) = create_lambda(default_aws_config(), name; kw...)


function update_lambda(aws::AWSConfig, name;
                       ZipFile=nothing,
                       S3Key="$name.zip",
                       S3Bucket=get(aws, :lambda_bucket, nothing),
                       args...)

    if ZipFile != nothing
        ZipFile = base64encode(ZipFile)
        query = @SymDict(ZipFile)
    else
        query = @SymDict(S3Key, S3Bucket)
    end

    lambda(aws, "PUT", path="$name/code", query=query)

    if !isempty(args)
        lambda(aws, "PUT", path="$name/configuration", query=@SymDict(args...))
    end
end

update_lambda(name; kw...) = update_lambda(default_aws_config(), name; kw...)


function lambda_publish_version(aws::AWSConfig, name, alias)

    r = lambda(aws, "POST", path="$name/versions")
    @protected try
        lambda_create_alias(aws, name, alias, FunctionVersion=r[:Version])
    catch e
        @ignore if ecode(e) == "409"
            lambda_update_alias(aws, name, alias, FunctionVersion=r[:Version])
        end
    end
end

lambda_publish_version(name, alias) =
    lambda_publish_version(default_aws_config(), name, alias)


function lambda_create_alias(aws::AWSConfig, name, alias;
                             FunctionVersion="\$LATEST")

    lambda(aws, "POST", path="$name/aliases",
                        query=@SymDict(FunctionVersion, Name=alias))
end

lambda_create_alias(name, alias; kw...) =
    lambda_create_alias(default_aws_config(), name, alias; kw...)


function lambda_update_alias(aws::AWSConfig, name, alias;
                             FunctionVersion="\$LATEST")

    lambda(aws, "PUT", path="$name/aliases/$alias",
                       query=@SymDict(FunctionVersion))
end

lambda_update_alias(name, alias; kw...) =
    lambda_update_alias(default_aws_config(), name, alias; kw...)


function lambda_add_permission(aws::AWSConfig, name, permission)

    lambda(aws, "POST", path="$name/policy", query=permission)
end

lambda_add_permission(name, permission) =
    lambda_add_permission(default_aws_config(), name, permission)


function lambda_delete_permission(aws::AWSConfig, name, id)

    lambda(aws, "DELETE", path="$name/policy/$id")
end

lambda_delete_permission(name, id) =
    lambda_delete_permission(default_aws_config(), name, id)


function lambda_delete_permissions(aws::AWSConfig, name)

    for p in lambda_get_permissions(aws, name)
        lambda_delete_permission(aws, name, p["Sid"])
    end
end

lambda_delete_permissions(name) =
    lambda_delete_permissions(default_aws_config(), name)


function lambda_get_permissions(aws::AWSConfig, name)

    @protected try
        r = lambda(aws, "GET", path="$name/policy")
        return JSON.parse(r[:Policy])["Statement"]
    catch e
        @ignore if ecode(e) == "404"
            return Dict[]
        end
    end
end

lambda_get_permissions(name) =
    lambda_get_permissions(default_aws_config(), name)


function delete_lambda(aws::AWSConfig, name)

    @protected try
        lambda(aws, "DELETE", path=name)
    catch e
        @ignore if ecode(e) == "404" end
    end

    return
end

delete_lambda(name) = delete_lambda(default_aws_config(), name)


export AWSLambdaException


type AWSLambdaException <: Exception
    name::String
    message::String
end


function Base.show(io::IO, e::AWSLambdaException)

    info = try
        JSON.parse(e.message)
    catch
        Dict("message" => e.message)
    end
    println(io, string("AWSLambdaException \"", e.name, "\":\n",
                       info["message"], "\n"))
    for (k, v) in info
        if k != "message"
            println(io, "$k: $v")
        end
    end
end


function invoke_lambda(aws::AWSConfig, name, args::Dict; async=false)


    @protected try

        r = lambda(aws, "POST",
                        path="$name/invocations",
                        headers=Dict("X-Amz-Invocation-Type" =>
                                     async ? "Event" : "RequestResponse"),
#FIXME async not working?
                        query=args)

        if isa(r, Dict) && haskey(r, :errorMessage)
            throw(AWSLambdaException(string(name), r[:errorMessage]))
        end

        return r

    catch e
        if ecode(e) == "429"
            e.message = e.message *
                " See http://docs.aws.amazon.com/lambda/latest/dg/limits.html"
        end
    end

    @assert false # Unreachable
end

invoke_lambda(name, args::Dict; kw...) = invoke_lambda(default_aws_config(),
                                                       name, args; kw...)

invoke_lambda(aws::AWSConfig, name; args...) =
    invoke_lambda(aws, name, symboldict(args))

invoke_lambda(name; args...) =
    invoke_lambda(default_aws_config(), name; args...)


async_lambda(aws::AWSConfig, name, args) =
    invoke_lambda(aws, name, args; async=true)

async_lambda(name, args) = async_lambda(default_aws_config(), name, args)


function create_lambda_role(aws::AWSConfig, name, policy="")

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
        @ignore if ecode(e) == "EntityAlreadyExists" end
    end

    AWSIAM.iam(aws, Action = "AttachRolePolicy",
                    RoleName = name,
                    PolicyArn = "arn:aws:iam::aws:policy" *
                                "/service-role/AWSLambdaBasicExecutionRole")

    if policy != ""
        AWSIAM.iam(aws, Action = "PutRolePolicy",
                        RoleName = name,
                        PolicyName = name,
                        PolicyDocument = policy)
    end

    return role_arn(aws, name)
end



#-------------------------------------------------------------------------------
# Python Code Support.
#-------------------------------------------------------------------------------


function create_py_lambda(aws::AWSConfig, name, py_code;
                          Role = create_lambda_role(aws, name))

    options = @SymDict(Role, ZipFile = create_zip("lambda_function.py" => py_code))

    old_config = lambda_configuration(aws, name)

    if old_config == nothing
        create_lambda(aws, name; options...)
    else
        update_lambda(aws, name; options...)
    end
end

create_py_lambda(name, py_code; kw...) =
    create_py_lambda(default_aws_config(), name, py_code; kw...)



#-------------------------------------------------------------------------------
# Julia Modules.
#-------------------------------------------------------------------------------


function local_module_cache()

    # List of modules in local ".ji" cache.
    r = [Symbol(splitext(f)[1]) for f in
            [[readdir(p) for p in
                filter(isdir, Base.LOAD_CACHE_PATH)]...;]]

    # List of modules compiled in to sys image.
    append!(r, filter(x->Main.eval(:(try isa($x, Module)
                                     catch ex
                                         if typeof(ex) != UndefVarError
                                            rethrow(ex)
                                         end
                                         false
                                     end)), names(Main)))

    return unique(r)
end


function __init__()
    global _lambda_module_cache = Symbol[]
end

global _lambda_module_cache = Symbol[]

global default_lambda_module_cache = [
    :AWSCore,
    :AWSIAM,
    :AWSLambda,
    :AWSS3,
    :Base,
    :Compat,
    :Core,
    :DataStructures,
    :FNVHash,
    :Glob,
    :HTTP,
    :InfoZIP,
    :IniFile,
    :IterTools,
    :JSON,
    :LightXML,
    :Main,
    :MbedTLS,
    :Nullables,
    :Retry,
    :SymDict,
    :XMLDict]

# List of modules in the Lambda sandbox ".ji" cache.

function lambda_module_cache(aws::AWSConfig = default_aws_config())

    global _lambda_module_cache
    if isempty(_lambda_module_cache)

        @protected try
            _lambda_module_cache = lambda_eval(aws, :(filter(x->Main.eval(:(
                try
                    isa($x, Module) && !isfile(string("/tmp/julia/", $x, ".ji"))
                catch ex
                    if typeof(ex) != UndefVarError
                        rethrow(ex)
                    end
                    false
                end
            )), names(Main))))
        catch e
            if ecode(e) == "404"
                return default_lambda_module_cache
            end
        end

    end
    return _lambda_module_cache
end


# List of source files required by "modules".

function precompiled_module_files(aws::AWSConfig, modules::Vector{Symbol})

    exclude = lambda_module_cache(aws)

    modules = collect(filter(m->!(m in exclude), modules))

    return unique([[_precompiled_module_files(i, exclude) for i in modules]...;])
end


function _precompiled_module_files(m, exclude_modules)

    # Module must be precompiled...
    if !(m in local_module_cache())
        error("$m not precompiled. Do \"using $m\".")
    end

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

    if length(paths) == 0
        return "", []
    end

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

function module_files(aws::AWSConfig, modules::Vector{Symbol})

    if length(modules) == 0
        return [], OrderedDict()
    end

    pkgd = realpath(Pkg.dir())

    # Build a dict of files for each load path location...
    d = Dict()
    add_file = (p,f) -> (if !haskey(d, p); d[p] = [] end; push!(d[p], f))
    for file in precompiled_module_files(aws, modules)
        file = realpath(file)

        if startswith(file, pkgd)
            add_file(pkgd, file[length(pkgd)+2:end])
            continue
        end

        for p in filter(isdir, LOAD_PATH)
            p = realpath(abspath(p))
            if joinpath(p, basename(file)) == file
                add_file(p, basename(file))
                break
            end
        end
    end

    if isempty(d)
        return [], OrderedDict()
    end


    # Remove common prefix from load path locations...
    load_path = collect(Base.Iterators.filter(p->p != pkgd, keys(d)))
    prefix, short_load_path = path_prefix_split(load_path)
    push!(short_load_path, basename(pkgd))

    # Build archive of file content...
    archive = OrderedDict()
    for (p, s) in zip([load_path...; pkgd],
                      [short_load_path...; basename(pkgd)])
        for f in get(d,p,[])
            path = joinpath("julia", s, f)
            path = replace(path, "\\", "/")
            archive[path] = read(joinpath(p, f))
        end
    end

    return short_load_path, archive
end



#-------------------------------------------------------------------------------
# Julia Code Support.
#-------------------------------------------------------------------------------


# Base64 representation of Julia objects...

function serialize64(x)

    buf = IOBuffer()
    b64 = Base64EncodePipe(buf)
    serialize(b64, x)
    close(b64)
    String(take!(buf))
end


# Invoke a Julia AWS Lambda function.
# Serialise "args" and deserialise result.

function invoke_jl_lambda(aws::AWSConfig, name::String, args...)

    r = invoke_lambda(aws, name, jl_data = serialize64(args))
    try
        println(r[:stdout])
    end
    try
        return deserialize(Base64DecodePipe(IOBuffer(r[:jl_data])))
    end
    return r
end

invoke_jl_lambda(name::String, args...) =
    invoke_jl_lambda(default_aws_config(), name, args...)


# Returns an anonymous function that calls "func" in the Lambda sandbox.
# e.g. lambda_function(println)("Hello")
#      lambda_function(x -> x*x)(4)
#      lambda_function(s -> JSON.parse(s))("{}")

lambda_function(aws, f) =
    (a...) -> invoke_jl_lambda(aws, "jl_lambda_eval:$jl_version",
                                    eval(Main,:(()->$f($a...))))

lambda_function(f) = lambda_function(default_aws_config(), f)


# Prepend `body` with expression to install `modules` under "/tmp"...
function embed_modules_in_body(aws, body, modules)

    load_path, mod_files = module_files(aws, modules)
    quote
        for (path, code) in $([(k, v) for (k,v) in mod_files])
            path = "/tmp/$path"
            println("$path, $(length(code)) bytes")
            mkpath(dirname(path))
            write(path, code)
        end
        if !("/tmp/julia" in Base.LOAD_CACHE_PATH)
            insert!(Base.LOAD_CACHE_PATH, 1, "/tmp/julia")
        end
        for dir in ["/tmp/julia/$p" for p in $load_path]
            if !(dir in Base.LOAD_PATH)
                push!(Base.LOAD_PATH, dir)
            end
        end
        for u in $modules
            eval(Main, :(using $u))
        end
        Base.invokelatest(()->$body)
    end
end


"""
    @lambda [using ...] function name(args...) body end [aws_config]

Define local `function` that executes `body` on AWS Lambda.
"""
macro lambda(args...)

    @require 1 <= length(args) <= 3
    @require all(x-> x isa Expr, args[1:end-1])
    @require args[1].head in (:using, :toplevel, :function)
    @require args[1].head != :toplevel || all(x->x.head == :using, args[1].args)
    @require args[1].head == :function || length(args) > 1 &&
                                          args[2].head == :function

    # Optional last argument is AWSConfig.
    if !(args[end] isa Expr) || args[end].head != :function
        aws = args[end]
    else
        aws = :(Main.AWSCore.default_aws_config())
    end

    if args[1].head == :function
        f = args[1]
        body = f.args[2]
        modules = Symbol[]
    else
        # Optional first argument is `using Foo, Bar, ...`
        f = args[2]
        modules = args[1]
        if modules.head == :using
            modules = Expr(:toplevel, modules)
        end
        @assert modules.head == :toplevel
        modules = [x.args[1] for x in modules.args]
        body = f.args[2]
        body = embed_modules_in_body(eval(aws), body, modules)
    end

    # Replace function body with Lambda invocation.
    args = f.args[1].args[2:end]
    arg_names = [isa(a, Expr) ? a.args[1] : a for a in args]
    l = Expr(:quote, Expr(:->, Expr(:tuple, args...), body))
    f.args[2] = :(AWSLambda.lambda_function($aws, eval(Main, $l))($(arg_names...)))

    return esc(f)
end


# Evaluate "expr" in the Lambda sandbox.

lambda_eval(aws, expr) =
    invoke_jl_lambda(aws, "jl_lambda_eval:$jl_version", expr)

lambda_eval(expr) = lambda_eval(default_aws_config(), expr)

macro lambda_eval(expr)
    if expr.head == :block
        expr = [e for e in expr.args]
    else
        expr = QuoteNode(expr)
    end
    :(lambda_eval($expr))
end


# Evaluate "code" in the Lambda sandbox.

lambda_include_string(aws, code) = lambda_function(aws, include_string)(code)

lambda_include_string(code) = lambda_include_string(default_aws_config(), code)


# Evaluate "filename" in the Lambda sandbox.

function lambda_include(aws::AWSConfig, filename)
    code = readstring(filename)
    lambda_function(aws, include_string)(code, filename)
end

lambda_include(filename) = lambda_include(default_aws_config(), filename)

                                                           # For build_sysimg.jl
                                       @static if isdefined(Base, :uv_eventloop)

# Create an AWS Lambda to run "jl_code".

function create_jl_lambda(name, jl_code, modules=Symbol[], options=SymbolDict())

    options = Dict{Symbol,Any}(copy(options))

    if !haskey(options, :aws)
        aws = default_aws_config()
    else
        aws = options[:aws]
        delete!(options, :aws)
    end

    # Find files and load path for required modules...
    load_path, mod_files = module_files(aws, modules)
    full_load_path = join([":/var/task/julia/$p" for p in load_path])
    py_config = ["os.environ['JULIA_LOAD_PATH'] += '$full_load_path'\n"]

    if AWSCore.debug_level > 0
        println("create_jl_lambda($name)")
        for f in keys(mod_files)
            println("    $f")
        end
    end

    # Get env vars from "aws" or "options"...
    env = get(options, :env,
          get(aws, :lambda_env, Dict()))
    options[:env] = env
    for (n,v) in env
        push!(py_config, "os.environ['$n'] = '$v'\n")
    end

    # Start with ZipFile from options...
    if !haskey(options, :ZipFile)
        options[:ZipFile] = UInt8[]
    end

    if AWSCore.debug_level > 1
        @show py_config
    end

    # Add lambda source and module files to zip...
    open_zip(options[:ZipFile]) do z
        merge!(z, mod_files)
        z["lambda_config.py"] = join(py_config)
        z["module_$name.jl"] = jl_code
    end

    # FNV hash of deployed Julia code is stored in the Description field.
    old_config = lambda_configuration(aws, name)
    new_code_hash = options[:ZipFile] |> open_zip |> Dict |>
                    serialize64 |> fnv32 |> hex
    old_code_hash = old_config == nothing ? nothing :
                    get(old_config, :Description, nothing)

    # Don't create a new lambda if one already exists with same code...
    if new_code_hash == old_code_hash && !get(aws, :lambda_force_update, false)
        return
    end

    options[:Description] = new_code_hash

    deploy_lambda(aws, name, load_path, options, old_config == nothing)
end


@lambda using AWSLambda, AWSS3, InfoZIP function deploy_lambda(
                                          aws, name, load_path, options, is_new)

    println("Foo")

    AWSCore.set_debug_level(1)

    # Unzip lambda source and modules files to /tmp...
    mktempdir() do tmpdir

        for (n, v) in options[:env]
            ENV[n] = replace(v, r"^/var/task", tmpdir)
        end

        if haskey(options, :ZipURL)
            InfoZIP.unzip(Requests.get(options[:ZipURL]).data, tmpdir)
        end

        InfoZIP.unzip(options[:ZipFile], tmpdir)

        # Create module precompilation directory under /tmp...
        v = "v$(VERSION.major).$(VERSION.minor)"
        ji_path = "$tmpdir/julia/lib/$v"
        mkpath(ji_path)

        # Run precompilation...
        cmd = "push!(LOAD_PATH, \"$tmpdir\")\n"
        for p in load_path
            cmd *= "push!(LOAD_PATH, \"$tmpdir/julia/$p\")\n"
        end
        cmd *= "insert!(Base.LOAD_CACHE_PATH, 1, \"$ji_path\")\n"
        cmd *= "using module_$name\n"
        println(cmd)
        run(`$JULIA_HOME/julia -e $cmd`)
        run(`chmod -R a+r $ji_path`)

        # Create new ZIP combining base image and new files from /tmp...
        run(`rm -f /tmp/lambda.zip`)
        run(Cmd(`zip -q --symlinks -r -9 /tmp/lambda.zip .`,
                dir="/var/task"))
        run(Cmd(`zip -q --symlinks -r -9 /tmp/lambda.zip .`,
                dir=tmpdir))
        options[:ZipFile] = read("/tmp/lambda.zip")

        run(`rm -f /tmp/lambda.zip`)
    end

    # Deploy the lambda to AWS...
    if is_new
        r = AWSLambda.create_lambda(aws, name; options...)
    else
        r = AWSLambda.update_lambda(aws, name; options...)
    end

end




# Create an AWS Lambda function.
#
# e.g.
#
#   AWSLambda.@deploy function hello(a, b)
#
#       message = "Hello $a$b"
#
#       println("Log: $message")
#
#       return message
#   end aws
#
#   hello("World", "!") # FIXME invoke lambda
#   Hello World!
#
# @deploy deploys an AWS Lambda that contains the body of the Julia function.


"""
    AWSLambda.@deploy [(option=value, ...)] [using ...] function name(args...)
        function_body
    end

Deploy `function` to AWS Lambda.
"""
macro deploy(options_ex, using_ex, function_ex)
    deploy_ex(options_ex, using_ex, function_ex)
end

macro deploy(ex, function_ex)
    if ex.head in (:toplevel, :using)
        deploy_ex(:(Dict{Symbol,Any}()), ex, function_ex)
    else
        deploy_ex(ex, Expr(:toplevel), function_ex)
    end
end

macro deploy(function_ex)
    deploy_ex(:(Dict{Symbol,Any}()), Expr(:toplevel), function_ex)
end


function deploy_ex(options_ex, using_ex, function_ex)

    # Wrap single-module using expression with :toplevel
    if using_ex.head == :using
        using_ex = Expr(:toplevel, using_ex)
    end

    @require using_ex.head == :toplevel
    @require all(x->x.head == :using, using_ex.args)
    @require function_ex.head == :function

    modules = Symbol[x.args[1] for x in using_ex.args]

    # Rewrite function name to be :lambda_function...
    call, body = function_ex.args
    name = call.args[1]
    call.args[1] = :lambda_function
    args = function_ex.args[1].args[2:end]

    # Generate code to extract args from event Dict...
    arg_names = [isa(a, Expr) ? a.args[1] : a for a in args]
    get_args = Expr(:tuple, [:(event[$(string(a))]) for a in arg_names]...)

    jl_code = """
        __precompile__()

        module $(Symbol("module_$name"))

        $(join(["using $m" for m in modules], "; "))

        $function_ex

        function lambda_function_with_event(event::Dict{String,Any})
            lambda_function$get_args
        end

        end
        """

    :(create_jl_lambda($(string(name)), $jl_code, $modules, $(esc(options_ex))))
end
                                            end # isdefined(Base, :uv_eventloop)
                                                           # For build_sysimg.jl


#-------------------------------------------------------------------------------
# Deploy pre-cooked Julia Base Lambda
#-------------------------------------------------------------------------------

function deploy_jl_lambda_eval(aws::AWSConfig = default_aws_config();
    bucket = "octech.com.au.$(aws[:region]).awslambda.jl.deploy",
    base_zip = "jl_lambda_eval_$(VERSION)_$(aws_lamabda_jl_version).zip")

    old_config = lambda_configuration(aws, "jl_lambda_eval")

    options = @SymDict(S3Key=base_zip,
                       S3Bucket=bucket,
                       Role = create_lambda_role(aws, "jl_lambda_eval"))

    if old_config == nothing
        create_lambda(aws, "jl_lambda_eval"; options...)
    else
        update_lambda(aws, "jl_lambda_eval"; options...)
    end

    lambda_publish_version(aws, "jl_lambda_eval", jl_version)
end



end # module AWSLambda



#==============================================================================#
# End of file.
#==============================================================================#
