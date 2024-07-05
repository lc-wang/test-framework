#!/usr/bin/env bash
set -uo pipefail

source core/libs/json_utils.sh
source core/libs/logging_utils.sh
source core/libs/result_utils.sh

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_FILE=${1:-configs/generic/config_main.json}
MODE=${2:-${MODE:-}}
RESULT_ROOT=${RESULT_DIR:-reports/results}

ensure_logging() {
  if [[ -n "${LOGGING_SESSION_ACTIVE:-}" ]]; then
    return
  fi

  local config_path
  config_path=${LOG_CONFIG_FILE:-configs/logging/logging.json}
  logging_setup_session "sequential" "$config_path"
}

ensure_jq_available() {
  if command -v jq >/dev/null 2>&1; then
    return 0
  fi

  log_error "❌ 需要 jq 才能解析設定檔，請先安裝 (sudo apt install -y jq)"
  exit 1
}

resolve_mode() {
  if [[ -z "$MODE" ]]; then
    log_error "未指定測試模式，請於第二個參數提供或先設定環境變數 MODE"
    exit 1
  fi

  if ! jq -e ".modes.\"${MODE}\"" "$CONFIG_FILE" >/dev/null 2>&1; then
    log_error "設定檔中找不到模式：${MODE}"
    exit 1
  fi
}

load_interactive_params() {
  if [[ -f "core/libs/config_param_utils.sh" ]]; then
    local seq_count
    seq_count=$(jq -r ".modes.\"${MODE}\".sequential | length" "$CONFIG_FILE" 2>/dev/null || echo 0)

    if [[ -z "$seq_count" || "$seq_count" -eq 0 ]]; then
      log_warn "沒有定義 sequential 測項，略過參數設定頁面。"
      return
    fi

    # shellcheck disable=SC1091
    source core/libs/config_param_utils.sh
    export_all_params_for_mode "$CONFIG_FILE" "$MODE" "sequential"
  else
    log_warn "找不到 core/libs/config_param_utils.sh，略過互動參數設定"
  fi
}

read_sequential_keys() {
  mapfile -t SEQ_KEYS < <(jq -r ".modes.\"${MODE}\".sequential[]" "$CONFIG_FILE" 2>/dev/null)
  if [[ ${#SEQ_KEYS[@]} -eq 0 ]]; then
    log_warn "沒有定義 sequential 測項，略過。"
    exit 0
  fi
}

init_counters() {
  declare -gA PASS_COUNT FAIL_COUNT TOTAL_COUNT
  for key in "${SEQ_KEYS[@]}"; do
    PASS_COUNT[$key]=0
    FAIL_COUNT[$key]=0
    TOTAL_COUNT[$key]=0
  done
}

run_test_item() {
  local key="$1"
  local script_rel enabled script_abs result

  enabled=$(jq -r ".tests.\"${key}\".enabled" "$CONFIG_FILE")
  if [[ "$enabled" != "true" ]]; then
    log_warn "略過 $key (disabled)"
    return
  fi

  script_rel=$(jq -r ".tests.\"${key}\".script" "$CONFIG_FILE")
  script_abs="$ROOT_DIR/$script_rel"

  if [[ ! -x "$script_abs" ]]; then
    log_error "找不到或不可執行: $script_abs"
    return
  fi

  log_info "執行測項：$key"
  export_params_for_test "$key" "$CONFIG_FILE"

  if bash "$script_abs"; then
    log_ok "$key 測試成功"
    ((PASS_COUNT["$key"]++))
  else
    result=$?
    log_error "$key 測試失敗 (exit=${result:-1})"
    ((FAIL_COUNT["$key"]++))
  fi

  ((TOTAL_COUNT["$key"]++))
}

main() {
  ensure_logging
  ensure_jq_available
  resolve_mode
  load_interactive_params

  log_info "執行順序測試流程 (${MODE}) using ${CONFIG_FILE}"

  read_sequential_keys
  init_counters

  for key in "${SEQ_KEYS[@]}"; do
    run_test_item "$key"
  done

  log_info "順序測試完成。"

  local result_json
  result_json="${RESULT_ROOT}/${MODE}/${MODE}_sequential_result.json"
  write_results_json "$result_json" SEQ_KEYS PASS_COUNT FAIL_COUNT TOTAL_COUNT

  log_info "順序測試結果已輸出：$result_json"
}

main "$@"

# 確保回傳碼為 0，避免中斷後續流程 (例如 runner_coproc)
exit 0
