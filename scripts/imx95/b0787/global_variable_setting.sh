#!/usr/bin/env bash
set -euo pipefail

source core/libs/logging_utils.sh
source core/libs/global_params_utils.sh

DEFAULT_GLOBAL_PARAMS_FILE="configs/generic/global_params.json"
TARGET_FILE=${1:-"$DEFAULT_GLOBAL_PARAMS_FILE"}

if [[ ! -f "$TARGET_FILE" ]]; then
	if [[ -f "$DEFAULT_GLOBAL_PARAMS_FILE" ]]; then
		TARGET_FILE="$DEFAULT_GLOBAL_PARAMS_FILE"
	else
		log_error "Global parameter configuration file not found: $TARGET_FILE"
		if command -v dialog >/dev/null 2>&1; then
			dialog --msgbox "Global parameter configuration file not found: $TARGET_FILE" 8 60 </dev/tty >/dev/tty 2>&1 || true
			clear >/dev/tty 2>/dev/null || true
		fi
		exit 1
	fi
fi

log_info "Starting global parameter configuration"
load_global_variables "$TARGET_FILE"
edit_global_variables "$TARGET_FILE"
load_global_variables "$TARGET_FILE"

if command -v dialog >/dev/null 2>&1; then
	dialog --msgbox "Global parameters have been updated." 8 60 </dev/tty >/dev/tty 2>&1 || true
	clear >/dev/tty 2>/dev/null || true
else
	echo "Global parameters have been updated."
fi
