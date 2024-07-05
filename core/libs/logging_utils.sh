#!/usr/bin/env bash

if [[ -n "${COPROC_ACTIVE:-}" ]]; then
	LOG_CONSOLE_FD=${LOG_CONSOLE_FD:-2}
else
	LOG_CONSOLE_FD=${LOG_CONSOLE_FD:-1}
fi

LOG_TO_CONSOLE=${LOG_TO_CONSOLE:-1}
LOG_TO_FILE=${LOG_TO_FILE:-0}
LOG_INCLUDE_CALLER=${LOG_INCLUDE_CALLER:-1}
LOG_COLORIZE=${LOG_COLORIZE:-1}
LOG_DIR=${LOG_DIR:-reports/logs}
LOG_FILE=${LOG_FILE:-}
LOG_CAPTURE_ALL=${LOG_CAPTURE_ALL:-1}
LOG_CAPTURE_MODE=${LOG_CAPTURE_MODE:-direct}
LOG_TIMEZONE=${LOG_TIMEZONE:-}
LOG_CONFIG_FILE_DEFAULT="configs/generic/logging/logging.json"

log_ts() {
	date "+[%Y-%m-%d %H:%M:%S]"
}

_logging_bool() {
	local value="$1"
	local fallback="${2:-0}"
	case "$value" in
	1 | true | TRUE | True | yes | YES | on | ON)
		echo 1
		;;
	0 | false | FALSE | False | no | NO | off | OFF)
		echo 0
		;;
	*)
		echo "$fallback"
		;;
	esac
}

_logging_load_kv() {
	local config_path="$1"
	local kv_lines=""

	if [[ -z "$config_path" || ! -f "$config_path" ]]; then
		return 0
	fi

	if command -v jq >/dev/null 2>&1; then
		kv_lines=$(jq -r 'to_entries | map("\(.key)=\(.value)")[]' "$config_path" 2>/dev/null || true)
	elif command -v python3 >/dev/null 2>&1; then
		kv_lines=$(
			python3 - "$config_path" <<'PY' 2>/dev/null || true
import json, sys
with open(sys.argv[1], encoding='utf-8') as fh:
    data = json.load(fh)
for key, value in data.items():
    print(f"{key}={value}")
PY
		)
	else
		return 0
	fi

	while IFS='=' read -r key value; do
		[[ -z "$key" ]] && continue
		case "$key" in
		log_to_console)
			LOG_TO_CONSOLE=$(_logging_bool "$value" "$LOG_TO_CONSOLE")
			;;
		log_to_file)
			LOG_TO_FILE=$(_logging_bool "$value" "$LOG_TO_FILE")
			;;
		capture_all_output)
			LOG_CAPTURE_ALL=$(_logging_bool "$value" "$LOG_CAPTURE_ALL")
			;;
		include_caller)
			LOG_INCLUDE_CALLER=$(_logging_bool "$value" "$LOG_INCLUDE_CALLER")
			;;
		colorize)
			LOG_COLORIZE=$(_logging_bool "$value" "$LOG_COLORIZE")
			;;
		zone | timezone)
			[[ -n "$value" && "$value" != "null" ]] && LOG_TIMEZONE="$value"
			;;
		log_dir)
			[[ -n "$value" && "$value" != "null" ]] && LOG_DIR="$value"
			;;
		log_file)
			[[ -n "$value" && "$value" != "null" ]] && LOG_FILE="$value"
			;;
		esac
	done <<<"$kv_lines"
}

logging_load_config() {
	local config_path="${1:-${LOG_CONFIG_FILE:-$LOG_CONFIG_FILE_DEFAULT}}"
	_logging_load_kv "$config_path"
}

logging_setup_session() {
	local session_name="${1:-session}"
	local config_path="${2:-}"

	if [[ -n "$config_path" ]]; then
		logging_load_config "$config_path"
	else
		logging_load_config
	fi

	if [[ -n "${LOG_TIMEZONE:-}" ]]; then
		export TZ="$LOG_TIMEZONE"
		log_info "Log timezone: ${LOG_TIMEZONE}"
	fi

	if [[ "${LOG_TO_FILE:-0}" == 1 ]]; then
		if [[ -z "${LOG_FILE:-}" ]]; then
			local timestamp
			timestamp=$(date +%Y%m%d_%H%M%S)
			local sanitized="${session_name//[^A-Za-z0-9_\-]/_}"
			mkdir -p "$LOG_DIR"
			LOG_FILE="$LOG_DIR/${timestamp}_${sanitized}.log"
		else
			mkdir -p "$(dirname "$LOG_FILE")"
		fi
	else
		LOG_FILE=""
	fi

	if [[ "${LOG_TO_FILE:-0}" == 1 && "${LOG_CAPTURE_ALL:-1}" == 1 && -n "${LOG_FILE:-}" ]]; then
		LOG_CAPTURE_MODE="tee"
		exec > >(tee -a "$LOG_FILE") 2>&1
	else
		LOG_CAPTURE_MODE="direct"
	fi

	if [[ "${LOG_TO_FILE:-0}" == 1 ]]; then
		log_info "Log file: $LOG_FILE"
	else
		log_info "Logging enabled (no file output)"
	fi

	export LOG_TO_CONSOLE LOG_TO_FILE LOG_INCLUDE_CALLER LOG_COLORIZE \
		LOG_DIR LOG_FILE LOG_CAPTURE_ALL LOG_CAPTURE_MODE LOG_TIMEZONE \
		LOG_CONFIG_FILE LOG_CONSOLE_FD
}

_logging_emit() {
	local level="$1"
	shift
	local message="$*"

	local ts
	ts=$(log_ts)

	local caller_meta=""
	if [[ "${LOG_INCLUDE_CALLER:-1}" == 1 ]]; then
		local caller_file="${BASH_SOURCE[2]:-${BASH_SOURCE[1]:-unknown}}"
		local caller_line="${BASH_LINENO[1]:-0}"
		local caller_func="${FUNCNAME[2]:-main}"
		local base_file
		base_file=$(basename "${caller_file:-unknown}")
		if [[ -n "$caller_func" && "$caller_func" != "main" ]]; then
			caller_meta="[$base_file:$caller_line:$caller_func] "
		else
			caller_meta="[$base_file:$caller_line] "
		fi
	fi

	local console_level="$level"
	local reset="\033[0m"
	local color=""
	if [[ "${LOG_COLORIZE:-1}" == 1 ]]; then
		case "$level" in
		INFO)
			color="\033[34m"
			;;
		WARN)
			color="\033[33m"
			;;
		ERROR)
			color="\033[31m"
			;;
		OK)
			color="\033[32m"
			;;
		*)
			color=""
			;;
		esac
	fi

	local console_line
	if [[ -n "$color" ]]; then
		console_line="${ts} ${color}${console_level}${reset}  ${caller_meta}${message}"
	else
		console_line="${ts} ${console_level}  ${caller_meta}${message}"
	fi
	local plain_line="${ts} ${console_level}  ${caller_meta}${message}"

	if [[ "${LOG_TO_CONSOLE:-1}" == 1 ]]; then
		if [[ "${LOG_CONSOLE_FD:-1}" -eq 1 ]]; then
			echo -e "$console_line"
		else
			echo -e "$console_line" >&2
		fi
	fi

	if [[ "${LOG_TO_FILE:-0}" == 1 && -n "${LOG_FILE:-}" ]]; then
		if [[ "${LOG_CAPTURE_MODE}" != "tee" || "${LOG_TO_CONSOLE:-1}" != 1 ]]; then
			echo -e "$plain_line" >>"$LOG_FILE"
		fi
	fi
}

log_info() { _logging_emit INFO "$@"; }
log_warn() { _logging_emit WARN "$@"; }
log_error() { _logging_emit ERROR "$@"; }
log_ok() { _logging_emit OK "$@"; }
