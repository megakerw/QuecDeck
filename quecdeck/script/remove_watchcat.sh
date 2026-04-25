#!/bin/sh

# Stop watchcat before touching the filesystem
systemctl stop watchcat

# Ensure remount,ro always runs on exit, even if the script is killed
trap 'mount -o remount,ro /' EXIT

# Remove boot persistence
mount -o remount,rw /

rm -f /lib/systemd/system/watchcat.service
rm -f /lib/systemd/system/multi-user.target.wants/watchcat.service

mount -o remount,ro /
trap - EXIT

systemctl daemon-reload
