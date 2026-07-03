#!/bin/sh
# Watchcat ping watchdog. Reads config from watchcat.json at startup.
# Run as www-data by systemd; config is written by watchcat_maker CGI.

. /usrdata/quecdeck/script/json-lib.sh

CONFIG=/usrdata/quecdeck/var/watchcat.json
REBOOT_STATE=/usrdata/quecdeck/var/watchcat_reboot_state.json
MAX_REBOOT_INTERVAL=3600

if [ ! -s "$CONFIG" ]; then
    echo "watchcat: config not found or empty: $CONFIG" >&2
    exit 1
fi

# Parse config
config_json=$(cat "$CONFIG")
enabled=$(json_get "$config_json" enabled)
TRACK_IPS=$(json_get "$config_json" track_ips | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | tr '\n' ' ')
PING_INTERVAL=$(json_get "$config_json" ping_interval)
PING_FAILURE_COUNT=$(json_get "$config_json" ping_failure_count)
sim=$(json_get "$config_json" disable_on_no_sim)
backoff=$(json_get "$config_json" reboot_backoff)
log=$(json_get "$config_json" log_restarts)
[ "$enabled" = "false" ] && { echo "watchcat: disabled in config, exiting." >&2; exit 0; }
[ "$sim" = "true" ] && DISABLE_ON_NO_SIM=1 || DISABLE_ON_NO_SIM=0
[ "$backoff" = "false" ] && REBOOT_BACKOFF=0 || REBOOT_BACKOFF=1
[ "$log" = "false" ] && LOG_RESTARTS=0 || LOG_RESTARTS=1

# Validate
case "$PING_INTERVAL" in
    ''|*[!0-9]*) echo "watchcat: invalid ping_interval in config" >&2; exit 1 ;;
esac
case "$PING_FAILURE_COUNT" in
    ''|*[!0-9]*) echo "watchcat: invalid ping_failure_count in config" >&2; exit 1 ;;
esac
[ -z "$TRACK_IPS" ] && { echo "watchcat: no track_ips in config" >&2; exit 1; }

STATS_PATH=/tmp/quecdeck/watchcat_stats.json
RESTART_LOG=/usrdata/quecdeck/var/restart_log.jsonl
failures=0
successes=0

log_restart() {
    local reason="$1" detail="$2"
    # json-lib.sh's parser can't handle embedded quotes/backslashes, and a raw
    # newline would split this entry across lines in the JSONL file. Strip
    # those here so every caller (current and future) gets safe JSON for free,
    # rather than relying on each call site to escape its own free text.
    reason=$(printf '%s' "$reason" | tr -d '"\\' | tr '\n\r' '  ')
    detail=$(printf '%s' "$detail" | tr -d '"\\' | tr '\n\r' '  ')
    mkdir -p "$(dirname "$RESTART_LOG")"
    # Store uptime rather than a wall-clock timestamp: it's correct even if
    # the device's clock has never synced (e.g. no tower for NITZ/NTP).
    # get_restart_log converts this to an estimated wall-clock time at read
    # time using the live clock, so display improves once the clock syncs.
    printf '{"uptime":%d,"reason":"%s","detail":"%s"}\n' "$(get_uptime)" "$reason" "$detail" >> "$RESTART_LOG"
    local count
    count=$(wc -l < "$RESTART_LOG" 2>/dev/null || echo 0)
    if [ "$count" -gt 50 ]; then
        tail -50 "$RESTART_LOG" > "${RESTART_LOG}.tmp" && mv "${RESTART_LOG}.tmp" "$RESTART_LOG"
    fi
}

get_uptime() { awk '{print int($1)}' /proc/uptime; }

# Read persistent reboot state
reboot_count=0
last_reboot_uptime=0
if [ "$REBOOT_BACKOFF" = "1" ] && [ -f "$REBOOT_STATE" ]; then
    reboot_state_json=$(cat "$REBOOT_STATE")
    reboot_count=$(json_get "$reboot_state_json" reboot_count)
    last_reboot_uptime=$(json_get "$reboot_state_json" last_reboot_uptime)
    [ -z "$reboot_count" ] && reboot_count=0
    [ -z "$last_reboot_uptime" ] && last_reboot_uptime=0
    # Uptime (unlike the wall clock) only resets to 0 on an actual reboot, so
    # it can't be thrown off by NTP/NITZ never syncing (e.g. no tower signal).
    # If the persisted value is ahead of current uptime, the state predates
    # this boot; anchor it to now so the backoff timer counts from this boot.
    now_uptime=$(get_uptime)
    [ "$last_reboot_uptime" -gt "$now_uptime" ] && last_reboot_uptime=$now_uptime
fi

# Wait for the system to settle before starting to ping.
# Skipped if the system has been up for more than 65 seconds (e.g. during install/update).
uptime_secs=$(get_uptime)
[ "$uptime_secs" -lt 65 ] && { sleep 65 & wait $!; }

# Per-IP miss counters stored in temp files
MISS_DIR=/tmp/quecdeck/watchcat_miss
rm -rf "$MISS_DIR"
mkdir -p "$MISS_DIR"
# Lock the base dir if this daemon created it before lighttpd's ExecStartPre did.
chmod 700 /tmp/quecdeck "$MISS_DIR" 2>/dev/null
trap 'rm -rf $MISS_DIR' EXIT
trap 'exit' INT TERM
_miss_file() { echo "${MISS_DIR}/miss_${1}"; }
_get_miss()  { cat "$(_miss_file "$1")" 2>/dev/null || echo 0; }
_set_miss()  { echo "$2" > "$(_miss_file "$1")"; }

i=1
for ip in $TRACK_IPS; do
    _set_miss "$i" 0
    i=$((i+1))
done

check_sim() {
    /usrdata/quecdeck/atcli 'AT+QSIMSTAT?' 2>/dev/null | grep -qE '^\+QSIMSTAT: [0-9]+,1$'
}

# Calculate minimum wait before the next reboot based on reboot_count.
# Doubles each time (2x, 4x, 8x ... cycle_time), capped at MAX_REBOOT_INTERVAL.
calc_min_wait() {
    cycle_time=$((PING_INTERVAL * PING_FAILURE_COUNT))
    min_wait=$((cycle_time * (1 << reboot_count)))
    [ "$min_wait" -gt "$MAX_REBOOT_INTERVAL" ] && min_wait=$MAX_REBOOT_INTERVAL
    echo "$min_wait"
}

write_stats() {
    stats="["
    first_stat=1
    i=1
    for ip in $TRACK_IPS; do
        count=$(_get_miss "$i")
        [ "$first_stat" = "1" ] && first_stat=0 || stats="$stats,"
        stats="${stats}{\"ip\":\"$ip\",\"miss\":$count}"
        i=$((i+1))
    done
    stats="$stats]"

    # Report remaining seconds (derived from monotonic uptime) rather than an
    # absolute deadline. An absolute wall-clock deadline would be wrong if the
    # device's clock is unsynced (e.g. never registered on a tower for
    # NITZ/NTP); the frontend ticks this value down locally using its own
    # elapsed time, so neither clock's absolute correctness matters.
    backoff_remaining=0
    if [ "$REBOOT_BACKOFF" = "1" ] && [ "$reboot_count" -gt 0 ]; then
        min_wait=$(calc_min_wait)
        elapsed=$(($(get_uptime) - last_reboot_uptime))
        backoff_remaining=$((min_wait - elapsed))
        [ "$backoff_remaining" -lt 0 ] && backoff_remaining=0
    fi

    echo "{\"stats\":$stats,\"consecutive_failures\":$failures,\"reboot_count\":$reboot_count,\"backoff_remaining\":$backoff_remaining}" > "$STATS_PATH"
}

while :; do
    overall_success=0
    i=1
    for ip in $TRACK_IPS; do
        if ping -c 1 -W 5 "$ip" > /dev/null 2>&1; then
            overall_success=1
            break
        fi
        _set_miss "$i" $(( $(_get_miss "$i") + 1 ))
        i=$((i+1))
    done

    # Reset all per-IP miss counts on any success (network is up)
    if [ "$overall_success" = "1" ]; then
        i=1; for ip in $TRACK_IPS; do _set_miss "$i" 0; i=$((i+1)); done
    fi

    if [ "$overall_success" = "1" ]; then
        failures=0
        successes=$((successes + 1))
        if [ "$REBOOT_BACKOFF" = "1" ] && [ "$reboot_count" -gt 0 ] && [ "$successes" -ge "$PING_FAILURE_COUNT" ]; then
            reboot_count=0
            last_reboot_uptime=0
            printf '{"reboot_count":0,"last_reboot_uptime":0}\n' > "$REBOOT_STATE"
        fi
    else
        failures=$((failures + 1))
        successes=0
    fi

    if [ "$failures" -ge "$PING_FAILURE_COUNT" ]; then
        if [ "$DISABLE_ON_NO_SIM" = "1" ] && ! check_sim; then
            failures=0
        else
            should_reboot=1
            if [ "$REBOOT_BACKOFF" = "1" ] && [ "$reboot_count" -gt 0 ]; then
                min_wait=$(calc_min_wait)
                now_uptime=$(get_uptime)
                elapsed=$((now_uptime - last_reboot_uptime))
                if [ "$elapsed" -lt "$min_wait" ]; then
                    should_reboot=0
                    failures=$PING_FAILURE_COUNT
                fi
            fi

            if [ "$should_reboot" = "1" ]; then
                if [ "$REBOOT_BACKOFF" = "1" ]; then
                    reboot_count=$((reboot_count + 1))
                    printf '{"reboot_count":%d,"last_reboot_uptime":%d}\n' "$reboot_count" "$(get_uptime)" > "$REBOOT_STATE"
                    detail="$failures consecutive ping failures (reboot streak #$reboot_count)"
                else
                    detail="$failures consecutive ping failures"
                fi
                [ "$LOG_RESTARTS" = "1" ] && log_restart "watchcat" "$detail"
                sync
                sleep 2
                echo "uptime $(get_uptime)s: $detail"
                /usrdata/quecdeck/atcli 'AT+CFUN=1,1' 2>/dev/null
                exit 0
            fi
        fi
    fi

    write_stats

    sleep "$PING_INTERVAL" & wait $!
done
