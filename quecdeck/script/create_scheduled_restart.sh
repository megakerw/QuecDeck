#!/bin/sh

# Ensure remount,ro always runs on exit, even if the script is killed
trap 'mount -o remount,ro /' EXIT

mount -o remount,rw /

cp -f /usrdata/quecdeck/systemd/scheduled_restart.service /lib/systemd/system/scheduled_restart.service
ln -sf /lib/systemd/system/scheduled_restart.service /lib/systemd/system/multi-user.target.wants/scheduled_restart.service

mount -o remount,ro /
trap - EXIT

systemctl daemon-reload
systemctl restart scheduled_restart
