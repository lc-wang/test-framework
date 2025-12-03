#!/usr/bin/env bash

test_logic() {
	if stress-ng --cpu 2 --timeout 5s 2>&1 | grep -q "successful"; then
		echo "PASS"
	else
		echo "FAIL"
	fi
}

source core/libs/test_template.sh
