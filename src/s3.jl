#==============================================================================#
# s3.jl
#
# S3 API. See http://docs.aws.amazon.com/AmazonS3/latest/API/APIRest.html
#
# Copyright Sam O'Connor 2014 - All rights reserved
#==============================================================================#

export s3_arn, s3_put, s3_get, s3_get_file, s3_exists, s3_delete, s3_copy,
       s3_create_bucket,
       s3_enable_versioning, s3_delete_bucket, s3_list_buckets,
       s3_list_objects, s3_list_versions, s3_get_meta, s3_purge_versions,
       s3_sign_url


s3_arn(resource) = "arn:aws:s3:::$resource"
s3_arn(bucket, path) = s3_arn("$bucket/$path")


# S3 REST API request.

function s3(aws, verb, bucket="";
            headers=StrDict(),
            path="",
            query=StrDict(),
            version="",
            content="",
            return_stream=false)

    if version != ""
        query["versionId"] = version
    end
    query = format_query_str(query)

    resource = "/$path$(query == "" ? "" : "?$query")"
    url = aws_endpoint("s3", aws[:region], bucket) * resource

    do_request(@symdict(service = "s3",
                        verb,
                        url,
                        resource,
                        headers,
                        content,
                        return_stream,
                        aws...))
end


# See http://docs.aws.amazon.com/AmazonS3/latest/API/RESTObjectGET.html

function s3_get(aws, bucket, path; version="")

    @repeat 4 try

        r = s3(aws, "GET", bucket; path = path, version = version)
        return r.data

    catch e
        @delay_retry if e.code in ["NoSuchBucket", "NoSuchKey"] end
    end
end


function s3_get_file(aws, bucket, path, filename; version="")

    stream = s3(aws, "GET", bucket; path = path,
                                    version = version,
                                    return_stream = true)

    open(filename, "w") do file
        while !eof(stream)
            write(file, readavailable(stream))
        end
    end
end


function s3_get_meta(aws, bucket, path; version="")

    res = s3(aws, "GET", bucket;
             path = path,
             headers = StrDict("Range" => "bytes=0-0"),
             version = version)
    return res.headers
end
    

function s3_exists(aws, bucket, path; version="")

    @repeat 4 try

        s3(aws, "GET", bucket; path = path,
                               headers = StrDict("Range" => "bytes=0-0"),
                               version = version)
        return true

    catch e
        @delay_retry if e.code in ["NoSuchBucket"] end
        @ignore if e.code in ["NoSuchKey", "AccessDenied"]
            return false
        end
    end
end


# See http://docs.aws.amazon.com/AmazonS3/latest/API/RESTObjectDELETE.html

function s3_delete(aws, bucket, path; version="")

    s3(aws, "DELETE", bucket; path = path, version = version)
end


# See http://docs.aws.amazon.com/AmazonS3/latest/API/RESTObjectCOPY.html

function s3_copy(aws, bucket, path; to_bucket=bucket, to_path="")

    s3(aws, "PUT", to_bucket;
                   path = to_path,
                   headers = StrDict("x-amz-copy-source" => "/$bucket/$path"))
end

 
# See http://docs.aws.amazon.com/AmazonS3/latest/API/RESTBucketPUT.html

function s3_create_bucket(aws, bucket)

    println("""Creating Bucket "$bucket"...""")

    @protected try

        if aws[:region] == "us-east-1"

            s3(aws, "PUT", bucket)

        else

            s3(aws, "PUT", bucket;
                headers = StrDict("Content-Type" => "text/plain"),
                content = """
                <CreateBucketConfiguration
                             xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
                    <LocationConstraint>$(aws[:region])</LocationConstraint>
                </CreateBucketConfiguration>""")
        end

    catch e
        @ignore if e.code == "BucketAlreadyOwnedByYou" end
    end
end


# See http://docs.aws.amazon.com/AmazonS3/latest/API/RESTBucketPUTVersioningStatus.html

function s3_enable_versioning(aws, bucket)

    s3(aws, "PUT", bucket;
       query = Dict("versioning" => ""),
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
    list(XML(r), "Buckets", "Bucket", "Name")
end


# See http://docs.aws.amazon.com/AmazonS3/latest/API/RESTBucketGET.html

function s3_list_objects(aws, bucket, path = "")

    more = true
    objects = []
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

        @repeat 4 try

            r = s3(aws, "GET", bucket; query = q)
            r = XML(r)

            more = r[:IsTruncated] == "true"
            for e in get_elements_by_tagname(root(r), "Contents")

                o = Dict()
                for field in ["Key", "LastModified", "ETag", "Size"]
                    o[field] = content(find_element(e, field))
                end
                push!(objects, o)
                marker = o["Key"]
            end

        catch e
            @delay_retry if e.code in ["NoSuchBucket"] end
        end
    end

    return objects
end


# See http://docs.aws.amazon.com/AmazonS3/latest/API/RESTBucketGETVersion.html

function s3_list_versions(aws, bucket, path="")

    more = true
    versions = []
    marker = ""

    while more

        query = Dict("versions" => "", "prefix" => path)
        if marker != ""
            query["key-marker"] = marker
        end

        r = s3(aws, "GET", bucket; query = query)
        r = XML(r)
        more = r[:IsTruncated] == "true"

        for e in child_elements(root(r))

            if name(e) in ["Version", "DeleteMarker"]

                version = Dict("state" => name(e))
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


import Base.ismatch
ismatch(pattern::AbstractString,s::AbstractString) = ismatch(Regex(pattern), s)


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
        for (e, t) in [
            (".pdf",  "application/pdf"),
            (".csv",  "text/csv"),
            (".txt",  "text/plain"),
            (".log",  "text/plain"),
            (".dat",  "application/octet-stream"),
            (".gz",   "application/octet-stream"),
            (".bz2",  "application/octet-stream"),
        ]
            if ismatch(e * "\$", path)
                data_type = t
                break
            end
        end
    end

    s3(aws, "PUT", bucket;
       path=path,
       headers=StrDict("Content-Type" => data_type),
       content=data)
end


import Nettle: digest


function s3_sign_url(aws, bucket, path, seconds = 3600)

    query = Dict("AWSAccessKeyId" =>  aws[:creds][:access_key_id],
                 "x-amz-security-token" => get(aws, "token", ""),
                 "Expires" => string(round(Int, Dates.datetime2unix(now(Dates.UTC)) + seconds)),
                 "response-content-disposition" => "attachment")

    to_sign = "GET\n\n\n$(query["Expires"])\n" *
              "x-amz-security-token:$(query["x-amz-security-token"])\n" *
              "/$bucket/$path?response-content-disposition=attachment"

    key = aws[:creds][:secret_key]
    query["Signature"] = digest("sha1", key, to_sign) |> base64encode |> strip

    endpoint=aws_endpoint("s3", aws[:region], bucket)
    return "$endpoint/$path?$(format_query_str(query))"
end



#==============================================================================#
# End of file.
#==============================================================================#
