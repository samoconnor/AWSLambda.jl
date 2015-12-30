# AWSLambda

AWS Lambda Interface for Julia

```julia
using AWSSNS
using AWSLambda


aws = aws_config(region = "us-east-1", lambda_bucket = "ocaws.jl.lambdatest")


# Build a base Julia runtime...
create_jl_lambda_base(aws, pkg_list = ["DataStructures",
                                       "StatsBase",
                                       "DataFrames",
                                       "DSP",
                                       "GZip"])

# Deploy a Lambda function to the cloud...
f = @lambda aws function foo(a, b)

    a * b
end

# Execute 100 instances of the function in parallel...
println(amap(f, [(i,i) for i = 1:100]))
```
