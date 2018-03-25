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


function invoke_jl_lambda(lambda_module, input::String, output::IOStream)

    b64in = Base64DecodePipe(IOBuffer(input))
    b64out = Base64EncodePipe(output)
    serialize(b64out, lambda_module.lambda_function(deserialize(b64in)...))
    close(b64out)
end


function invoke_lambda(lambda_module, input, output::IOStream)

    if input isa Dict{String,Any} && haskey(input, "jl_data")
        invoke_jl_lambda(lambda_module, input["jl_data"], output)
    else
        JSON.print(output, lambda_module.lambda_function_with_event(input))
    end
end


function main(lambda_module::Module)

    # Wait for python wrapper to send "\n", signalling that input is waiting.
    while !eof(STDIN)
        readavailable(STDIN)

        # Read JSON input from file.
        input = JSON.parsefile("/tmp/lambda_in", dicttype=Dict{String,Any})

        # Invoke lambda_module and save output to file.
        open("/tmp/lambda_out", "w") do output
            invoke_lambda(lambda_module, input, output)
        end

        # Signal end of output. 
        write(STDOUT, "\0\n")
    end
end


context() = JSON.parsefile("/tmp/lambda_context")


precompile(main, (Module,))
precompile(invoke_jl_lambda, (Module, String, IOStream))
precompile(invoke_lambda, (Module, String, IOStream))
precompile(invoke_lambda, (Module, Dict{String,Any}, IOStream))
precompile(invoke_lambda, (Module, Vector{Any}, IOStream))


end # module AWSLambdaWrapper


#==============================================================================#
# End of file.
#==============================================================================#
