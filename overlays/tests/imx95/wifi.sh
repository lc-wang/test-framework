#!/usr/bin/env bash
echo "[WIFI] rk3588 yocto override test"
if ! wpa_cli status | grep -q "COMPLETED"; then
  echo "wifi disconnected"; exit 1; fi

