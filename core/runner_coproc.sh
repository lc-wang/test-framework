#!/usr/bin/env bash
set -uo pipefail

DIALOG_PID=-1
CONFIG_FILE=${1:-configs/generic/config_main.json}
MODE=${2:-system_test}
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

exec 3>&1 # 保存真實終端給 dialog 使用

source core/libs/json_utils.sh
source core/libs/logging_utils.sh
source core/libs/result_utils.sh

ensure_logging() {
  if [[ -n "${LOGGING_SESSION_ACTIVE:-}" ]]; then
    return
  fi

  local config_path
  config_path=${LOG_CONFIG_FILE:-configs/logging/logging.json}
  logging_setup_session "coproc" "$config_path"
}

ensure_jq_available() {
  if command -v jq >/dev/null 2>&1; then
    return 0
  fi

  dialog --msgbox "❌ 需要 jq，但系統未安裝。\n請先安裝：sudo apt install -y jq" 8 60 >&3
  exit 1
}

load_params() {
  if [[ -f "core/libs/config_param_utils.sh" ]]; then
    # shellcheck disable=SC1091
    source core/libs/config_param_utils.sh
    export_all_params_for_mode "$CONFIG_FILE" "$MODE" "parallel"
  else
    log_warn "找不到 core/libs/config_param_utils.sh，略過參數載入"
  fi

  if jq -e ".env" "$CONFIG_FILE" >/dev/null 2>&1; then
    log_info "載入測試環境參數"
    while IFS="=" read -r key val; do
      [[ -z "$key" ]] && continue
      local new_val
      new_val=$(dialog --inputbox "設定參數 ${key}：" 8 60 "$val" --stdout 2>/dev/null)
      export "$key"="$new_val"
    done < <(jq -r '.env | to_entries[] | "\(.key)=\(.value)"' "$CONFIG_FILE")
  fi
}

load_mode_metadata() {
  mode_type=$(jq -r ".modes.\"${MODE}\".type" "$CONFIG_FILE" 2>/dev/null)
  mapfile -t TEST_KEYS < <(jq -r ".modes.\"${MODE}\".parallel[]" "$CONFIG_FILE" 2>/dev/null)
  log_info "模式類型: ${mode_type:-unknown}"
  log_info "Parallel 測項: ${TEST_KEYS[*]:-(無)}"
}

prepare_tests() {
  declare -gA TOLERANCE_MAP
  declare -ga TEST_ITEMS=()

  for key in "${TEST_KEYS[@]}"; do
    local enabled
    enabled=$(jq -r ".tests.\"${key}\".enabled" "$CONFIG_FILE")
    if [[ "$enabled" != "true" ]]; then
      continue
    fi

    local script_rel script_abs tolerance
    script_rel=$(jq -r ".tests.\"${key}\".script" "$CONFIG_FILE")
    script_abs="$ROOT_DIR/$script_rel"
    TEST_ITEMS+=("$key:$script_abs")

    tolerance=$(jq -r ".tests.\"${key}\".tolerance // 0" "$CONFIG_FILE")
    TOLERANCE_MAP["$key"]="$tolerance"
  done
}

cleanup() {
  for pid in "${COPROC_PIDS[@]}"; do
    if ps -p "$pid" >/dev/null 2>&1; then
      log_warn "結束子程序 (PID=$pid)"
      kill -TERM -"$pid" 2>/dev/null || true
      pkill -TERM -P "$pid" 2>/dev/null || true
      sleep 0.3

      if ps -p "$pid" >/dev/null 2>&1; then
        log_warn "強制 kill -9 (PID=$pid)"
        kill -9 -"$pid" 2>/dev/null || true
        pkill -9 -P "$pid" 2>/dev/null || true
      fi
    fi
  done

  local end_time duration duration_str result_json
  end_time=$(date +%s)
  duration=$((end_time - start_time))
  printf -v duration_str "%02d:%02d:%02d" $((duration / 3600)) $(((duration % 3600) / 60)) $((duration % 60))

  result_json="reports/results/${MODE}_result.json"
  write_results_json "$result_json" COPROC_NAMES PASS_COUNT FAIL_COUNT TOTAL_COUNT
  log_info "測試結果已輸出：$result_json (耗時 ${duration_str})"
}

start_children() {
  for entry in "${TEST_ITEMS[@]}"; do
    IFS=':' read -r name script_abs <<<"$entry"
    if [[ ! -x "$script_abs" ]]; then
      dialog --msgbox "⚠️ 測項不存在或不可執行:\n$script_abs" 8 70 </dev/tty >/dev/tty 2>&1
      continue
    fi

    declare -A PARAMS=()
    while IFS="=" read -r k v; do
      [[ -z "$k" ]] && continue
      local current_val
      current_val="${!k:-$v}"
      PARAMS["$k"]="$current_val"
    done < <(jq -r ".tests.\"${name}\".params | to_entries[] | \"\(.key)=\(.value)\"" "$CONFIG_FILE" 2>/dev/null)

    coproc CHILD_COPROC {
      export COPROC_ACTIVE=1
      cd "$ROOT_DIR" || exit 1
      # shellcheck disable=SC1091
      source core/libs/json_utils.sh
      export_params_for_test "$name" "$CONFIG_FILE"

      for key in "${!PARAMS[@]}"; do
        export "$key"="${PARAMS[$key]}"
      done

      bash "$script_abs"
    }

    COPROC_PIDS+=(${CHILD_COPROC_PID})
    COPROC_READS+=(${CHILD_COPROC[0]})
    COPROC_WRITES+=(${CHILD_COPROC[1]})
    COPROC_NAMES+=("$name")

    DATA_MAP["$name"]="WAITING"
    PASS_COUNT["$name"]=0
    FAIL_COUNT["$name"]=0
    TOTAL_COUNT["$name"]=0
  done
}

update_data() {
  for fd in "${COPROC_WRITES[@]}"; do
    echo "!GET" >&"$fd" 2>/dev/null || true
  done

  for ((i = 0; i < ${#COPROC_READS[@]}; i++)); do
    local fd name line
    fd=${COPROC_READS[$i]}
    name=${COPROC_NAMES[$i]}
    if read -t 0.1 -u "$fd" line; then
      DATA_MAP["$name"]="$line"
      ((TOTAL_COUNT["$name"]++))

      case "$line" in
      PASS) ((PASS_COUNT["$name"]++)) ;;
      FAIL) ((FAIL_COUNT["$name"]++)) ;;
      esac
    fi
  done
}

display_dashboard() {
  local now elapsed elapsed_str
  now=$(date +%s)
  elapsed=$((now - start_time))
  printf -v elapsed_str "%02d:%02d:%02d" \
    $((elapsed / 3600)) $(((elapsed % 3600) / 60)) $((elapsed % 60))

  local output="🧩 測項狀態\n───────────────────────────────\n"
  output+="經過時間：$elapsed_str\n───────────────────────────────\n"

  for key in "${COPROC_NAMES[@]}"; do
    local val pass fail total tolerance fail_ratio color_val line
    val="${DATA_MAP[$key]}"
    pass=${PASS_COUNT[$key]:-0}
    fail=${FAIL_COUNT[$key]:-0}
    total=${TOTAL_COUNT[$key]:-0}
    tolerance=${TOLERANCE_MAP[$key]:-0}

    if ((total > 0)); then
      fail_ratio=$(awk -v f="$fail" -v t="$total" 'BEGIN { if (t == 0) { print 0 } else { printf "%.6f", f / t } }')
    else
      fail_ratio=0
    fi

    if ((total > 0)) && awk -v r="$fail_ratio" -v tol="$tolerance" 'BEGIN { exit !(r > tol) }'; then
      val="FAIL"
    elif ((total > 0)); then
      val="PASS"
    fi

    case "$val" in
    PASS) color_val="\Z2PASS\Zn" ;;
    FAIL) color_val="\Z1FAIL\Zn" ;;
    *) color_val="\Z3${val}\Zn" ;;
    esac

    printf -v line "%-10s %-6s │ PASS:%-4d FAIL:%-4d TOTAL:%-4d" \
      "$key" "$color_val" "$pass" "$fail" "$total"
    output+="$line\n"
  done

  output+="───────────────────────────────\n(按下 ESC 或 Enter 結束測試)\n"

  dialog --colors --no-collapse --timeout 1 --msgbox "$output" 20 85 </dev/tty >/dev/tty 2>&1
}

main_loop() {
  start_time=$(date +%s)
  local test_time_hr=${1:-0}
  local duration_sec=$((test_time_hr * 3600))

  while true; do
    update_data
    display_dashboard
    local ret=$?

    if [[ $ret -eq 0 || $ret -eq 1 ]]; then
      log_info "使用者按下 ESC/Enter，結束測試"
      cleanup
      break
    fi

    if ((duration_sec > 0)); then
      local now
      now=$(date +%s)
      if ((now - start_time >= duration_sec)); then
        log_info "測試時長 ${test_time_hr} 小時已達，結束測試。"
        cleanup
        break
      fi
    fi
  done

  log_info "main loop end"
}

main() {
  ensure_logging
  ensure_jq_available
  load_params
  load_mode_metadata

  declare -gA DATA_MAP PASS_COUNT FAIL_COUNT TOTAL_COUNT
  declare -ga COPROC_PIDS COPROC_READS COPROC_WRITES COPROC_NAMES

  prepare_tests

  local test_time=0
  if [[ "$mode_type" == "timed" ]]; then
    test_time=$(dialog --inputbox "輸入測試時長（小時，0 或空白代表無限循環）" 8 60 0 --stdout 2>/dev/null)
    [[ -z "$test_time" ]] && test_time=0
  fi

  clear >&3
  start_children
  main_loop "$test_time"

  log_info "coproc 結束，返回 runner_menu.sh"
}

main "$@"

return 0 2>/dev/null || exit 0
