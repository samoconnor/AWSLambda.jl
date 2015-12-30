#==============================================================================#
# OCAWS/test/runtests.jl
#
# Copyright Sam O'Connor 2014 - All rights reserved
#==============================================================================#


using AWSS3
using Base.Test
using Retry

AWSCore.set_debug_level(1)


#-------------------------------------------------------------------------------
# Load credentials...
#-------------------------------------------------------------------------------

aws = AWSCore.aws_config(region="ap-southeast-2")



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

bucket_name = "ocaws.jl.test." * lowercase(Dates.format(now(Dates.UTC),
                                                        "yyyymmddTHHMMSSZ"))


# Test exception code for deleting non existand bucket...

@protected try

    s3_delete_bucket(aws, bucket_name)

catch e
     @ignore if e.code == "NoSuchBucket" end
end


# Create bucket...

s3_create_bucket(aws, bucket_name)
#sleep(5)



@repeat 4 try

    # Turn on object versioning for this bucket...

    s3_enable_versioning(aws, bucket_name)

    # Check that the new bucket is returned in the list of buckets...

    @test bucket_name in s3_list_buckets(aws)


    # Check that our test keys do not exist yet...

    @test !s3_exists(aws, bucket_name, "key1")
    @test !s3_exists(aws, bucket_name, "key2")
    @test !s3_exists(aws, bucket_name, "key3")

catch e

    @delay_retry if e.code == "NoSuchBucket" end
end


# Create test objects...

s3_put(aws, bucket_name, "key1", "data1.v1")
s3_put(aws, bucket_name, "key2", "data2.v1")
s3_put(aws, bucket_name, "key3", "data3.v1")
s3_put(aws, bucket_name, "key3", "data3.v2")
s3_put(aws, bucket_name, "key3", "data3.v3")

# Check that test objects have expected content...

@test s3_get(aws, bucket_name, "key1") == b"data1.v1"
@test s3_get(aws, bucket_name, "key2") == b"data2.v1"
@test s3_get(aws, bucket_name, "key3") == b"data3.v3"

# Check object copy function...

s3_copy(aws, bucket_name, "key1";
        to_bucket = bucket_name, to_path = "key1.copy")

@test s3_get(aws, bucket_name, "key1.copy") == b"data1.v1"


url = s3_sign_url(aws, bucket_name, "key1")
curl_output = ""
@repeat 3 try
    curl_output = readall(`curl -s -o - $url`)
catch e
    @delay_retry if true end
end
@test curl_output == "data1.v1"

fn = "/tmp/jl_qws_test_key1"
if isfile(fn)
    rm(fn)
end
@repeat 3 try
    s3_get_file(aws, bucket_name, "key1", fn)
catch e
    sleep(1)
    @retry if true end
end
@test readall(fn) == "data1.v1"
rm(fn)


# Check exists and list objects functions...

for key in ["key1", "key2", "key3", "key1.copy"]
    @test s3_exists(aws, bucket_name, key)
    @test key in [o["Key"] for o in s3_list_objects(aws, bucket_name)]
end

# Check delete...

s3_delete(aws, bucket_name, "key1.copy")

@test !("key1.copy" in [o["Key"] for o in s3_list_objects(aws, bucket_name)])

# Check metadata...

meta = s3_get_meta(aws, bucket_name, "key1")
@test meta["ETag"] == "\"68bc8898af64159b72f349b391a7ae35\""


# Check versioned object content...

versions = s3_list_versions(aws, bucket_name, "key3")
@test length(versions) == 3
@test (s3_get(aws, bucket_name, "key3"; version = versions[3]["VersionId"])
      == b"data3.v1")
@test (s3_get(aws, bucket_name, "key3"; version = versions[2]["VersionId"])
      == b"data3.v2")
@test (s3_get(aws, bucket_name, "key3"; version = versions[1]["VersionId"])
      == b"data3.v3")


# Check pruning of old versions...

s3_purge_versions(aws, bucket_name, "key3")
versions = s3_list_versions(aws, bucket_name, "key3")
@test length(versions) == 1
@test s3_get(aws, bucket_name, "key3") == b"data3.v3"


println("AWSS3 ok.")




#==============================================================================#
# End of file.
#==============================================================================#
