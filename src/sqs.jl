#==============================================================================#
# sqs.jl
#
# SQS API. See http://aws.amazon.com/documentation/sqs/
#
# Copyright Sam O'Connor 2014 - All rights reserved
#==============================================================================#


export sqs_get_queue, sqs_create_queue, sqs_delete_queue, 
       sqs_send_message, sqs_send_message_batch, sqs_receive_message,
       sqs_delete_message, sqs_flush, sqs_get_queue_attributes, sqs_count,
       sqs_busy_count


# SQS Queue Lookup.
# Find queue URL.
# Return a revised "aws" dict that captures the URL path.

function sqs_get_queue(aws, name)

    @safe try

        r = sqs(aws,"GetQueueUrl",{"QueueName" => name})

        url = get(parse_xml(r.data), "GetQueueUrlResult")
        return merge(aws, {"path" => URI(url).path})

    catch e
        @trap e if e.code == "AWS.SimpleQueueService.NonExistentQueue"
            return nothing
        end
    end
end


sqs_name(q) = split(q["path"], "/")[3]
sqs_arn(q) = arn(q, "sqs", sqs_name(q))


# Create new queue with "name".
# options: VisibilityTimeout, MessageRetentionPeriod, DelaySeconds etc
# See http://docs.aws.amazon.com/AWSSimpleQueueService/latest/APIReference/API_CreateQueue.html

function sqs_create_queue(aws, name, options::Dict=Dict())

    println("""Creating SQS Queue "$name"...""")

    attributes = Dict()
    
    for (i, k) in enumerate(keys(options))
        push(attributes, ("Attribute.$i.Name", n))
        push(attributes, ("Attribute.$i.Value", options[n]))
    end

    @with_retry_limit 4 try

        r = sqs(aws, "CreateQueue",
                            merge(attributes, {"QueueName" => name}))
        url = get(parse_xml(r.data), "QueueUrl")
        return merge(aws, {"path" => URI(url).path})

    catch e

        if typeof(e) == AWSException

            if (e.code == "QueueAlreadyExists")
                sqs_delete_queue(aws, name)
                @retry
            end

            if (e.code == "AWS.SimpleQueueService.QueueDeletedRecently")
                println("""Waiting 1 minute to re-create Queue "$name"...""")
                sleep(60)
                @retry
            end
        end
    end

    assert(false) # Unreachable.
end


function sqs_delete_queue(queue)

    @safe try

        println("Deleting SQS Queue $(aws["path"])")
        sqs(aws, "DeleteQueue")

    catch e
        @trap e if e.code == "AWS.SimpleQueueService.NonExistentQueue" end
    end
end


function sqs_send_message(queue, message)

    sqs (queue, "SendMessage", {"MessageBody" => message,
                                "MD5OfMessageBody" => string(md5_hash(message))})
end


function sqs_send_message_batch(queue, messages)

    batch = {}
    
    for (i, message) in enumerate(messages)
        push(batch, ("SendMessageBatchRequestEntry.$i.Id",  i))
        push(batch, ("SendMessageBatchRequestEntry.$i.MessageBody", message))
    end
    sqs(queue, "SendMessageBatch", batch)
end


function sqs_receive_message(queue)

    r = sqs(queue, "ReceiveMessage", {"MaxNumberOfMessages" => "1"})
    xdoc = parse_xml(r.data)

    handle = get(xdoc, "ReceiptHandle")
    if handle == ""
        return nothing
    end

    message = get(xdoc, "Body")
    @assert get(xdoc, "MD5OfBody") == bytes2hex(md5_hash(message))

    return {"message" => message, "handle" => handle}
end
    

function sqs_delete_message(queue, message)

    sqs(queue, "DeleteMessage", {"ReceiptHandle" => message["handle"]})
end


function sqs_flush(queue)

    while (m = sqs_receive_message(queue)) != nothing
        sqs_delete_message(queue, m)
    end
end


function sqs_get_queue_attributes(queue)

    @safe try

        r = sqs(queue, "GetQueueAttributes", {"AttributeName.1" => "All"})

        return dict(parse_xml(r.data), "GetQueueAttributesResult", "Attribute")

    catch e
        @trap e if e.code == "AWS.SimpleQueueService.NonExistentQueue"
            return nothing
        end
    end
end


function sqs_count(queue)
    
    int(sqs_get_queue_attributes(queue)["ApproximateNumberOfMessages"])
end


function sqs_busy_count(queue)
    
    int(sqs_get_queue_attributes(queue)["ApproximateNumberOfMessagesNotVisible"])
end



#==============================================================================#
# End of file.
#==============================================================================#

