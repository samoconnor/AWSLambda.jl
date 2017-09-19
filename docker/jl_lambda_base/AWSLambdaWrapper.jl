#==============================================================================#
# AWSLambdaWrapper.jl
#
# AWS Lambda wrapper for Julia.
#
# See http://docs.aws.amazon.com/lambda/latest/dg/API_Reference.html
#
# Copyright OC Technology Pty Ltd 2014 - All rights reserved
#==============================================================================#


__precompile__()


module AWSLambdaWrapper


using JSON


# Run the lambda function...
@inline function invoke_lambda(lambda_module::Module)

    # Read input file...
    local input::Dict{String,Any}
    input = JSON.parsefile("/tmp/lambda_in", dicttype=Dict{String,Any})

    local event::Dict{String,Any}
    event = input["event"]

    global AWS_LAMBDA_CONTEXT = input["context"]

    # Load optional modules...
    local modules::Vector{Any}
    modules = get(event, "jl_modules", [])
    for m in modules
        eval(Main, :(using $(Symbol(m))))
    end

    # Run function and save result to output file...
    open("/tmp/lambda_out", "w") do out

        if haskey(event, "jl_data")

            local jl_data::String
            jl_data = event["jl_data"]

            local args::Tuple
            args = deserialize(Base64DecodePipe(IOBuffer(jl_data)))
            b64_out = Base64EncodePipe(out)
            serialize(b64_out, lambda_module.lambda_function(args...))
            close(b64_out)

        else

            JSON.print(out, lambda_module.lambda_function_with_event(event))

        end
    end
end


function main(lambda_module::Module)

    while !eof(STDIN)
        readavailable(STDIN)
        invoke_lambda(lambda_module)
        write(STDOUT, "\0\n")
    end
end


precompile(main, (Module,))


end # module AWSLambdaWrapper


#==============================================================================#
# End of file.
#==============================================================================#
