

function deploy_jl_lambda_base_to_s3(aws::AWSConfig)

    source_bucket = "octech.com.au.ap-southeast-2.awslambda.jl.deploy"

    # Upload base zip to source bucket...

    AWSS3.s3(aws, "PUT", source_bucket;
             path = base_zip,
             headers = Dict("x-amz-acl" => "public-read"),
             content = read(joinpath(Pkg.dir("AWSLambda"),
                                     "docker/jl_lambda_base.$VERSION.zip")))


    lambda_regions = ["us-east-1",
                      "us-east-2",
                      "us-west-1",
                      "us-west-2",
                      "ap-northeast-2",
                      "ap-south-1",
                      "ap-southeast-1",
                      "ap-northeast-1",
                      "eu-central-1",
                      "eu-west-1",
                      "eu-west-2"]

    # Deploy to other regions...
    @sync for r in lambda_regions

        raws = merge(aws, Dict(:region => r))
        bucket = "octech.com.au.$r.awslambda.jl.deploy"

        @async begin

            s3_create_bucket(raws, bucket)

            AWSS3.s3(aws, "PUT", bucket;
                     path = base_zip,
                     headers = Dict(
                         "x-amz-copy-source" => "$source_bucket/$base_zip",
                         "x-amz-acl" => "public-read"))
        end
    end
end

