#!/usr/bin/env bash

test_logic() {
	sleep 5 # 模擬測試耗時 30 秒
	if ((RANDOM % 10 < 8)); then
		echo "PASS"
	else
		echo "FAIL"
	fi
}

source core/libs/test_template.sh
