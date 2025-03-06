#!/usr/bin/with-contenv bashio

readonly CONFIG_DIR=/etc/alloy
readonly CONFIG_FILE="${CONFIG_DIR}/config.alloy"
readonly BASE_CONFIG="${CONFIG_DIR}/base_config.alloy"

mv ${BASE_CONFIG} ${CONFIG_FILE}