#!/usr/bin/env bash
set -e
dialog --title "系統重新啟動" --yesno "確定要重新啟動系統嗎？" 7 45
if [[ $? -eq 0 ]]; then
	dialog --infobox "系統即將重新啟動..." 5 40
	sleep 2
	sudo reboot || true
else
	dialog --msgbox "已取消重新啟動。" 5 40
fi
clear
