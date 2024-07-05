#!/usr/bin/env bash
# ============================================================
# config_param_utils.sh
# 共用工具：從 config_main.json 載入、互動啟用與修改測項參數
# ============================================================
source core/libs/logging_utils.sh 2>/dev/null || true

# ------------------------------------------------------------
# 寫回 JSON 設定檔
# ------------------------------------------------------------
_apply_jq_update() {
        local config_file="$1"
        local filter="$2"
        shift 2

        local tmp_file
        if ! tmp_file=$(mktemp); then
                log_error "建立暫存檔失敗，無法更新 ${config_file}"
                return 1
        fi

        if jq "$@" "$filter" "$config_file" >"$tmp_file"; then
                mv "$tmp_file" "$config_file"
                return 0
        fi

        log_error "更新設定檔失敗：$config_file"
        rm -f "$tmp_file"
        return 1
}

_set_test_enabled_state() {
        local config_file="$1"
        local test_name="$2"
        local state="$3"

        local jq_filter='.tests[$test].enabled = ($state == "true")'
        if _apply_jq_update "$config_file" "$jq_filter" --arg test "$test_name" --arg state "$state"; then
                log_info "更新 ${test_name} enabled=${state}"
                return 0
        fi

        return 1
}

_set_test_param() {
        local config_file="$1"
        local test_name="$2"
        local key="$3"
        local value="$4"

        local jq_filter='.tests[$test].params = ((.tests[$test].params // {}) | .[$key] = $val)'
        if _apply_jq_update "$config_file" "$jq_filter" --arg test "$test_name" --arg key "$key" --arg val "$value"; then
                log_info "更新 ${test_name}.${key}=${value}"
                return 0
        fi

        return 1
}

_prompt_yes_no() {
        local message="$1"
        local height="${2:-10}"
        local width="${3:-60}"

        if command -v dialog >/dev/null 2>&1; then
                local status
                if dialog --yesno "$message" "$height" "$width" </dev/tty >/dev/tty 2>&1; then
                        status=0
                else
                        status=$?
                        [[ $status -eq 0 ]] && status=1
                fi
                clear >/dev/tty 2>/dev/null || true
                return $status
        fi

        while true; do
                echo -n "$message (y/n/c): "
                read -r answer
                case "$answer" in
                        [Yy]*) return 0 ;;
                        [Nn]*) return 1 ;;
                        [Cc]*) return 255 ;;
                        "") return 255 ;;
                        *) echo "請輸入 y、n 或 c (取消)。" ;;
                esac
        done
}

_select_from_list() {
        local prompt="$1"
        shift
        local -n _options_map=$1
        shift
        local -a labels=("$@")

        echo "$prompt"
        local idx=1
        for entry in "${labels[@]}"; do
                local key label
                key=$(cut -d$'\t' -f1 <<<"$entry")
                label=$(cut -d$'\t' -f2- <<<"$entry")
                printf "%2d) %s\n" "$idx" "$label"
                _options_map[$idx]="$key"
                ((idx++))
        done
        echo
        echo -n "請輸入選項編號："
        read -r selection
        if [[ "$selection" =~ ^[0-9]+$ ]] && [[ -n "${_options_map[$selection]:-}" ]]; then
                echo "${_options_map[$selection]}"
        fi
}

_edit_tests_in_group() {
        local config_file="$1"
        local group="$2"
        local -n tests_ref=$3
        local -n enabled_ref=$4

        local group_label="平行"
        [[ "$group" == "sequential" ]] && group_label="順序"

        if [[ ${#tests_ref[@]} -eq 0 ]]; then
                if command -v dialog >/dev/null 2>&1; then
                        dialog --msgbox "此模式沒有${group_label}測項。" 8 50 </dev/tty >/dev/tty 2>&1 || true
                        clear >/dev/tty 2>/dev/null || true
                else
                        echo "此模式沒有${group_label}測項。"
                fi
                return 0
        fi

        while true; do
                local choice=""
                if command -v dialog >/dev/null 2>&1; then
                        local menu_items=()
                        for t in "${tests_ref[@]}"; do
                                [[ -z "$t" ]] && continue
                                local state="${enabled_ref[$t]:-false}"
                                local status_label="❌ Disabled"
                                [[ "$state" == "true" ]] && status_label="✅ Enabled"
                                menu_items+=("$t" "$status_label")
                        done
                        menu_items+=("BACK" "⬅ 返回上一層")
                        choice=$(dialog --no-cancel --menu "選擇要修改的${group_label}測項 (Enter 進入設定)" 20 70 12 "${menu_items[@]}" --stdout 2>/dev/null) || true
                        clear >/dev/tty 2>/dev/null || true
                else
                        declare -A options_map=()
                        local labels=()
                        for t in "${tests_ref[@]}"; do
                                [[ -z "$t" ]] && continue
                                local state="${enabled_ref[$t]:-false}"
                                local status_label="[ ]"
                                [[ "$state" == "true" ]] && status_label="[x]"
                                labels+=("${t}\t${status_label} ${t}")
                        done
                        labels+=("BACK\t返回上一層")
                        choice=$(_select_from_list "選擇要修改的${group_label}測項：" options_map "${labels[@]}")
                fi

                [[ -z "$choice" ]] && continue
                [[ "$choice" == "BACK" ]] && break

                if jq -e ".tests.\"${choice}\".params" "$config_file" >/dev/null 2>&1; then
                        local enable_ans
                        if _prompt_yes_no "是否啟用 [${choice}] 測項？\n\nYes：啟用並設定參數\nNo：停用此測項" 10 60; then
                                enable_ans=0
                        else
                                enable_ans=$?
                        fi

                        if [[ $enable_ans -eq 0 ]]; then
                                enabled_ref["$choice"]="true"
                                _set_test_enabled_state "$config_file" "$choice" "true" || true
                                while IFS="=" read -r key val; do
                                        [[ -z "$key" ]] && continue
                                        local new_val
                                        new_val=$(prompt_input "設定 [${choice}] 參數 ${key}：" "$val")
                                        if [[ "$new_val" != "$val" ]]; then
                                                _set_test_param "$config_file" "$choice" "$key" "$new_val" || true
                                        fi
                                        export "$key"="$new_val"
                                        log_info "設定 ${key}=${new_val}"
                                done < <(jq -r ".tests.\"${choice}\".params | to_entries[] | \"\(.key)=\(.value)\"" "$config_file")

                        elif [[ $enable_ans -eq 1 ]]; then
                                enabled_ref["$choice"]="false"
                                _set_test_enabled_state "$config_file" "$choice" "false" || true
                                log_info "[${choice}] 已停用"
                        else
                                log_info "[${choice}] 無變更"
                        fi
                else
                        local enable_ans
                        if _prompt_yes_no "是否啟用 [${choice}] 測項？" 8 40; then
                                enable_ans=0
                        else
                                enable_ans=$?
                        fi

                        if [[ $enable_ans -eq 0 ]]; then
                                enabled_ref["$choice"]="true"
                                _set_test_enabled_state "$config_file" "$choice" "true" || true
                        elif [[ $enable_ans -eq 1 ]]; then
                                enabled_ref["$choice"]="false"
                                _set_test_enabled_state "$config_file" "$choice" "false" || true
                        else
                                log_info "[${choice}] 無變更"
                        fi
                fi
        done

        return 0
}

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
        local group_filter=${3:-all}

        local include_seq=true
        local include_par=true

        case "$group_filter" in
                sequential)
                        include_par=false
                        ;;
                parallel)
                        include_seq=false
                        ;;
        esac

        log_info "載入模式 ${mode} 的測項清單"

        mapfile -t sequential_tests < <(jq -r ".modes.\"${mode}\".sequential[]" "$config_file" 2>/dev/null)
        mapfile -t parallel_tests < <(jq -r ".modes.\"${mode}\".parallel[]" "$config_file" 2>/dev/null)

        declare -A seen_tests=()
        declare -a unique_tests=()

        if [[ "$include_seq" == true ]]; then
                for t in "${sequential_tests[@]}"; do
                        [[ -z "$t" ]] && continue
                        if [[ -z "${seen_tests[$t]:-}" ]]; then
                                seen_tests["$t"]=1
                                unique_tests+=("$t")
                        fi
                done
        fi

        if [[ "$include_par" == true ]]; then
                for t in "${parallel_tests[@]}"; do
                        [[ -z "$t" ]] && continue
                        if [[ -z "${seen_tests[$t]:-}" ]]; then
                                seen_tests["$t"]=1
                                unique_tests+=("$t")
                        fi
                done
        fi

        declare -A TEST_ENABLED=()
        for t in "${unique_tests[@]}"; do
                local state
                state=$(jq -r ".tests.\"${t}\".enabled" "$config_file" 2>/dev/null)
                [[ "$state" != "true" ]] && state="false"
                TEST_ENABLED["$t"]="$state"
        done


        while true; do
                local choice=""

                if command -v dialog >/dev/null 2>&1; then
                        local menu_items=()
                        if [[ "$include_seq" == true && ${#sequential_tests[@]} -gt 0 ]]; then
                                local enabled_count=0
                                for t in "${sequential_tests[@]}"; do
                                        [[ "${TEST_ENABLED[$t]:-false}" == "true" ]] && ((enabled_count+=1))
                                done
                                menu_items+=("SEQ_GROUP" "順序測項 (啟用 ${enabled_count}/${#sequential_tests[@]})")
                        fi
                        if [[ "$include_par" == true && ${#parallel_tests[@]} -gt 0 ]]; then
                                local enabled_count=0
                                for t in "${parallel_tests[@]}"; do
                                        [[ "${TEST_ENABLED[$t]:-false}" == "true" ]] && ((enabled_count+=1))
                                done
                                menu_items+=("PAR_GROUP" "平行測項 (啟用 ${enabled_count}/${#parallel_tests[@]})")
                        fi
                        menu_items+=("ALL_DONE" "➡ 確認並開始測試")

                        choice=$(dialog --no-cancel --menu "選擇要設定的測項群組" 15 70 10 "${menu_items[@]}" --stdout 2>/dev/null) || true
                        clear >/dev/tty 2>/dev/null || true
                else
                        declare -A options_map=()
                        local labels=()
                        if [[ "$include_seq" == true && ${#sequential_tests[@]} -gt 0 ]]; then
                                local enabled_count=0
                                for t in "${sequential_tests[@]}"; do
                                        [[ "${TEST_ENABLED[$t]:-false}" == "true" ]] && ((enabled_count+=1))
                                done
                                labels+=("SEQ_GROUP\t順序測項 (啟用 ${enabled_count}/${#sequential_tests[@]})")
                        fi
                        if [[ "$include_par" == true && ${#parallel_tests[@]} -gt 0 ]]; then
                                local enabled_count=0
                                for t in "${parallel_tests[@]}"; do
                                        [[ "${TEST_ENABLED[$t]:-false}" == "true" ]] && ((enabled_count+=1))
                                done
                                labels+=("PAR_GROUP\t平行測項 (啟用 ${enabled_count}/${#parallel_tests[@]})")
                        fi
                        labels+=("ALL_DONE\t確認並開始測試")
                        choice=$(_select_from_list "選擇要設定的測項群組：" options_map "${labels[@]}")
                fi

                [[ -z "$choice" || "$choice" == "ALL_DONE" ]] && break

                case "$choice" in
                        SEQ_GROUP)
                                _edit_tests_in_group "$config_file" "sequential" sequential_tests TEST_ENABLED
                                ;;
                        PAR_GROUP)
                                _edit_tests_in_group "$config_file" "parallel" parallel_tests TEST_ENABLED
                                ;;
                        *)
                                continue
                                ;;
                esac
        done
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
        local group_filter=${3:-all}

	log_info "載入並覆寫所有參數 (${mode})"
        load_global_params "$config_file"
        configure_tests_interactively "$config_file" "$mode" "$group_filter"
        log_info "參數設定完成"
}
