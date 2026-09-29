FROM ubuntu:18.04

ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential ca-certificates flex bison git make pkg-config python \
      zlib1g-dev libpng-dev libjpeg-dev \
      libglib2.0-dev libpixman-1-dev libfdt-dev libaio-dev \
      libcap-dev libattr1-dev libncurses5-dev libusb-1.0-0-dev netcat-openbsd \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /work
