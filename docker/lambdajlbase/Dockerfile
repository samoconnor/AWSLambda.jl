ARG JL_VERSION=0.6.0
FROM lambdajlsrc

ARG JL_VERSION

RUN cd /var/src/julia \
 && [ $JL_VERSION == master ] || git checkout v$JL_VERSION

# Note LLVM build patch for https://github.com/JuliaLang/julia/issues/23462
COPY *.patch /var/src/julia/

RUN cd /var/src/julia \
 && for p in *.patch ; do patch -p0 < $p ; done

# Note, Lambda does not always run on HASWELL/AVX2:
# https://forums.aws.amazon.com/thread.jspa?messageID=802829#802829
ENV LAMBDAJL_MAKE \
        make VERBOSE=1 \
             prefix= \
             DESTDIR=/var/task \
             OPENBLAS_TARGET_ARCH=SANDYBRIDGE \
             MARCH=core-avx-i

RUN cd /var/src/julia \
 && $LAMBDAJL_MAKE -j2 julia-deps

RUN cd /var/src/julia \
 && $LAMBDAJL_MAKE -j2 \
 && $LAMBDAJL_MAKE install

ENV JULIA_PKGDIR=/var/task/julia \
    PATH=/var/task/bin:$PATH

RUN julia -e 'Pkg.init()'
