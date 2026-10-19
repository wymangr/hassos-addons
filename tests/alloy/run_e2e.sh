#!/usr/bin/env bash
# End-to-end test for the Grafana Alloy add-on config generation and service.
#
# Runs INSIDE the built add-on image. For each scenario it:
#   1. Seeds the scenario options into bashio's cache (see note below)
#   2. Runs the real /etc/cont-init.d/alloy_setup.sh
#   3. Runs `alloy validate` on the generated config
# Listener scenarios also start the real service and check HTTP reachability.
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
SERVICE_SCRIPT="/etc/services.d/alloy/run"
GENERATED_CONFIG="/etc/alloy/config.alloy"
ENV_FILE="/etc/alloy/alloy.env"

# Isolated bashio cache directory (bashio reads CACHE_DIR at startup).
export CACHE_DIR="/tmp/bashio-cache"
readonly OPTIONS_CACHE_FILE="${CACHE_DIR}/addons.self.options.config.cache"

rc_total=0
alloy_pid=""

stop_alloy() {
	if [[ -n "${alloy_pid}" ]]; then
		kill -TERM "${alloy_pid}" 2>/dev/null || true
		wait "${alloy_pid}" 2>/dev/null || true
		alloy_pid=""
	fi
}
trap stop_alloy EXIT
trap 'exit 1' INT TERM

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

# Exercise the CLI flag, not just config generation. A loopback listener must
# answer locally but refuse the container's non-loopback IP (the LAN equivalent).
expect_http_listener() {
	local name="$1" scenario="$2" patch="$3" address="$4" remote_access="$5"
	local options_file="/tmp/http-options.json" failed=0 ip actual_access
	local url="http://${address/0.0.0.0/127.0.0.1}/-/ready"
	echo "::group::scenario ${name} (HTTP listener)"
	if ! jq --arg journal_config "${FIXTURES_DIR}/journal.alloy" \
		"${patch}" "${scenario}" > "${options_file}"; then
		echo "FAIL[${name}]: could not prepare listener options"
		rc_total=1
		echo "::endgroup::"
		return
	fi
	run_setup "${options_file}"
	if [[ ${setup_rc} -ne 0 ]]; then
		echo "FAIL[${name}]: setup failed"
		cat /tmp/setup.log
		rc_total=1
		echo "::endgroup::"
		return
	fi

	"${SERVICE_SCRIPT}" >/tmp/http-service.log 2>&1 &
	alloy_pid=$!
	if ! curl --noproxy '*' -g -fsS --connect-timeout 1 --max-time 2 \
		--retry 20 --retry-connrefused --retry-delay 1 --retry-max-time 25 \
		"${url}" >/dev/null 2>/tmp/http-curl.log; then
		echo "FAIL[${name}]: expected listener did not become ready"
		cat /tmp/http-curl.log
		failed=1
	elif ! tr '\0' '\n' < "/proc/${alloy_pid}/cmdline" \
		| grep -Fx -- "--server.http.listen-addr=${address}" >/dev/null; then
		echo "FAIL[${name}]: service did not pass the expected listener argument"
		failed=1
	else
		ip="$(hostname -i | awk '{print $1}')"
		if [[ -z "${ip}" || "${ip}" == 127.* || "${ip}" == *:* ]]; then
			echo "FAIL[${name}]: could not determine a non-loopback IPv4 address"
			failed=1
		else
			actual_access=no
			if curl --noproxy '*' -fsS --connect-timeout 1 --max-time 2 \
				"http://${ip}:${address##*:}/-/ready" >/dev/null 2>&1; then
				actual_access=yes
			fi
			if [[ "${actual_access}" != "${remote_access}" ]]; then
				echo "FAIL[${name}]: non-loopback access was ${actual_access}, expected ${remote_access}"
				failed=1
			fi
		fi
	fi
	if [[ "${name}" == http_loopback_override ]]; then
		if ! tr '\0' '\n' < "/proc/${alloy_pid}/environ" | grep -qxF 'HTTP_LISTEN_ADDR=keep-user-address' \
			|| ! tr '\0' '\n' < "/proc/${alloy_pid}/environ" | grep -qxF 'HTTP_LISTEN_PORT=keep-user-port'; then
			echo "FAIL[${name}]: listener settings overwrote user environment variables"
			failed=1
		fi
	fi
	stop_alloy
	if [[ ${failed} -ne 0 ]]; then
		cat /tmp/http-service.log
		rc_total=1
	else
		echo "PASS[${name}]: ${address}, non-loopback access=${remote_access}"
	fi
	echo "::endgroup::"
}

# These errors must come from our startup validation, not an unrelated config
# failure or a timeout after Alloy accidentally opened a listener.
expect_invalid_http_listeners() {
	local address service_rc
	echo "::group::scenario invalid_http_listeners"
	run_setup "${SCEN_DIR}/override.json"
	if [[ ${setup_rc} -ne 0 ]]; then
		echo "FAIL[invalid_http_listeners]: setup failed"
		cat /tmp/setup.log
		rc_total=1
		echo "::endgroup::"
		return
	fi
	for address in '' '   ' '127.0.0.1' '127.0.0.1:' ':12345' \
		'127.0.0.1:abc' '127.0.0.1:0' '127.0.0.1:65536' \
		'127.0.0.1:100000' '127.0.0.1:-1' '127.0.0.1:1.5' \
		'::1:12345' '[::1]' '[::1]:0' '[::1]:65536' \
		'http://127.0.0.1:12345' '127.0.0.1:12345 --disable-reporting'; do
		if ! jq --arg address "${address}" '. + {server_http_listen_addr: $address}' \
			"${SCEN_DIR}/override.json" > "${OPTIONS_CACHE_FILE}"; then
			echo "FAIL[invalid_http_listeners]: could not prepare options"
			rc_total=1
			break
		fi
		service_rc=0
		timeout --kill-after=1s 10s "${SERVICE_SCRIPT}" >/tmp/http-service.log 2>&1 || service_rc=$?
		if [[ ${service_rc} -ne 1 ]] \
			|| ! grep -qF 'Invalid server_http_listen_addr:' /tmp/http-service.log \
			|| grep -qF 'Starting Grafana Alloy' /tmp/http-service.log; then
			printf 'FAIL[invalid_http_listeners]: %q was not rejected before startup\n' "${address}"
			cat /tmp/http-service.log
			rc_total=1
		else
			printf 'PASS[invalid_http_listeners]: rejected %q\n' "${address}"
		fi
	done
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

expect_http_listener "http_legacy_generated" "${SCEN_DIR}/default.json" '.' '0.0.0.0:12345' yes
expect_http_listener "http_legacy_override" "${SCEN_DIR}/override.json" '.' '0.0.0.0:12345' yes
expect_http_listener "http_null" "${SCEN_DIR}/override.json" '. + {server_http_listen_addr: null}' '0.0.0.0:12345' yes
expect_http_listener "http_explicit_default" "${SCEN_DIR}/default.json" '. + {server_http_listen_addr: "0.0.0.0:12345"}' '0.0.0.0:12345' yes
expect_http_listener "http_loopback_generated" "${SCEN_DIR}/loki_only.json" '. + {server_http_listen_addr: "127.0.0.1:12345"}' '127.0.0.1:12345' no
expect_http_listener "http_loopback_override" "${SCEN_DIR}/override.json" '. + {server_http_listen_addr: "127.0.0.1:12345", override_config_path: $journal_config, environment_variables: [{name: "HTTP_LISTEN_ADDR", value: "keep-user-address"}, {name: "HTTP_LISTEN_PORT", value: "keep-user-port"}]}' '127.0.0.1:12345' no
expect_http_listener "http_ipv6" "${SCEN_DIR}/override.json" '. + {server_http_listen_addr: "[::1]:12345"}' '[::1]:12345' no
expect_http_listener "http_hostname" "${SCEN_DIR}/override.json" '. + {server_http_listen_addr: "localhost:12345"}' 'localhost:12345' no
expect_http_listener "http_lower_port" "${SCEN_DIR}/override.json" '. + {server_http_listen_addr: "127.0.0.1:00001"}' '127.0.0.1:00001' no
expect_http_listener "http_upper_port" "${SCEN_DIR}/override.json" '. + {server_http_listen_addr: "127.0.0.1:65535"}' '127.0.0.1:65535' no
expect_invalid_http_listeners

if [[ ${rc_total} -ne 0 ]]; then
	echo "ALLOY E2E: FAILED"
	exit 1
fi
echo "ALLOY E2E: ALL SCENARIOS PASSED"
