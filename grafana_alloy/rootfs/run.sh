#!/usr/bin/env bashio

/etc/cont-init.d/alloy_setup.sh

exec /etc/services.d/alloy/run
