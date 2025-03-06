#!/usr/bin/env bashio

bashio::require.unprotected
echo "${SUPERVISOR_TOKEN}" > '/run/home-assistant.token'

readonly CONFIG_DIR=/etc/alloy
readonly CONFIG_FILE="${CONFIG_DIR}/config.alloy"
readonly BASE_CONFIG="${CONFIG_DIR}/base_config.alloy"

CONFIG=$(<$BASE_CONFIG)

if bashio::config.true 'overrid_config'; then
    if bashio::config.is_empty 'overide_config_path'; then
        bashio::config.require 'overide_config_path' "Config override is Enabled, must set overide_config_path"
    fi
else
    # Add Prometheus Write Endpoint
    if bashio::config.has_value 'prometheus_write_endpoint'; then
        PROMETHEUS_ENDPOINT="$(bashio::config "prometheus_write_endpoint")"
        CONFIG="${CONFIG//PROMETHEUS_WRITE_ENDPOINT/${PROMETHEUS_ENDPOINT}}"
    else
        bashio::config.require 'prometheus_write_endpoint' "You need to supply Prometheus write endpoint"
    fi

    # Add "servername" External Lable if configured
    if bashio::config.has_value 'servername_tag'; then
        EXTERNAL_LABELS="external_labels = {
                    \"servername\" = \"$(bashio::config "servername_tag")\",
                }"
        CONFIG="${CONFIG//SERVERNAME_TAG/${EXTERNAL_LABELS}}"
    else
        CONFIG="${CONFIG//SERVERNAME_TAG/}"
    fi

    # Relabel "instance" tag if configured
    if bashio::config.has_value 'instance_tag'; then
        RELABEL_CONFIG="write_relabel_config {
                        action        = \"replace\"
                        source_labels = [\"instance\"]
                        target_label  = \"instance\"
                        replacement   = \"$(bashio::config "instance_tag")\"
                    }"

        CONFIG="${CONFIG//INSTANCE_TAG/${RELABEL_CONFIG}}"
    else
        CONFIG="${CONFIG//INSTANCE_TAG/}"
    fi

    # Create Config File
    echo "$CONFIG" > $CONFIG_FILE

    # Add Loki to config if endpoint is supplied
    if bashio::config.has_value 'loki_endpoint'; then
        LOKI_CONFIG="
        loki.relabel \"journal\" {
            forward_to = []
            rule {
                source_labels = [\"__journal__systemd_unit\"]
                target_label  = \"unit\"
            }
            rule {
                source_labels = [\"__journal__hostname\"]
                target_label  = \"nodename\"
            }
            rule {
                source_labels = [\"__journal_syslog_identifier\"]
                target_label  = \"syslog_identifier\"
            }
            rule {
                source_labels = [\"__journal_container_name\"]
                target_label  = \"container_name\"
            }
        }
        loki.source.journal \"read\"  {
            forward_to    = [loki.write.endpoint.receiver]
            relabel_rules = loki.relabel.journal.rules
            labels        = {component = \"loki.source.journal\"}
            path          = \"/var/log/journal\"
        }
        loki.write \"endpoint\" {
            endpoint {
                url = \"$(bashio::config "loki_endpoint")\"
            }
        }"
        echo "$LOKI_CONFIG" >> $CONFIG_FILE
    fi
fi
