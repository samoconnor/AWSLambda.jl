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


lambda_function(f::Function) = Base.invokelatest(f)

lambda_function(e::Expr) = eval(Main, e)

function lambda_function(v::Vector)
    for e in v[1:end-1]
        eval(Main, e)
    end
    eval(Main, v[end])
end


lambda_function_with_event(event::String) = include_string(event)


precompile(lambda_function, (Function,))
precompile(lambda_function, (Expr,))
precompile(lambda_function, (Vector{Expr},))
precompile(lambda_function_with_event, (String,))


end



#==============================================================================#
# End of file.
#==============================================================================#
