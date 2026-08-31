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
ENV_FILE="/etc/alloy/alloy.env"

# Isolated bashio cache directory (bashio reads CACHE_DIR at startup).
export CACHE_DIR="/tmp/bashio-cache"
readonly OPTIONS_CACHE_FILE="${CACHE_DIR}/addons.self.options.config.cache"

rc_total=0

# Run the add-on setup script with a given options file.
# Populates the global `setup_rc` with its exit code. Output is captured to
# /tmp/setup.log; callers decide whether to display it (e.g. only on an
# unexpected result), so negative tests don't print alarming output on success.
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
}

# Scenario that is expected to generate a valid config.
#   $3 required_substrs : space-separated substrings that MUST appear (optional)
#   $4 forbidden_substrs: space-separated substrings that must NOT appear (optional)
# (substrings themselves cannot contain spaces).
expect_valid() {
	local name="$1" options_file="$2" required_substrs="${3:-}" forbidden_substrs="${4:-}"
	echo "::group::scenario ${name} (expect valid)"
	run_setup "${options_file}"

	if [[ ${setup_rc} -ne 0 ]]; then
		echo "FAIL[${name}]: alloy_setup.sh exited ${setup_rc} but was expected to succeed"
		echo "----- setup output -----"
		cat /tmp/setup.log
		echo "------------------------"
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
	# real content before doing anything else.
	if [[ -z "$(tr -d '[:space:]' < "${GENERATED_CONFIG}")" ]]; then
		echo "FAIL[${name}]: generated config is empty (options were not applied)"
		rc_total=1
		echo "::endgroup::"
		return
	fi

	local substr
	for substr in ${required_substrs}; do
		if ! grep -qF "${substr}" "${GENERATED_CONFIG}"; then
			echo "FAIL[${name}]: generated config is missing expected content: ${substr}"
			rc_total=1
			echo "::endgroup::"
			return
		fi
	done

	for substr in ${forbidden_substrs}; do
		if grep -qF "${substr}" "${GENERATED_CONFIG}"; then
			echo "FAIL[${name}]: generated config unexpectedly contains: ${substr}"
			rc_total=1
			echo "::endgroup::"
			return
		fi
	done

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
# guard rails, e.g. a required option left empty). The setup output (which
# includes intentional FATAL messages) is captured and only shown if the test
# does NOT behave as expected, to avoid alarming-looking output on success.
expect_setup_failure() {
	local name="$1" options_file="$2"
	echo "::group::scenario ${name} (expect setup failure)"
	run_setup "${options_file}"

	if [[ ${setup_rc} -ne 0 ]]; then
		echo "PASS[${name}]: setup correctly rejected the invalid options"
	else
		echo "FAIL[${name}]: alloy_setup.sh succeeded but was expected to fail"
		echo "----- setup output -----"
		cat /tmp/setup.log
		echo "------------------------"
		rc_total=1
	fi
	echo "::endgroup::"
}

# Negative test for the validation step itself: feed `alloy validate` a config
# that is deliberately invalid and assert it is REJECTED. This proves the
# validate step actually catches bad config for the pinned Alloy version (i.e.
# it is not silently passing everything), which is what guards against a bad
# config-generation change or an Alloy version bump that drops an option.
# The validator's error output is captured and only shown if the test does NOT
# behave as expected.
expect_invalid_config() {
	local name="invalid_config"
	echo "::group::scenario ${name} (expect alloy validate to reject)"
	if alloy validate "${FIXTURES_DIR}/invalid.alloy" >/tmp/validate.log 2>&1; then
		echo "FAIL[${name}]: alloy validate ACCEPTED an invalid config (validation has no teeth!)"
		echo "----- alloy validate output -----"
		cat /tmp/validate.log
		echo "---------------------------------"
		rc_total=1
	else
		echo "PASS[${name}]: alloy validate correctly rejected the invalid config"
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
		echo "----- setup output -----"
		cat /tmp/setup.log
		echo "------------------------"
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

# User supplied environment variables: the setup script writes an env file that
# the service sources before starting Alloy. Assert the values survive shell
# escaping (quotes, spaces, would-be command substitution) and that a config
# using sys.env() validates once they are applied.
expect_env_vars() {
	local name="env_vars"
	echo "::group::scenario ${name} (environment_variables)"
	run_setup "${SCEN_DIR}/env_vars.json"

	if [[ ${setup_rc} -ne 0 ]]; then
		echo "FAIL[${name}]: alloy_setup.sh exited ${setup_rc} but was expected to succeed"
		echo "----- setup output -----"
		cat /tmp/setup.log
		echo "------------------------"
		rc_total=1
		echo "::endgroup::"
		return
	fi

	# A variable without a value must be exported as an empty string, not "null".
	local expected="prod|alloy-agent|p@ss w'ord\"\$(id)|"
	local actual
	actual="$(. "${ENV_FILE}" && printf '%s|%s|%s|%s' "${ALLOY_ENV}" "${ALLOY_USER}" "${ALLOY_TOKEN}" "${ALLOY_EMPTY?unset}")"
	if [[ "${actual}" != "${expected}" ]]; then
		echo "FAIL[${name}]: sourced environment variables do not match"
		echo "  expected: ${expected}"
		echo "  actual  : ${actual}"
		rc_total=1
		echo "::endgroup::"
		return
	fi

	if (. "${ENV_FILE}" && alloy validate "${FIXTURES_DIR}/env.alloy"); then
		echo "PASS[${name}]: sys.env() config validates with the injected variables"
	else
		echo "FAIL[${name}]: sys.env() config failed validation with the injected variables"
		rc_total=1
	fi

	# Removing the option again must clear the previously written variables.
	run_setup "${SCEN_DIR}/default.json"
	if [[ -s "${ENV_FILE}" ]]; then
		echo "FAIL[${name}]: env file still has content when no environment_variables are configured"
		cat "${ENV_FILE}"
		rc_total=1
	else
		echo "PASS[${name}]: env file is reset when no environment_variables are configured"
	fi
	echo "::endgroup::"
}

expect_valid          "default"           "${SCEN_DIR}/default.json"          "prometheus.remote_write"
expect_valid          "prometheus_labels" "${SCEN_DIR}/prom_labels.json"      "prometheus.remote_write ha-instance-01"
expect_valid          "loki"              "${SCEN_DIR}/loki.json"             "prometheus.remote_write loki.write"
expect_valid          "loki_syslog"       "${SCEN_DIR}/loki_syslog.json"      "prometheus.remote_write loki.source.syslog"
expect_valid          "full"              "${SCEN_DIR}/full.json"             "prometheus.remote_write loki.source.syslog"
# Loki only (Prometheus disabled): must have Loki, must NOT have remote_write.
expect_valid          "loki_only"         "${SCEN_DIR}/loki_only.json"        "loki.write" "prometheus.remote_write"
# Environment variables must never be substituted into the generated config, so
# the value of the PROMETHEUS_CONFIG variable must not leak into it.
expect_valid          "env_vars_generated" "${SCEN_DIR}/env_vars_generated.json" "prometheus.remote_write" "should-not-leak"
# No servername_tag: exercises the else-branches (no external_labels block, and
# Loki journal labels without a servername), so "servername" must not appear.
expect_valid          "no_servername"     "${SCEN_DIR}/no_servername.json"    "prometheus.remote_write loki.source.journal" "servername external_labels"
# Exporters disabled: unix/process scrape blocks must be omitted, self stays.
expect_valid          "no_exporters"      "${SCEN_DIR}/no_exporters.json"     "prometheus.remote_write prometheus.exporter.self" "prometheus.exporter.unix prometheus.exporter.process"
# Basic auth on both endpoints: both must emit a basic_auth block with the creds.
expect_valid          "basic_auth"        "${SCEN_DIR}/basic_auth.json"       "basic_auth promuser1234 lokiuser4321 loki.write"
# Basic auth with username but no password: auth must NOT be emitted (both the
# username and password are required), so no basic_auth block should appear.
expect_valid          "basic_auth_username_only" "${SCEN_DIR}/basic_auth_username_only.json" "prometheus.remote_write" "basic_auth"
# Basic auth password containing " and \: river_escape must produce config that
# alloy validate still accepts (guards the escaping against breakage).
expect_valid          "basic_auth_special_chars" "${SCEN_DIR}/basic_auth_special_chars.json" "basic_auth"
expect_setup_failure  "missing_endpoint"  "${SCEN_DIR}/missing_endpoint.json"
expect_setup_failure  "override_empty_path" "${SCEN_DIR}/override_empty_path.json"
# An environment variable name that is not a valid shell identifier must be
# rejected instead of being written into the sourced env file.
expect_setup_failure  "env_vars_invalid_name" "${SCEN_DIR}/env_vars_invalid_name.json"
# Names used by the service script (or the shell that starts Alloy) must be
# rejected so the env file cannot redirect Alloy to another config.
expect_setup_failure  "env_vars_reserved_name" "${SCEN_DIR}/env_vars_reserved_name.json"
expect_invalid_config
expect_override
expect_env_vars

if [[ ${rc_total} -ne 0 ]]; then
	echo "ALLOY E2E: FAILED"
	exit 1
fi
echo "ALLOY E2E: ALL SCENARIOS PASSED"
