#!/usr/bin/env bash
set -e
dialog --title "System Reboot" --yesno "Are you sure you want to reboot the system?" 7 45
if [[ $? -eq 0 ]]; then
	dialog --infobox "System will reboot shortly..." 5 40
	sleep 2
	sudo reboot || true
else
	dialog --msgbox "Reboot cancelled." 5 40
fi
clear
