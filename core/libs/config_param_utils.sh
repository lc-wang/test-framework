#!/usr/bin/env bash
# ============================================================
# config_param_utils.sh
# 共用工具：從 config_main.json 載入、互動啟用與修改測項參數
# ============================================================
source core/libs/logging_utils.sh 2>/dev/null || true

# ------------------------------------------------------------
# 安全輸入對話框
# ------------------------------------------------------------
prompt_input() {
	local prompt="$1"
	local default="$2"
	local result

	if command -v dialog >/dev/null 2>&1; then
		result=$(dialog --inputbox "$prompt" 8 60 "$default" --stdout 2>/dev/null)
		clear >/dev/tty
	else
		echo "$prompt [$default]:"
		read -r result
	fi
	[[ -z "$result" ]] && result="$default"
	echo "$result"
}

# ------------------------------------------------------------
# 全域系統參數載入
# ------------------------------------------------------------
load_global_params() {
	local config_file=$1
	if jq -e ".system" "$config_file" >/dev/null 2>&1; then
		log_info "載入全域系統參數"
		while IFS="=" read -r key val; do
			[[ -z "$key" ]] && continue
			local new_val
			new_val=$(prompt_input "設定系統參數 ${key}：" "$val")
			export "$key"="$new_val"
			log_info "設定 ${key}=${new_val}"
		done < <(jq -r ".system | to_entries[] | \"\(.key)=\(.value)\"" "$config_file")
	fi
}

# ------------------------------------------------------------
# 測項參數互動選擇與修改
# ------------------------------------------------------------
configure_tests_interactively() {
	local config_file=$1
	local mode=$2

	log_info "載入模式 ${mode} 的測項清單"
	mapfile -t all_tests < <(
		jq -r ".modes.\"${mode}\".sequential[], .modes.\"${mode}\".parallel[]" "$config_file" 2>/dev/null | sort -u
	)

	declare -A TEST_ENABLED
	for t in "${all_tests[@]}"; do
		TEST_ENABLED["$t"]=$(jq -r ".tests.\"${t}\".enabled" "$config_file" 2>/dev/null)
		[[ "${TEST_ENABLED[$t]}" != "true" ]] && TEST_ENABLED["$t"]="false"
	done

	while true; do
		local menu_items=()
		for t in "${all_tests[@]}"; do
			local state="${TEST_ENABLED[$t]}"
			local label="❌ Disabled"
			[[ "$state" == "true" ]] && label="✅ Enabled"
			menu_items+=("$t" "$label")
		done
		menu_items+=("ALL_DONE" "➡ 確認並開始測試")

		local choice
		choice=$(dialog --menu "選擇要修改的測項 (Enter 進入設定, ALL_DONE 開始測試)" 20 70 12 "${menu_items[@]}" --stdout 2>/dev/null) || true
		clear >/dev/tty

		[[ "$choice" == "ALL_DONE" || -z "$choice" ]] && break

		# --- 切換 enable 狀態或進入參數設定 ---
		local current_state="${TEST_ENABLED[$choice]}"

		if jq -e ".tests.\"${choice}\".params" "$config_file" >/dev/null 2>&1; then
			dialog --yesno "是否啟用 [${choice}] 測項？\n\nYes：啟用並設定參數\nNo：停用此測項" 10 60 </dev/tty >/dev/tty 2>&1
			local enable_ans=$?
			clear >/dev/tty

			if [[ $enable_ans -eq 0 ]]; then
				# ✅ 啟用並修改參數
				TEST_ENABLED["$choice"]="true"
				while IFS="=" read -r key val; do
					[[ -z "$key" ]] && continue
					new_val=$(prompt_input "設定 [${choice}] 參數 ${key}：" "$val")
					export "$key"="$new_val"
					log_info "設定 ${key}=${new_val}"
				done < <(jq -r ".tests.\"${choice}\".params | to_entries[] | \"\(.key)=\(.value)\"" "$config_file")

			elif [[ $enable_ans -eq 1 ]]; then
				# ❌ 停用測項
				TEST_ENABLED["$choice"]="false"
				log_info "[${choice}] 已停用"
			else
				# 取消 → 保持現狀
				log_info "[${choice}] 無變更"
			fi
		else
			# 沒有參數的測項 → 用簡單 enable/disable 切換
			dialog --yesno "是否啟用 [${choice}] 測項？" 8 40 </dev/tty >/dev/tty 2>&1
			local enable_ans=$?
			clear >/dev/tty
			if [[ $enable_ans -eq 0 ]]; then
				TEST_ENABLED["$choice"]="true"
			else
				TEST_ENABLED["$choice"]="false"
			fi
		fi

	done

	# 匯出最終啟用狀態
	for t in "${!TEST_ENABLED[@]}"; do
		export "TEST_${t^^}_ENABLED"="${TEST_ENABLED[$t]}"
		log_info "${t} 啟用狀態: ${TEST_ENABLED[$t]}"
	done
}

# ------------------------------------------------------------
# 主入口：載入 + 使用者互動設定
# ------------------------------------------------------------
export_all_params_for_mode() {
	local config_file=$1
	local mode=$2

	log_info "載入並覆寫所有參數 (${mode})"
	load_global_params "$config_file"
	configure_tests_interactively "$config_file" "$mode"
	log_info "參數設定完成"
}
