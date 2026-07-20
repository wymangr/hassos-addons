# The Home Assistant builder always passes --build-arg BUILD_FROM, so this
# default is only a fallback for a bare `docker build` (e.g. local testing) and
# silences the InvalidDefaultArgInFrom lint warning.
ARG BUILD_FROM=ghcr.io/hassio-addons/debian-base/aarch64:9.1.0
FROM $BUILD_FROM

ARG \
    BUILD_ARCH \
    BUILD_VERSION

LABEL \
    io.hass.version=${BUILD_VERSION} \
    io.hass.type="addon" \
    io.hass.arch="${BUILD_ARCH}"

WORKDIR /src

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        python3.13 \
        python3-pip \
        python3.13-dev \
        python3.13-venv \
        build-essential \
        gcc-aarch64-linux-gnu \
        binutils-aarch64-linux-gnu \
        libgpiod3 && \
    rm -rf /var/lib/apt/lists/* && \
    apt clean && \
    python3 -m venv .venv

COPY rootfs /

RUN .venv/bin/pip3 install --no-cache-dir -r /src/requirements.txt && \
    chmod a+x /run.sh

ENTRYPOINT []
CMD ["/run.sh"]
