#!/bin/sh

# Wait for the location HAL service to start before stopping it (up to 15s).
# lean_mode.sh runs early on boot; without this wait, systemctl stop fires
# before the service is up and the service starts anyway.
i=0
while [ $i -lt 15 ]; do
    systemctl is-active location_hal_daemon.service > /dev/null 2>&1 && break
    sleep 1
    i=$((i+1))
done

# Stop GPS/location services — not needed for data-only RGMII operation.
# Use systemctl stop so supervised services don't respawn.
systemctl stop loc_launcher.service location_hal_daemon.service 2>/dev/null
killall edgnss-daemon 2>/dev/null

exit 0
