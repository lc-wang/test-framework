#!/usr/bin/env bash

test_logic() {
	score=$(glmark2-es2-wayland --off-screen 2>/dev/null | awk '/glmark2 Score/ {print $3}')

	if [[ -n "$score" && "$score" -ge "${PASS_SCORE-0}" ]]; then
		echo "PASS"
	else
		echo "FAIL"
	fi
}

source core/libs/test_template.sh
