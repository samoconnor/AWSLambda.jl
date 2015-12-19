#==============================================================================#
# sign.jl
#
# AWS Request Signing.
#
# Copyright Sam O'Connor 2014 - All rights reserved
#==============================================================================#


import Nettle: digest, hexdigest


function sign!(r::AWSRequest, t = now(Dates.UTC))

    if r[:service] == "sdb"
        sign_aws2!(r, t)
    else
        sign_aws4!(r, t)
    end
end


# Create AWS Signature Version 2 Authentication query parameters.
# http://docs.aws.amazon.com/general/latest/gr/signature-version-2.html

function sign_aws2!(r::AWSRequest, t)

    uri = URI(r[:url])

    query = Dict{AbstractString,AbstractString}()
    for elem in split(r[:content], '&', keep=false)
        (n, v) = split(elem, "=")
        query[n] = v
    end
    
    r[:headers]["Content-Type"] = 
        "application/x-www-form-urlencoded; charset=utf-8"

    query["AWSAccessKeyId"] = r[:creds][:access_key_id]
    query["Expires"] = Dates.format(t + Dates.Second(120),
                                    "yyyy-mm-ddTHH:MM:SSZ")
    query["SignatureVersion"] = "2"
    query["SignatureMethod"] = "HmacSHA256"
    if haskey(r[:creds], :token)
        query["SecurityToken"] = r[:creds][:token]
    end

    query = [(k, query[k]) for k in sort(collect(keys(query)))]

    to_sign = "POST\n$(uri.host)\n$(uri.path)\n$(format_query_str(query))"
    
    secret = r[:creds][:secret_key]
    push!(query, ("Signature", digest("sha256", secret, to_sign)
                               |> base64encode |> strip))

    r[:content] = format_query_str(query)
end
    
                                        

# Create AWS Signature Version 4 Authentication Headers.
# http://docs.aws.amazon.com/general/latest/gr/signature-version-4.html

function sign_aws4!(r::AWSRequest, t)

    # ISO8601 date/time strings for time of request...
    date = Dates.format(t,"yyyymmdd")
    datetime = Dates.format(t,"yyyymmddTHHMMSSZ")

    # Authentication scope...
    scope = [date, r[:region], r[:service], "aws4_request"]

    # Signing key generated from today's scope string...
    signing_key = string("AWS4", r[:creds][:secret_key])
    for element in scope
        signing_key = digest("sha256", signing_key, element)
    end

    # Authentication scope string...
    scope = join(scope, "/")

    # SHA256 hash of content...
    content_hash = hexdigest("sha256", r[:content])

    # HTTP headers...
    delete!(r[:headers], "Authorization")
    merge!(r[:headers], StrDict(
        "x-amz-content-sha256" => content_hash,
        "x-amz-date"           => datetime,
        "Content-MD5"          => base64encode(digest("md5", r[:content]))
    ))
    if haskey(r[:creds], :token)
        r[:headers]["x-amz-security-token"] = r[:creds][:token]
    end

    # Sort and lowercase() Headers to produce canonical form...
    canonical_headers = ["$(lowercase(k)):$(strip(v))" for (k,v) in r[:headers]]
    signed_headers = join(sort([lowercase(k) for k in keys(r[:headers])]), ";")

    # Sort Query String...
    uri = URI(r[:url])
    query = query_params(uri)
    query = [(k, query[k]) for k in sort(collect(keys(query)))]

    # Create hash of canonical request...
    canonical_form = string(r[:verb], "\n",
                            uri.path, "\n",
                            format_query_str(query), "\n",
                            join(sort(canonical_headers), "\n"), "\n\n",
                            signed_headers, "\n",
                            content_hash)
    canonical_hash = hexdigest("sha256", canonical_form)

    # Create and sign "String to Sign"...
    string_to_sign = "AWS4-HMAC-SHA256\n$datetime\n$scope\n$canonical_hash"
    signature = hexdigest("sha256", signing_key, string_to_sign)

    # Append Authorization header...
    r[:headers]["Authorization"] = string(
        "AWS4-HMAC-SHA256 ",
        "Credential=$(r[:creds][:access_key_id])/$scope, ",
        "SignedHeaders=$signed_headers, ",
        "Signature=$signature"
    )
end



#==============================================================================#
# End of file.
#==============================================================================#

