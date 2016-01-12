# AWSLambda

AWS Lambda Interface for Julia

[![Build Status](https://travis-ci.org/samoconnor/AWSLambda.jl.svg)](https://travis-ci.org/samoconnor/AWSLambda.jl)


Start by creating a basic AWSCore configuration...

```julia
using AWSLambda
aws = aws_config(region = "us-east-1")
```


Set up a bucket to store Lambda .ZIP files...

```julia
s3_create_bucket(aws, "com.me.jl_lambda")
aws[:lambda_bucket] = "com.me.jl_lambda")
```


Build a base Julia runtime for the AWS Lambda sandbox...

```julia
aws[:lambda_packages] = ["DataStructures",
                         "StatsBase",
                         "DataFrames",
                         "DSP"]
create_jl_lambda_base(aws)
```

_`create_jl_lambda_base` creates a temporary EC2 server to build the Julia runtime.
The runtime is stored at `aws[:lambda_bucket]/jl_lambda_base.zip`.
It takes about 1 hour to do a full build the first time.
After that rebuilds take about 5 minutes._


Deploy a Lambda function to cound prime numbers...

```julia
λ = @λ aws function count_primes(low::Int, high::Int)
    count = length(primes(low, high))
    println("$count primes between $low and $high.")
    return count
end
```

Run 20 instances in parallel...

```julia
function count_primes(low::Int, high::Int)
    w = 500000000
    counts = amap(λ, [(i, min(high,i + w)) for i = low:w:high])
    count = sum(counts)
    println("$count primes between $low and $high.")
    return count
end

@test count_primes(10, 10000000000) == 455052507
```

Create a local module  `TestModule/TestModule.jl`...

```julia
module TestModule

export test_function

__precompile__()

test_function(x) = x * x

end
```


Use the module in a Lambda...

```julia
push!(LOAD_PATH, "TestModule")

λ = @λ aws function lambda_test(x)

    # Check that precompile cache is being used...
    @assert !Base.stale_cachefile("/var/task/TestModule/TestModule.jl",
                                  "/var/task/TestModule.ji")
    using TestModule
    return test_function(x)
end

@test λ(4) == 16
```
