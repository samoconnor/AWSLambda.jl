#==============================================================================#
# module_jl_lambda_eval.jl
#
# Default AWS Lambda function for Julia.
#
# See http://docs.aws.amazon.com/lambda/latest/dg/API_Reference.html
#
# Copyright Sam O'Connor 2014 - All rights reserved
#==============================================================================#


__precompile__()


module module_jl_lambda_eval


using Compat.UTF8String


lambda_function(func, args) = eval(Main, func)(args...)


function lambda_function_with_event(event::Dict{UTF8String, Any})
    lambda_function(parse(event["func"]), event["args"])
end


end



#==============================================================================#
# End of file.
#==============================================================================#
