#!/usr/bin/env bash

test_logic() {
	if [ -f "$TOUCHFILE" ]; then
		rm -f "$TOUCHFILE"
	fi

	if touch "$TOUCHFILE"; then
		echo "PASS"
	else
		echo "FAIL"
	fi
}

source core/libs/test_template.sh
