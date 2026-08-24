#!/bin/bash
# Scheduled modem restart. Configuration is loaded at startup. The maker CGI
# restarts the unit after every explicit save.

CONFIG=/usrdata/quecdeck/var/scheduled_restart.json
CLOCK_FLOOR=1735689600 # Dates before 2025-01-01 mean time is not set.

for _lib in json-lib.sh at-lib.sh; do
    . "/usrdata/quecdeck/script/$_lib" || exit 1
done

inactive() {
    echo "scheduled_restart: $1" >&2
    exit 0
}

[ -s "$CONFIG" ] || inactive "config not found or empty: $CONFIG"
config_json=$(cat "$CONFIG")
[ "$(json_get "$config_json" enabled)" = "true" ] || inactive "disabled in config"

RESTART_TYPE=$(json_get "$config_json" type)
RESTART_DAY=$(json_get "$config_json" day)
RESTART_HOUR=$(json_get "$config_json" hour)
RESTART_MINUTE=$(json_get "$config_json" minute)
case "$RESTART_TYPE" in daily|weekly) ;; *) inactive "invalid type" ;; esac
case "$RESTART_DAY" in ''|*[!0-9]*) inactive "invalid day" ;; esac
case "$RESTART_HOUR" in ''|*[!0-9]*) inactive "invalid hour" ;; esac
case "$RESTART_MINUTE" in ''|*[!0-9]*) inactive "invalid minute" ;; esac
[ "$RESTART_DAY" -ge 1 ] && [ "$RESTART_DAY" -le 7 ] || inactive "day out of range"
[ "$RESTART_HOUR" -ge 0 ] && [ "$RESTART_HOUR" -le 23 ] || inactive "hour out of range"
[ "$RESTART_MINUTE" -ge 0 ] && [ "$RESTART_MINUTE" -le 59 ] || inactive "minute out of range"

read -r uptime_secs _ < /proc/uptime || exit 1
uptime_secs=${uptime_secs%.*}
case "$uptime_secs" in ''|*[!0-9]*) exit 1 ;; esac
[ "$uptime_secs" -lt 60 ] && { sleep "$((60 - uptime_secs))" & wait $!; }
trap 'exit' INT TERM

target_hour=$(printf '%02d' "$RESTART_HOUR")
target_minute=$(printf '%02d' "$RESTART_MINUTE")
last_occurrence=
clock_held=0
startup_check=1

while :; do
    # Read all wall-clock fields together so they describe one instant. Wall
    # time is appropriate for the user's schedule. Unlike Watchcat backoff it
    # is never used to rate-limit reboots.
    set -- $(date '+%s %Y-%m-%dT%H:%M %H %M %u')
    now_epoch=$1 occurrence=$2 now_hour=$3 now_minute=$4 now_day=$5
    if [ "$now_epoch" -lt "$CLOCK_FLOOR" ]; then
        [ "$clock_held" = "1" ] || echo "scheduled_restart: clock not set. Schedule held" >&2
        clock_held=1
    else
        [ "$clock_held" = "0" ] || echo "scheduled_restart: clock set. Schedule resumed" >&2
        clock_held=0
        day_matches=0
        [ "$RESTART_TYPE" = "daily" ] && day_matches=1
        [ "$RESTART_TYPE" = "weekly" ] && [ "$now_day" = "$RESTART_DAY" ] && day_matches=1
        if [ "$day_matches" = "1" ] && [ "$now_hour" = "$target_hour" ] \
            && [ "$now_minute" = "$target_minute" ] && [ "$occurrence" != "$last_occurrence" ]; then
            last_occurrence=$occurrence
            if [ "$startup_check" = "1" ]; then
                # Starting or reloading the unit during its scheduled minute
                # must not immediately reboot the modem. In particular, the
                # updater restarts this worker as its final recovery step.
                echo "scheduled_restart: matching startup minute skipped" >&2
            else
                echo "scheduled_restart: scheduled restart triggered" >&2
                atcmd_fire 'AT+CFUN=1,1' 10000 || echo "scheduled_restart: reboot dispatch failed" >&2
                # If the modem stays up, move beyond the matching minute before
                # checking again. A successful reboot terminates this sleep.
                sleep 90 & wait $!
                continue
            fi
        fi
    fi
    startup_check=0
    sleep 30 & wait $!
done
