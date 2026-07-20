# The Home Assistant builder always passes --build-arg BUILD_FROM, so this
# default is only a fallback for a bare `docker build` (e.g. local testing) and
# silences the InvalidDefaultArgInFrom lint warning.
ARG BUILD_FROM=ghcr.io/hassio-addons/debian-base/amd64:9.1.0
FROM $BUILD_FROM

ARG \
  BUILD_ARCH \
  BUILD_VERSION \
  GRAFANA_ALLOY_VERSION="1.12.2"

LABEL \
  io.hass.version=${BUILD_VERSION} \
  io.hass.type="addon" \
  io.hass.arch="${BUILD_ARCH}"

RUN apt-get update && \
  apt-get install -y --no-install-recommends \
        unzip \
        gettext-base \
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
RUN chmod +x /run.sh /etc/cont-init.d/alloy_setup.sh /etc/services.d/alloy/run

ENTRYPOINT []
CMD ["/run.sh"]
