# AWSLambda

[AWS Lambda](https://aws.amazon.com/documentation/lambda/) Interface for Julia

[![Build Status](https://travis-ci.org/samoconnor/AWSLambda.jl.svg)](https://travis-ci.org/samoconnor/AWSLambda.jl)


Start by creating a basic [AWSCore configuration](https://github.com/samoconnor/AWSCore.jl#configuration)...

```julia
using AWSCore
using AWSLambda
aws = aws_config(region = "us-east-1")
```

_The AWS IAM user requires acess to Lambda, EC2 and AWS._

Set up a bucket to store Lambda .ZIP files...

```julia
using AWSS3
s3_create_bucket(aws, "com.me.jl-lambda")
aws[:lambda_bucket] = "com.me.jl-lambda"
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
After that rebuilds take about 5 minutes.
An EC2 keypair with the name `ssh-ec2` must be created by hand._


Execute a function on Lambda...
```julia
@lambda_call(aws, readdir)("/var/task/bin")

1-element Array{ByteString,1}:
 "julia"

@lambda_call(aws, sum)([1,2,3])

6
```


Evaluate an expression on Lambda...
```julia
@lambda_eval aws ENV["LAMBDA_TASK_ROOT"]

"/var/task"
```

Evaluate an expression on Lambda...
```julia
@lambda_eval aws begin
    l = open(readlines, "/proc/cpuinfo")
    l = filter(i->ismatch(r"^model name", i), l)
    strip(split(l[1], ":")[2])
end

"Intel(R) Xeon(R) CPU E5-2680 v2 @ 2.80GHz"
```


Deploy a Lambda function to count prime numbers...

```julia
λ = @λ aws function count_primes(low::Int, high::Int)
    count = length(primes(low, high))
    println("$count primes between $low and $high.")
    return count
end
```
_The @λ macro creates an AWS Lambda named "count_primes". It wraps the body
of the function with serialisation/deserialistion code and packages it into
a .ZIP file. The .ZIP file deployed to AWS. The @λ macro returns an
anonymous function that can be called to invoke the Lambda._

Run 20 instances of λ in parallel using `amap()`...

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

Publish a verion with an alias...
```julia
lambda_publish_version(aws, "count_primes", "PROD")
```


Call a deployed Lambda by name with named arguments...

```julia
r = invoke_lambda(aws, "count_primes", low = 10, high = 100)
@test r[:jl_data] == "21"
```
_Arguments and result are transfered as JSON._


Call a deployed Lambda and don't wait for the result...

```julia
r = async_lambda(aws, "count_primes", @SymDict(low = 10, high = 100))
```
_Arguments are transfered as JSON._


Call a deployed Lambda by name...
```julia
r = invoke_jl_lambda(aws, "count_primes", 10 = 100)
@test r == 21
```
_Arguments and result are transfered as serialised Julia objects._


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
_The @λ macro sees the `using` statement and bundles the corresponding `.jl`
files into the deployment .ZIP file. It then does a dry-run invocation to
trigger module precompilation. The resulting '.ji' files are retrieved from
the Lambda sandbox and added to the deployment .ZIP file. Subsequent calls
do not have to wait for compilation._
