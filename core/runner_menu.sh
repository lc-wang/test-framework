#!/usr/bin/env bash
set -euo pipefail

source core/libs/logging_utils.sh
source core/libs/global_params_utils.sh

MENU_FILE="configs/generic/menu.json"
CONFIG_FILE="configs/generic/config_main.json"
GLOBAL_PARAMS_FILE="configs/generic/global_params.json"
RESULT_ROOT="${RESULT_DIR:-reports/results}"

LOG_CONFIG_FILE=${LOG_CONFIG_FILE:-configs/logging/logging.json}

declare -A MODE_TYPES
declare -A MODE_SCRIPTS
MENU_ITEMS=()
MODE=""
SEQ_RESULT=""
COP_RESULT=""
FINAL_RESULT=""

setup_logging() {
    if [[ -z "${LOGGING_SESSION_ACTIVE:-}" ]]; then
        logging_setup_session "menu" "$LOG_CONFIG_FILE"
    fi
}

prepare_directories() {
    mkdir -p "$RESULT_ROOT"
}

load_menu_items() {
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
}

run_script_choice() {
    local choice="$1"
    local script_path=${MODE_SCRIPTS[$choice]:-}

    if [[ -z "$script_path" ]]; then
        log_error "選項 $choice 未設定 script 欄位"
        return
    fi

    if [[ ! -f "$script_path" ]]; then
        log_error "找不到 script：$script_path"
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

        choice=$(dialog --menu "請選擇測試模式：" 20 70 10 "${MENU_ITEMS[@]}" --stdout)
        clear >/dev/tty 2>/dev/null || true

        if [[ -z "$choice" ]]; then
            log_warn "使用者取消選擇"
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
        log_warn "沒有可合併的結果檔案"
        return 1
    fi

    jq -s 'reduce .[] as $item ({}; .tests += ($item.tests // {})) | {tests: .tests}' "${files[@]}" >"$FINAL_RESULT"
    log_info "合併結果已輸出：$FINAL_RESULT"
}

show_final_summary_dialog() {
    if [[ ! -f "$FINAL_RESULT" ]]; then
        log_warn "未找到可整合的結果檔案"
        return
    fi

    local summary dialog_text
    summary=$(jq -r '.tests
        | to_entries
        | map("\(.key): PASS \(.value.pass), FAIL \(.value.fail), TOTAL \(.value.total)")
        | join("\n")' "$FINAL_RESULT")

    if [[ -n "$summary" ]]; then
        dialog_text=$(printf "測試結束！\n\n%s" "$summary")
        dialog --msgbox "$dialog_text" 20 70 </dev/tty >/dev/tty 2>&1
    else
        log_warn "沒有可顯示的測試結果摘要"
    fi
}

run_sequential_tests() {
    if jq -e ".modes.\"${MODE}\".sequential" "$CONFIG_FILE" >/dev/null 2>&1; then
        log_info "執行順序測項..."
        RUN_MODE=sequential bash core/runner_seq.sh "$CONFIG_FILE" "$MODE"
        log_info "順序測試結束"
    else
        log_info "此模式無順序測項"
    fi
}

run_parallel_tests() {
    if jq -e ".modes.\"${MODE}\".parallel" "$CONFIG_FILE" >/dev/null 2>&1; then
        log_info "執行平行測項..."
        bash core/runner_coproc.sh "$CONFIG_FILE" "$MODE"
        log_info "平行測試結束"
    else
        log_info "此模式無平行測項"
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
    SUMMARY=$'✅ 測試結束。\n\n'
    SUMMARY+=$'🕒 結束時間：'"$(date '+%Y-%m-%d %H:%M:%S')"$'\n'
    SUMMARY+=$'───────────────────────────────\n'

    merge_and_display "$FINAL_RESULT"

    SUMMARY+=$'───────────────────────────────\n'
    if [[ -f "$FINAL_RESULT" ]]; then
        SUMMARY+="合併結果檔案：${FINAL_RESULT##*/}\n"
    else
        SUMMARY+=$'尚未產生合併結果檔案。\n'
    fi
    SUMMARY+=$'請確認所有測項完成。\n\n按 [OK] 離開測試系統。'
}

show_final_dialog() {
    dialog --clear --msgbox "$SUMMARY" 20 70 </dev/tty >/dev/tty 2>&1
    clear >/dev/tty
    log_ok "測試報告顯示完畢"
}

main() {
    setup_logging
    prepare_directories
    load_menu_items
    prompt_mode_choice
    load_parameters
    setup_result_files

    log_info "開始執行模式：$MODE"

    run_sequential_tests
    run_parallel_tests

    merge_results_to_file
    show_final_summary_dialog
    build_summary_message
    show_final_dialog
}

main "$@"
