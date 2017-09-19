#==============================================================================#
# module_jl_lambda_eval.jl
#
# Default AWS Lambda function for Julia.
#
# See http://docs.aws.amazon.com/lambda/latest/dg/API_Reference.html
#
# Copyright OC Technology Pty Ltd 2014 - All rights reserved
#==============================================================================#


__precompile__()


module module_jl_lambda_eval


lambda_function(func::Expr, args::Vector{Any}) = eval(Main, func)(args...)


function lambda_function_with_event(event::Dict{String, Any})
    local func::String
    func = event["func"]
    local args::Vector
    args = event["args"]
    lambda_function(parse(func), (args...))
end


precompile(lambda_function, (Expr, Vector{Any}))
precompile(lambda_function_with_event, (Dict{String,Any},))


end



#==============================================================================#
# End of file.
#==============================================================================#
