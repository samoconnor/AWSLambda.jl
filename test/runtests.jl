#==============================================================================#
# SQS/test/runtests.jl
#
# Copyright Sam O'Connor 2014 - All rights reserved
#==============================================================================#


using AWSSQS
using Base.Test

AWSCore.set_debug_level(1)


#-------------------------------------------------------------------------------
# Load credentials...
#-------------------------------------------------------------------------------

aws = AWSCore.aws_config(region="ap-southeast-2")



#-------------------------------------------------------------------------------
# SQS tests
#-------------------------------------------------------------------------------

test_queue = "ocaws-jl-test-queue-" * lowercase(Dates.format(now(Dates.UTC),
                                                             "yyyymmddTHHMMSSZ"))

qa = sqs_create_queue(aws, test_queue)

qb = sqs_get_queue(aws, test_queue)

@test qa[:resource] == qb[:resource]


sqs_send_message(qa, "Hello!")

m = sqs_receive_message(qa)
@test m[:message] == "Hello!"

sqs_delete_message(qa, m)
sqs_flush(qa)

info = sqs_get_queue_attributes(qa)
@test info["ApproximateNumberOfMessages"] == "0"
@test sqs_count(qa) == 0


println("SQS ok.")



#==============================================================================#
# End of file.
#==============================================================================#
