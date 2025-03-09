ARG BUILD_FROM
FROM $BUILD_FROM

ARG \
  BUILD_ARCH \
  BUILD_VERSION \
  GRAFANA_ALLOY_VERSION="1.7.1"

LABEL \
  io.hass.version=${BUILD_VERSION} \
  io.hass.type="addon" \
  io.hass.arch="${BUILD_ARCH}"

RUN apt-get update && \
  apt-get install -y --no-install-recommends \
        unzip \
        gettext-base \
        libsystemd-dev \
        curl && \
    rm -rf /var/lib/apt/lists/* && \
    apt clean && \
    ARCH="${BUILD_ARCH}" && \
    if [ "${BUILD_ARCH}" = "aarch64" ]; then ARCH="arm64"; fi && \
    curl -J -L -o /tmp/alloy.zip "https://github.com/grafana/alloy/releases/download/v${GRAFANA_ALLOY_VERSION}/alloy-linux-${ARCH}.zip" && \
    cd /tmp && \
    unzip alloy.zip && \
    mv alloy-linux-${ARCH} /usr/local/bin/alloy && \
    chmod +x /usr/local/bin/alloy && \
    rm -rf /tmp/alloy*

COPY rootfs /

ENTRYPOINT []
CMD ["/run.sh"]
