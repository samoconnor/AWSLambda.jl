# AWSSNS

AWS SNS Interface for Julia

```julia
using AWSSNS
using AWSSQS

aws = AWSCore.aws_config()

sns_create_topic(aws, "my-topic")

q = sqs_get_queue(aws, "my-queue")
sns_subscribe_sqs(aws, "my-topic", q; raw = true)

sns_publish(aws, "my-topic", "Hello!")

m = sqs_receive_message(q)
println(m["message"])
sqs_delete_message(q, m)
```
