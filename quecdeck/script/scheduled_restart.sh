#!/bin/sh
# Scheduled restart — reads config from scheduled_restart.json at startup.
# Run as www-data by systemd; config is written by scheduled_restart_maker CGI.

CONFIG=/usrdata/quecdeck/var/scheduled_restart.json

if [ ! -f "$CONFIG" ]; then
    echo "scheduled_restart: config not found: $CONFIG" >&2
    exit 1
fi

# Parse config
_enabled=$(grep -o '"enabled"[^,}]*' "$CONFIG" | grep -o 'true\|false')
RESTART_TYPE=$(grep -o '"type"[^,}]*' "$CONFIG" | grep -o 'daily\|weekly')
RESTART_DAY=$(grep -o '"day"[^,}]*' "$CONFIG" | grep -o '[0-9]*$')
RESTART_HOUR=$(grep -o '"hour"[^,}]*' "$CONFIG" | grep -o '[0-9]*$')
RESTART_MINUTE=$(grep -o '"minute"[^,}]*' "$CONFIG" | grep -o '[0-9]*$')
[ "$_enabled" = "false" ] && { echo "scheduled_restart: disabled in config, exiting." >&2; exit 0; }

# Validate
case "$RESTART_TYPE" in
    daily|weekly) ;;
    *) echo "scheduled_restart: invalid type in config: $RESTART_TYPE" >&2; exit 1 ;;
esac
case "$RESTART_DAY" in
    ''|*[!0-9]*) echo "scheduled_restart: invalid day in config" >&2; exit 1 ;;
esac
case "$RESTART_HOUR" in
    ''|*[!0-9]*) echo "scheduled_restart: invalid hour in config" >&2; exit 1 ;;
esac
case "$RESTART_MINUTE" in
    ''|*[!0-9]*) echo "scheduled_restart: invalid minute in config" >&2; exit 1 ;;
esac

# Wait for the system to settle before starting
uptime_secs=$(awk '{print int($1)}' /proc/uptime)
[ "$uptime_secs" -lt 60 ] && { sleep 60 & wait $!; }

# Exit cleanly on SIGTERM/SIGINT so systemctl stop doesn't block
trap 'exit' INT TERM

while :; do
    now_hour=$(date +%H)
    now_min=$(date +%M)
    now_day=$(date +%u)
    target_hour=$(printf '%02d' "$RESTART_HOUR")
    target_min=$(printf '%02d' "$RESTART_MINUTE")

    time_match=0
    [ "$now_hour" = "$target_hour" ] && [ "$now_min" = "$target_min" ] && time_match=1

    day_match=0
    [ "$RESTART_TYPE" = "daily" ] && day_match=1
    [ "$RESTART_TYPE" = "weekly" ] && [ "$now_day" = "$RESTART_DAY" ] && day_match=1

    if [ "$time_match" = "1" ] && [ "$day_match" = "1" ]; then
        echo "$(date): Scheduled restart triggered."
        /usrdata/quecdeck/atcli 'AT+CFUN=1,1' 2>/dev/null
        exit 0
    fi

    sleep 60 & wait $!
done
