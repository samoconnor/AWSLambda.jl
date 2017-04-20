#==============================================================================#
# AWSLambda.jl
#
# AWS Lambda API.
#
# See http://docs.aws.amazon.com/lambda/latest/dg/API_Reference.html
#
# Copyright OC Technology Pty Ltd 2014 - All rights reserved
#==============================================================================#


__precompile__()


module AWSLambda


export list_lambdas, create_lambda, update_lambda, delete_lambda, invoke_lambda,
       async_lambda, create_jl_lambda, invoke_jl_lambda, create_lambda_role,
       @λ, @lambda, lambda_add_permission, lambda_get_permissions,
       lambda_delete_permission, lambda_delete_permissions,
       create_py_lambda,
       lambda_compilecache,
       deploy_jl_lambda_base, create_jl_lambda_base,
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
using FNVHash
using Base.Pkg

import Nettle: hexdigest



#-------------------------------------------------------------------------------
# AWS Lambda REST API.
#-------------------------------------------------------------------------------


function lambda(aws::AWSConfig, verb; path="", query="", headers = Dict())

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
        r = symboldict(r)
    end

    return r
end


list_lambdas(aws::AWSConfig) = [symboldict(f)
                                for f in lambda(aws, "GET")[:Functions]]


function lambda_configuration(aws::AWSConfig, name)

    @protected try

        return lambda(aws, "GET", path="$name/configuration")

    catch e
        @ignore if e.code == "404" end
    end

    return nothing
end


function lambda_update_configuration(aws::AWSConfig, name, options)

    lambda(aws, "PUT", path="$name/configuration", query=options)
end


lambda_exists(aws::AWSConfig, name) = lambda_configuration(aws, name) != nothing


function create_lambda(aws::AWSConfig, name;
                       ZipFile=nothing,
                       S3Key="$name.zip",
                       S3Bucket=get(aws, :lambda_bucket, nothing),
                       Handler="lambda_main.main",
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
        @delay_retry if e.code == "400" end
    end
end


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


function lambda_publish_version(aws::AWSConfig, name, alias)

    r = lambda(aws, "POST", path="$name/versions")
    @protected try
        lambda_create_alias(aws, name, alias, FunctionVersion=r[:Version])
    catch e
        @ignore if e.code == "409"
            lambda_update_alias(aws, name, alias, FunctionVersion=r[:Version])
        end
    end
end


function lambda_create_alias(aws::AWSConfig, name, alias;
                             FunctionVersion="\$LATEST")

    lambda(aws, "POST", path="$name/aliases",
                        query=@SymDict(FunctionVersion, Name=alias))
end


function lambda_update_alias(aws::AWSConfig, name, alias;
                             FunctionVersion="\$LATEST")

    lambda(aws, "PUT", path="$name/aliases/$alias",
                       query=@SymDict(FunctionVersion))
end


function lambda_add_permission(aws::AWSConfig, name, permission)

    lambda(aws, "POST", path="$name/policy", query=permission)
end


function lambda_delete_permission(aws::AWSConfig, name, id)

    lambda(aws, "DELETE", path="$name/policy/$id")
end

function lambda_delete_permissions(aws::AWSConfig, name)

    for p in lambda_get_permissions(aws, name)
        lambda_delete_permission(aws, name, p["Sid"])
    end
end


function lambda_get_permissions(aws::AWSConfig, name)

    @protected try
        r = lambda(aws, "GET", path="$name/policy")
        return JSON.parse(r[:Policy])["Statement"]
    catch e
        @ignore if e.code == "404"
            return Dict[]
        end
    end
end


function delete_lambda(aws::AWSConfig, name)

    @protected try
        lambda(aws, "DELETE", path=name)
    catch e
        @ignore if e.code == "404" end
    end
end


export AWSLambdaException


type AWSLambdaException <: Exception
    name::String
    message::String
end


function Base.show(io::IO, e::AWSLambdaException)

    println(io, string("AWSLambdaException \"", e.name, "\":\n", e.message, "\n"))
end


function invoke_lambda(aws::AWSConfig, name, args; async=false)


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
        if try e.code == "429" catch false end
            e.message = e.message *
                " See http://docs.aws.amazon.com/lambda/latest/dg/limits.html"
        end
    end

    @assert false # Unreachable
end


function invoke_lambda(aws::AWSConfig, name; args...)
    return invoke_lambda(aws, name, symboldict(args))
end


function async_lambda(aws::AWSConfig, name, args)
    return invoke_lambda(aws, name, args; async=true)
end


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
        @ignore if e.code == "EntityAlreadyExists" end
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

    options = @SymDict(Role, ZipFile = create_zip("lambda_main.py" => py_code))

    old_config = lambda_configuration(aws, name)

    if old_config == nothing
        create_lambda(aws, name; options...)
    else
        update_lambda(aws, name; options...)
    end
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
    takebuf_string(buf)
end


# Invoke a Julia AWS Lambda function.
# Serialise "args" and deserialise result.

function invoke_jl_lambda(aws::AWSConfig, name, args...;
                          jl_modules=Symbol[])

    r = invoke_lambda(aws, name, jl_modules = jl_modules,
                                 jl_data = serialize64(args))
    try
        println(r[:stdout])
    end
    try
        return deserialize(Base64DecodePipe(IOBuffer(r[:jl_data])))
    end
    return r
end


# Returns an anonymous function that calls "func" in the Lambda sandbox.
# e.g. @lambda_call(aws, println)("Hello")
#      @lambda_call(aws, x -> x*x)(4)
#      @lambda_call(aws, [:JSON], s -> JSON.parse(s))("{}")

macro lambda_call(aws, args...)

    @assert length(args) <= 2
    func = Expr(:quote, args[end])
    modules = length(args) > 1 ? eval(args[1]) : Symbol[]
    @assert isa(modules, Vector{Symbol})

    esc(quote
        (args...) -> invoke_jl_lambda($aws, :jl_lambda_eval, $func, args;
                                            jl_modules = $modules)
    end)
end


# Evaluate "expr" in the Lambda sandbox.

macro lambda_eval(aws, args...)

    @assert length(args) <= 2
    expr = args[end]
    modules = length(args) > 1 ? eval(args[1]) : Symbol[]
    @assert isa(modules, Vector{Symbol})

    esc(quote @lambda_call($aws,$modules,()->$expr)() end)
end


# Evaluate "code" in the Lambda sandbox.

function lambda_include_string(aws::AWSConfig, code)
    @lambda_call(aws, include_string)(code)
end


# Evaluate "filename" in the Lambda sandbox.

function lambda_include(aws::AWSConfig, filename)
    code = readstring(filename)
    @lambda_call(aws, include_string)(code, filename)
end


# Create an AWS Lambda to run "jl_code".

function create_jl_lambda(aws::AWSConfig, name, jl_code,
                          modules=Symbol[], options=SymDict())

    options = copy(options)

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

    # Get error topic from "aws" or "options"...
    error_sns_arn = get(options, :error_sns_arn,
                    get(aws, :lambda_error_sns_arn, ""))
    push!(py_config, "error_sns_arn = '$error_sns_arn'\n")

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

    deploy_lambda = @lambda_call(aws,
        [:AWSLambda, :AWSS3, :InfoZIP],
        (aws, name, load_path, options, is_new) -> begin

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
                #run(`ls -la / $tmpdir`)

                # Create module precompilation directory under /tmp...
                ji_path = Base.LOAD_CACHE_PATH[1]
                ji_path = replace(ji_path, "/var/task", tmpdir, 1)
                mkpath(ji_path)

                # Run precompilation...
                cmd = "push!(LOAD_PATH, \"$tmpdir\")\n"
                v = "v$(VERSION.major).$(VERSION.minor)"
                cmd *= "push!(LOAD_PATH, \"$tmpdir/julia/$v\")\n"
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
                r = create_lambda(aws, name; options...)
            else
                r = update_lambda(aws, name; options...)
            end
        end)

    deploy_lambda(aws, name, load_path, options, old_config == nothing)
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

    @assert length(args) <= 3 usage

    aws = args[1]

    f = args[end]
    @assert isa(f, Expr) usage
    @assert f.head == :function usage

    options = length(args) > 2 ? esc(args[2]) : :(Dict())

    # Rewrite function name to be :lambda...
    call, body = f.args
    name = call.args[1]
    call.args[1] = :lambda_function
    args = call.args[2:end]

    # Split "using module" lines out of body...
    modules = filter(e->isa(e, Expr) && e.head == :using, body.args)
    modules = Symbol[m.args[1] for m in modules]
    body.args = filter(e->!isa(e, Expr) || e.head != :using, body.args)

    # Generate code to extract args from event Dict...
    arg_names = [isa(a, Expr) ? a.args[1] : a for a in args]
    get_args = join(["""event["$a"]""" for a in arg_names], ", ")

    jl_code = """
        __precompile__()

        module module_$name

        $(join(["using $m" for m in modules], "\n"))

        function $call
            $body
        end

        function lambda_function_with_event(event::Dict{String,Any})
            lambda_function($get_args)
        end

        end
        """

    # Add "aws" dict as first arg...
    insert!(f.args[1].args, 2, :aws)

    # Replace function body with Lambda invocation...
    f.args[2] = :(invoke_jl_lambda(aws, $name, $(args...)))


    call.args[1] = name

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


# List of modules in the Lambda sandbox ".ji" cache.

function lambda_module_cache(aws::AWSConfig)

    @lambda_call(aws, [:AWSLambda], AWSLambda.local_module_cache)()
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
    load_path = collect(filter(p->p != pkgd, keys(d)))
    prefix, short_load_path = path_prefix_split(load_path)

    # Build archive of file content...
    archive = OrderedDict()
    for (p, s) in zip([load_path...; pkgd],
                      [short_load_path...; basename(pkgd)])
        for f in get(d,p,[])
            archive[joinpath("julia", s, f)] = read(joinpath(p, f))
        end
    end

    return short_load_path, archive
end


#-------------------------------------------------------------------------------
# Deploy pre-cooked Julia Base Lambda
#-------------------------------------------------------------------------------

function deploy_jl_lambda_base(aws::AWSConfig)

    create_lambda(aws, "jl_lambda_eval";
                  S3Key="jl_lambda_base_0.1.3.zip",
                  S3Bucket="octech.com.au.$(aws[:region]).awslambda.jl.deploy",
                  Role = create_lambda_role(aws, "jl_lambda_eval"))
end

function deploy_jl_lambda_base_to_s3(aws::AWSConfig)

    zip = "jl_lambda_base_0.1.3.zip"

    source_path = "octech.com.au.awslambda.jl.deploy/$zip"

    lambda_regions = ["us-east-1",
                      "us-east-2",
                      "us-west-1",
                      "us-west-2",
                      "ap-northeast-2",
                      "ap-south-1",
                      "ap-southeast-1",
                      "ap-southeast-2",
                      "ap-northeast-1",
                      "eu-central-1",
                      "eu-west-1",
                      "eu-west-2"]

    for r in lambda_regions
        raws = merge(aws, Dict(:region => r))

        bucket = "octech.com.au.$r.awslambda.jl.deploy"

        s3_create_bucket(raws, bucket)

        AWSS3.s3(aws, "PUT", bucket;
                 path = zip,
                 headers = Dict("x-amz-copy-source" => source_path,
                                "x-amz-acl" => "public-read"))
    end
end


#-------------------------------------------------------------------------------
# Julia Runtime Build Script
#-------------------------------------------------------------------------------


# Build the Julia runtime using a temporary EC2 server.
# Takes about 1 hour, (or about 5 minutes if full rebuild is not done).
# Upload the Julia runtime to "aws[:lambda_bucket]/jl_lambda_base.zip".

function create_jl_lambda_base(aws::AWSConfig;
                               release = "v0.5.0", ssh_key=nothing)

    # Role assumed by basic "jl_lambda_eval" lambda function...
    role = create_lambda_role(aws, "jl_lambda_eval")

    # List of Amazon Linux packages to install...
    yum_list = ["git",
                "cmake",
                "m4",
                "patch",
                "gcc",
                "gcc-c++",
                "gcc-gfortran",
                "libgfortran",
                "openssl-devel",
                "mesa-libGL-devel"]

    append!(yum_list, get(aws, :lambda_yum_packages, []))

    # Default Julia packages...
    pkg_list = ["Compat",
                "DataFrames",
                "DSP",
                "Colors",
                "FixedSizeArrays",
                "Iterators",
                "Requests",
                "FNVHash",
                "GR",
                ("SymDict", "master"),
                ("AWSCore", "master"),
                ("AWSEC2", "master"),
                ("AWSIAM", "master"),
                "AWSS3",
                ("AWSSNS", "master"),
                ("AWSSQS", "master"),
                "AWSSES",
                ("AWSSDB", "master"),
                ("AWSLambda", "master")]

    for p in get(aws, :lambda_packages, [])
        if !(p in pkg_list)
            push!(pkg_list, p)
        end
    end

    build_env = []
    for (k,v) in get(aws, :lambda_build_env, Dict())
        push!(build_env, "export $k=\"$v\"\n")
    end

    # List of Julia packages to install...
    pkg_add_cmd = "Pkg.init(); Pkg.update(); "
    pkg_using_cmd = "using AWSLambdaWrapper; using module_jl_lambda_eval; "
    for p in pkg_list
        if isa(p, Tuple)
            p, x = p
            if ismatch(r"^http", x)
                pkg_add_cmd *= "Pkg.clone(\"$x\"); "
                pkg_add_cmd *= "Pkg.build(\"$p\"); "
            else
                pkg_add_cmd *= "Pkg.add(\"$p\"); "
                pkg_add_cmd *= "Pkg.checkout(\"$p\", \"$x\"); "
            end
        else
            pkg_add_cmd *= "Pkg.add(\"$p\"); "
        end
        pkg_using_cmd *= "using $p; "
    end

    # ZIP archive of wrapper code...
    zip = ["lambda_main.py",
           "lambda_config.py",
           "AWSLambdaWrapper.jl",
           "module_jl_lambda_eval.jl"]
    zip = Dict(Pair[f => read(joinpath(dirname(@__FILE__), f)) for f in zip])
    zip = base64encode(create_zip(zip))


    # FIXME
    # consider downloading base tarball from here:
    # https://github.com/samoconnor/AWSLambda.jl/releases/download/v0.0.10/jl_lambda_base.tgz

    # Intel(R) Xeon(R) CPU E5-2666 v3 @ 2.90GHz
    arch = "HASWELL"
    march = "core-avx2"
    instance_type = "c4.large"

    bash_script = [

    """
    cd /

    # Set up /var/task Lambda staging dir...
    mkdir -p /var/task/julia
    export HOME=/var/task
    export JULIA_PKGDIR=/var/task/julia
    export AWS_DEFAULT_REGION=$(aws[:region])
    """,

    build_env...,

    """
    if aws s3 cp s3://$(aws[:lambda_bucket])/jl_lambda_base.tgz \\
                 /jl_lambda_base.tgz
    then
        tar xzf jl_lambda_base.tgz
    else

        # Download Julia source code...
        git clone git://github.com/JuliaLang/julia.git
        cd julia
        git checkout $release


        # Configure Julia for the CPU used by AWS Lambda...
        cp Make.inc Make.inc.orig
        find='OPENBLAS_TARGET_ARCH:=.*\$'
        repl='OPENBLAS_TARGET_ARCH:=$arch\\nMARCH:=$march'
        sed s/\$find/\$repl/ < Make.inc.orig > Make.inc


        # Disable precompile path check...
        patch -p1 << EOF
        diff --git a/base/loading.jl b/base/loading.jl
        index e1b9946..ed0bc3e 100644
        --- a/base/loading.jl
        +++ b/base/loading.jl
        @@ -677,6 +677,7 @@ function stale_cachefile(modpath::String, cachefile::String)
                         return true # cachefile doesn't provide the required version of the dependency
                     end
                 end
        +return false

                 # now check if this file is fresh relative to its source files
                 if !samefile(files[1][1], modpath)
    EOF

        # Build and install Julia under /var/task...
        make -j2 prefix= DESTDIR=/var/task all
        make prefix= DESTDIR=/var/task install

        # Save tarball of raw Julia build...
        cd /
        tar czfP jl_lambda_base.tgz var/task
        aws s3 cp /jl_lambda_base.tgz \\
                  s3://$(aws[:lambda_bucket])/jl_lambda_base.tgz
    fi

    # Disable yum to prevent BinDeps.jl from using it...
    # https://github.com/JuliaLang/BinDeps.jl/issues/168
    chmod 000 /usr/bin/yum

    # Install Julia modules...
    /var/task/bin/julia -e '$pkg_add_cmd'
    echo $zip | base64 -d > /tmp/jl.zip && unzip -d /var/task /tmp/jl.zip

    # Precompile modules...
    #JULIA_LOAD_PATH=/var/task /var/task/bin/julia -e '$pkg_using_cmd'

    # FIXME userimg experiment....
    echo '$pkg_using_cmd' > /tmp/userimg.jl
    cp /var/task/AWSLambdaWrapper.jl \\
       /var/task/module_jl_lambda_eval.jl \\
       /var/task/julia/v*
    HAVE_INFOZIP=1 \\
    /var/task/bin/julia /var/task/share/julia/build_sysimg.jl \\
                        /tmp/sys native /tmp/userimg.jl
    mv -f /tmp/sys.so /var/task/lib/julia/
    rm -f /var/task/julia/lib/v*/*.ji

    # Copy minimal set of files to /task-staging...
    mkdir -p /task-staging/bin
    mkdir -p /task-staging/lib/julia

    cd /task-staging

    cp /var/task/bin/julia bin/
    cp -a /var/task/lib/julia/*.so* lib/julia/
    rm -f lib/julia/*-debug.so*

    cp -a /var/task/lib/*.so* lib/
    rm -f lib/*-debug.so*

    cp -a /usr/lib64/libgfortran.so* lib/
    cp -a /usr/lib64/libquadmath.so* lib/

    cp /usr/bin/zip bin/

    # Copy pre-compiled modules to /tmp/task...
    cp -a /var/task/julia .
    chmod -R a+r julia/lib/
    cp -a /var/task/*.jl .
    cp -a /var/task/*.py .

    # Remove unnecessary files...
    find julia -name '.git' \\
            -o -name '.cache' \\
            -o -name '.travis.yml' \\
            -o -name '.gitignore' \\
            -o -name 'REQUIRE' \\
            -o -name 'test' \\
            -o -path '*/deps/downloads' \\
            -o -path '*/deps/builds' \\
            -o \\( -type f -path '*/deps/src/*' ! -name '*.so.*' \\) \\
            -o -path '*/deps/usr/include' \\
            -o -path '*/deps/usr/bin' \\
            -o -path '*/deps/usr/lib/*.a' \\
            -o -name 'doc' \\
            -o -name 'examples' \\
            -o -name '*.md' \\
            -o -name 'METADATA' \\
            -o -path '*/gr/lib/movplugin.so' \\
            -o -path '*/GR/src/*.js' \\
        | xargs rm -rf

    find . -name '*.so' | xargs strip

    # Create .zip file...
    zip -u --symlinks -r -9 /jl_lambda_base.zip *

    # Copy .zip file to S3...
    aws s3 cp /jl_lambda_base.zip \\
              s3://$(aws[:lambda_bucket])/jl_lambda_base.zip

    # Delete Lambda function...
    aws lambda delete-function --function-name "jl_lambda_eval" || true

    # Create Lambda function...
    aws lambda create-function \\
            --function-name "jl_lambda_eval" \\
            --runtime "python2.7" \\
            --role "$role" \\
            --timeout 300 \\
            --handler "lambda_main.main" \\
            --memory-size 1536 \\
            --zip-file fileb:///jl_lambda_base.zip
    """]

    ec2_bash(aws,

        bash_script...,

        instance_name = "ocaws_jl_lambda_build_server",

        instance_type = instance_type,

        image = "amzn-ami-hvm-2015.09.1.x86_64-gp2",

        ssh_key = ssh_key,

        packages = yum_list,

        policy = """{
            "Version": "2012-10-17",
            "Statement": [ {
                "Effect": "Allow",
                "Action": "lambda:*",
                "Resource": "*"
            }, {
                "Effect": "Allow",
                "Action": "iam:PassRole",
                "Resource": "*"
            }, {
                "Effect": "Allow",
                "Action": [ "s3:PutObject", "s3:GetObject" ],
                "Resource": [
                    "arn:aws:s3:::$(aws[:lambda_bucket])/jl_lambda_base.*"
                ]
            } ]
        }""")

end



#-------------------------------------------------------------------------------
# API Gateway support http://docs.aws.amazon.com/apigateway/
#-------------------------------------------------------------------------------

hallink(hal, name) = hal["_links"][name]["href"]


#function apigateway(aws::AWSConfig, verb, resource; args...)
#    apigateway(aws, verb, resource, Dict(args))
#end


function apigateway(aws::AWSConfig, verb, resource="/restapis", query=Dict())

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


function apigateway_restapis(aws::AWSConfig)
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


function apigateway_lambda_arn(aws::AWSConfig, name)
    name = arn(aws, "lambda", "function:$name")
    f = "/2015-03-31/functions/$name/invocations"
    "arn:aws:apigateway:$(aws[:region]):lambda:path$f"
end


function apigateway_create(aws::AWSConfig, name, args)

    lambda_arn = apigateway_lambda_arn(aws, name)
    api = apigateway(aws, "POST", "/restapis", name = name)
    id = api["id"]
    method = "$(hallink(api, "resource:create"))/methods/GET"
    params = Dict(Pair["method.request.querystring.$a" => false for a in args])
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
