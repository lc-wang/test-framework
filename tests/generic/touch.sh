#!/usr/bin/env bash

test_logic() {
	log_info "touch"
	if ((RANDOM % 10 < 8)); then
		echo "PASS"
	else
		echo "FAIL"
	fi
}

source core/libs/test_template.sh
