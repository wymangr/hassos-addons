#!/usr/bin/with-contenv bashio

/etc/cont-init.d/alloy_setup.sh
exec //usr/local/bin/alloy run /etc/alloy/config.alloy