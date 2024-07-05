#!/usr/bin/env bash
set -uo pipefail
source core/libs/logging_utils.sh

# ------------------------------------------------------------
# 檢查執行函式
# ------------------------------------------------------------
if [ -z "${TASK_FUNCTION:-}" ]; then
	if declare -f test_logic >/dev/null; then
		TASK_FUNCTION="test_logic"
	else
		echo "Error: 未定義 TASK_FUNCTION 或 test_logic()."
		exit 1
	fi
fi

log_info "載入 test_template (PID=$$)"
log_info "啟動測試迴圈，執行函式：$TASK_FUNCTION"

# ------------------------------------------------------------
# 如果是 sequential 模式，只執行一次並結束
# ------------------------------------------------------------
if [[ "${RUN_MODE:-}" == "sequential" ]]; then
	result=$($TASK_FUNCTION)
	log_info "Sequential 模式結果：$result"
	echo "$result"
	exit 0
fi

# ------------------------------------------------------------
# 並行模式（coproc）
# ------------------------------------------------------------
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
