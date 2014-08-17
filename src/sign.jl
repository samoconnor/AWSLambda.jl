#==============================================================================#
# sign.jl
#
# AWS Request Signing.
#
# Copyright Sam O'Connor 2014 - All rights reserved
#==============================================================================#


import Nettle: sha256_hash, sha256_hmac, md5_hash
import Dates: format, DateTime, now


function sign_aws_request!(r::AWSRequest, t = now())

    if r.aws["service"] == "sdb"
        sign_aws2_request!(r)
    else
        sign_aws4_request!(r, t)
    end
end


# Create AWS Signature Version 2 Authentication query parameters.
# http://docs.aws.amazon.com/general/latest/gr/signature-version-2.html

function sign_aws2_request!(r::AWSRequest)

    @assert false
#=
    assign $args url query
    assign [uri::split $url] host path

    set common [subst {
        AWSAccessKeyId    [get $aws AWSAccessKeyId]
        Expires           [aws_iso8601 [expr {[clock seconds] + 120}]]
        SignatureVersion  2
        SignatureMethod   HmacSHA256
    }]
    if {[exists $aws AWSToken]} {
        dset common SecurityToken [get $aws AWSToken]
    }
    set query [merge $common $query]

    foreach key [lsort [keys $query]] {
        dset sorted $key [get $query $key]
    }
    set query $sorted

    set digest "POST\n$host\n/$path\n[qstring $query]"
    dset query Signature [sign_aws_string $aws sha2 $digest]

    return $query
=#

end
    
                                        

# Create AWS Signature Version 4 Authentication Headers.
# http://docs.aws.amazon.com/general/latest/gr/signature-version-4.html

function sign_aws4_request!(r::AWSRequest, t)

    # ISO8601 date/time strings for time of request...
    date = format(t,"yyyymmdd")
    datetime = format(t,"yyyymmddTHHMMSSZ")

    # Authentication scope...
    scope = {date, r.aws["region"], r.aws["service"], "aws4_request"}

    # Signing key generated from today's scope string...
    signing_key = string("AWS4", r.aws["secret_key"])
    for element in scope
        signing_key = sha256_hmac(signing_key, element)
    end

    # Authentication scope string...
    scope = join(scope, "/")

    # SHA256 hash of content...
    content_hash = sha256_hash(r.content) |> bytes2hex

    # HTTP headers...
    delete!(r.headers, "Authorization")
    uri = URI(r.url)
    merge!(r.headers, {
        "x-amz-content-sha256" => content_hash,
        "x-amz-date"           => datetime,
        "Host"                 => uri.host,
        "Content-MD5"          => base64(md5_hash(r.content))
    })
    if !haskey(r.headers, "Content-Type") && r.verb == "POST"
        r.headers["Content-Type"] = 
            "application/x-www-form-urlencoded; charset=utf-8"
    end
    if haskey(r.aws, "AWSToken")
        r.headers["x-amz-security-token"] = r.aws["AWSToken"]
    end

    # Sort and lowercase() Headers to produce canonical form...
    canonical_headers = ["$(lowercase(k)):$(strip(v))" for (k,v) in r.headers]
    signed_headers = join(sort([lowercase(k) for k in keys(r.headers)]), ";")

    # Sort Query String...
    query = query_params(uri)
    query = [(k, query[k]) for k in sort(collect(keys(query)))]

    # Create hash of canonical request...
    canonical_form = string(r.verb, "\n",
                            uri.path, "\n",
                            format_query_str(query), "\n",
                            join(sort(canonical_headers), "\n"), "\n\n",
                            signed_headers, "\n",
                            content_hash)
    canonical_hash = sha256_hash(canonical_form) |> bytes2hex

    # Create and sign "String to Sign"...
    string_to_sign = "AWS4-HMAC-SHA256\n$datetime\n$scope\n$canonical_hash"
    signature = sha256_hmac(signing_key, string_to_sign) |> bytes2hex

    # Append Authorization header...
    r.headers["Authorization"] = string (
        "AWS4-HMAC-SHA256 ",
        "Credential=$(r.aws["access_key_id"])/$scope, ",
        "SignedHeaders=$signed_headers, ",
        "Signature=$signature"
    )
end



#==============================================================================#
# End of file.
#==============================================================================#

