#!/bin/bash

set -e
set -x

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
zip -u --symlinks -r -9 /var/src/jl_lambda_base.zip *
