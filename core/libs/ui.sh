#!/usr/bin/env bash
# UI helpers for dialog-based interactions

require_dialog() {
	if ! command -v dialog >/dev/null 2>&1; then
		echo "❌ dialog is required but not installed"
		exit 1
	fi
}

ui_inputbox() {
	local prompt="$1"
	local default="${2:-}"
	dialog --inputbox "$prompt" 8 50 "$default" 3>&1 1>&2 2>&3
}

ui_msgbox() {
	local msg="$1"
	dialog --msgbox "$msg" 10 60
}

ui_yesno() {
	local question="$1"
	dialog --yesno "$question" 7 50
}

ui_infobox() {
	local msg="$1"
	dialog --infobox "$msg" 6 60
}
