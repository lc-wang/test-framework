#!/usr/bin/env bash
source core/libs/logging_utils.sh 2>/dev/null || true

_detect_global_root() {
	local file="$1"

	if jq -e 'type == "object"' "$file" >/dev/null 2>&1; then
		if jq -e 'has("global_params") and .global_params | type == "object"' "$file" >/dev/null 2>&1; then
			echo ".global_params"
			return 0
		fi

		if jq -e 'type == "object" and (values | all(. | (type != "object" and type != "array")))' "$file" >/dev/null 2>&1; then
			echo "."
			return 0
		fi
	fi

	return 1
}

load_global_variables() {
	local config_file="$1"

	if [[ ! -f "$config_file" ]]; then
		log_warn "Global parameter file not found: $config_file"
		return 0
	fi

	local jq_root
	if ! jq_root=$(_detect_global_root "$config_file"); then
		log_warn "Global parameter file format is invalid: $config_file"
		return 0
	fi

	if ! jq -e "${jq_root} | type == \"object\" and length > 0" "$config_file" >/dev/null 2>&1; then
		log_warn "Global parameter file has no keys to load: $config_file"
		return 0
	fi

	log_info "Loading global parameters (file: $config_file)..."
	while IFS="=" read -r key val; do
		[[ -z "$key" ]] && continue
		export "$key"="$val"
		log_info "export ${key}=${val}"
	done < <(jq -r "${jq_root} | to_entries[] | \"\\(.key)=\\(.value)\"" "$config_file")
}

edit_global_variables() {
	local config_file="$1"

	if [[ ! -f "$config_file" ]]; then
		log_warn "Global parameter file not found: $config_file"
		return 0
	fi

	local jq_root
	if ! jq_root=$(_detect_global_root "$config_file"); then
		log_warn "Global parameter file format is invalid: $config_file"
		return 0
	fi

	mapfile -t keys < <(jq -r "${jq_root} | keys[]" "$config_file")
	if [[ ${#keys[@]} -eq 0 ]]; then
		log_warn "Global parameter file has no keys to edit"
		return 0
	fi

	for key in "${keys[@]}"; do
		local current_val new_val
		local jq_read_expr
		jq_read_expr="${jq_root} | .[\$key]"
		current_val=$(jq -r --arg key "$key" "$jq_read_expr" "$config_file")

		if command -v dialog >/dev/null 2>&1; then
			if new_val=$(dialog --inputbox "Set global parameter ${key}:" 8 60 "$current_val" --stdout); then
				clear >/dev/tty 2>/dev/null || true
			else
				clear >/dev/tty 2>/dev/null || true
				new_val="$current_val"
			fi
		else
			printf 'Set global parameter %s [%s]: ' "$key" "$current_val"
			read -r new_val
		fi

		[[ -z "$new_val" ]] && new_val="$current_val"

		if [[ "$new_val" != "$current_val" ]]; then
			local jq_write_expr tmp_file
			jq_write_expr="${jq_root} |= (.[\$key] = \$val)"
			if ! tmp_file=$(mktemp); then
				log_error "Failed to create temp file; cannot update ${key}"
				continue
			fi

			if jq --arg key "$key" --arg val "$new_val" "$jq_write_expr" "$config_file" >"$tmp_file"; then
				mv "$tmp_file" "$config_file"
				log_info "Updated ${key}=${new_val}"
			else
				log_error "Failed to update ${key}"
				rm -f "$tmp_file"
				continue
			fi
		else
			log_info "${key} remains ${current_val}"
		fi

		export "$key"="$new_val"
	done

	log_ok "Global parameters updated"
}
