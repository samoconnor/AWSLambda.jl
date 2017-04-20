#==============================================================================#
# SNS/test/runtests.jl
#
# Copyright OC Technology Pty Ltd 2014 - All rights reserved
#==============================================================================#


using AWSCore
using AWSLambda
using AWSSNS
using Retry
using SymDict
using JSON
using Base.Test

AWSCore.set_debug_level(1)


#-------------------------------------------------------------------------------
# Load credentials...
#-------------------------------------------------------------------------------

aws = aws_config()


deploy_jl_lambda_base()



#-------------------------------------------------------------------------------
# Lambda tests
#-------------------------------------------------------------------------------


# Count primes in the cloud...

if false
λ = @λ aws function count_primes(low::Int, high::Int)

    using Primes

    count = length(primes(low, high))
    println("$count primes between $low and $high.")
    return count
end

@test invoke_lambda(aws, "count_primes", low = 10, high = 100)[:jl_data] == "21"
end


# Count primes in parallel...
if false
function count_primes(low::Int, high::Int)
    w = 500000000
    counts = amap(λ, [(i, min(high,i + w)) for i = low:w:high])
    count = sum(counts)
    println("$count primes between $low and $high.")
    return count
end

@test count_primes(10, 10000000000) == 455052507
end



mktempdir() do tmp
    cd(tmp) do

        # Create a test module under "tmp"...

        mkpath("TestModule")
        open(io->write(io, """
            __precompile__()

            module TestModule

            export test_function


            test_function(x) = x * x

            end
        """), "TestModule/TestModule.jl", "w")

        push!(LOAD_PATH, "TestModule")
        eval(:(using TestModule))

        # Create a lambda that uses the TestModule...
        λ = @λ aws function lambda_test(x)

            # Check that precompile cache is being used...
            @assert !Base.stale_cachefile("/var/task/julia/TestModule/TestModule.jl",
                                          "/var/task/julia/lib/v0.5/TestModule.ji")
            using TestModule
            return test_function(x)
        end

        @test λ(4) == 16
    end
end



#-------------------------------------------------------------------------------
# API Gateway tests
#-------------------------------------------------------------------------------


if false

for api in apigateway_restapis(aws)
    apigateway(aws, "DELETE", "/restapis/$(api["id"])")
end


apigateway_create(aws, "count_primes", (:low, :high))

end


#==============================================================================#
# End of file.
#==============================================================================#
