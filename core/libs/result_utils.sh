#!/usr/bin/env bash

write_results_json() {
	local output_path="$1"
	local -n keys_ref=$2
	local -n pass_ref=$3
	local -n fail_ref=$4
	local -n total_ref=$5

	mkdir -p "$(dirname "$output_path")"

	{
		echo '{ "tests": {'
		local first=true
		for key in "${keys_ref[@]}"; do
			[[ -z "${total_ref[$key]:-}" ]] && continue
			$first || echo ','
			first=false
			printf '  "%s": { "pass": %d, "fail": %d, "total": %d }' \
				"$key" "${pass_ref[$key]:-0}" "${fail_ref[$key]:-0}" "${total_ref[$key]:-0}"
		done
		echo ' } }'
	} >"$output_path"
}
