#!/usr/bin/env bash
set -euo pipefail

source core/libs/logging_utils.sh

if [ -z "${TASK_FUNCTION:-}" ]; then
	die "TASK_FUNCTION 未定義."
fi

log_info "啟動測試迴圈，執行函式：$TASK_FUNCTION"

exec 3<&0
while true; do
	latest_result=$($TASK_FUNCTION 2>/dev/null)
	if read -r -u 3 command; then
		case "$command" in
		"!EXIT")
			log_info "接收 !EXIT，結束測試"
			exit 0
			;;
		"!GET") echo "$latest_result" ;;
		esac
	fi
	sleep 0.1
done
