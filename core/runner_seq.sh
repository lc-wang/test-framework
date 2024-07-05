#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/core/libs/logging_utils.sh"
source "$ROOT_DIR/core/libs/json_utils.sh"

CONFIG_FILE=$1
MODE=$2

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

	script_abs="$ROOT_DIR/$script_rel"
	if [[ ! -x "$script_abs" ]]; then
		log_error "找不到或不可執行: $script_abs"
		continue
	fi

	log_info "執行測項：$key"
	source "$ROOT_DIR/core/libs/json_utils.sh"
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
