#!/usr/bin/env bash
set -euo pipefail

source core/libs/logging_utils.sh
source core/libs/json_utils.sh

if [[ -z "${LOGGING_SESSION_ACTIVE:-}" ]]; then
	LOG_CONFIG_FILE=${LOG_CONFIG_FILE:-configs/logging/logging.json}
	logging_setup_session "sequential" "$LOG_CONFIG_FILE"
fi

CONFIG_FILE=${1:-configs/generic/config_main.json}
MODE=${2:-system_test}

if [[ -f "core/libs/config_param_utils.sh" ]]; then
        source core/libs/config_param_utils.sh
        export_all_params_for_mode "$CONFIG_FILE" "$MODE" "sequential"
else
        log_warn "找不到 core/libs/config_param_utils.sh，略過互動參數設定"
fi

log_info "執行順序測試流程 ($MODE) using $CONFIG_FILE"

mapfile -t SEQ_KEYS < <(jq -r ".modes.\"${MODE}\".sequential[]" "$CONFIG_FILE" 2>/dev/null)

if [[ ${#SEQ_KEYS[@]} -eq 0 ]]; then
	log_warn "沒有定義 sequential 測項，略過。"
	exit 0
fi

for key in "${SEQ_KEYS[@]}"; do
	script_rel=$(jq -r ".tests.\"${key}\".script" "$CONFIG_FILE")
	enabled=$(jq -r ".tests.\"${key}\".enabled" "$CONFIG_FILE")
	[[ "$enabled" != "true" ]] && log_warn "略過 $key (disabled)" && continue

	script_abs="$script_rel"
	if [[ ! -x "$script_abs" ]]; then
		log_error "找不到或不可執行: $script_abs"
		continue
	fi

        log_info "執行測項：$key"
        export_params_for_test "$key" "$CONFIG_FILE"

	# 呼叫測試項目
	bash "$script_abs"
	result=$?

	if [[ $result -eq 0 ]]; then
		log_ok "$key 測試成功"
	else
		log_error "$key 測試失敗 (exit=$result)"
	fi
done

log_info "順序測試完成。"
