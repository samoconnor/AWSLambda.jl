#==============================================================================#
# SNS/test/runtests.jl
#
# Copyright Sam O'Connor 2014 - All rights reserved
#==============================================================================#


using AWSSQS
using AWSSNS
using Retry
using Base.Test

AWSCore.set_debug_level(1)


#-------------------------------------------------------------------------------
# Load credentials...
#-------------------------------------------------------------------------------

aws = AWSCore.aws_config(region="ap-southeast-2")



#-------------------------------------------------------------------------------
# SNS tests
#-------------------------------------------------------------------------------

test_queue = "ocaws-jl-test-queue-" * lowercase(Dates.format(now(Dates.UTC),
                                                             "yyyymmddTHHMMSSZ"))

qa = sqs_create_queue(aws, test_queue)


test_topic = "ocaws-jl-test-topic-" * lowercase(Dates.format(now(Dates.UTC),
                                                             "yyyymmddTHHMMSSZ"))

sns_create_topic(aws, test_topic)

sns_subscribe_sqs(aws, test_topic, qa; raw = true)

sns_publish(aws, test_topic, "Hello SNS!")

@repeat 6 try

    sleep(2)
    m = sqs_receive_message(qa)
    @test m != nothing && m[:message] == "Hello SNS!"

catch e
    @retry if true end
end


println("SNS ok.")



#==============================================================================#
# End of file.
#==============================================================================#
