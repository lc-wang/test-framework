#!/usr/bin/env bash
set -uo pipefail

DIALOG_PID=-1
CONFIG_FILE=${1:-configs/generic/config_main.json}
MODE=${2:-${MODE:-}}
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RESULT_ROOT=${RESULT_DIR:-reports/results}

exec 3>&1

source core/libs/json_utils.sh
source core/libs/logging_utils.sh
source core/libs/result_utils.sh

ensure_logging() {
	if [[ -n "${LOGGING_SESSION_ACTIVE:-}" ]]; then
		return
	fi

	LOG_FILE=""

	local config_path
	config_path=${LOG_CONFIG_FILE:-$LOG_CONFIG_FILE_DEFAULT}
	logging_setup_session "coproc" "$config_path"
}

ensure_jq_available() {
	if command -v jq >/dev/null 2>&1; then
		return 0
	fi

	dialog --msgbox "jq is required but not installed.\nPlease install: sudo apt install -y jq" 8 60 >&3
	exit 1
}

load_params() {
	if [[ -f "core/libs/config_param_utils.sh" ]]; then
		local parallel_count
		parallel_count=$(jq -r ".modes.\"${MODE}\".parallel | length" "$CONFIG_FILE" 2>/dev/null || echo 0)

		if [[ -z "$parallel_count" || "$parallel_count" -eq 0 ]]; then
			log_warn "No parallel tests defined; skipping parameter setup page."
		else
			source core/libs/config_param_utils.sh
			export_all_params_for_mode "$CONFIG_FILE" "$MODE" "parallel"
		fi
	else
		log_warn "core/libs/config_param_utils.sh not found; skipping parameter loading"
	fi

	if jq -e ".env" "$CONFIG_FILE" >/dev/null 2>&1; then
		log_info "Loading test environment parameters"
		while IFS="=" read -r key val; do
			[[ -z "$key" ]] && continue
			local new_val
			new_val=$(dialog --inputbox "Set parameter ${key}:" 8 60 "$val" --stdout 2>/dev/null)
			export "$key"="$new_val"
		done < <(jq -r '.env | to_entries[] | "\(.key)=\(.value)"' "$CONFIG_FILE")
	fi
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

load_mode_metadata() {
	mode_type=$(jq -r ".modes.\"${MODE}\".type" "$CONFIG_FILE" 2>/dev/null)
	mapfile -t TEST_KEYS < <(jq -r ".modes.\"${MODE}\".parallel[]" "$CONFIG_FILE" 2>/dev/null)
	log_info "Mode type: ${mode_type:-unknown}"
	log_info "Parallel tests: ${TEST_KEYS[*]:-(none)}"
}

prepare_tests() {
	declare -gA TOLERANCE_MAP
	declare -ga TEST_ITEMS=()

	for key in "${TEST_KEYS[@]}"; do
		local enabled
		enabled=$(jq -r ".tests.\"${key}\".enabled" "$CONFIG_FILE")
		if [[ "$enabled" != "true" ]]; then
			continue
		fi

		local script_rel script_abs tolerance
		script_rel=$(jq -r ".tests.\"${key}\".script" "$CONFIG_FILE")
		script_abs="$ROOT_DIR/$script_rel"
		TEST_ITEMS+=("$key:$script_abs")

		tolerance=$(jq -r ".tests.\"${key}\".tolerance // 0" "$CONFIG_FILE")
		TOLERANCE_MAP["$key"]="$tolerance"
	done
}

cleanup() {
	for pid in "${COPROC_PIDS[@]}"; do
		if ps -p "$pid" >/dev/null 2>&1; then
			log_warn "Terminating child process (PID=$pid)"
			kill -TERM -"$pid" 2>/dev/null || true
			pkill -TERM -P "$pid" 2>/dev/null || true
			sleep 0.3

			if ps -p "$pid" >/dev/null 2>&1; then
				log_warn "Force kill -9 (PID=$pid)"
				kill -9 -"$pid" 2>/dev/null || true
				pkill -9 -P "$pid" 2>/dev/null || true
			fi
		fi
	done

	local end_time duration duration_str result_json
	end_time=$(date +%s)
	duration=$((end_time - start_time))
	printf -v duration_str "%02d:%02d:%02d" $((duration / 3600)) $(((duration % 3600) / 60)) $((duration % 60))

	result_json="${RESULT_ROOT}/${MODE}/${MODE}_result.json"
	write_results_json "$result_json" COPROC_NAMES PASS_COUNT FAIL_COUNT TOTAL_COUNT
	log_info "Test results exported: $result_json (duration ${duration_str})"
}

start_children() {
	for entry in "${TEST_ITEMS[@]}"; do
		IFS=':' read -r name script_abs <<<"$entry"
		if [[ ! -x "$script_abs" ]]; then
			dialog --msgbox "Warning: Test item does not exist or is not executable:\n$script_abs" 8 70 </dev/tty >/dev/tty 2>&1
			continue
		fi

		declare -A PARAMS=()
		while IFS="=" read -r k v; do
			[[ -z "$k" ]] && continue
			local current_val
			current_val="${!k:-$v}"
			PARAMS["$k"]="$current_val"
		done < <(jq -r ".tests.\"${name}\".params | to_entries[] | \"\(.key)=\(.value)\"" "$CONFIG_FILE" 2>/dev/null)

		coproc CHILD_COPROC {
			export COPROC_ACTIVE=1
			cd "$ROOT_DIR" || exit 1
			source core/libs/json_utils.sh
			export_params_for_test "$name" "$CONFIG_FILE"

			for key in "${!PARAMS[@]}"; do
				export "$key"="${PARAMS[$key]}"
			done

			bash "$script_abs"
		}

		COPROC_PIDS+=(${CHILD_COPROC_PID})
		COPROC_READS+=(${CHILD_COPROC[0]})
		COPROC_WRITES+=(${CHILD_COPROC[1]})
		COPROC_NAMES+=("$name")

		DATA_MAP["$name"]="WAITING"
		PASS_COUNT["$name"]=0
		FAIL_COUNT["$name"]=0
		TOTAL_COUNT["$name"]=0
	done
}

update_data() {
	for fd in "${COPROC_WRITES[@]}"; do
		echo "!GET" >&"$fd" 2>/dev/null || true
	done

	for ((i = 0; i < ${#COPROC_READS[@]}; i++)); do
		local fd name line
		fd=${COPROC_READS[$i]}
		name=${COPROC_NAMES[$i]}
		if read -t 0.1 -u "$fd" line; then
			DATA_MAP["$name"]="$line"
			((TOTAL_COUNT["$name"]++))

			case "$line" in
			PASS) ((PASS_COUNT["$name"]++)) ;;
			FAIL) ((FAIL_COUNT["$name"]++)) ;;
			esac
		fi
	done
}

display_dashboard() {
	local allow_exit=$1
	local remaining_sec=${2:-0}
	local has_timer=${3:-false}

	local now elapsed elapsed_str remaining_str
	now=$(date +%s)
	elapsed=$((now - start_time))
	printf -v elapsed_str "%02d:%02d:%02d" \
		$((elapsed / 3600)) $(((elapsed % 3600) / 60)) $((elapsed % 60))

	if ((remaining_sec > 0)); then
		printf -v remaining_str "%02d:%02d:%02d" \
			$((remaining_sec / 3600)) $(((remaining_sec % 3600) / 60)) $((remaining_sec % 60))
	else
		remaining_str="00:00:00"
	fi

	local output="Test Status\n-------------------------------\n"
	output+="Elapsed time: $elapsed_str\n"
	if ((remaining_sec > 0)); then
		output+="Remaining time: ${remaining_str}\n"
	fi
	output+="-------------------------------\n"

	for key in "${COPROC_NAMES[@]}"; do
		local val pass fail total tolerance fail_ratio color_val line
		val="${DATA_MAP[$key]}"
		pass=${PASS_COUNT[$key]:-0}
		fail=${FAIL_COUNT[$key]:-0}
		total=${TOTAL_COUNT[$key]:-0}
		tolerance=${TOLERANCE_MAP[$key]:-0}

		if ((total > 0)); then
			fail_ratio=$(awk -v f="$fail" -v t="$total" 'BEGIN { if (t == 0) { print 0 } else { printf "%.6f", f / t } }')
		else
			fail_ratio=0
		fi

		if ((total > 0)) && awk -v r="$fail_ratio" -v tol="$tolerance" 'BEGIN { exit !(r > tol) }'; then
			val="FAIL"
		elif ((total > 0)); then
			val="PASS"
		fi

		case "$val" in
		PASS) color_val="\Z2PASS\Zn" ;;
		FAIL) color_val="\Z1FAIL\Zn" ;;
		*) color_val="\Z3${val}\Zn" ;;
		esac

		printf -v line "%-10s %-6s | PASS:%-4d FAIL:%-4d TOTAL:%-4d" \
			"$key" "$color_val" "$pass" "$fail" "$total"
		output+="$line\n"
	done

	if [[ "$allow_exit" == "true" ]]; then
		if [[ "$has_timer" == "true" ]]; then
			output+="Time reached; press Enter to end the test\n"
		else
			output+="Press Enter to end the test\n"
		fi
		output+="-------------------------------\n"
		dialog --colors --no-collapse --timeout 1 --msgbox "$output" 20 85 </dev/tty >/dev/tty 2>&1
	else
		output+="Preset duration not reached; please wait for the end prompt\n"
		output+="-------------------------------\n"
		dialog --colors --no-collapse --timeout 1 --no-ok --msgbox "$output" 20 85 </dev/tty >/dev/tty 2>&1
	fi
}

main_loop() {
	start_time=$(date +%s)
	local test_time_hr=${1:-0}
	local duration_sec=$((test_time_hr * 3600))

	while true; do
		update_data

		local now remaining_sec allow_exit ret
		now=$(date +%s)
		remaining_sec=0
		allow_exit=true

		if ((duration_sec > 0)); then
			remaining_sec=$((duration_sec - (now - start_time)))
			if ((remaining_sec > 0)); then
				allow_exit=false
			else
				remaining_sec=0
			fi
		fi

		display_dashboard "$allow_exit" "$remaining_sec" "$([[ $duration_sec -gt 0 ]] && echo true || echo false)"
		ret=$?

		if [[ "$allow_exit" == "true" ]] && [[ $ret -eq 0 || $ret -eq 1 ]]; then
			log_info "User pressed ESC/Enter, ending test"
			cleanup
			break
		fi
	done

	log_info "main loop end"
}

main() {
	ensure_logging
	ensure_jq_available
	resolve_mode
	load_params
	load_mode_metadata

	declare -gA DATA_MAP PASS_COUNT FAIL_COUNT TOTAL_COUNT
	declare -ga COPROC_PIDS COPROC_READS COPROC_WRITES COPROC_NAMES

	prepare_tests

	local test_time=0
	if [[ "$mode_type" == "timed" ]]; then
		test_time=$(dialog --inputbox "Enter test duration (hours, 0 or blank for infinite loop)" 8 60 0 --stdout 2>/dev/null)
		[[ -z "$test_time" ]] && test_time=0
	fi

	clear >&3
	start_children
	main_loop "$test_time"

	log_info "coproc finished, returning to runner_menu.sh"
}

main "$@"

return 0 2>/dev/null || exit 0
