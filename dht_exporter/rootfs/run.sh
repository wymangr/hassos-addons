#!/usr/bin/env bashio

cd /src || exit

if bashio::config.is_empty 'location'; then
    bashio::config.require 'location' "location label is required"
else
    export LOCATION="$(bashio::config 'location')"
fi

if bashio::config.has_value 'pin'; then
    export PIN="$(bashio::config 'pin')"
fi

if bashio::config.has_value 'sensor'; then
    export SENSOR="$(bashio::config 'sensor')"
fi

if bashio::config.true 'fahrenheit'; then
    export FAHRENHEIT=true
fi

## Update cpuinfo with Hardware Version
## Needed by adafruit-circuitpython-dht & RPi.GPIO
cp /proc/cpuinfo /tmp/cpuinfo
chmod 777 /tmp/cpuinfo
if ! grep -q "Hardware" "/tmp/cpuinfo"; then
    echo "Hardware        : $(bashio::config 'pi_chip')" >> /tmp/cpuinfo
    mount --bind /tmp/cpuinfo /proc/cpuinfo
fi

exec .venv/bin/gunicorn app:app -k uvicorn.workers.UvicornWorker -w 1 -b 0.0.0.0:8182 --access-logfile - --error-logfile -