#!/usr/bin/env bash
source core/libs/logging_utils.sh 2>/dev/null || true

_apply_jq_update() {
	local config_file="$1"
	local filter="$2"
	shift 2

	local tmp_file
	if ! tmp_file=$(mktemp); then
		log_error "Failed to create temp file; cannot update ${config_file}"
		return 1
	fi

	if jq "$@" "$filter" "$config_file" >"$tmp_file"; then
		mv "$tmp_file" "$config_file"
		return 0
	fi

	log_error "Failed to update config file: $config_file"
	rm -f "$tmp_file"
	return 1
}

_set_test_enabled_state() {
	local config_file="$1"
	local test_name="$2"
	local state="$3"

	local jq_filter='.tests[$test].enabled = ($state == "true")'
	if _apply_jq_update "$config_file" "$jq_filter" --arg test "$test_name" --arg state "$state"; then
		log_info "Updated ${test_name} enabled=${state}"
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
		log_info "Updated ${test_name}.${key}=${value}"
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
		*) echo "Please enter y, n, or c (cancel)." ;;
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
	echo -n "Enter the option number: "
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

	local group_label="Parallel"
	[[ "$group" == "sequential" ]] && group_label="Sequential"

	if [[ ${#tests_ref[@]} -eq 0 ]]; then
		if command -v dialog >/dev/null 2>&1; then
			dialog --msgbox "This mode has no ${group_label} test items." 8 50 </dev/tty >/dev/tty 2>&1 || true
			clear >/dev/tty 2>/dev/null || true
		else
			echo "This mode has no ${group_label} test items."
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
				local status_label="Disabled"
				[[ "$state" == "true" ]] && status_label="Enabled"
				menu_items+=("$t" "$status_label")
			done
			menu_items+=("BACK" "<- Back to previous")
			choice=$(dialog --no-cancel --menu "Select the ${group_label} test item to modify (Enter to configure)" 20 70 12 "${menu_items[@]}" --stdout 2>/dev/null) || true
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
			labels+=("BACK\tBack to previous")
			choice=$(_select_from_list "Select the ${group_label} test item to modify:" options_map "${labels[@]}")
		fi

		[[ -z "$choice" ]] && continue
		[[ "$choice" == "BACK" ]] && break

		if jq -e ".tests.\"${choice}\".params" "$config_file" >/dev/null 2>&1; then
			local enable_ans
			if _prompt_yes_no "Enable test item [${choice}]?\n\nYes: Enable and configure parameters\nNo: Disable this test item" 10 60; then
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
					new_val=$(prompt_input "Set [${choice}] parameter ${key}:" "$val")
					if [[ "$new_val" != "$val" ]]; then
						_set_test_param "$config_file" "$choice" "$key" "$new_val" || true
					fi
					export "$key"="$new_val"
					log_info "Set ${key}=${new_val}"
				done < <(jq -r ".tests.\"${choice}\".params | to_entries[] | \"\(.key)=\(.value)\"" "$config_file")

			elif [[ $enable_ans -eq 1 ]]; then
				enabled_ref["$choice"]="false"
				_set_test_enabled_state "$config_file" "$choice" "false" || true
				log_info "[${choice}] disabled"
			else
				log_info "[${choice}] unchanged"
			fi
		else
			local enable_ans
			if _prompt_yes_no "Enable test item [${choice}]?" 8 40; then
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
				log_info "[${choice}] unchanged"
			fi
		fi
	done

	return 0
}

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

load_global_params() {
	local config_file=$1
	if jq -e ".system" "$config_file" >/dev/null 2>&1; then
		log_info "Loading global system parameters"
		while IFS="=" read -r key val; do
			[[ -z "$key" ]] && continue
			local new_val
			new_val=$(prompt_input "Set system parameter ${key}:" "$val")
			export "$key"="$new_val"
			log_info "Set ${key}=${new_val}"
		done < <(jq -r ".system | to_entries[] | \"\(.key)=\(.value)\"" "$config_file")
	fi
}

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

	log_info "Loading test list for mode ${mode}"

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
					[[ "${TEST_ENABLED[$t]:-false}" == "true" ]] && ((enabled_count += 1))
				done
				menu_items+=("SEQ_GROUP" "Sequential tests (enabled ${enabled_count}/${#sequential_tests[@]})")
			fi
			if [[ "$include_par" == true && ${#parallel_tests[@]} -gt 0 ]]; then
				local enabled_count=0
				for t in "${parallel_tests[@]}"; do
					[[ "${TEST_ENABLED[$t]:-false}" == "true" ]] && ((enabled_count += 1))
				done
				menu_items+=("PAR_GROUP" "Parallel tests (enabled ${enabled_count}/${#parallel_tests[@]})")
			fi
			menu_items+=("ALL_DONE" "-> Confirm and start tests")

			choice=$(dialog --no-cancel --menu "Choose the test group to configure" 15 70 10 "${menu_items[@]}" --stdout 2>/dev/null) || true
			clear >/dev/tty 2>/dev/null || true
		else
			declare -A options_map=()
			local labels=()
			if [[ "$include_seq" == true && ${#sequential_tests[@]} -gt 0 ]]; then
				local enabled_count=0
				for t in "${sequential_tests[@]}"; do
					[[ "${TEST_ENABLED[$t]:-false}" == "true" ]] && ((enabled_count += 1))
				done
				labels+=("SEQ_GROUP\tSequential tests (enabled ${enabled_count}/${#sequential_tests[@]})")
			fi
			if [[ "$include_par" == true && ${#parallel_tests[@]} -gt 0 ]]; then
				local enabled_count=0
				for t in "${parallel_tests[@]}"; do
					[[ "${TEST_ENABLED[$t]:-false}" == "true" ]] && ((enabled_count += 1))
				done
				labels+=("PAR_GROUP\tParallel tests (enabled ${enabled_count}/${#parallel_tests[@]})")
			fi
			labels+=("ALL_DONE\tConfirm and start tests")
			choice=$(_select_from_list "Choose the test group to configure:" options_map "${labels[@]}")
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
		log_info "${t} enabled state: ${TEST_ENABLED[$t]}"
	done
}

export_all_params_for_mode() {
	local config_file=$1
	local mode=$2
	local group_filter=${3:-all}

	log_info "Loading and overriding all parameters (${mode})"
	load_global_params "$config_file"
	configure_tests_interactively "$config_file" "$mode" "$group_filter"
	log_info "Parameter configuration complete"
}
