#!/bin/sh

systemctl stop scheduled_restart

# Ensure remount,ro always runs on exit, even if the script is killed
trap 'mount -o remount,ro /' EXIT

mount -o remount,rw /

rm -f /lib/systemd/system/scheduled_restart.service
rm -f /lib/systemd/system/multi-user.target.wants/scheduled_restart.service

mount -o remount,ro /
trap - EXIT

systemctl daemon-reload
