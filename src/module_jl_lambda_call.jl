#==============================================================================#
# module_jl_lambda_call.jl
#
# Default AWS Lambda function for Julia.
#
# See http://docs.aws.amazon.com/lambda/latest/dg/API_Reference.html
#
# Copyright Sam O'Connor 2014 - All rights reserved
#==============================================================================#


module module_jl_lambda_call


using FNVHash
using AWSCore
using AWSEC2
using AWSIAM
using AWSLambda
using AWSS3
using AWSSNS
using AWSSQS
using AWSSES
using AWSSDB
using InfoZIP


function lambda_function(modules::Vector{Symbol}, func, args)

    for m in modules
        eval(:(using $m))
    end

    eval(func)(args...)
end


function lambda_function_with_event(event) 

    lambda_function(Vector{Symbol}(get(event,"modules",[])),
                    parse(event["func"]),
                    event["args"])
end


end



#==============================================================================#
# End of file.
#==============================================================================#
