#!/usr/bin/env bash

# ------------------------------------------------------------
# 若在 Coproc 環境中（由 runner_coproc 啟動）
# 就讓所有 log 輸出到 stderr，避免干擾 stdout。
# ------------------------------------------------------------
if [[ -n "${COPROC_ACTIVE:-}" ]]; then
	LOG_FD="/dev/stderr"
else
	LOG_FD="/dev/stdout"
fi

log_ts() { date "+[%Y-%m-%d %H:%M:%S]"; }

log_info() { echo -e "$(log_ts) \033[34mINFO\033[0m  $*" >>"$LOG_FD"; }
log_warn() { echo -e "$(log_ts) \033[33mWARN\033[0m  $*" >>"$LOG_FD"; }
log_error() { echo -e "$(log_ts) \033[31mERROR\033[0m $*" >>"$LOG_FD"; }
log_ok() { echo -e "$(log_ts) \033[32mOK\033[0m    $*" >>"$LOG_FD"; }

die() {
	log_error "$*"
	exit 1
}
