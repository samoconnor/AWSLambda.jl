FROM lambdajlsrc

COPY *.patch /var/src/julia/

RUN cd /var/src/julia \
 && for p in *.patch ; do patch -p0 < $p ; done

ENV LAMBDAJL_MAKE \
        make VERBOSE=1 \
             prefix= \
             DESTDIR=/var/task \
             OPENBLAS_TARGET_ARCH=HASWELL \
             MARCH=core-avx2

RUN cd /var/src/julia \
 && $LAMBDAJL_MAKE -j2 julia-deps

RUN cd /var/src/julia \
 && $LAMBDAJL_MAKE -j2 \
 && $LAMBDAJL_MAKE install

ENV JULIA_PKGDIR=/var/task/julia \
    HAVE_INFOZIP=1 \
    PATH=/var/task/bin:$PATH
                    
RUN julia -e 'Pkg.init()'
