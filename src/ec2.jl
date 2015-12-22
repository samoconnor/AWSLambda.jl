#==============================================================================#
# ec2.jl
#
# EC2 API. See http://aws.amazon.com/documentation/ec2/
#
# Copyright Sam O'Connor 2015 - All rights reserved
#==============================================================================#


export ec2

include("mime.jl")


function ec2(aws, query)

    do_request(post_request(aws, "ec2", "2014-02-01", StrDict(query)))
end


function ec2_id(aws, name)

    r = ec2(aws, @symdict(Action             = "DescribeTags",
                          "Filter.1.Name"    = "key",
                          "Filter.1.Value.1" = "Name",
                          "Filter.2.Name"    = "value",
                          "Filter.2.Value.1" = name))

    XML(r)[:resourceId]
end


function create_ec2(aws, name; ImageId="ami-1ecae776",
                               UserData="",
                               Policy="",
                               args...)

    if isa(UserData,Array)
        UserData=base64encode(mime_multipart(UserData))
    end

    # Delete old instance...
    old_id = ec2_id(aws, name)
    if old_id != nothing

        ec2(aws, @symdict(Action = "DeleteTags", 
                          "ResourceId.1" = old_id,
                          "Tag.1.Key" = "Name"))

        ec2(aws, @symdict(Action = "TerminateInstances", 
                          "InstanceId.1" = old_id))
    end

    request = @symdict(Action="RunInstances",
                       ImageId,
                       UserData,
                       MinCount="1",
                       MaxCount="1",
                       args...)

    # Set up InstanceProfile Policy...
    if Policy != ""

        @safe try 

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

        catch e
            @trap e if e.code == "EntityAlreadyExists" end
        end

        iam(aws, Action = "PutRolePolicy",
                 RoleName = name,
                 PolicyName = name,
                 PolicyDocument = Policy)

        @safe try 

            iam(aws, Action = "CreateInstanceProfile",
                     InstanceProfileName = name,
                     Path = "/")
        catch e
            @trap e if e.code == "EntityAlreadyExists" end
        end


        @repeat 2 try 

            iam(aws, Action = "AddRoleToInstanceProfile",
                     InstanceProfileName = name,
                     RoleName = name)

        catch e
            @trap e if e.code == "LimitExceeded"
                iam(aws, Action = "RemoveRoleFromInstanceProfile",
                         InstanceProfileName = name,
                         RoleName = name)
                @retry
            end
        end

        request[symbol("IamInstanceProfile.Name")] = name
    end

    r = nothing

    @repeat 3 try

        # Deploy instance...
        r = ec2(aws, request)

    catch e
        @trap e if e.code == "InvalidParameterValue"
            sleep(2)
            @retry
        end
    end

    r = XML(r)

    ec2(aws, StrDict("Action"       => "CreateTags",
                     "ResourceId.1" => r[:instanceId],
                     "Tag.1.Key"    => "Name",
                     "Tag.1.Value"  => name))

    return r
end



#==============================================================================#
# End of file.
#==============================================================================#
