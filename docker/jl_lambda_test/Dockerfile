ARG JL_VERSION=0.6.2

FROM octech/jllambdaeval:$JL_VERSION

FROM lambci/lambda:python2.7

ENV AWS_LAMBDA_FUNCTION_NAME=jl_lambda_eval

COPY --from=0 /var/task/ /var/task/
