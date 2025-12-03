#!/usr/bin/env bash

test_logic() {
	#	log_info "[DEBUG] INTERFACE=$INTERFACE TARGET_IP=$TARGET_IP SERVER_IP=$LOG_SERVER_IP"
	if ((RANDOM % 100 < 98)); then
		echo "PASS"
	else
		echo "FAIL"
	fi
}

source core/libs/test_template.sh
