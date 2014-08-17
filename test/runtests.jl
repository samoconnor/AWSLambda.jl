#!/Applications/Julia-0.3.0-rc4.app/Contents/Resources/julia/bin/julia
#==============================================================================#
# OCAWS/test/runtests.jl
#
# Copyright Sam O'Connor 2014 - All rights reserved
#==============================================================================#


using OCAWS
using Base.Test

import Dates: format, DateTime, now

import OCAWS: @safe, @trap, @with_retry_limit, @retry



#-------------------------------------------------------------------------------
# AWS Signature Version 4 test
#-------------------------------------------------------------------------------


function aws4_request_headers_test()

    r = AWSRequest()
    r.aws = {
        "access_key_id" => "AKIDEXAMPLE",
        "secret_key"    => "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
        "region"        => "us-east-1",
        "service"       => "iam"
    }
    r.url     = "http://iam.amazonaws.com/"
    r.content = "Action=ListUsers&Version=2010-05-08"
    r.headers = Dict()

    sign_aws_request!(r, DateTime("2011-09-09T23:36:00Z"))

    out = join(["$k: $(r.headers[k])\n" for k in sort(collect(keys(r.headers)))])

    expected = (
        "Authorization: AWS4-HMAC-SHA256 " *
        "Credential=AKIDEXAMPLE/20110909/us-east-1/iam/aws4_request, " *
        "SignedHeaders=content-md5;content-type;host;" *
        "x-amz-content-sha256;x-amz-date, " *
        "Signature=1a6db936024345449ef4507f890c5161" *
                 "bbfa2ff2490866653bb8b58b7ba1554a\n" *
        "Content-MD5: r2d9jRneykOuUqFWSFXKCg==\n" *
        "Content-Type: application/x-www-form-urlencoded; " *
                     "charset=utf-8\n" *
        "Host: iam.amazonaws.com\n" *
        "x-amz-content-sha256: b6359072c78d70ebee1e81adcbab4f01" *
                             "bf2c23245fa365ef83fe8f1f955085e2\n" *
        "x-amz-date: 20110909T233600Z\n")

    @test out == expected
end

aws4_request_headers_test



#-------------------------------------------------------------------------------
# Load credentials...
#-------------------------------------------------------------------------------


aws = readlines("jltest.aws")
aws = {
    "user_arn"      => strip(aws[1]),
    "access_key_id" => strip(aws[2]),
    "secret_key"    => strip(aws[3]),
    "region"        => strip(aws[4]),
}



#-------------------------------------------------------------------------------
# Arn tests
#-------------------------------------------------------------------------------


@test arn(aws,"s3","foo/bar") == "arn:aws:s3:::foo/bar"
@test arn(aws,"s3","foo/bar") == s3_arn("foo","bar")
@test arn(aws,"s3","foo")     == s3_arn("foo")
@test arn(aws,"sqs", "au-test-queue", "ap-southeast-2", "1234") ==
      "arn:aws:sqs:ap-southeast-2:1234:au-test-queue"

@test arn(aws,"sns","*","*",1234) == "arn:aws:sns:*:1234:*"
@test arn(aws,"iam","role/foo-role", "", 1234) == 
      "arn:aws:iam::1234:role/foo-role"



#-------------------------------------------------------------------------------
# Endpoint URL tests
#-------------------------------------------------------------------------------


import OCAWS: aws_endpoint, s3_endpoint


@test aws_endpoint("sqs", "us-east-1") == "http://sqs.us-east-1.amazonaws.com"
@test aws_endpoint("sdb", "us-east-1") == "http://sdb.amazonaws.com"
@test aws_endpoint("iam", "us-east-1") == "https://iam.us-east-1.amazonaws.com"
@test aws_endpoint("sts", "us-east-1") == "https://sts.us-east-1.amazonaws.com"
@test aws_endpoint("sqs", "eu-west-1") == "http://sqs.eu-west-1.amazonaws.com"
@test aws_endpoint("sdb", "eu-west-1") == "http://sdb.eu-west-1.amazonaws.com"
@test aws_endpoint("sns", "eu-west-1") == "http://sns.eu-west-1.amazonaws.com"

@test s3_endpoint("us-east-1", "bucket") == "http://bucket.s3.amazonaws.com"
@test s3_endpoint("eu-west-1", "bucket") ==
      "http://bucket.s3-eu-west-1.amazonaws.com"



#-------------------------------------------------------------------------------
# S3 tests
#-------------------------------------------------------------------------------


# Delete old test files...

for b in s3_list_buckets(aws)

    if ismatch(r"^ocaws.jl.test", b)
        
        println("Cleaning up old test bucket: " * b)
        for v in s3_list_versions(aws, b)
            s3_delete(aws, b, v["Key"]; version = v["VersionId"])
        end
        s3_delete_bucket(aws, b)
    end
end


# Temporary bucket name...

bucket_name = "ocaws.jl.test." * lowercase(format(now(),"yyyymmddTHHMMSSZ"))


# Test exception code for deleting non existand bucket...

@safe try

    s3_delete_bucket(aws, bucket_name)

catch e
     @trap e if e.code == "NoSuchBucket" end
end


# Create bucket...

s3_create_bucket(aws, bucket_name)
sleep(5)



@with_retry_limit 4 try

    # Turn on object versioning for this bucket...

    s3_enable_versioning(aws, bucket_name)

    # Check that the new bucket is returned in the list of buckets...

    @test bucket_name in s3_list_buckets(aws)


    # Check that our test keys do not exist yet...

    @test !s3_exists(aws, bucket_name, "key1")
    @test !s3_exists(aws, bucket_name, "key2")
    @test !s3_exists(aws, bucket_name, "key3")

catch e

    if typeof(e) == AWSException && e.code == "NoSuchBucket"
        sleep(1)
        @retry
    end
end


# Create test objects...

s3_put(aws, bucket_name, "key1", "data1.v1")
s3_put(aws, bucket_name, "key2", "data2.v1")
s3_put(aws, bucket_name, "key3", "data3.v1")
s3_put(aws, bucket_name, "key3", "data3.v2")
s3_put(aws, bucket_name, "key3", "data3.v3")


@with_retry_limit 4 try

    # Check that test objects have expected content...

    @test s3_get(aws, bucket_name, "key1") == "data1.v1"
    @test s3_get(aws, bucket_name, "key2") == "data2.v1"
    @test s3_get(aws, bucket_name, "key3") == "data3.v3"

    # Check object copy function...

    s3_copy(aws, bucket_name, "key1";
            to_bucket = bucket_name, to_path = "key1.copy")

    @test s3_get(aws, bucket_name, "key1.copy") == "data1.v1"

catch e

    if typeof(e) == AWSException && e.code == "NoSuchKey"
        sleep(3)
        @retry
    end
end


@with_retry_limit 4 try

    # Check exists and list objects functions...

    for key in {"key1", "key2", "key3", "key1.copy"} 
        @test s3_exists(aws, bucket_name, key)
        @test key in [o["Key"] for o in s3_list_objects(aws, bucket_name)]
    end

    # Check delete...

    s3_delete(aws, bucket_name, "key1.copy")

    @test !("key1.copy" in [o["Key"] for o in s3_list_objects(aws, bucket_name)])

    # Check metadata...

    meta = s3_get_meta(aws, bucket_name, "key1")
    @test meta["ETag"] == "\"68bc8898af64159b72f349b391a7ae35\""

catch e
    sleep(5)
    @retry
end


# Check versioned object content...

versions = s3_list_versions(aws, bucket_name, "key3")
@test length(versions) == 3
@test (s3_get(aws, bucket_name, "key3"; version = versions[3]["VersionId"])
      == "data3.v1")
@test (s3_get(aws, bucket_name, "key3"; version = versions[2]["VersionId"])
      == "data3.v2")
@test (s3_get(aws, bucket_name, "key3"; version = versions[1]["VersionId"])
      == "data3.v3")

# Check pruning of old versions...

s3_purge_versions(aws, bucket_name, "key3")
versions = s3_list_versions(aws, bucket_name, "key3")
@test length(versions) == 1
@test s3_get(aws, bucket_name, "key3") == "data3.v3"



#-------------------------------------------------------------------------------
# SQS tests
#-------------------------------------------------------------------------------


test_queue = "ocaws-jl-test-queue-" * lowercase(format(now(),"yyyymmddTHHMMSSZ"))

qa = sqs_create_queue(aws, test_queue)

qb = sqs_get_queue(aws, test_queue)

@test qa["path"] == qb["path"]


sqs_send_message(qa, "Hello!")

m = sqs_receive_message(qa)
@test m["message"] == "Hello!"

sqs_delete_message(qa, m)
sqs_flush(qa)

info = sqs_get_queue_attributes(qa)
@test info["ApproximateNumberOfMessages"] == "0"
@test sqs_count(qa) == 0



#-------------------------------------------------------------------------------
# SNS tests
#-------------------------------------------------------------------------------


test_topic = "ocaws-jl-test-topic-" * lowercase(format(now(),"yyyymmddTHHMMSSZ"))

sns_create_topic(aws, test_topic)

sns_subscribe_sqs(aws, test_topic, qa; raw = true)

sns_publish(aws, test_topic, "Hello SNS!")

m = sqs_receive_message(qa)
@test m["message"] == "Hello SNS!"



#-------------------------------------------------------------------------------
# DynamoDB tests
#-------------------------------------------------------------------------------


#r = dynamodb(aws, "ListTables", "{}")
#println(r)


println("Done!")



#==============================================================================#
# End of file.
#==============================================================================#
