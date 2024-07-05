#!/usr/bin/env bash
set -euo pipefail
source core/libs/logging_utils.sh

MENU_FILE="configs/generic/menu.json"
RESULT_DIR="reports/results"
mkdir -p "$RESULT_DIR"

load_global_params() {
  local CONFIG_FILE="$1"
  if jq -e '.global_params' "$CONFIG_FILE" >/dev/null 2>&1; then
    log_info "載入全域參數..."
    while IFS="=" read -r key val; do
      export "$key"="$val"
    done < <(jq -r '.global_params | to_entries[] | "\(.key)=\(.value)"' "$CONFIG_FILE")
  fi
}

edit_global_params() {
  local CONFIG_FILE="$1"
  mapfile -t keys < <(jq -r '.global_params | keys[]' "$CONFIG_FILE")
  for key in "${keys[@]}"; do
    val=$(jq -r ".global_params.\"$key\"" "$CONFIG_FILE")
    new_val=$(dialog --inputbox "設定全域參數 ${key}：" 8 60 "$val" --stdout)
    [[ -n "$new_val" ]] && \
      jq ".global_params.\"$key\" = \"$new_val\"" "$CONFIG_FILE" | sponge "$CONFIG_FILE"
    export "$key"="$new_val"
  done
}

# ------------------------------------------------------------
# 顯示選單
# ------------------------------------------------------------
MENU_ITEMS=()
while IFS=":" read -r label mode type file; do
	[[ -z "$label" || -z "$mode" ]] && continue
	MENU_ITEMS+=("$mode" "$label")
done < <(jq -r '.modes[] | "\(.label):\(.mode):\(.type)"' "$MENU_FILE")

if [[ ${#MENU_ITEMS[@]} -eq 0 ]]; then
	dialog --msgbox "❌ 無可用的選單項目，請檢查 $MENU_FILE" 8 60
	exit 1
fi
CHOICE=$(dialog --menu "請選擇測試模式：" 20 70 10 "${MENU_ITEMS[@]}" --stdout)
[[ -z "$CHOICE" ]] && {
	log_warn "使用者取消選擇"
	clear >/dev/tty
	exit 0
}

MODE="$CHOICE"
CONFIG_FILE="configs/generic/config_main.json"
load_global_params "$CONFIG_FILE"

log_info "開始執行模式：$MODE"

# ------------------------------------------------------------
# 先跑順序測項
# ------------------------------------------------------------
if jq -e ".modes.\"${MODE}\".sequential" "$CONFIG_FILE" >/dev/null 2>&1; then
	log_info "執行順序測項..."
	bash core/runner_sequential.sh "$CONFIG_FILE" "$MODE" || true
else
	log_info "此模式無順序測項"
fi

# ------------------------------------------------------------
# 再跑平行測項
# ------------------------------------------------------------
if jq -e ".modes.\"${MODE}\".parallel" "$CONFIG_FILE" >/dev/null 2>&1; then
	log_info "執行平行測項..."
	bash core/runner_coproc.sh "$CONFIG_FILE" "$MODE"
	log_info "平行測試結束"

	RESULT_JSON="reports/results/${MODE}_result.json"

	if [[ -f "$RESULT_JSON" ]]; then
		log_ok "測試完成，顯示最終結果"
		# 顯示報告摘要
		SUMMARY=$(jq -r '.tests | to_entries[] | "\(.key): PASS \(.value.pass), FAIL \(.value.fail), TOTAL \(.value.total)"' "$RESULT_JSON")
		dialog --msgbox "測試結束！\n\n${SUMMARY}" 20 70 </dev/tty >/dev/tty 2>&1
	else
		log_warn "未找到結果檔案：$RESULT_JSON"
	fi

else
	log_info "此模式無平行測項"
fi

# ------------------------------------------------------------
# 結束後整合 JSON 結果
# ------------------------------------------------------------
SEQ_RESULT="${RESULT_DIR}/${MODE}_sequential_result.json"
COP_RESULT="${RESULT_DIR}/${MODE}_result.json"

SUMMARY="✅ 測試結束。\n\n"
SUMMARY+="🕒 結束時間：$(date '+%Y-%m-%d %H:%M:%S')\n"
SUMMARY+="───────────────────────────────\n"

merge_and_display() {
	local FILE="$1"
	[[ ! -f "$FILE" ]] && return
	jq -r '.tests | to_entries[] | "\(.key)  PASS:\(.value.pass) FAIL:\(.value.fail) TOTAL:\(.value.total)"' "$FILE" | while read -r line; do
		SUMMARY+="$line\n"
	done
}

merge_and_display "$SEQ_RESULT"
merge_and_display "$COP_RESULT"

SUMMARY+="───────────────────────────────\n"
SUMMARY+="請確認所有測項完成。\n\n按 [OK] 離開測試系統。"

dialog --clear --msgbox "$SUMMARY" 20 70 </dev/tty >/dev/tty 2>&1
clear >/dev/tty
log_ok "測試報告顯示完畢"
