FROM lambci/lambda:build

RUN mkdir /var/src \
 && cd /var/src \
 && git clone git://github.com/JuliaLang/julia.git

RUN yum install -y gcc-gfortran libgfortran \
 && cd /var/src/julia/contrib/ \
 && ./download_cmake.sh
