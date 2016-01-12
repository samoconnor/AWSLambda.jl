#==============================================================================#
# SNS/test/runtests.jl
#
# Copyright Sam O'Connor 2014 - All rights reserved
#==============================================================================#


using AWSLambda
using AWSSNS
using Retry
using Base.Test

AWSCore.set_debug_level(1)


#-------------------------------------------------------------------------------
# Load credentials...
#-------------------------------------------------------------------------------

aws = AWSCore.aws_config(
                         region = "ap-northeast-1",
                         lambda_bucket = "ocaws.jl.lambdatest.tokyo",
                         #region = "us-east-1",
                         #lambda_bucket = "ocaws.jl.lambdatest",
                         lambda_packages = ["Requests",
                                            "Nettle",
                                            "LightXML",
                                            "JSON",
                                            "DataStructures",
                                            "StatsBase",
                                            "DataFrames",
                                            "DSP",
                                            "GZip",
                                            "ZipFile",
                                            "IniFile",
                                            "SymDict",
                                            "XMLDict",
                                            "Retry"
                                           ])


#using AWSS3
#s3_copy(aws, "ocaws.jl.lambdatest", "jl_lambda_base.zip",
#             to_bucket="ocaws.jl.lambdatest.tokyo", to_path= "jl_lambda_base.zip")

#-------------------------------------------------------------------------------
# Lambda tests
#-------------------------------------------------------------------------------


if false
create_jl_lambda_base(aws)
else


push!(LOAD_PATH, "/Users/sam/git/octech/pkg/software/oclib")
#aws[:lambda_modules] = ["OCUtil.jl"]


f = @lambda aws function foo(a, b::Int)

#    using Requests
#    using Nettle
#    using LightXML
#    using JSON
#    using DataStructures
#    using StatsBase
#    using DataFrames
#    using DSP
#    using GZip
#    using ZipFile
#    using IniFile
    using OCUtil
#    using SymDict
#    using XMLDict
#    using Retry

    fnv32(Array{UInt8}([1,2,3,4,5,6,7,8,9,0,1,2, a, b]))
end

for i = 1:4
    println(i % 2 == 0 ? f(i,i) : foo(aws,i,i))
end

#=
@lambda aws function lambda_compilecache(name)

    ji = nothing
    mktempdir() do tmp
        insert!(Base.LOAD_CACHE_PATH, 1, tmp)
        ji = open(readbytes, compilecache(name))
    end
    return ji
end

println(amap(f, [(i,i) for i = 1:1]))

=#

#println(lambda_compilecache(aws, "OCUtil"))


end


#==============================================================================#
# End of file.
#==============================================================================#
