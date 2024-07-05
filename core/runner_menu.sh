#!/usr/bin/env bash
set -euo pipefail

source core/libs/logging_utils.sh
source core/libs/global_params_utils.sh

MENU_FILE="configs/generic/menu.json"
CONFIG_FILE="configs/generic/config_main.json"
GLOBAL_PARAMS_FILE="configs/generic/global_params.json"
RESULT_DIR="reports/results"
mkdir -p "$RESULT_DIR"

LOG_CONFIG_FILE=${LOG_CONFIG_FILE:-configs/logging/logging.json}
if [[ -z "${LOGGING_SESSION_ACTIVE:-}" ]]; then
        logging_setup_session "menu" "$LOG_CONFIG_FILE"
fi

# ------------------------------------------------------------
# 準備選單
# ------------------------------------------------------------
declare -A MODE_TYPES
declare -A MODE_SCRIPTS
MENU_ITEMS=()

while IFS=$'\t' read -r mode label type script; do
        [[ -z "$mode" || -z "$label" ]] && continue
        MENU_ITEMS+=("$mode" "$label")
        MODE_TYPES["$mode"]="$type"
        MODE_SCRIPTS["$mode"]="$script"
done < <(jq -r '.modes | sort_by((.order // 999))[] | [.mode, .label, (.type // "flow"), (.script // "")] | @tsv' "$MENU_FILE")

if [[ ${#MENU_ITEMS[@]} -eq 0 ]]; then
	dialog --msgbox "❌ 無可用的選單項目，請檢查 $MENU_FILE" 8 60
	exit 1
fi
while true; do
        CHOICE=$(dialog --menu "請選擇測試模式：" 20 70 10 "${MENU_ITEMS[@]}" --stdout)
        clear >/dev/tty 2>/dev/null || true
        [[ -z "$CHOICE" ]] && {
                log_warn "使用者取消選擇"
                exit 0
        }

        TYPE=${MODE_TYPES[$CHOICE]:-flow}
        if [[ "$TYPE" == "script" ]]; then
                SCRIPT_PATH=${MODE_SCRIPTS[$CHOICE]}
                if [[ -z "$SCRIPT_PATH" ]]; then
                        log_error "選項 $CHOICE 未設定 script 欄位"
                else
                        if [[ -f "$SCRIPT_PATH" ]]; then
                                if [[ "$CHOICE" == "global_variable_setting" ]]; then
                                        bash "$SCRIPT_PATH" "$GLOBAL_PARAMS_FILE"
                                else
                                        bash "$SCRIPT_PATH" "$CONFIG_FILE"
                                fi
                        else
                                log_error "找不到 script：$SCRIPT_PATH"
                        fi
                fi
                continue
        fi

        MODE="$CHOICE"
        break
done

if [[ -f "$GLOBAL_PARAMS_FILE" ]]; then
        load_global_variables "$GLOBAL_PARAMS_FILE"
else
        load_global_variables "$CONFIG_FILE"
fi

log_info "開始執行模式：$MODE"

# ------------------------------------------------------------
# 先跑順序測項
# ------------------------------------------------------------
if jq -e ".modes.\"${MODE}\".sequential" "$CONFIG_FILE" >/dev/null 2>&1; then
	log_info "執行順序測項..."
	RUN_MODE=sequential bash core/runner_seq.sh "$CONFIG_FILE" "$MODE"
	log_info "順序測試結束"
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
