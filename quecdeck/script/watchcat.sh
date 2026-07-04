#!/bin/bash
# Watchcat ping watchdog. Reads config from watchcat.json at startup.
# Run as www-data by systemd; config is written by watchcat_maker CGI.

. /usrdata/quecdeck/script/json-lib.sh
. /usrdata/quecdeck/script/at-lib.sh

CONFIG=/usrdata/quecdeck/var/watchcat.json
REBOOT_STATE=/usrdata/quecdeck/var/watchcat_reboot_state.json
# ~2h of pings between capped reboots keeps a worst-case continuous outage
# well under Quectel's ~20 reboots/day flash-wear guidance.
MAX_REBOOT_INTERVAL=7200

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
    ''|0|*[!0-9]*) echo "watchcat: invalid ping_interval in config" >&2; exit 1 ;;
esac
case "$PING_FAILURE_COUNT" in
    ''|0|*[!0-9]*) echo "watchcat: invalid ping_failure_count in config" >&2; exit 1 ;;
esac
[ -z "$TRACK_IPS" ] && { echo "watchcat: no track_ips in config" >&2; exit 1; }

STATS_PATH=/tmp/quecdeck/watchcat_stats.json
RESTART_LOG=/usrdata/quecdeck/var/restart_log.jsonl
BOOT_ID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
failures=0
successes=0

log_restart() {
    local reason="$1" detail="$2"
    # json-lib.sh's parser can't handle embedded quotes/backslashes, and a raw
    # newline would split the JSONL entry; strip them here for every caller.
    reason=$(printf '%s' "$reason" | tr -d '"\\' | tr '\n\r' '  ')
    detail=$(printf '%s' "$detail" | tr -d '"\\' | tr '\n\r' '  ')
    mkdir -p "$(dirname "$RESTART_LOG")"
    # Store wall ts, uptime AND boot_id: the wall clock may never sync, and
    # uptime is only meaningful within its own boot. get_restart_log picks
    # whichever source is trustworthy at read time.
    printf '{"ts":%d,"uptime":%d,"boot_id":"%s","reason":"%s","detail":"%s"}\n' \
        "$(date +%s)" "$(get_uptime)" "$BOOT_ID" "$reason" "$detail" >> "$RESTART_LOG"
    local count
    count=$(wc -l < "$RESTART_LOG" 2>/dev/null || echo 0)
    if [ "$count" -gt 50 ]; then
        tail -50 "$RESTART_LOG" > "${RESTART_LOG}.tmp" && mv "${RESTART_LOG}.tmp" "$RESTART_LOG"
    fi
}

get_uptime() { awk '{print int($1)}' /proc/uptime; }

# Consecutive failures required before the next reboot: doubles per reboot,
# capped at roughly MAX_REBOOT_INTERVAL worth of pings, never below the
# configured base. Throttling is failure-denominated on purpose: no clock or
# uptime source is involved, so it cannot be affected by time sync.
calc_threshold() {
    # Clamp the shift: bash wraps at 64 bits, which would cycle the threshold
    # back to base during a very long outage. 2^20 already exceeds any cap.
    shift_n=$reboot_count
    [ "$shift_n" -gt 20 ] && shift_n=20
    threshold=$((PING_FAILURE_COUNT * (1 << shift_n)))
    max_threshold=$((MAX_REBOOT_INTERVAL / PING_INTERVAL))
    [ "$max_threshold" -lt "$PING_FAILURE_COUNT" ] && max_threshold=$PING_FAILURE_COUNT
    [ "$threshold" -gt "$max_threshold" ] && threshold=$max_threshold
    echo "$threshold"
}

# Read persistent reboot state
reboot_count=0
if [ "$REBOOT_BACKOFF" = "1" ] && [ -f "$REBOOT_STATE" ]; then
    reboot_count=$(json_get "$(cat "$REBOOT_STATE")" reboot_count)
    case "$reboot_count" in ''|*[!0-9]*) reboot_count=0 ;; esac
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
    atcmd_run 'AT+QSIMSTAT?' | grep -qE '^\+QSIMSTAT: [0-9]+,1$'
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

    echo "{\"stats\":$stats,\"consecutive_failures\":$failures,\"reboot_count\":$reboot_count,\"failure_threshold\":$(calc_threshold)}" > "$STATS_PATH"
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
            printf '{"reboot_count":0}\n' > "$REBOOT_STATE"
        fi
    else
        failures=$((failures + 1))
        successes=0
    fi

    if [ "$failures" -ge "$(calc_threshold)" ]; then
        if [ "$DISABLE_ON_NO_SIM" = "1" ] && ! check_sim; then
            echo "uptime $(get_uptime)s: reboot suppressed, SIM check failed ($failures ping failures)"
            failures=0
        else
            if [ "$REBOOT_BACKOFF" = "1" ]; then
                reboot_count=$((reboot_count + 1))
                printf '{"reboot_count":%d}\n' "$reboot_count" > "$REBOOT_STATE"
                detail="$failures consecutive ping failures (reboot streak #$reboot_count)"
            else
                detail="$failures consecutive ping failures"
            fi
            [ "$LOG_RESTARTS" = "1" ] && log_restart "watchcat" "$detail"
            sync
            sleep 2
            echo "uptime $(get_uptime)s: $detail"
            atcmd_run 'AT+CFUN=1,1' >/dev/null
            exit 0
        fi
    fi

    write_stats

    sleep "$PING_INTERVAL" & wait $!
done
