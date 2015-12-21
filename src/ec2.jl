#==============================================================================#
# ec2.jl
#
# EC2 API. See http://aws.amazon.com/documentation/ec2/
#
# Copyright Sam O'Connor 2015 - All rights reserved
#==============================================================================#


export 

include("mime.jl")


function ec2(aws; query)

    do_request(post_request(aws, "ec2", "2014-02-01", query))
end


function ec2_id(aws, name)

    r = ec2(aws, @symdict(Action             = "DescribeTags",
                          "Filter.1.Name"    = "key",
                          "Filter.1.Value.1" = "Name",
                          "Filter.2.Name"    = "value",
                          "Filter.2.Value.1" = name))
    println(r)
    exir(0)
end


function create_ec2(aws, name; ImageId="ami-1ecae776",
                               UserData="",
                               Policy="",
                               args...)

    if isa(UserData,Array{Tuple,1})
        UserData=mime_multipart(UserData)
    end

    # Delete old instance...
    old_id = ec2_id(aws, name)
    if old_id != nothing

        ec2(aws, @symdict(Action = "DeleteTags", 
                          "ResourceId.1" = old_id
                          "Tag.1.Key" = "Name"))

        ec2(aws, @symdict(Action = "TerminateInstances", 
                          "InstanceId.1" = old_id))
    end
    
    # Set up InstanceProfile Policy...
    if Policy != ""

        iam(aws, Action = "CreateRole",
                 Path = "/",
                 RoleName = name,
                 AssumeRolePolicyDocument = """{
                    "Version": "2012-10-17",
                    "Statement": [ {
                        "Effect": "Allow",
                        "Principal": {
                            "Service": "ec2.amazonaws.com"
                        },
                        "Action": "sts:AssumeRole"
                    } ]
                 }""")

        iam(aws, Action = "PutRolePolicy",
                 RoleName = "$name-role",
                 PolicyName = "$name-policy",
                 PolicyDocument = Policy)

        iam(aws, Action = "CreateInstanceProfile",
                 InstanceProfileName = "$name-role",
                 Path = "/")

        iam(aws, Action = "AddRoleToInstanceProfile",
                 InstanceProfileName = "$name-role",
                 RoleName = "$name-role")
    end

    # Deploy instance...
    r = ec2(aws, @symdict(Action="RunInstances",
                          ImageID,
                          UserData,
                          "IamInstanceProfile.Name" = "$name-role",
                          MinCount=1,
                          MaxCount=1,
                          args...))

    println(r)
exit(0)
#FIXME     
#    dset ec2 id [get $response instancesSet item instanceId]

    ec2(aws, StrDict("Action"       => "CreateTags",
                     "ResourceId.1" => r[:id],
                     "Tag.1.Key"    => "Name",
                     "Tag.1.Value"  => name))

    return r
end



#==============================================================================#
# End of file.
#==============================================================================#
