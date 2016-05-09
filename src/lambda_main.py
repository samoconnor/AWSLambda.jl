#==============================================================================#
# lambda_main.py
#
# AWS Lambda wrapper for Julia.
#
# See http://docs.aws.amazon.com/lambda/latest/dg/API_Reference.html
#
# Copyright Sam O'Connor 2014 - All rights reserved
#==============================================================================#


from __future__ import print_function

import subprocess
import os
import json
import threading
import time
import select


# Set Julia package directory...
name = os.environ['AWS_LAMBDA_FUNCTION_NAME']
root = os.environ['LAMBDA_TASK_ROOT']
os.environ['HOME'] = '/tmp/'
os.environ['JULIA_PKGDIR'] = root + '/julia'
os.environ['JULIA_LOAD_PATH'] = root + ':' + root + '/julia/lib'
os.environ['PATH'] += ':' + root + '/bin'


# Load configuration...
execfile('lambda_config.py')


# Start Julia interpreter and run /var/task/lambda.jl...
julia_proc = None
def start_julia():
    global julia_proc
    julia_proc = subprocess.Popen(
        [root + '/bin/julia', '-i', '-e',
         'using module_' + name + '; '                                         \
       + 'using AWSLambdaWrapper; '                                            \
       + 'AWSLambdaWrapper.main(module_' + name + ');'],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT)


# Pass event and context to Julia as JSON with null,newline terminator...
def julia_invoke_lambda(event, context):
    json.dump({'event': event, 'context': context.__dict__},
              julia_proc.stdin,
              default=lambda o: '')
    julia_proc.stdin.write('\0\n')
    julia_proc.stdin.flush()


def main(event, context):

    # Clean up old return value file...
    if os.path.isfile('/tmp/lambda_out'):
        os.remove('/tmp/lambda_out')

    # Start or restart the Julia interpreter as needed...
    if julia_proc is None or julia_proc.poll() is not None:
        start_julia()

    # Pass "event" to Julia in new thread...
    threading.Thread(target=julia_invoke_lambda, args=(event, context)).start()

    # Calcualte execution time limit...
    time_limit = time.time() + context.get_remaining_time_in_millis()/1000.0
    time_limit -= 5.0

    # Wait for output from "julia_proc"...
    out = ''
    complete = False
    while time.time() < time_limit:
        ready = select.select([julia_proc.stdout], [], [],  
                              time_limit - time.time())
        if julia_proc.stdout in ready[0]:
            line = julia_proc.stdout.readline()
            if line == '\0\n' or line == '':
                complete = True
                break
            print(line, end='')
            out += line

    if not complete:
        print('Timeout!')
        out += 'Timeout!\n'
        julia_proc.terminate()

    # Check exit status...
    if julia_proc.poll() != None or not complete:
        if error_sns_arn != '':
            subject = 'Lambda ' + ('Error: ' if complete else 'Timeout: ')     \
                    + name + json.dumps(event, separators=(',',':'))
            error = name + '\n'                                                \
                  + context.invoked_function_arn + '\n'                        \
                  + context.log_group_name + context.log_stream_name + '\n'    \
                  + json.dumps(event) + '\n\n'                                 \
                  + out
            import boto3
            try:
                boto3.client('sns').publish(TopicArn=error_sns_arn,
                                            Message=error,
                                            Subject=subject[:100])
            except Exception:
                pass

        raise Exception(out)

    # Return content of output file...
    if os.path.isfile('/tmp/lambda_out'):
        with open('/tmp/lambda_out', 'r') as f:
            return {'jl_data': f.read(), 'stdout': out}
    else:
        return {'stdout': out}



#==============================================================================#
# End of file.
#==============================================================================#
