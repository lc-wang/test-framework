#!/usr/bin/env bash
set -euo pipefail

source core/libs/logging_utils.sh
source core/libs/global_params_utils.sh

DEFAULT_MENU_FILE="configs/generic/menu.json"
DEFAULT_CONFIG_FILE="configs/generic/config_main.json"
DEFAULT_GLOBAL_PARAMS_FILE="configs/generic/global_params.json"

MENU_FILE="${MENU_FILE:-$DEFAULT_MENU_FILE}"
CONFIG_FILE="${CONFIG_FILE:-$DEFAULT_CONFIG_FILE}"
GLOBAL_PARAMS_FILE="${GLOBAL_PARAMS_FILE:-$DEFAULT_GLOBAL_PARAMS_FILE}"
RESULT_ROOT="${RESULT_DIR:-reports/results}"

LOG_CONFIG_FILE="${LOG_CONFIG_FILE:-}"

declare -A MODE_TYPES
declare -A MODE_SCRIPTS
MENU_ITEMS=()
MODE=""
SEQ_RESULT=""
COP_RESULT=""
FINAL_RESULT=""

override_paths_from_args() {
	local original_log_config="${LOG_CONFIG_FILE:-}"

	if [[ $# -ge 1 && -n "$1" ]]; then
		CONFIG_FILE="$1"
	fi

	if [[ $# -ge 2 && -n "$2" ]]; then
		GLOBAL_PARAMS_FILE="$2"
	fi

	if [[ $# -ge 3 && -n "$3" ]]; then
		MENU_FILE="$3"
	fi

	if [[ $# -ge 4 && -n "$4" ]]; then
		LOG_CONFIG_FILE="$4"
	fi

	export LOG_CONFIG_FILE
}

setup_logging() {
	if [[ -z "${LOGGING_SESSION_ACTIVE:-}" ]]; then
		logging_setup_session "menu" "$LOG_CONFIG_FILE"
	fi
}

prepare_directories() {
	mkdir -p "$RESULT_ROOT"
}

validate_required_files() {
	local missing=0

	for file in "$CONFIG_FILE" "$MENU_FILE"; do
		if [[ ! -f "$file" ]]; then
			log_error "Required file not found: $file"
			missing=1
		fi
	done

	if [[ "$missing" -eq 1 ]]; then
		exit 1
	fi
}

load_menu_items() {
	while IFS=$'\t' read -r mode label type script; do
		[[ -z "$mode" || -z "$label" ]] && continue

		MENU_ITEMS+=("$mode" "$label")
		MODE_TYPES["$mode"]="$type"
		MODE_SCRIPTS["$mode"]="$script"
	done < <(jq -r '.modes | sort_by((.order // 999))[] | [.mode, .label, (.type // "flow"), (.script // "")] | @tsv' "$MENU_FILE")

	if [[ ${#MENU_ITEMS[@]} -eq 0 ]]; then
		dialog --msgbox "No available menu items. Please check $MENU_FILE" 8 60
		exit 1
	fi
}

run_script_choice() {
	local choice="$1"
	local script_path=${MODE_SCRIPTS[$choice]:-}

	if [[ -z "$script_path" ]]; then
		log_error "Option $choice is missing the script field"
		return
	fi

	if [[ ! -f "$script_path" ]]; then
		log_error "Script not found: $script_path"
		return
	fi

	if [[ "$choice" == "global_variable_setting" ]]; then
		bash "$script_path" "$GLOBAL_PARAMS_FILE"
	else
		bash "$script_path" "$CONFIG_FILE"
	fi
}

prompt_mode_choice() {
	while true; do
		local choice type

		choice=$(dialog --menu "Please select a test mode:" 20 70 10 "${MENU_ITEMS[@]}" --stdout)
		clear >/dev/tty 2>/dev/null || true

		if [[ -z "$choice" ]]; then
			log_warn "User cancelled selection"
			exit 0
		fi

		type=${MODE_TYPES[$choice]:-flow}
		if [[ "$type" == "script" ]]; then
			run_script_choice "$choice"
			continue
		fi

		MODE="$choice"
		break
	done
}

load_parameters() {
	if [[ -f "$GLOBAL_PARAMS_FILE" ]]; then
		load_global_variables "$GLOBAL_PARAMS_FILE"
	else
		load_global_variables "$CONFIG_FILE"
	fi
}

setup_result_files() {
	local mode_dir="${RESULT_ROOT}/${MODE}"

	mkdir -p "$mode_dir"

	SEQ_RESULT="${mode_dir}/${MODE}_sequential_result.json"
	COP_RESULT="${mode_dir}/${MODE}_result.json"
	FINAL_RESULT="${mode_dir}/${MODE}_final_result.json"
}

merge_results_to_file() {
	local files=()

	[[ -f "$SEQ_RESULT" ]] && files+=("$SEQ_RESULT")
	[[ -f "$COP_RESULT" ]] && files+=("$COP_RESULT")

	if [[ ${#files[@]} -eq 0 ]]; then
		log_warn "No result files available to merge"
		return 1
	fi

	jq -s 'reduce .[] as $item ({}; .tests += ($item.tests // {})) | {tests: .tests}' "${files[@]}" >"$FINAL_RESULT"
	log_info "Merged results exported: $FINAL_RESULT"
}

show_final_summary_dialog() {
	if [[ ! -f "$FINAL_RESULT" ]]; then
		log_warn "No aggregated result file found"
		return
	fi

	local summary dialog_text
	summary=$(jq -r '.tests
        | to_entries
        | map("\(.key): PASS \(.value.pass), FAIL \(.value.fail), TOTAL \(.value.total)")
        | join("\n")' "$FINAL_RESULT")

	if [[ -n "$summary" ]]; then
		dialog_text=$(printf "Testing complete!\n\n%s" "$summary")
		dialog --msgbox "$dialog_text" 20 70 </dev/tty >/dev/tty 2>&1
	else
		log_warn "No test result summary to display"
	fi
}

run_sequential_tests() {
	if jq -e ".modes.\"${MODE}\".sequential" "$CONFIG_FILE" >/dev/null 2>&1; then
		log_info "Running sequential tests..."
		RUN_MODE=sequential bash core/runner_seq.sh "$CONFIG_FILE" "$MODE"
		log_info "Sequential testing finished"
	else
		log_info "This mode has no sequential tests"
	fi
}

run_parallel_tests() {
	if jq -e ".modes.\"${MODE}\".parallel" "$CONFIG_FILE" >/dev/null 2>&1; then
		log_info "Running parallel tests..."
		bash core/runner_coproc.sh "$CONFIG_FILE" "$MODE"
		log_info "Parallel testing finished"
	else
		log_info "This mode has no parallel tests"
	fi
}

merge_and_display() {
	local file="$1"
	[[ ! -f "$file" ]] && return

	jq -r '.tests | to_entries[] | "\(.key)  PASS:\(.value.pass) FAIL:\(.value.fail) TOTAL:\(.value.total)"' "$file" | while read -r line; do
		SUMMARY+="${line}"$'\n'
	done
}

build_summary_message() {
	SUMMARY=$'Testing finished.\n\n'
	SUMMARY+=$'End time: '"$(date '+%Y-%m-%d %H:%M:%S')"$'\n'
	SUMMARY+=$'-------------------------------\n'

	merge_and_display "$FINAL_RESULT"

	SUMMARY+=$'-------------------------------\n'
	if [[ -f "$FINAL_RESULT" ]]; then
		SUMMARY+="Merged result file: ${FINAL_RESULT##*/}\n"
	else
		SUMMARY+=$'Merged result file not yet generated.\n'
	fi
	SUMMARY+=$'Please confirm all tests are complete.\n\nPress [OK] to exit the test system.'
}

show_final_dialog() {
	dialog --clear --msgbox "$SUMMARY" 20 70 </dev/tty >/dev/tty 2>&1
	clear >/dev/tty
	log_ok "Test report display complete"
}

main() {
	override_paths_from_args "$@"
	setup_logging
	validate_required_files
	prepare_directories
	load_menu_items
	prompt_mode_choice
	load_parameters
	setup_result_files

	log_info "Starting mode: $MODE"

	run_sequential_tests
	run_parallel_tests

	merge_results_to_file
	show_final_summary_dialog
	build_summary_message
	show_final_dialog
}

main "$@"
