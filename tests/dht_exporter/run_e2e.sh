#!/usr/bin/env bash
# End-to-end test for the DHT exporter add-on.
#
# The production app (app.py) imports Raspberry Pi hardware libraries (board,
# adafruit_dht) that only import on real Pi hardware, so it cannot run in CI.
# Rather than depend on the local-only (gitignored) app_test.py, this test uses
# run_app.py, a committed launcher that injects fake board/adafruit_dht modules
# and then imports the REAL app.py. That way CI exercises the actual production
# code (metrics endpoint, temperature scaling, error handling, Prometheus
# output) with only the hardware leaf faked, and depends on nothing gitignored.
#
# It runs the app twice: once in Celsius mode and once in Fahrenheit mode, to
# cover the temperature-scale branch (the metric HELP text and the fahrenheit
# conversion depend on the FAHRENHEIT option, which the app reads at import
# time, so each mode needs a fresh process).
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TEST_DIR="${REPO_ROOT}/tests/dht_exporter"
HOST="127.0.0.1"
PORT="8182"
BASE_URL="http://${HOST}:${PORT}"

if [[ ! -f "${TEST_DIR}/run_app.py" ]]; then
	echo "FAIL: launcher not found: ${TEST_DIR}/run_app.py"
	exit 1
fi

rc_total=0
SERVER_PID=""

stop_server() {
	if [[ -n "${SERVER_PID}" ]]; then
		kill "${SERVER_PID}" >/dev/null 2>&1
		wait "${SERVER_PID}" 2>/dev/null
		SERVER_PID=""
	fi
}
trap stop_server EXIT

# Start the mock exporter with a given FAHRENHEIT setting and wait until ready.
# Returns non-zero if the server never becomes ready.
start_server() {
	local fahrenheit="$1"
	# run_app injects fake hardware modules and imports the real app.py.
	# --app-dir points uvicorn at the committed launcher.
	LOCATION="ci-testroom" PIN="4" SENSOR="2302" FAHRENHEIT="${fahrenheit}" \
		python -m uvicorn run_app:app --app-dir "${TEST_DIR}" \
		--host "${HOST}" --port "${PORT}" \
		>/tmp/dht_server.log 2>&1 &
	SERVER_PID=$!

	local i
	for ((i = 0; i < 30; i++)); do
		if curl -sf "${BASE_URL}/metrics" >/tmp/metrics.out 2>/dev/null; then
			return 0
		fi
		sleep 1
	done
	return 1
}

# Run all assertions for one temperature scale.
#   $1 fahrenheit setting ("True"/"False")
#   $2 expected scale word in the metric HELP text ("celsius"/"fahrenheit")
run_scale() {
	local fahrenheit="$1" scale="$2" scale_fail=0
	echo "::group::dht exporter (FAHRENHEIT=${fahrenheit}, expect ${scale})"

	if ! start_server "${fahrenheit}"; then
		echo "FAIL[${scale}]: exporter did not become ready on ${BASE_URL}/metrics"
		echo "----- server log -----"
		cat /tmp/dht_server.log
		rc_total=1
		stop_server
		echo "::endgroup::"
		return
	fi

	echo "----- /metrics -----"
	cat /tmp/metrics.out
	echo "--------------------"

	# The error counter is always registered for the configured location, so it
	# must be present regardless of whether the mock produced a reading.
	if ! grep -q "dht_exporter_error" /tmp/metrics.out; then
		echo "FAIL[${scale}]: dht_exporter_error metric family missing"
		rc_total=1
		scale_fail=1
	fi

	# The TEMPERATURE gauge HELP text is "Temperature in ${scale}", which proves
	# the FAHRENHEIT option was applied.
	if ! grep -q "Temperature in ${scale}" /tmp/metrics.out; then
		echo "FAIL[${scale}]: expected HELP text 'Temperature in ${scale}' not found"
		rc_total=1
		scale_fail=1
	fi

	# Confirm we get Prometheus exposition format back.
	local content_type
	content_type="$(curl -s -o /dev/null -w '%{content_type}' "${BASE_URL}/metrics")"
	echo "content-type: ${content_type}"
	if ! printf '%s' "${content_type}" | grep -qi "text/plain"; then
		echo "FAIL[${scale}]: unexpected content type for /metrics: ${content_type}"
		rc_total=1
		scale_fail=1
	fi

	# run_app.py returns fixed, valid readings, so every scrape must expose a
	# temperature and humidity sample. Assert we actually see them (hard fail),
	# which confirms the success path — not just HELP/TYPE lines — is exercised.
	local i saw_reading=0 body
	for ((i = 0; i < 5; i++)); do
		body="$(curl -sf "${BASE_URL}/metrics" || true)"
		if printf '%s' "${body}" | grep -Eq "dht_exporter_(temperature|humidity)\{"; then
			saw_reading=1
			break
		fi
	done
	if [[ "${saw_reading}" -ne 1 ]]; then
		echo "FAIL[${scale}]: no temperature/humidity samples exposed (success path not exercised)"
		rc_total=1
		scale_fail=1
	fi

	stop_server
	if [[ "${scale_fail}" -eq 0 ]]; then
		echo "PASS[${scale}]: exporter served valid ${scale} metrics"
	fi
	echo "::endgroup::"
}

run_scale "False" "celsius"
run_scale "True" "fahrenheit"

if [[ "${rc_total}" -ne 0 ]]; then
	echo "DHT EXPORTER E2E: FAILED"
	exit 1
fi

echo "DHT EXPORTER E2E: PASSED"
