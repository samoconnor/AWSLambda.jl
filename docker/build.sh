#!/bin/bash

set -e
set -x

export PATH=var/task/bin:$PATH
export JULIA_PKGDIR=/var/task/julia
export HAVE_INFOZIP=1

cp /var/host/jl_lambda_base/* /var/task

julia -e 'Pkg.update()'

# Install Julia Packages...
JL_PACKAGES="
    AWSCore
    AWSEC2
    AWSIAM
    AWSS3
    AWSSNS
    AWSSQS
    AWSSES
    AWSSDB
    AWSLambda
"

julia -e \
    'for p in ARGS; println(p); Pkg.add(p); end' \
    $JL_PACKAGES

julia -e \
    'for p in ARGS; println("using $p"); end' \
    $JL_PACKAGES \
    AWSLambdaWrapper \
    module_jl_lambda_eval \
    > /var/src/userimg.jl

cp  /var/task/AWSLambdaWrapper.jl \
    /var/task/module_jl_lambda_eval.jl \
    /var/task/julia/v* \

# Build Julia sys.so...
julia /var/task/share/julia/build_sysimg.jl \
    /var/src/sys core-avx-i /var/src/userimg.jl
mv -f /var/src/sys.so /var/task/lib/julia/
rm -f /var/task/julia/lib/v*/*.ji


# Copy minimal set of files to /task-staging...
mkdir -p /var/task-staging/bin
mkdir -p /var/task-staging/lib/julia

cd /var/task-staging

cp /var/task/bin/julia bin/
cp -a /var/task/lib/julia/*.so* lib/julia/
rm -f lib/julia/*-debug.so*

cp -a /var/task/lib/*.so* lib/
rm -f lib/*-debug.so*

cp -a /usr/lib64/libgfortran.so* lib/
cp -a /usr/lib64/libquadmath.so* lib/

cp /usr/bin/zip bin/

# Copy pre-compiled modules to /tmp/task...
cp -a /var/task/julia .
chmod -R a+r julia/lib/
cp -a /var/task/*.jl .
cp -a /var/task/*.py .

# Remove unnecessary files...
find julia -name '.git' \
        -o -name '.cache' \
        -o -name '.travis.yml' \
        -o -name '.gitignore' \
        -o -name 'REQUIRE' \
        -o -name 'test' \
        -o -path '*/deps/downloads' \
        -o -path '*/deps/builds' \
        -o \( -type f -path '*/deps/src/*' ! -name '*.so.*' \) \
        -o -path '*/deps/usr/include' \
        -o -path '*/deps/usr/bin' \
        -o -path '*/deps/usr/lib/*.a' \
        -o -name 'doc' \
        -o -name 'examples' \
        -o -name '*.md' \
        -o -name 'METADATA' \
        -o -path '*/gr/lib/movplugin.so' \
        -o -path '*/GR/src/*.js' \
    | xargs rm -rf

find . -name '*.so' | xargs strip

# Create .zip file...
zip -u --symlinks -r -9 /var/host/$1 *
