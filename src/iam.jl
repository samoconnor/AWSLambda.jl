#==============================================================================#
# iam.jl
#
# IAM API. See http://aws.amazon.com/documentation/iam/
#
# Copyright Sam O'Connor 2014 - All rights reserved
#==============================================================================#


export iam_whoami,
       iam_create_user, iam_create_access_key,
       iam_delete_access_key, iam_delete_user, iam_put_user_policy,
       iam_format_policy


role_arn(aws, role_name) = arn(aws, "iam", "role/$role_name")
user_arn(aws, user_name) = arn(aws, "iam", "user/$user_name")

function iam(aws; args...)

    aws = merge(aws, region = "us-east-1")

    @repeat 4 try

        return do_request(post_request(aws, "iam", "2010-05-08",
                                       StringDict(args)))

    catch e
        @retry if e.code == "NoSuchEntity" end
    end
end


function sts(aws; args...)

    do_request(post_request(merge(aws, region = "us-east-1"),
                            "iam", "2011-06-15", StringDict(args)))
end


function iam_whoami(aws)

    iam(aws, Action = "GetUser")["User"]["Arn"]
end


function iam_create_user(aws, user_name)

    iam(aws, "CreateUser", Dict("UserName" => user_name))

    iam_create_access_key(aws, user_name)
end


function iam_delete_access_key(aws, user_name)

    r = iam(aws, "ListAccessKeys", Dict("UserName" => user_name))
    # ListAccessKeysResult AccessKeyMetadata] {
 #       set key [get $key AccessKeyId]
    iam(aws, "DeleteAccessKey", Dict("UserName" => user_name, "AccessKeyId" => key))
end


function iam_create_access_key(aws, user_name)

    r = iam(aws, "CreateAccessKey", Dict("UserName" => user_name))
    r = r["CreateAccessKeyResult"]["AccessKey"]
    AWSCredentials(r[:AccessKeyId], r[:SecretAccessKey])
end


function iam_delete_user(aws, user_name)

    r = iam(aws, "ListUserPolicies", Dict("UserName" => user_name))
#    for {- policy} in 
#                    ListUserPoliciesResult PolicyNames] {
        iam(aws, "DeleteUserPolicy", Dict("UserName" => user_name,
                                          "PolicyName" => policy))
#    }

    iam_delete_access_key(aws, user_name)

    r = iam(aws, "ListMFADevices", Dict("UserName" => user_name))
#    for {- key} in 
#                    ListMFADevicesResult MFADevices] {
        sn = get(r, "SerialNumber")
        iam(aws, "DeactivateMFADevice", Dict("UserName" => user_name,
                                             "SerialNumber" => sn))
        iam(aws, "DeleteVirtualMFADevice", Dict("SerialNumber" => sn))
#    end

    iam(aws, "DeleteUser", Dict("UserName" => user_name))
end


function iam_put_user_policy(aws, user_name, policy_name, policy)

    iam(aws, "PutUserPolicy",   
             Dict("UserName" => user_name,
                  "PolicyName" => policy_name,
                  "PolicyDocument" => iam_format_policy(policy)))
end


function iam_format_policy(policy_statement)

#    json [dict create Version 2012-10-17 Statement $policy_statement]
end


function iam_create_role(aws, name; path="/")

    policy = """{
      "Version": "2012-10-17",
      "Statement": [
        {
          "Effect": "Allow",
          "Principal": {
            "Service": "ec2.amazonaws.com"
          },
          "Action": "sts:AssumeRole"
        }
      ]
    }"""

    r = iam(aws, Action = "CreateRole",
                 AssumeRolePolicyDocument = policy,
                 Path = path,
                 RoleName = name)
end


#=

proc assume_aws_sts_role {aws duration_s name role {policy {}} {mfa {}}} {

    dset args Version 2011-06-15
    dset args DurationSeconds $duration_s
    dset args RoleArn [aws_iam_role_arn $aws $role]
    dset args RoleSessionName $name


    if {$policy != {}} {
        dset args Policy [aws_iam_policy_format $policy]
    }
    if {$mfa != {}} {
        dset args SerialNumber [lindex $mfa 0]
        dset args TokenCode [lindex $mfa 1]
    }

    set response [aws_request $aws sts Action AssumeRole {*}$args]

    set TokenArn [get $response AssumeRoleResult AssumedRoleUser Arn]
    set creds [get $response AssumeRoleResult Credentials]
    dict with creds {}
    subst {
        AWSAccessKeyId $AccessKeyId
        AWSSecretKey   $SecretAccessKey
        AWSToken       $SessionToken
        AWSUserArn     $TokenArn
        Expiration     $Expiration
    }
}


proc create_aws_iam_instance_profile {aws name {path /}} {
    # Create an Instance Profile for use with and EC2 instance.

    try {

        aws_iam $aws DeleteInstanceProfile InstanceProfileName $name

    } trap NoSuchEntity {} {}

    set response [aws_iam $aws CreateInstanceProfile \
                               InstanceProfileName $name \
                               Path $path]

    get $response CreateInstanceProfileResult InstanceProfile Arn
}


proc add_role_to_aws_iam_instance_profile {aws ip_name role_name} {
    # Add "role_name to "ip_name".

    set response [aws_iam $aws AddRoleToInstanceProfile \
                               InstanceProfileName  $ip_name \
                               RoleName $role_name]
}


proc create_aws_iam_role {aws name {path /} {options {}}} {
    # Create a Role.

    puts "Creating Role \"$name\"..."

    # Allow EC2 to assume this role...
    # Allow this account number to assume this role...
    if {"-require-mfa" in $options} {
        set assume_role_policy [aws_iam_policy_format [tcl_subst {
            Effect Allow
            Action sts:AssumeRole
            Principal {AWS "arn:aws:iam::[aws_account_number $aws]:root"}
            Condition {Null {JSONDict: aws:MultiFactorAuthAge false}}
        }]]
    } else {
        set assume_role_policy [aws_iam_policy_format [tcl_subst {
            Effect Allow
            Action sts:AssumeRole
            Principal {
                Service "ec2.amazonaws.com"
                AWS "arn:aws:iam::[aws_account_number $aws]:root"
            }
        }]]
    }

    # Clean up old role policies...
    try {

        set response [aws_iam $aws ListRolePolicies RoleName $name]
        set policy_names [get $response ListRolePoliciesResult PolicyNames]
        foreach {member policy_name} $policy_names {
            aws_iam $aws DeleteRolePolicy RoleName $name PolicyName $policy_name
        }
    } trap NoSuchEntity {} {}

    # Remove role from instance profiles...
    try {

        set response [aws_iam $aws ListInstanceProfilesForRole RoleName $name]
        set ip_names [get $response ListInstanceProfilesForRoleResult \
                                         InstanceProfiles]
        foreach {member ip} $ip_names {
            aws_iam $aws RemoveRoleFromInstanceProfile \
                         InstanceProfileName [get $ip InstanceProfileName]\
                         RoleName $name
        }
    } trap NoSuchEntity {} {}

    # Delete role...
    try {

        aws_iam $aws DeleteRole RoleName $name

    } trap NoSuchEntity {} {}

    set response [aws_iam $aws CreateRole \
                               AssumeRolePolicyDocument $assume_role_policy \
                               Path $path \
                               RoleName $name]

    get $response CreateRoleResult Role Arn
}


proc put_aws_iam_role_policy {aws role_name policy_name policy} {
    # Attach "policy" as "policy_name" to "role_name".

    set response [aws_iam $aws PutRolePolicy \
                               PolicyDocument [aws_iam_policy_format $policy] \
                               PolicyName $policy_name \
                               RoleName $role_name]
}


proc create_aws_iam_mfa {aws name {path /}} {

    aws_iam $aws DeleteVirtualMFADevice \
                 SerialNumber [aws_arn $aws iam mfa$path$name]

    : [aws_iam $aws CreateVirtualMFADevice \
                    VirtualMFADeviceName $name \
                    Path $path] \
    | get CreateVirtualMFADeviceResult VirtualMFADevice
}


proc enable_aws_iam_mfa {aws mfa_name user_name code1 code2} {

    aws_iam $aws EnableMFADevice \
                 UserName $user_name \
                 SerialNumber [aws_arn $aws iam mfa/$mfa_name] \
                 AuthenticationCode1 $code1 \
                 AuthenticationCode2 $code2
}


=#

#==============================================================================#
# End of file.
#==============================================================================#
