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

aws = AWSCore.aws_config(region = "us-east-1",
                         lambda_bucket = "ocaws.jl.lambdatest")



#-------------------------------------------------------------------------------
# Lambda tests
#-------------------------------------------------------------------------------

if false
create_jl_lambda_base(aws, pkg_list = ["Requests",
                                       "Nettle",
                                       "LightXML",
                                       "JSON",
                                       "DataStructures",
                                       "StatsBase",
                                       "DataFrames",
                                       "DSP",
                                       "GZip",
                                       "ZipFile",
                                       "IniFile"])
else

f = @lambda aws function foo(a, b)

    require("Requests")
    require("Nettle")
    require("LightXML")
    require("JSON")
    require("DataStructures")
    require("StatsBase")
    require("DataFrames")
    require("DSP")
    require("GZip")
    require("ZipFile")
    require("IniFile")

    readdir("/var")
end


println(amap(f, [(i,i) for i = 1:1]))

end


#==============================================================================#
# End of file.
#==============================================================================#
