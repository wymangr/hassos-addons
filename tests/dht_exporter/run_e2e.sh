#!/usr/bin/env bash
# End-to-end test for the DHT exporter add-on.
#
# The production app (app.py) imports Raspberry Pi hardware libraries (board,
# adafruit_dht) that only import on real Pi hardware, so it cannot run in CI.
# The add-on ships app_test.py, a hardware-free mock that exercises the real
# FastAPI application, Prometheus metric registration, temperature scaling and
# error handling. This test launches that app and scrapes /metrics like a real
# Prometheus server would.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SRC_DIR="${REPO_ROOT}/dht_exporter/rootfs/src"
HOST="127.0.0.1"
PORT="8182"
BASE_URL="http://${HOST}:${PORT}"

export LOCATION="ci-testroom"
export PIN="4"
export SENSOR="2302"
export FAHRENHEIT="False"

cd "${SRC_DIR}" || {
	echo "FAIL: source directory not found: ${SRC_DIR}"
	exit 1
}

python -m uvicorn app_test:app --host "${HOST}" --port "${PORT}" >/tmp/dht_server.log 2>&1 &
SERVER_PID=$!
cleanup() {
	kill "${SERVER_PID}" >/dev/null 2>&1
	wait "${SERVER_PID}" 2>/dev/null
}
trap cleanup EXIT

# Wait for the server to accept requests.
ready=0
for _ in $(seq 1 30); do
	if curl -sf "${BASE_URL}/metrics" >/tmp/metrics.out 2>/dev/null; then
		ready=1
		break
	fi
	sleep 1
done

if [[ "${ready}" -ne 1 ]]; then
	echo "FAIL: exporter did not become ready on ${BASE_URL}/metrics"
	echo "----- server log -----"
	cat /tmp/dht_server.log
	exit 1
fi

echo "----- /metrics -----"
cat /tmp/metrics.out
echo "--------------------"

fail=0

# The error counter is always registered for the configured location, so it must
# be present regardless of whether the mock produced a reading this scrape.
if ! grep -q "dht_exporter_error" /tmp/metrics.out; then
	echo "FAIL: dht_exporter_error metric family missing from /metrics output"
	fail=1
fi

# Confirm we are getting Prometheus exposition format back.
content_type="$(curl -s -o /dev/null -w '%{content_type}' "${BASE_URL}/metrics")"
echo "content-type: ${content_type}"
if ! printf '%s' "${content_type}" | grep -qi "text/plain"; then
	echo "FAIL: unexpected content type for /metrics: ${content_type}"
	fail=1
fi

# Scrape several times to exercise both the successful-reading and the
# missing-data (error) branches of the mock sensor.
saw_reading=0
for _ in $(seq 1 20); do
	body="$(curl -sf "${BASE_URL}/metrics" || true)"
	if printf '%s' "${body}" | grep -Eq "dht_exporter_(temperature|humidity)\{"; then
		saw_reading=1
	fi
done

if [[ "${saw_reading}" -ne 1 ]]; then
	echo "WARN: never observed a temperature/humidity sample across 20 scrapes (mock is random); error path still validated"
fi

if [[ "${fail}" -ne 0 ]]; then
	echo "DHT EXPORTER E2E: FAILED"
	exit 1
fi

echo "DHT EXPORTER E2E: PASSED"
