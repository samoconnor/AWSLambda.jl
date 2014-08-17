#==============================================================================#
# s3.jl
#
# S3 API. See http://docs.aws.amazon.com/AmazonS3/latest/API/APIRest.html
#
# Copyright Sam O'Connor 2014 - All rights reserved
#==============================================================================#


export s3_put, s3_get, s3_exists, s3_delete, s3_copy, s3_create_bucket,
       s3_enable_versioning, s3_delete_bucket, s3_list_buckets,
       s3_list_objects, s3_list_versions, s3_get_meta, s3_purge_versions


# See http://docs.aws.amazon.com/AmazonS3/latest/API/RESTObjectGET.html

function s3_get(aws, bucket, path; version="")

    r = s3(aws, "GET", bucket; path = path, version = version)
    return r.data
end


function s3_get_meta(aws, bucket, path; version="")

    res = s3(aws, "GET", bucket;
             path = path,
             headers = {"Range" => "bytes=0-0"},
             version = version)
    return res.headers
end
    

function s3_exists(aws, bucket, path; version="")

    @safe try

        s3(aws, "GET", bucket; path = path,
                               headers = {"Range" => "bytes=0-0"},
                               version = version)
        return true

    catch e
        @trap e if e.code in {"NoSuchKey", "AccessDenied"}
            return false
        end
    end
end


# See http://docs.aws.amazon.com/AmazonS3/latest/API/RESTObjectDELETE.html

function s3_delete(aws, bucket, path; version="")

    s3(aws, "DELETE", bucket; path = path, version = version)
end


# See http://docs.aws.amazon.com/AmazonS3/latest/API/RESTObjectCOPY.html

function s3_copy(aws, bucket, path; to_bucket="", to_path="")

    s3(aws, "PUT", to_bucket;
                   path = to_path,
                   headers = {"x-amz-copy-source" => "/$bucket/$path"})
end

 
# See http://docs.aws.amazon.com/AmazonS3/latest/API/RESTBucketPUT.html

function s3_create_bucket(aws, bucket)

    println("""Creating Bucket "$bucket"...""")

    @safe try

        if aws["region"] == "us-east-1"

            s3(aws, "PUT", bucket)

        else

            s3(aws, "PUT", bucket;
                headers = {"Content-Type" => "text/plain"},
                content = """
                <CreateBucketConfiguration
                             xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
                    <LocationConstraint>$(aws["region"])</LocationConstraint>
                </CreateBucketConfiguration>""")
        end

    catch e
        @trap e if e.code == "BucketAlreadyOwnedByYou" end
    end
end


# See http://docs.aws.amazon.com/AmazonS3/latest/API/RESTBucketPUTVersioningStatus.html

function s3_enable_versioning(aws, bucket)

    s3(aws, "PUT", bucket;
       query = {"versioning" => ""},
       content = """
       <VersioningConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/"> 
           <Status>Enabled</Status> 
       </VersioningConfiguration>""")
end


# See http://docs.aws.amazon.com/AmazonS3/latest/API/RESTBucketDELETE.html

s3_delete_bucket(aws, bucket) = s3(aws, "DELETE", bucket)


# See http://docs.aws.amazon.com/AmazonS3/latest/API/RESTServiceGET.html

function s3_list_buckets(aws)

    r = s3(aws,"GET")
    r = parse_xml(r.data)
    list(r, "Buckets", "Bucket", "Name")
end


# See http://docs.aws.amazon.com/AmazonS3/latest/API/RESTBucketGET.html

function s3_list_objects(aws, bucket, path = "")

    more = true
    objects = {}
    marker = ""

    while more

        q = Dict()
        if path != ""
            q["delimiter"] = "/"
            q["prefix"] = path
        end
        if marker != ""
            q["key-marker"] = marker
        end

        r = s3(aws, "GET", bucket; query = q)
        r = parse_xml(r.data)
        more = get(r, "IsTruncated") == "true"
        for e in get_elements_by_tagname(root(r), "Contents")

            o = Dict()
            for field in {"Key", "LastModified", "ETag", "Size"}
                o[field] = content(find_element(e, field))
            end
            push!(objects, o)
            marker = o["Key"]
        end
    end

    return objects
end


# See http://docs.aws.amazon.com/AmazonS3/latest/API/RESTBucketGETVersion.html

function s3_list_versions(aws, bucket, path="")

    more = true
    versions = {}
    marker = ""

    while more

        query = {"versions" => "", "prefix" => path}
        if marker != ""
            query["key-marker"] = marker
        end

        r = s3(aws, "GET", bucket; query = query)
        r = parse_xml(r.data)
        more = get(r, "IsTruncated") == "true"

        for e in child_elements(root(r))

            if name(e) in {"Version", "DeleteMarker"}

                version = {"state" => name(e)}
                for e in child_elements(e)
                    version[name(e)] = content(e)               
                end
                push!(versions, version)
                marker = version["Key"]
            end
        end
    end
    return versions
end


function s3_purge_versions(aws, bucket, path="", pattern="")

    for v in s3_list_versions(aws, bucket, path)
        if pattern == "" || ismatch(pattern, v["Key"])
            if v["IsLatest"] != "true"
                s3_delete(aws, bucket, v["Key"]; version = v["VersionId"])
            end
        end
    end
end


# See http://docs.aws.amazon.com/AmazonS3/latest/API/RESTObjectPUT.html

function s3_put(aws, bucket, path, data, data_type="")

    if data_type == ""
        data_type = "application/octet-stream"
        for (e, t) in {
            (".pdf",  "application/pdf"),
            (".csv",  "text/csv"),
            (".txt",  "text/plain"),
            (".log",  "text/plain"),
            (".dat",  "application/octet-stream"),
            (".gz",   "application/octet-stream"),
            (".bz2",  "application/octet-stream"),
        }    
            if ismatch(e * "\$", path)
                data_type = t
                break
            end
        end
    end

    s3(aws, "PUT", bucket;
       path=path,
       headers={"Content-Type" => data_type},
       content=data)
end


#=
proc sign_aws_s3_url {aws bucket path seconds} {
    aws_attempt sign_aws_s3_url_attempt $aws $bucket $path $seconds
}


proc sign_aws_s3_url_attempt {aws bucket path seconds} {
    # Signed URL that grants access to "path" for "seconds".

    dset query AWSAccessKeyId [get $aws AWSAccessKeyId]
    dset query x-amz-security-token [get $aws AWSToken]
    dset query Expires [expr {[clock seconds] + $seconds}]
    dset query response-content-disposition attachment

    set digest "GET\n\n\n[get $query Expires]\n"
    append digest "x-amz-security-token:[get $query x-amz-security-token]\n"
    append digest "/$bucket/$path?response-content-disposition=attachment"
    dset query Signature [sign_aws_string $aws sha1 $digest]

    return [aws_s3_endpoint $bucket]$path?[qstring $query]
}
=#



#==============================================================================#
# End of file.
#==============================================================================#

