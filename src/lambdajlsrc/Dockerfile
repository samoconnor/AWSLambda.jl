FROM lambci/lambda:build

ARG JULIA_VERSION=v0.6.0

RUN yum install -y gcc-gfortran libgfortran

RUN mkdir /var/src \
 && cd /var/src \
 && git clone git://github.com/JuliaLang/julia.git \
 && cd julia \
 && git checkout $JULIA_VERSION

RUN cd /var/src/julia/contrib/ \
 && ./download_cmake.sh
