ARG BUILD_FROM
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
        python3.11 \
        python3-pip \
        python3.11-dev \
        python3.11-venv \
        gcc-aarch64-linux-gnu \
        libgpiod2 && \
    rm -rf /var/lib/apt/lists/* && \
    apt clean && \
    python3 -m venv .venv

COPY rootfs /

RUN .venv/bin/pip3 install --no-cache-dir -r /src/requirements.txt && \
    chmod a+x /run.sh

ENTRYPOINT []
CMD ["/run.sh"]
