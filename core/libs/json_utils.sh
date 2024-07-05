#!/usr/bin/env bash

export_params_for_test() {
	local test_name="$1"
	local config_file="$2"

	# 檢查該測項是否有 params
	local has_params
	has_params=$(jq -r "has(\"tests\") and (.tests.\"${test_name}\" | has(\"params\"))" "$config_file" 2>/dev/null)

	if [[ "$has_params" != "true" ]]; then
		return 0
	fi

	# 取得 params 並逐一轉為 key/value
	local params_json
	params_json=$(jq -c ".tests.\"${test_name}\".params" "$config_file" 2>/dev/null)

	if [[ -z "$params_json" || "$params_json" == "null" ]]; then
		return 0
	fi

	# jq to_entries 處理後逐項 export
	while IFS=$'\n' read -r line; do
		local key val
		key=$(echo "$line" | jq -r '.key' 2>/dev/null)
		val=$(echo "$line" | jq -r '.value' 2>/dev/null)
		if [[ -n "$key" && "$key" != "null" ]]; then
			export "$key=$val"
		fi
	done < <(echo "$params_json" | jq -c 'to_entries[]' 2>/dev/null)
}
