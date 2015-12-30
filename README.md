# AWSSQS

AWS SQS Interface for Julia

```julia
using AWSSQS

aws = AWSCore.aws_config()

q = sqs_get_queue(aws, "my-queue")

sqs_send_message(q, "Hello!")

m = sqs_receive_message(q)
println(m["message"])
sqs_delete_message(q, m)
```
