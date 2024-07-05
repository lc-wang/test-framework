#!/usr/bin/env bash
# ============================================================
# global_params_utils.sh
# 提供載入與互動編輯全域參數設定檔的工具
# ============================================================

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
                log_warn "找不到全域參數檔：$config_file"
                return 0
        fi

        local jq_root
        if ! jq_root=$(_detect_global_root "$config_file"); then
                log_warn "全域參數檔格式不正確：$config_file"
                return 0
        fi

        if ! jq -e "${jq_root} | type == \"object\" and length > 0" "$config_file" >/dev/null 2>&1; then
                log_warn "全域參數檔沒有可載入的鍵值：$config_file"
                return 0
        fi

        log_info "載入全域參數（檔案：$config_file）..."
        while IFS="=" read -r key val; do
                [[ -z "$key" ]] && continue
                export "$key"="$val"
                log_info "export ${key}=${val}"
        done < <(jq -r "${jq_root} | to_entries[] | \"\\(.key)=\\(.value)\"" "$config_file")
}

edit_global_variables() {
        local config_file="$1"

        if [[ ! -f "$config_file" ]]; then
                log_warn "找不到全域參數檔：$config_file"
                return 0
        fi

        local jq_root
        if ! jq_root=$(_detect_global_root "$config_file"); then
                log_warn "全域參數檔格式不正確：$config_file"
                return 0
        fi

        mapfile -t keys < <(jq -r "${jq_root} | keys[]" "$config_file")
        if [[ ${#keys[@]} -eq 0 ]]; then
                log_warn "全域參數檔沒有任何鍵值可供編輯"
                return 0
        fi

        for key in "${keys[@]}"; do
                local current_val new_val
                local jq_read_expr
                jq_read_expr="${jq_root} | .[\$key]"
                current_val=$(jq -r --arg key "$key" "$jq_read_expr" "$config_file")

                if command -v dialog >/dev/null 2>&1; then
                        if new_val=$(dialog --inputbox "設定全域參數 ${key}：" 8 60 "$current_val" --stdout); then
                                clear >/dev/tty 2>/dev/null || true
                        else
                                clear >/dev/tty 2>/dev/null || true
                                new_val="$current_val"
                        fi
                else
                        printf '設定全域參數 %s [%s]: ' "$key" "$current_val"
                        read -r new_val
                fi

                [[ -z "$new_val" ]] && new_val="$current_val"

                if [[ "$new_val" != "$current_val" ]]; then
                        local jq_write_expr tmp_file
                        jq_write_expr="${jq_root} |= (.[\$key] = \$val)"
                        if ! tmp_file=$(mktemp); then
                                log_error "建立暫存檔失敗，無法更新 ${key}"
                                continue
                        fi

                        if jq --arg key "$key" --arg val "$new_val" "$jq_write_expr" "$config_file" >"$tmp_file"; then
                                mv "$tmp_file" "$config_file"
                                log_info "更新 ${key}=${new_val}"
                        else
                                log_error "更新 ${key} 失敗"
                                rm -f "$tmp_file"
                                continue
                        fi
                else
                        log_info "${key} 維持為 ${current_val}"
                fi

                export "$key"="$new_val"
        done

        log_ok "全域參數已更新"
}
