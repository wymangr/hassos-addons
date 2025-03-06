# ARG BUILD_FROM
# FROM $BUILD_FROM

FROM ghcr.io/hassio-addons/base/amd64:17.2.1

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ARG \
  BUILD_ARCH="amd64" \
  GRAFANA_ALLOY_VERSION="1.7.1"

COPY rootfs /


RUN \
apk add --no-cache --update gcompat curl \
    && ARCH="${BUILD_ARCH}" \
    && if [ "${BUILD_ARCH}" = "aarch64" ]; then ARCH="arm64"; fi \
    && curl -J -L -o /tmp/alloy.zip "https://github.com/grafana/alloy/releases/download/v${GRAFANA_ALLOY_VERSION}/alloy-linux-${ARCH}.zip" \
    && echo "https://github.com/grafana/alloy/releases/download/v${GRAFANA_ALLOY_VERSION}/alloy-linux-${ARCH}.zip" \
    && cd /tmp \
    && unzip alloy.zip \
    && mv alloy-linux-${ARCH} /usr/local/bin/alloy \
    && chmod +x /usr/local/bin/alloy \
    && rm -rf /tmp/alloy*


ENTRYPOINT []
CMD ["run.sh"]