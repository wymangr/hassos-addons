#!/usr/bin/env bash
# End-to-end test for the Grafana Alloy add-on config generation.
#
# Runs INSIDE the built add-on image. For each scenario it:
#   1. Seeds the scenario options into bashio's cache (see note below)
#   2. Runs the real /etc/cont-init.d/alloy_setup.sh
#   3. Runs `alloy validate` on the generated config
#
# How the add-on options are injected
# -----------------------------------
# This version of bashio does NOT read /data/options.json directly. It fetches
# options from the Supervisor API via `bashio::app.config`, which first checks a
# file-backed cache at "${CACHE_DIR}/addons.self.options.config.cache" (key
# "addons.self.options.config"). With raw=false, the cached value is the plain
# options object (the API response's ".data"), which is exactly the shape of the
# scenario JSON files. By pre-writing that cache file we make every
# `bashio::config` call return the scenario options without any network access
# to the (absent) Supervisor. CACHE_DIR is read by bashio at startup.
#
# `alloy validate` uses the default stability level (generally-available) and no
# community components, which matches the flags the add-on uses at runtime in
# etc/services.d/alloy/run. All components used by the generated config are GA.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCEN_DIR="${TESTS_DIR}/scenarios"
FIXTURES_DIR="${TESTS_DIR}/fixtures"
SETUP_SCRIPT="/etc/cont-init.d/alloy_setup.sh"
GENERATED_CONFIG="/etc/alloy/config.alloy"

# Isolated bashio cache directory (bashio reads CACHE_DIR at startup).
export CACHE_DIR="/tmp/bashio-cache"
readonly OPTIONS_CACHE_FILE="${CACHE_DIR}/addons.self.options.config.cache"

rc_total=0

# Run the add-on setup script with a given options file.
# Populates the global `setup_rc` with its exit code.
run_setup() {
	local options_file="$1"
	# Seed bashio's app-config cache with this scenario's options so that
	# bashio::config reads them without contacting the Supervisor API.
	rm -rf "${CACHE_DIR}"
	mkdir -p "${CACHE_DIR}"
	cp "${options_file}" "${OPTIONS_CACHE_FILE}"
	rm -f "${GENERATED_CONFIG}"
	if "${SETUP_SCRIPT}" >/tmp/setup.log 2>&1; then
		setup_rc=0
	else
		setup_rc=$?
	fi
	cat /tmp/setup.log
}

# Scenario that is expected to generate a valid config.
# Optional third arg: a substring that must appear in the generated config
# (used to assert scenario-specific blocks were rendered, e.g. "loki.write").
expect_valid() {
	local name="$1" options_file="$2" required_substr="${3:-}"
	echo "::group::scenario ${name} (expect valid)"
	run_setup "${options_file}"

	if [[ ${setup_rc} -ne 0 ]]; then
		echo "FAIL[${name}]: alloy_setup.sh exited ${setup_rc} but was expected to succeed"
		rc_total=1
		echo "::endgroup::"
		return
	fi

	if [[ ! -f "${GENERATED_CONFIG}" ]]; then
		echo "FAIL[${name}]: expected generated config at ${GENERATED_CONFIG} but none was produced"
		rc_total=1
		echo "::endgroup::"
		return
	fi

	# `alloy validate` treats an empty/whitespace-only file as valid, which would
	# mask a broken config-generation run (e.g. options not injected). Require
	# real content and at least the prometheus.remote_write block, which every
	# "expect valid" scenario here enables.
	if [[ -z "$(tr -d '[:space:]' < "${GENERATED_CONFIG}")" ]]; then
		echo "FAIL[${name}]: generated config is empty (options were not applied)"
		rc_total=1
		echo "::endgroup::"
		return
	fi

	if ! grep -q "prometheus.remote_write" "${GENERATED_CONFIG}"; then
		echo "FAIL[${name}]: generated config is missing the prometheus.remote_write block"
		rc_total=1
		echo "::endgroup::"
		return
	fi

	if [[ -n "${required_substr}" ]] && ! grep -qF "${required_substr}" "${GENERATED_CONFIG}"; then
		echo "FAIL[${name}]: generated config is missing expected content: ${required_substr}"
		rc_total=1
		echo "::endgroup::"
		return
	fi

	echo "----- generated config -----"
	cat "${GENERATED_CONFIG}"
	echo "----------------------------"

	if alloy validate "${GENERATED_CONFIG}"; then
		echo "PASS[${name}]: alloy validate succeeded"
	else
		echo "FAIL[${name}]: alloy validate rejected the generated config"
		rc_total=1
	fi
	echo "::endgroup::"
}

# Scenario that is expected to make the setup script exit non-zero (validation
# guard rails, e.g. a required option left empty).
expect_setup_failure() {
	local name="$1" options_file="$2"
	echo "::group::scenario ${name} (expect setup failure)"
	run_setup "${options_file}"

	if [[ ${setup_rc} -ne 0 ]]; then
		echo "PASS[${name}]: alloy_setup.sh correctly failed (rc=${setup_rc})"
	else
		echo "FAIL[${name}]: alloy_setup.sh succeeded but was expected to fail"
		rc_total=1
	fi
	echo "::endgroup::"
}

# override_config path: the setup script does not generate a config, it defers to
# a user-provided file. Confirm the script succeeds and that a representative
# override file validates.
expect_override() {
	local name="override"
	echo "::group::scenario ${name} (override_config)"
	run_setup "${SCEN_DIR}/override.json"

	if [[ ${setup_rc} -ne 0 ]]; then
		echo "FAIL[${name}]: alloy_setup.sh exited ${setup_rc} but was expected to succeed"
		rc_total=1
		echo "::endgroup::"
		return
	fi

	if alloy validate "${FIXTURES_DIR}/override.alloy"; then
		echo "PASS[${name}]: override fixture validates"
	else
		echo "FAIL[${name}]: override fixture failed validation"
		rc_total=1
	fi
	echo "::endgroup::"
}

expect_valid          "default"          "${SCEN_DIR}/default.json"
expect_valid          "prometheus_labels" "${SCEN_DIR}/prom_labels.json"  "ha-instance-01"
expect_valid          "loki"             "${SCEN_DIR}/loki.json"           "loki.write"
expect_valid          "loki_syslog"      "${SCEN_DIR}/loki_syslog.json"    "loki.source.syslog"
expect_valid          "full"             "${SCEN_DIR}/full.json"           "loki.source.syslog"
expect_setup_failure  "missing_endpoint" "${SCEN_DIR}/missing_endpoint.json"
expect_override

if [[ ${rc_total} -ne 0 ]]; then
	echo "ALLOY E2E: FAILED"
	exit 1
fi
echo "ALLOY E2E: ALL SCENARIOS PASSED"
