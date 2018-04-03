using AWSLambda

image_name = "octech/$(replace(basename(pwd()), "_", "")):$VERSION"

if length(ARGS) == 0 || ARGS[1] == "build"
    run(`docker build --build-arg JL_VERSION=$VERSION -t $image_name .`)
end


module LambdaTest

    using JSON

    import ..image_name
    import ..AWSLambda.serialize64

    function test_jl_eval_lambda(input)
        p = Pipe()
        @async (write(p, JSON.json(input)); close(p))
        docker = `docker run --rm -i -e DOCKER_LAMBDA_USE_STDIN=1 $image_name`
        run(pipeline(p, docker))
    end

    function invoke_jl_lambda(f)
        args = (f,)
        test_jl_eval_lambda(Dict("jl_data" => serialize64(args)))
    end

    lambda_call(f) =
        (a...) -> invoke_jl_lambda(eval(Main,:(()->$f($a...))))

    lambda_eval(expr) = invoke_jl_lambda(expr)

    macro lambda_eval(expr)
        if expr.head == :block
            expr = [e for e in expr.args]
        else
            expr = QuoteNode(expr)
        end
        :(lambda_eval($expr))
    end
end


if length(ARGS) > 0 && ARGS[1] == "test"


    LambdaTest.test_jl_eval_lambda("println(VERSION)")
    LambdaTest.test_jl_eval_lambda(
        Dict("jl_data" => AWSLambda.serialize64((()->println(VERSION),))))


    LambdaTest.lambda_call(println)("Foo")

    LambdaTest.lambda_eval(:(println("Foo")))

    LambdaTest.@lambda_eval println("Foo")

    LambdaTest.@lambda_eval begin
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

        println(foo())
    end

    LambdaTest.lambda_eval([
        :(module Foo

            export foo

            using HTTP
            using JSON

            const url = "http://httpbin.org/ip"

            function foo()
                JSON.parse(String(HTTP.get(url).body))
            end
        end),
        :(
            using .Foo;
            println(foo())
        )])
end
