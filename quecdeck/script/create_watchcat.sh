#!/bin/sh

# Ensure remount,ro always runs on exit, even if the script is killed
trap 'mount -o remount,ro /' EXIT

# Enable watchcat service for boot persistence
mount -o remount,rw /

# Restore service file in case it was removed by a previous disable
cp -f /usrdata/quecdeck/systemd/watchcat.service /lib/systemd/system/watchcat.service
ln -sf /lib/systemd/system/watchcat.service /lib/systemd/system/multi-user.target.wants/watchcat.service

mount -o remount,ro /
trap - EXIT

systemctl daemon-reload
systemctl restart watchcat
