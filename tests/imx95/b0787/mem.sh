#!/usr/bin/env bash

test_logic() {
	freemem_kb=$(awk '/MemFree/ {print $2; exit}' /proc/meminfo)
	freemem_mb=$(awk -v kb="$freemem_kb" 'BEGIN {print int(kb / 1024)}')
	mem_to_test=$(awk -v mb="$freemem_mb" -v pct="${TEST_PERCENTAGE-1}" 'BEGIN {print int(mb * pct)}')

	if [[ "$mem_to_test" -le 0 ]]; then
		echo "FAIL"
		return
	fi

	if memtester "$mem_to_test" 1 2>&1 | grep -q "Done."; then
		echo "PASS"
	else
		echo "FAIL"
	fi
}

source core/libs/test_template.sh
