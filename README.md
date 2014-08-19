# OCAWS

Work in progress.


### Features

S3, SQS, SNS, EC2, IAM, STS, SDB, DynamoDB

AWS Signature Version 4.

Automatic HTTP request retry with exponential back-off.

Parsing of XML and JSON API error messages to AWSException type.

Automatic API Request retry in case of ExpiredToken or HTTP Redirect.


### Exceptions

May throw: UVError, HTTPException or AWSException.


### Dependencies

[JSON.jl](https://github.com/JuliaLang/JSON.jl)

[Zlib.jl](https://github.com/dcjones/Zlib.jl) -- for crc32()

[URIParser.jl](https://github.com/Keno/URIParser.jl)

[Requests.jl](https://github.com/Keno/Requests.jl)

[HttpCommon.jl](https://github.com/JuliaLang/HttpCommon.jl)

[Nettle.jl](https://github.com/staticfloat/Nettle.jl)

[Dates.jl](https://github.com/quinnj/Dates.jl)

[LightXml.jl](https://github.com/lindahua/LightXML.jl)


### Examples

Create an "aws" dictionary containing user credentials and region...

```julia
aws = {
    "user_arn"      => "arn:aws:iam::xxxxxxxxxx:user/ocaws.jl.test",
    "access_key_id" => "AKIDEXAMPLE",
    "secret_key"    => "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY",
    "region"        => "ap-southeast-2"
}
```


Create an S3 bucket and store some data...

```julia
s3_create_bucket(aws, "my.bucket")
s3_enable_versioning(aws, "my.bucket")

s3_put(aws, "my.bucket", "key", "Hello!")
println(s3_get(aws, "my.bucket", "key"))
```


Post a message to a queue...

```julia
q = sqs_get_queue(aws, "my-queue")

sqs_send_message(q, "Hello!")

m = sqs_receive_message(q)
println(m["message"])
sqs_delete_message(q, m)
```


Post a message to a notification topic...

```julia
sns_create_topic(aws, "my-topic")
sns_subscribe_sqs(aws, "my-topic", q; raw = true)

sns_publish(aws, "my-topic", "Hello!")

m = sqs_receive_message(q)
println(m["message"])
sqs_delete_message(q, m)

```


Start an EC2 server and fetch info...

```julia
ec2(aws, "StartInstances", {"InstanceId.1" => my_instance_id})
r = ec2(aws, "DescribeInstances", {"Filter.1.Name" => "instance-id",
                                   "Filter.1.Value.1" => my_instance_id})
println(r)
```


Create an IAM user...

```julia
iam(aws, "CreateUser", {"UserName" => "me"})
```


Get a list of DynamoDB tables...

```julia
r = dynamodb(aws, "ListTables", "{}")
println(r)
```


[![Build Status](https://travis-ci.org/samoc/OCAWS.jl.svg?branch=master)](https://travis-ci.org/samoc/OCAWS.jl)
