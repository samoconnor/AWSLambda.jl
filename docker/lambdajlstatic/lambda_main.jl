module LambdaMain


using HTTP
#=
using AWSS3


function lambda_main(event, context)
    println(s3_list_buckets())
end
=#


Base.@ccallable function julia_main(ARGS::Vector{String})::Cint
    #lambda_main(ARGS[1], ARGS[2])
    println(HTTP.get("http://httpbin.org/ip"))
    return 0
end


end # module LambdaMain
