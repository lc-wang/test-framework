#!/usr/bin/env bash
set -uo pipefail

source core/libs/json_utils.sh
source core/libs/logging_utils.sh
source core/libs/result_utils.sh

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_FILE=${1:-configs/generic/config_main.json}
MODE=${2:-${MODE:-}}
RESULT_ROOT=${RESULT_DIR:-reports/results}

ensure_logging() {
	if [[ -n "${LOGGING_SESSION_ACTIVE:-}" ]]; then
		return
	fi

	LOG_FILE=""

	local config_path
	config_path=${LOG_CONFIG_FILE:-$LOG_CONFIG_FILE_DEFAULT}
	logging_setup_session "sequential" "$config_path"
}

ensure_jq_available() {
	if command -v jq >/dev/null 2>&1; then
		return 0
	fi

	log_error "jq is required to parse the config file. Please install it (sudo apt install -y jq)."
	exit 1
}

resolve_mode() {
	if [[ -z "$MODE" ]]; then
		log_error "Test mode not specified. Provide it as the second argument or set the MODE environment variable."
		exit 1
	fi

	if ! jq -e ".modes.\"${MODE}\"" "$CONFIG_FILE" >/dev/null 2>&1; then
		log_error "Mode not found in the config file: ${MODE}"
		exit 1
	fi
}

load_interactive_params() {
	if [[ -f "core/libs/config_param_utils.sh" ]]; then
		local seq_count
		seq_count=$(jq -r ".modes.\"${MODE}\".sequential | length" "$CONFIG_FILE" 2>/dev/null || echo 0)

		if [[ -z "$seq_count" || "$seq_count" -eq 0 ]]; then
			log_warn "No sequential tests defined; skipping parameter setup page."
			return
		fi

		source core/libs/config_param_utils.sh
		export_all_params_for_mode "$CONFIG_FILE" "$MODE" "sequential"
	else
		log_warn "core/libs/config_param_utils.sh not found; skipping interactive parameter setup."
	fi
}

read_sequential_keys() {
	mapfile -t SEQ_KEYS < <(jq -r ".modes.\"${MODE}\".sequential[]" "$CONFIG_FILE" 2>/dev/null)
	if [[ ${#SEQ_KEYS[@]} -eq 0 ]]; then
		log_warn "No sequential tests defined; skipping."
		exit 0
	fi
}

init_counters() {
	declare -gA PASS_COUNT FAIL_COUNT TOTAL_COUNT
	for key in "${SEQ_KEYS[@]}"; do
		PASS_COUNT[$key]=0
		FAIL_COUNT[$key]=0
		TOTAL_COUNT[$key]=0
	done
}

run_test_item() {
	local key="$1"
	local script_rel enabled script_abs result

	enabled=$(jq -r ".tests.\"${key}\".enabled" "$CONFIG_FILE")
	if [[ "$enabled" != "true" ]]; then
		log_warn "Skipping $key (disabled)"
		return
	fi

	script_rel=$(jq -r ".tests.\"${key}\".script" "$CONFIG_FILE")
	script_abs="$ROOT_DIR/$script_rel"

	if [[ ! -x "$script_abs" ]]; then
		log_error "Not found or not executable: $script_abs"
		return
	fi

	log_info "Running test item: $key"
	export_params_for_test "$key" "$CONFIG_FILE"

	if bash "$script_abs"; then
		log_ok "$key test passed"
		((PASS_COUNT["$key"]++))
	else
		result=$?
		log_error "$key test failed (exit=${result:-1})"
		((FAIL_COUNT["$key"]++))
	fi

	((TOTAL_COUNT["$key"]++))
}

main() {
	ensure_logging
	ensure_jq_available
	resolve_mode
	load_interactive_params

	log_info "Running sequential test flow (${MODE}) using ${CONFIG_FILE}"

	read_sequential_keys
	init_counters

	for key in "${SEQ_KEYS[@]}"; do
		run_test_item "$key"
	done

	log_info "Sequential testing completed."

	local result_json
	result_json="${RESULT_ROOT}/${MODE}/${MODE}_sequential_result.json"
	write_results_json "$result_json" SEQ_KEYS PASS_COUNT FAIL_COUNT TOTAL_COUNT

	log_info "Sequential test results exported: $result_json"
}

main "$@"

exit 0
