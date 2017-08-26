FROM samoconnor/lambdajlbase

RUN julia -e 'Pkg.update()'

ENV LAMBDAJL_PACKAGES \
    AWSCore \
    AWSEC2 \
    AWSIAM \
    AWSS3 \
    AWSSNS \
    AWSSQS \
    AWSSES \
    AWSSDB \
    AWSLambda

COPY *.py *.jl /var/task/

RUN julia -e ' \
    for p in ARGS; \
        println(p); \
        Pkg.add(p); \
    end' \
    $LAMBDAJL_PACKAGES

RUN julia -e ' \
    for p in ARGS; \
        println("using $p"); \
    end' \
    $LAMBDAJL_PACKAGES \
    AWSLambdaWrapper \
    module_jl_lambda_eval \
    > /var/src/userimg.jl \
\
&&  cp /var/task/AWSLambdaWrapper.jl \
       /var/task/module_jl_lambda_eval.jl \
       /var/task/julia/v* \
\
&&  julia /var/task/share/julia/build_sysimg.jl \
        /var/src/sys native /var/src/userimg.jl \
\
&&  mv -f /var/src/sys.so /var/task/lib/julia/ \
&&  rm -f /var/task/julia/lib/v*/*.ji
