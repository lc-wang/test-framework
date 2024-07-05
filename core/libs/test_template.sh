#!/usr/bin/env bash
set -uo pipefail
source core/libs/logging_utils.sh

if [ -z "${TASK_FUNCTION:-}" ]; then
	if declare -f test_logic >/dev/null; then
		TASK_FUNCTION="test_logic"
	else
		echo "Error: TASK_FUNCTION or test_logic() is not defined."
		exit 1
	fi
fi

log_info "Loading test_template (PID=$$)"
log_info "Starting test loop, running function: $TASK_FUNCTION"

if [[ "${RUN_MODE:-}" == "sequential" ]]; then
	result=$($TASK_FUNCTION)
	log_info "Sequential mode result: $result"
	echo "$result"
	exit 0
fi

exec 3<&0

while true; do
	latest_result=$($TASK_FUNCTION)
	if read -r -u 3 command; then
		case "$command" in
		"!EXIT")
			exit 0
			;;
		"!GET")
			echo "$latest_result"
			;;
		esac
	fi
	sleep 0.1
done
