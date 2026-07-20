#!/usr/bin/env bash
# End-to-end test for the Grafana Alloy add-on config generation.
#
# Runs INSIDE the built add-on image. For each scenario it:
#   1. Writes the scenario options to /data/options.json (where bashio reads them)
#   2. Runs the real /etc/cont-init.d/alloy_setup.sh
#   3. Runs `alloy validate` on the generated config
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

rc_total=0

# Run the add-on setup script with a given options file.
# Populates the global `setup_rc` with its exit code.
run_setup() {
	local options_file="$1"
	mkdir -p /data
	cp "${options_file}" /data/options.json
	rm -f "${GENERATED_CONFIG}"
	if "${SETUP_SCRIPT}" >/tmp/setup.log 2>&1; then
		setup_rc=0
	else
		setup_rc=$?
	fi
	cat /tmp/setup.log
}

# Scenario that is expected to generate a valid config.
expect_valid() {
	local name="$1" options_file="$2"
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
expect_valid          "prometheus_labels" "${SCEN_DIR}/prom_labels.json"
expect_valid          "loki"             "${SCEN_DIR}/loki.json"
expect_valid          "loki_syslog"      "${SCEN_DIR}/loki_syslog.json"
expect_valid          "full"             "${SCEN_DIR}/full.json"
expect_setup_failure  "missing_endpoint" "${SCEN_DIR}/missing_endpoint.json"
expect_override

if [[ ${rc_total} -ne 0 ]]; then
	echo "ALLOY E2E: FAILED"
	exit 1
fi
echo "ALLOY E2E: ALL SCENARIOS PASSED"
