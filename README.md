# AWSLambda

[AWS Lambda](https://aws.amazon.com/documentation/lambda/) Interface for Julia.

If you are new to Lambda, please read [What is AWS Lambda](https://docs.aws.amazon.com/lambda/latest/dg/welcome.html)
and try the [Create a Simple Lambda Function](https://docs.aws.amazon.com/lambda/latest/dg/get-started-create-function.html) (Node.js) exercise.


[![Build Status](https://travis-ci.org/samoconnor/AWSLambda.jl.svg)](https://travis-ci.org/samoconnor/AWSLambda.jl)

With this package you can:

 - Call a Lambda function (defined in Node.js, Python, etc) from Julia.
    ```julia
    AWSLambda.invoke_lambda("MyFunction")
    ```
 - Use the Lambda service to evaluate a Julia expression.
    ```julia
    AWSLambda.@lambda_eval binomial(big(10^6), big(10^5))
    ```
 - Create a local Julia function who's body is evaluated on the Lambda service.
    ```julia
    AWSLambda.@lambda function lambda_env(x)
        return ENV[x]
    end
    ```
 - Deploy a Julia Lambda function that can be called using the AWS SDK
   for JavaScript, Python etc.
    ```julia
    AWSLambda.@deploy_lambda function lambda_env(x)
        return ENV[x]
    end
    ```



## Getting Started

### AWS Credentials

Your AWS credentials should be configured in the `~/.aws/credentials`
file or in the environment variables
`AWS_ACCESS_KEY_ID` and `AWS_SECRET_ACCESS_KEY`.
See the [AWSCore configuration documentation](https://juliacloud.github.io/AWSCore.jl/build/index.html#AWSCore.aws_config)
or the [AWS CLI User Guide](https://docs.aws.amazon.com/cli/latest/userguide/cli-config-files.html)
for mode detail.

You can verify that your credentials are working by calling the IAM GetUser API:
```julia
julia> using AWSCore
julia> AWSCore.set_debug_level(1)
julia> AWSCore.Services.iam("GetUser")["User"]
Loading "octech" AWSCredentials from /Users/sam/.aws/credentials... (AKIAXXXXXXXXXXXXXXXX, XXX...)
Dict{String,Any} with 7 entries:
  "Arn"              => "arn:aws:iam::XXXXXXXXXXXX:user/sam"
  ...
```


### Invoke a Node.js Lambda function from Julia

This example assumes that you created a Node.js Lambda function `MyFunction`
in the [Create a Simple Lambda Function](https://docs.aws.amazon.com/lambda/latest/dg/get-started-create-function.html) exercise.

```julia
julia> using AWSLambda
julia> AWSLambda.invoke_lambda("MyFunction")
"Hello from Lambda"
```

Using the AWS Lambda Management Console, modify the Node.js source code
of `MyFunction` to return the values of event arguments `foo` and `bar`:


```js
exports.handler = (event, context, callback) => {
    let x = 'foo=' + event['foo'] + ', ' +
            'bar=' + event['bar']
    callback(null, x)
};
```

Now the function can be called with keyword arguments `foo=` and `bar=`:

```julia
julia> AWSLambda.invoke_lambda("MyFunction", foo=7, bar="xyz")
"Hello from Lambda, foo=7, bar=xyz"
```



### Deploy `jl_lambda_eval` to Lambda

The `jl_lambda_eval` Lambda function takes a Julia expression as input and
returns the result of evaluating that expression. This function must be
deployed to your AWS account before `AWSLambda.@lambda_eval`,
`AWSLambda.@lambda` or `AWSLambda.@deploy_lambda` can be used:

```julia
julia> using AWSLambda
julia> AWSLambda.deploy_jl_lambda_eval()
```
After deployment `jl_lambda_eval` should be visible in the
[AWS Lambda Console](`https://console.aws.amazon.com/lambda/)
(be sure to set the console to the correct AWS region).

_To learn more about the internals of `jl_lambda_eval` see the [`Dockerfile`](https://github.com/samoconnor/AWSLambda.jl/blob/master/docker/jl_lambda_eval/Dockerfile) and the [`make.jl`](https://github.com/samoconnor/AWSLambda.jl/blob/master/docker/jl_lambda_eval/make.jl) script._


### Use `jl_lambda_eval` to run Julia code in the cloud

The `@lambda_eval` macro passess a Julia expression to the `jl_lambda_eval`
Lambda and returns the result.

```julia
>julia AWSLambda.@lambda_eval run(`uname -snr`)
Linux ip-10-13-21-185 4.9.85-38.58.amzn1.x86_64

>julia AWSLambda.@lambda_eval ENV["LAMBDA_TASK_ROOT"]
"/var/task"
```

The `@lambda function ...` macro creates a local function that
passes its arguments and its function body expression to `jl_lambda_eval`
and returns the result.


```julia
julia> AWSLambda.@lambda function foo(x)
           x = x * 2
           system = chomp(readstring(`uname`))
           return x, system
       end

julia> foo(7)

(14, "Linux")
```


A more complex expression example:
```julia
julia> x = AWSLambda.@lambda_eval begin
           l = open(readlines, "/proc/cpuinfo")
           l = filter(i->ismatch(r"^model name", i), l)
           strip(split(l[1], ":")[2])
       end

"Intel(R) Xeon(R) CPU E5-2680 v2 @ 2.80GHz"
```


An expression with an embedded module:

```julia
julia> r = AWSLambda.@lambda_eval begin

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

Dict{String,Any} with 1 entry:
  "origin" => "13.55.241.245"
```


A function to count primes in the cloud:

```julia
julia> AWSLambda.@lambda function count_primes(low::Int, high::Int)

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
count_primes (generic function with 1 method)

julia> count_primes(10, 100)
21 primes between 10 and 100.

21
```

Using `asyncmap` to count primes in parallel:

```julia
julia> sum(asyncmap(x->count_primes(x.start, x.stop),
                   [1:1000000, 1000001:2000000, 2000001:3000000]))
78498 primes between 1 and 1000000.

70435 primes between 1000001 and 2000000.

67883 primes between 2000001 and 3000000.

216816
```
_The `Base.asyncmap` function uses three concurrent tasks to call three
instances of `count_primes` in parallel._

The `@lambda function ...` macro accepts an optional `using ...` argument
that allows local modules to be used.

e.g. Count primes faster using the `Primes.jl` package:

```julia
julia> AWSLambda.@lambda using Primes function count_primes_fast(low::Int, high::Int)

           c = length(Primes.primes(low, high))
           println("$c primes between $low and $high.")
           return c
       end

julia> count_primes_fast(10, 10^9)
50847530 primes between 10 and 1000000000.

50847530
```
_The `@lambda using ... function ...` macro bundles up the source files for
specified local modules and passess them to `jl_lambda_eval` along with the
function body and arguments each time the function is called._


### Deploy a Julia Lambda function

The examples above all rely on the `jl_lambda_eval` Lambda function to execute
Julia code on demand. The code is uploaded, compiled and executed at call time.

Deploying a new named Lambda function will enable your Julia code to be called 
using the AWS SDK for JavaScript, Python etc. The deployment process also
precompiles the Julia code to help speed up execution time.

Deploy a Lambda function to count prime numbers:

```julia
julia> @deploy_lambda using Primes function count_primes_fast(low::Int, high::Int)

           c = length(Primes.primes(low, high))
           println("$c primes between $low and $high.")
           return c
       end
```

The `@deploy_lambda` macro creates a new AWS Lambda named `count_primes_fast`.
It wraps the body of the function with serialisation/deserialistion code and
packages it into a .ZIP file along with the source code for the required
modules. The .ZIP file is then deployed to AWS Lambda. After deployment the
new function should be visible in the
[AWS Lambda Console](`https://console.aws.amazon.com/lambda/).

Use the console to configure a test event as follows, and then use the `Test`
button to invoke the function.
```json
{
  "low": 10,
  "high": 100000000
}
```

Or invoke the deployed Lambda function from the AWS CLI:
```bash
bash$ aws lambda invoke --function-name count_primes_fast \
                    --payload "{\"low\": 10, \"high\": 100}" \
                      output.txt
{
    "ExecutedVersion": "$LATEST",
    "StatusCode": 200
}
$ cat output.txt
"21"
```

Or from Julia:

```julia
julia> AWSLambda.invoke_lambda("count_primes_fast", low = 10, high = 100)
```

The examples above all pass the `low` and `high` arguments to the Lambda
function using JSON. The `invoke_jl_lambda` function uses Julia's built-in
serialization mechanism to pass arguments and return values as native Julia
objects:

```julia
julia> AWSLambda.invoke_jl_lambda("count_primes_fast", 10, 100)
21 primes between 10 and 100.

21
```


### Publish a Version with an Alias


```julia
julia> AWSLambda.lambda_publish_version("count_primes_fast", "PROD")
```

```julia
julia> AWSLambda.invoke_lambda("count_primes_fast:PROD", low = 10, high = 100)
```



### Deploy a Lambda that depends on a Module

Create a local module  `TestModule/TestModule.jl`...

```julia
module TestModule

export test_function

__precompile__()

test_function(x) = x * x

end
```


Ensure that the module is locally precompiled:

```julia
push!(LOAD_PATH, "TestModule")
using TestModule
```

Use the module in a Lambda...
```julia
julia> AWSLambda.@deploy_lambda using TestModule function module_test(x)

           # Check that precompile cache is being used...
           @assert !Base.stale_cachefile("/var/task/TestModule/TestModule.jl",
                                         Base.LOAD_CACHE_PATH[1] * "/TestModule.ji")
           run(`ls -l $(Base.LOAD_CACHE_PATH[1])`)
           return test_function(x)
       end

julia> AWSLambda.invoke_jl_lambda("module_test", 4)
total 8
-rw-r--r-- 1 slicer 497 2998 Apr 12 11:23 module_module_test.ji
-rw-r--r-- 1 slicer 497 1888 Apr 12 11:23 TestModule.ji

16
```


## Documentation TODO

- Example of [`DeadLetterConfig` option](https://docs.aws.amazon.com/lambda/latest/dg/API_CreateFunction.html#SSS-CreateFunction-request-DeadLetterConfig)

- Example of [`MemorySize` option](https://docs.aws.amazon.com/lambda/latest/dg/API_CreateFunction.html#SSS-CreateFunction-request-MemorySize)

- Example of custom `jl_lambda_eval` image with project specific modules.
