#!/usr/bin/env bash
set -uo pipefail

# --- global flags ---
DIALOG_PID=-1

exec 3>&1 # 保存真實終端給 dialog 使用
if [[ -z "${LOGGING_SESSION_ACTIVE:-}" ]]; then
        LOG_CONFIG_FILE=${LOG_CONFIG_FILE:-configs/logging/logging.json}
        logging_setup_session "coproc" "$LOG_CONFIG_FILE"
fi

# ------------------------------------------------------------
# 匯入共用工具
# ------------------------------------------------------------
source core/libs/json_utils.sh

CONFIG_FILE=${1:-configs/generic/config_main.json}
MODE=${2:-system_test}
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

log_info "使用設定檔: $CONFIG_FILE"
log_info "執行模式: $MODE"

if [[ -f "core/libs/config_param_utils.sh" ]]; then
        source core/libs/config_param_utils.sh
        export_all_params_for_mode "$CONFIG_FILE" "$MODE" "parallel"
else
	log_warn "找不到 core/libs/config_param_utils.sh，略過參數載入"
fi

if ! command -v jq >/dev/null 2>&1; then
	dialog --msgbox "❌ 需要 jq，但系統未安裝。\n請先安裝：sudo apt install -y jq" 8 60 >&3
	exit 1
fi

# ------------------------------------------------------------
# 模式判斷
# ------------------------------------------------------------
mode_type=$(jq -r ".modes.\"${MODE}\".type" "$CONFIG_FILE" 2>/dev/null)
log_info "模式類型: ${mode_type:-unknown}"

# ------------------------------------------------------------
# 從 config 載入環境參數並允許使用者覆寫
# ------------------------------------------------------------
if jq -e ".env" "$CONFIG_FILE" >/dev/null 2>&1; then
	log_info "載入測試環境參數"
	while IFS="=" read -r key val; do
		[[ -z "$key" ]] && continue
		new_val=$(dialog --inputbox "設定參數 ${key}：" 8 60 "$val" --stdout 2>/dev/null)
		export "$key"="$new_val"
	done < <(jq -r '.env | to_entries[] | "\(.key)=\(.value)"' "$CONFIG_FILE")
fi

# ------------------------------------------------------------
# 讀取 parallel 測項列表
# ------------------------------------------------------------
mapfile -t TEST_KEYS < <(jq -r ".modes.\"${MODE}\".parallel[]" "$CONFIG_FILE" 2>/dev/null)
log_info "Parallel 測項: ${TEST_KEYS[*]:-(無)}"

declare -A DATA_MAP PASS_COUNT FAIL_COUNT TOTAL_COUNT
declare -a COPROC_PIDS COPROC_READS COPROC_WRITES COPROC_NAMES

# ------------------------------------------------------------
# 準備測項
# ------------------------------------------------------------
declare -a TEST_ITEMS=()
for key in "${TEST_KEYS[@]}"; do
	enabled=$(jq -r ".tests.\"${key}\".enabled" "$CONFIG_FILE")
	if [[ "$enabled" == "true" ]]; then
		script_rel=$(jq -r ".tests.\"${key}\".script" "$CONFIG_FILE")
		script_abs="$ROOT_DIR/$script_rel"
		TEST_ITEMS+=("$key:$script_abs")
	fi
done

# ------------------------------------------------------------
# 子程序清理與結束畫面
# ------------------------------------------------------------
cleanup() {
	for pid in "${COPROC_PIDS[@]}"; do
		if ps -p "$pid" >/dev/null 2>&1; then
			log_warn "結束子程序 (PID=$pid)"
			# 結束整個 process group
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
	# 計算時長
	local end_time=$(date +%s)
	local duration=$((end_time - start_time))
	printf -v duration_str "%02d:%02d:%02d" $((duration / 3600)) $(((duration % 3600) / 60)) $((duration % 60))

	# ✅ 寫出 JSON 結果給 runner_menu.sh
	local result_json="reports/results/${MODE}_result.json"
	mkdir -p "$(dirname "$result_json")"
	{
		echo '{ "tests": {'
		local first=true
		for key in "${COPROC_NAMES[@]}"; do
			$first || echo ','
			first=false
			printf '  "%s": { "pass": %d, "fail": %d, "total": %d }' \
				"$key" "${PASS_COUNT[$key]:-0}" "${FAIL_COUNT[$key]:-0}" "${TOTAL_COUNT[$key]:-0}"
		done
		echo ' } }'
	} >"$result_json"

	log_info "測試結果已輸出：$result_json"

	return 0
}

# ------------------------------------------------------------
# 啟動所有測項
# ------------------------------------------------------------
start_children() {
	for entry in "${TEST_ITEMS[@]}"; do
		IFS=':' read -r name script_abs <<<"$entry"
		if [[ ! -x "$script_abs" ]]; then
			dialog --msgbox "⚠️ 測項不存在或不可執行:\n$script_abs" 8 70 </dev/tty >/dev/tty 2>&1
			continue
		fi

		# 先讀取 config 中的 params
		declare -A PARAMS
		while IFS="=" read -r k v; do
			[[ -z "$k" ]] && continue
			# 若該 key 在環境變數中已有使用者覆蓋，就用覆蓋的值
			current_val="${!k:-$v}"
			PARAMS["$k"]="$current_val"
		done < <(jq -r ".tests.\"${name}\".params | to_entries[] | \"\(.key)=\(.value)\"" "$CONFIG_FILE" 2>/dev/null)

		# 啟動子程序，帶入參數環境
		coproc CHILD_COPROC {
			export COPROC_ACTIVE=1
			cd "$ROOT_DIR" || exit 1
			source core/libs/json_utils.sh
			export_params_for_test "$name" "$CONFIG_FILE"

			# 明確 export 所有參數（優先使用使用者更新後的）
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

# ------------------------------------------------------------
# 更新資料
# ------------------------------------------------------------
update_data() {
	for fd in "${COPROC_WRITES[@]}"; do
		echo "!GET" >&"$fd" 2>/dev/null || true
	done

	for ((i = 0; i < ${#COPROC_READS[@]}; i++)); do
		FD=${COPROC_READS[$i]}
		NAME=${COPROC_NAMES[$i]}
		if read -t 0.1 -u "$FD" line; then
			DATA_MAP["$NAME"]="$line"
			((TOTAL_COUNT["$NAME"]++))
			if [[ "$line" == "PASS" ]]; then
				((PASS_COUNT["$NAME"]++))
			elif [[ "$line" == "FAIL" ]]; then
				((FAIL_COUNT["$NAME"]++))
			fi
		fi
	done
}

# ------------------------------------------------------------
# 顯示儀表板 (非阻塞，純 infobox，每秒重畫)
# ------------------------------------------------------------
# ------------------------------------------------------------
# 顯示儀表板 (可用 ESC/Enter 結束)
# ------------------------------------------------------------
display_dashboard() {
	local now elapsed elapsed_str
	now=$(date +%s)
	elapsed=$((now - start_time))
	printf -v elapsed_str "%02d:%02d:%02d" \
		$((elapsed / 3600)) $(((elapsed % 3600) / 60)) $((elapsed % 60))

	local output="🧩 測項狀態\n───────────────────────────────\n"
	output+="經過時間：$elapsed_str\n───────────────────────────────\n"

	for key in "${COPROC_NAMES[@]}"; do
		local val="${DATA_MAP[$key]}"
		local pass=${PASS_COUNT[$key]:-0}
		local fail=${FAIL_COUNT[$key]:-0}
		local total=${TOTAL_COUNT[$key]:-0}
		local color_val
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

	# 顯示 msgbox，設定 timeout=1，每秒更新畫面
	dialog --colors --no-collapse --timeout 1 --msgbox "$output" 20 85 </dev/tty >/dev/tty 2>&1
	return $?
}

# ------------------------------------------------------------
# 主迴圈 (用 ESC/Enter 結束)
# ------------------------------------------------------------
main_loop() {
	start_time=$(date +%s)
	local test_time_hr=${1:-0}
	local duration_sec=$((test_time_hr * 3600))

	while true; do
		update_data
		display_dashboard
		ret=$?

		# 使用者結束
		if [[ $ret -eq 0 || $ret -eq 1 ]]; then
			log_info "使用者按下 ESC/Enter，結束測試"
			cleanup
			break
		fi

		# 若設定測試時長，到達後自動結束
		if ((duration_sec > 0)); then
			local now=$(date +%s)
			if ((now - start_time >= duration_sec)); then
				log_info "測試時長 ${test_time_hr} 小時已達，結束測試。"
				cleanup
				break
			fi
		fi
	done

	log_info "main loop end"
	return 0
}
# ------------------------------------------------------------
# 啟動流程
# ------------------------------------------------------------
if [[ "$mode_type" == "timed" ]]; then
	test_time=$(dialog --inputbox "輸入測試時長（小時，0 或空白代表無限循環）" 8 60 0 --stdout 2>/dev/null)
	[[ -z "$test_time" ]] && test_time=0
else
	test_time=0
fi

clear >&3
start_children
main_loop "$test_time"

# --- 保證主程式結束後不 exit，只回呼叫者 ---
log_info "coproc 結束，返回 runner_menu.sh"
return 0 2>/dev/null || exit 0
