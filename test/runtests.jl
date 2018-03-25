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
# Lambda tests
#-------------------------------------------------------------------------------


f = lambda_function(readstring)
@test chomp(f(`uname`)) == "Linux"

f = lambda_function(sum)
@test f([1,2,3.5]) == 6.5

f = lambda_function((a::String, b::Int) -> begin
    repeat(a, b)
end)
@test f("FOO", 2) == "FOOFOO"

@lambda function foo(a::String, b::Int)
    repeat(a, b)
end
@test foo("FOO", 2) == "FOOFOO"


@test lambda_eval(quote
        open("/proc/cpuinfo") do io
            return Dict(strip(k) => strip(v)
                        for (k, v) in (split(l, ":")
                        for l in Iterators.filter(x -> contains(x, ":"), eachline(io))))
        end
    end)["model name"] in ["Intel(R) Xeon(R) CPU E5-2680 v2 @ 2.80GHz",
                           "Intel(R) Xeon(R) CPU E5-2666 v3 @ 2.90GHz",
                           "Intel(R) Xeon(R) CPU E5-2676 v3 @ 2.40GHz"]

@test lambda_include_string("1 + 1") == 2

@test (@lambda_eval begin
    HTTP.header(HTTP.get("http://httpbin.org/ip"), "Content-Type")
end) == "application/json"

r = @lambda_eval begin

    module Foo

        export foo

        using HTTP
        using JSON

        const url = "http://httpbin.org/ip"

        function foo()
            JSON.parse(String(HTTP.get(url).body))
        end
    end

    using .Foo

    foo()
end

@test ismatch(r"^[0-9.]+$", r["origin"])


# Count primes in the cloud...

@lambda function count_primes(low::Int, high::Int)

    function is_prime(n)
        if n ≤ 1
            return false
        elseif n ≤ 3
            return true
        elseif n % 2 == 0 || n % 3 == 0
            return false
        end
        i = 5
        while i * i ≤ n
            if n % i == 0 || n % (i + 2) == 0
                return false
            end
            i += 6
        end
        return true
    end

    c = count(is_prime, low:high)
    println("$c primes between $low and $high.")
    return c
end

@test count_primes(10, 100) == 21


                                 if !haskey(ENV, "AWS_LAMBDA_JL_TEST_SKIP_SLOW")
# Count primes in parallel...
function pcount_primes(low::Int, high::Int)
    w = 5000000
    counts = asyncmap(x->count_primes(x...),
                      [(i, min(high,i + w)) for i = low:w:high])
    count = sum(counts)
    println("$count primes between $low and $high.")
    return count
end

@test pcount_primes(10, 100000000) == 5761451
                                                                             end
@lambda function count_primes2(low::Int, high::Int)

    using Primes

    c = length(Primes.primes(low, high))
    println("$c primes between $low and $high.")
    return c
end

@test count_primes2(10, 100) == 21

                                 if !haskey(ENV, "AWS_LAMBDA_JL_TEST_SKIP_SLOW")
# Count primes in parallel...
function pcount_primes2(low::Int, high::Int)
    w = 100000000
    counts = asyncmap(x->count_primes2(x...),
                      [(i, min(high,i + w)) for i = low:w:high])
    count = sum(counts)
    println("$count primes between $low and $high.")
    return count
end

@test pcount_primes2(10, 10^10) == 455052507
                                                                             end


#@test invoke_lambda(aws, "count_primes", low = 10, high = 100)[:jl_data] == "21"

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

        eval(Main, :(using TestModule))
        @test Base.invokelatest(test_function,5) == 25

        # Create a lambda that uses the TestModule...
        eval(:(@lambda function lambda_test(x)

            using TestModule

            return test_function(x)
        end))

        @test Base.invokelatest(lambda_test,4) == 16
    end
end



#==============================================================================#
# End of file.
#==============================================================================#
