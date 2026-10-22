# Flutter Linux desktop build environment on Ubuntu 22.04 (GLib 2.72, glibc 2.35):
# binaries built here run on Ubuntu 22.04 and newer. Used by package_linux_docker.sh.
FROM ubuntu:22.04
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends clang cmake ninja-build pkg-config libgtk-3-dev liblzma-dev \
    libstdc++-12-dev git ca-certificates curl unzip xz-utils zip file \
 && rm -rf /var/lib/apt/lists/*
