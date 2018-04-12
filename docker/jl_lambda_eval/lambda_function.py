#==============================================================================#
# lambda_function.py
#
# AWS Lambda wrapper for Julia.
#
# See http://docs.aws.amazon.com/lambda/latest/dg/API_Reference.html
#
# Copyright OC Technology Pty Ltd 2014 - All rights reserved
#==============================================================================#


from __future__ import print_function

import subprocess
import os
import json
import time
import select


# Get CPU type for logging...
# See https://forums.aws.amazon.com/thread.jspa?messageID=804338
def cpu_model():
   with open("/proc/cpuinfo") as f:
       for l in f:
           if "model name" in l:
               return l.split(":")[1].strip()

cpu_model_name = cpu_model()


# Set Julia package directory...
name = os.environ['AWS_LAMBDA_FUNCTION_NAME']
root = os.environ['LAMBDA_TASK_ROOT']
os.environ['HOME'] = '/tmp/'
os.environ['JULIA_PKGDIR'] = root + '/julia'
os.environ['JULIA_LOAD_PATH'] = root
os.environ['PATH'] += ':' + root + '/bin'


# Load configuration...
execfile('lambda_config.py')


# Start Julia interpreter...
julia_proc = None
def start_julia():
    global julia_proc
    cmd = [root + '/bin/julia', '-i', '-e',
           'using module_' + name + '; '                                       \
         + 'using AWSLambdaWrapper; '                                          \
         + 'AWSLambdaWrapper.main(module_' + name + ');']
    print(' '.join(cmd))
    julia_proc = subprocess.Popen(cmd, stdin=subprocess.PIPE,
                                       stdout=subprocess.PIPE,
                                       stderr=subprocess.STDOUT)


def lambda_handler(event, context):

    print(cpu_model_name)

    info = {
        'invoked_function_arn': context.invoked_function_arn,
        'function_version':     context.function_version,
        'aws_request_id':       context.aws_request_id,
        'log_group_name':       context.log_group_name,
        'log_stream_name':      context.log_stream_name,
        'cpu':                  cpu_model_name
    }

    # Store input in tmp files...
    with open('/tmp/lambda_in', 'w') as f:
        json.dump(event, f)
    with open('/tmp/lambda_context', 'w') as f:
        json.dump(context.__dict__, f, default=lambda o: '')

    # Clean up old return value files...
    if os.path.isfile('/tmp/lambda_out'):
        os.remove('/tmp/lambda_out')

    # Start or restart the Julia interpreter as needed...
    global julia_proc
    if julia_proc is None or julia_proc.poll() is not None:
        start_julia()

    # Tell the Julia interpreter that input is ready...
    julia_proc.stdin.write('\n')
    julia_proc.stdin.flush()

    # Calculate execution time limit...
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
            if line == '\0\n':
                complete = True
                break
            if line == '':
                message = 'EOF on Julia stdout!'
                if julia_proc.poll() != None:
                    message += (' Exit code: ' + str(julia_proc.returncode))
                info['message'] = message + '\n' + out
                raise Exception(json.dumps(info))
            print(line, end='')
            out += line

    # Terminate Julia process on timeout...
    if not complete:
        print('Timeout!')
        out += 'Timeout!\n'
        p = julia_proc
        julia_proc = None
        p.terminate()
        while p.poll() == None:
            ready = select.select([p.stdout], [], [], 1)
            if p.stdout in ready[0]:
                line = p.stdout.readline()
                print(line, end='')
                out += line

    # Check exit status...
    if julia_proc == None or julia_proc.poll() != None:
        info['message'] = out
        raise Exception(json.dumps(info))

    # Return content of output file...
    if os.path.isfile('/tmp/lambda_out'):
        with open('/tmp/lambda_out', 'r') as f:
            if 'jl_data' in event:
                return {'jl_data': f.read(), 'stdout': out}
            else:
                return json.load(f)

    return {'stdout': out}



#==============================================================================#
# End of file.
#==============================================================================#
