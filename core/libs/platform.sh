#!/usr/bin/env bash
# Platform detection and parameter export helper

detect_platform() {
	# 這只是範例，你可以替換成實際偵測邏輯
	if grep -q "Rockchip" /proc/cpuinfo 2>/dev/null; then
		PLATFORM="rk3588"
	elif grep -q "i.MX8" /proc/cpuinfo 2>/dev/null; then
		PLATFORM="imx8mp"
	elif grep -q "Renesas" /proc/cpuinfo 2>/dev/null; then
		PLATFORM="rzv2h"
	else
		PLATFORM="generic"
	fi
}

detect_os() {
	if [[ -f /etc/os-release ]]; then
		OS_TYPE=$(grep ^ID= /etc/os-release | cut -d= -f2 | tr -d '"')
	else
		OS_TYPE="generic"
	fi
}

# === 匯出測試項目參數 ===
# 從 config.json 將 .tests.<key>.params 轉為 export 環境變數
export_params_for_test() {
	local key="$1"
	local params_json
	params_json=$(jq -r ".tests.\"$key\".params // {}" "$CONFIG")

	if [[ "$params_json" != "{}" ]]; then
		while IFS="=" read -r k v; do
			[[ -n "$k" && -n "$v" ]] && export "$k"="$v"
		done < <(jq -r 'to_entries[] | "\(.key)=\(.value)"' <<<"$params_json")
	fi
}
