#==============================================================================#
# AWSCredentials.jl
#
# Load AWS Credentials from:
# - EC2 Instance Profile,
# - Environment variables, or
# - ~/.aws/credentials file.
#
# Copyright Sam O'Connor 2014 - All rights reserved
#==============================================================================#

export AWSCredentials,
       localhost_is_lambda,
       localhost_is_ec2,
       aws_user_arn,
       aws_account_number


type AWSCredentials
    access_key_id::ASCIIString
    secret_key::ASCIIString
    token::ASCIIString
    user_arn::ASCIIString
end


function Base.show(io::IO,c::AWSCredentials)
    println(io, string(c.user_arn,
                       " (",
                       c.access_key_id,
                       c.secret_key == "" ? "" : ", $(c.secret_key[1:3])...",
                       c.token == "" ? "" : ", $(c.token[1:3])..."),    
                       ")")
end


function AWSCredentials(access_key_id, secret_key, token="", user_arn="")

    c = AWSCredentials(access_key_id, secret_key, token, user_arn)

    if u == ""
        c.usr_arn = aws_user_arn(c)
    end

    return c
end
    

# Discover AWS Credentials for local host.

function AWSCredentials()

    if localhost_is_ec2()

        return ec2_instance_credentials()

    elseif haskey(ENV, "AWS_ACCESS_KEY_ID")

        return env_instance_credentials()

    elseif isfile("$(ENV["HOME"])/.aws/credentials")

        return dot_aws_credentials()
    end

    error("Can't find AWS credentials!")
end


# Is Julia running in an AWS Lambda sandbox?

localhost_is_lambda() = haskey(ENV, "LAMBDA_TASK_ROOT")


# Is Julia running on an EC2 virtual machine?

function localhost_is_ec2()

    if localhost_is_lambda()
        return false
    end

    host = readall(`hostname -f`)
    return ismatch(r"compute.internal$", host) ||
           ismatch(r"ec2.internal$", host)
end


# Get User ARN for "creds".

function aws_user_arn(c::AWSCredentials)

    if c.user_arn != ""
        c.user_arn
    else
        aws = SymDict(:creds => c, :region => "us-east-1")
        r = do_request(post_request(aws, "iam", "2010-05-08",
                                    Dict("Action" => "GetUser")))
        XML(r.data)[:Arn]
    end
end


aws_account_number(c::AWSCredentials) = split(aws_user_arn(c), ":")[5]


# Fetch EC2 meta-data for "key".
# http://docs.aws.amazon.com/AWSEC2/latest/UserGuide/AESDG-chapter-instancedata.html

function ec2_metadata(key)

    @assert localhost_is_ec2()

    http_request("169.254.169.254", "latest/meta-data/$key").data
end



# Load Instance Profile Credentials for EC2 virtual machine.

using JSON

function ec2_instance_credentials()

    @assert localhost_is_ec2()

    info  = ec2_metadata("iam/info")
    info  = JSON.parse(info)

    name  = ec2_metadata("iam/security-credentials/")
    creds = ec2_metadata("iam/security-credentials/$name")
    creds = JSON.parse(new_creds)

    AWSCredentials(new_creds["AccessKeyId"],
                   new_creds["SecretAccessKey"],
                   new_creds["Token"],
                   info["InstanceProfileArn"])
end


# Load Credentials from environment variables (e.g. in Lambda sandbox)

function env_instance_credentials()

    AWSCredentials(ENV["AWS_ACCESS_KEY_ID"],
                   ENV["AWS_SECRET_ACCESS_KEY"],
                   get(ENV, "AWS_SESSION_TOKEN", ""),
                   get(ENV, "AWS_USER_ARN", ""))
end


# Load Credentials from AWS CLI ~/.aws/credentials file.

using IniFile

function dot_aws_credentials()

    @assert isfile("$(ENV["HOME"])/.aws/credentials")

    ini = read(Inifile(), "$(ENV["HOME"])/.aws/credentials")

    AWSCredentials(get(ini, "default", "aws_access_key_id"),
                   get(ini, "default", "aws_secret_access_key"))
end



#==============================================================================#
# End of file.
#==============================================================================#
