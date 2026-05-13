#!/bin/sh
# Watchcat ping watchdog — reads config from watchcat.json at startup.
# Run as www-data by systemd; config is written by watchcat_maker CGI.

CONFIG=/usrdata/quecdeck/var/watchcat.json
REBOOT_STATE=/usrdata/quecdeck/var/watchcat_reboot_state.json
MAX_REBOOT_INTERVAL=3600

if [ ! -f "$CONFIG" ]; then
    echo "watchcat: config not found: $CONFIG" >&2
    exit 1
fi

# Parse config
_enabled=$(grep -o '"enabled"[^,}]*' "$CONFIG" | grep -o 'true\|false')
TRACK_IPS=$(grep -o '"track_ips"[^]]*' "$CONFIG" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | tr '\n' ' ')
PING_INTERVAL=$(grep -o '"ping_interval"[^,}]*' "$CONFIG" | grep -o '[0-9]*$')
PING_FAILURE_COUNT=$(grep -o '"ping_failure_count"[^,}]*' "$CONFIG" | grep -o '[0-9]*$')
_sim=$(grep -o '"disable_on_no_sim"[^,}]*' "$CONFIG" | grep -o 'true\|false')
_backoff=$(grep -o '"reboot_backoff"[^,}]*' "$CONFIG" | grep -o 'true\|false')
[ "$_enabled" = "false" ] && { echo "watchcat: disabled in config, exiting." >&2; exit 0; }
[ "$_sim" = "true" ] && DISABLE_ON_NO_SIM=1 || DISABLE_ON_NO_SIM=0
[ "$_backoff" = "false" ] && REBOOT_BACKOFF=0 || REBOOT_BACKOFF=1

# Validate
case "$PING_INTERVAL" in
    ''|*[!0-9]*) echo "watchcat: invalid ping_interval in config" >&2; exit 1 ;;
esac
case "$PING_FAILURE_COUNT" in
    ''|*[!0-9]*) echo "watchcat: invalid ping_failure_count in config" >&2; exit 1 ;;
esac
[ -z "$TRACK_IPS" ] && { echo "watchcat: no track_ips in config" >&2; exit 1; }

STATS_PATH=/tmp/quecdeck/watchcat_stats.json
failures=0
successes=0

# Read persistent reboot state
reboot_count=0
last_reboot=0
if [ "$REBOOT_BACKOFF" = "1" ] && [ -f "$REBOOT_STATE" ]; then
    reboot_count=$(grep -o '"reboot_count":[0-9]*' "$REBOOT_STATE" | grep -o '[0-9]*$')
    last_reboot=$(grep -o '"last_reboot":[0-9]*' "$REBOOT_STATE" | grep -o '[0-9]*$')
    [ -z "$reboot_count" ] && reboot_count=0
    [ -z "$last_reboot" ]  && last_reboot=0
    # If the clock has gone backwards (RTC not synced after reboot), anchor
    # last_reboot to now so the backoff timer can still make forward progress.
    # Don't write this correction back to flash — it self-corrects on each start.
    now=$(date +%s)
    [ "$last_reboot" -gt "$now" ] && last_reboot=$now
fi

# Wait for the system to settle before starting to ping.
# Skipped if the system has been up for more than 60 seconds (e.g. during install/update).
uptime_secs=$(awk '{print int($1)}' /proc/uptime)
[ "$uptime_secs" -lt 60 ] && { sleep 60 & wait $!; }

# Per-IP miss counters stored in temp files
MISS_DIR=/tmp/quecdeck/watchcat_miss
rm -rf "$MISS_DIR"
mkdir -p "$MISS_DIR"
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
    /usrdata/quecdeck/atcli 'AT+QSIMSTAT?' 2>/dev/null | grep -qE '^\+QSIMSTAT: [0-9]+,1'
}

# Calculate minimum wait before the next reboot based on reboot_count.
# Doubles each time (1x, 2x, 4x, 8x ... cycle_time), capped at MAX_REBOOT_INTERVAL.
calc_min_wait() {
    cycle_time=$((PING_INTERVAL * PING_FAILURE_COUNT))
    multiplier=1
    i=1
    while [ "$i" -lt "$reboot_count" ]; do
        multiplier=$((multiplier * 2))
        i=$((i + 1))
    done
    min_wait=$((multiplier * cycle_time))
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

    next_reboot_allowed=0
    if [ "$REBOOT_BACKOFF" = "1" ] && [ "$reboot_count" -gt 0 ]; then
        min_wait=$(calc_min_wait)
        next_reboot_allowed=$((last_reboot + min_wait))
    fi

    echo "{\"stats\":$stats,\"consecutive_failures\":$failures,\"reboot_count\":$reboot_count,\"next_reboot_allowed\":$next_reboot_allowed}" > "$STATS_PATH"
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

    # Reset all per-IP miss counts on any success — network is up
    if [ "$overall_success" = "1" ]; then
        i=1; for ip in $TRACK_IPS; do _set_miss "$i" 0; i=$((i+1)); done
    fi

    if [ "$overall_success" = "1" ]; then
        failures=0
        successes=$((successes + 1))
        if [ "$REBOOT_BACKOFF" = "1" ] && [ "$reboot_count" -gt 0 ] && [ "$successes" -ge "$PING_FAILURE_COUNT" ]; then
            reboot_count=0
            last_reboot=0
            printf '{"reboot_count":0,"last_reboot":0}\n' > "$REBOOT_STATE"
        fi
    else
        failures=$((failures + 1))
        successes=0
    fi

    write_stats

    if [ "$failures" -ge "$PING_FAILURE_COUNT" ]; then
        if [ "$DISABLE_ON_NO_SIM" = "1" ] && ! check_sim; then
            failures=0
        else
            should_reboot=1
            if [ "$REBOOT_BACKOFF" = "1" ] && [ "$reboot_count" -gt 0 ]; then
                min_wait=$(calc_min_wait)
                now=$(date +%s)
                elapsed=$((now - last_reboot))
                if [ "$elapsed" -lt "$min_wait" ]; then
                    should_reboot=0
                    failures=$PING_FAILURE_COUNT
                fi
            fi

            if [ "$should_reboot" = "1" ]; then
                reboot_count=$((reboot_count + 1))
                printf '{"reboot_count":%d,"last_reboot":%d}\n' "$reboot_count" "$(date +%s)" > "$REBOOT_STATE"
                sync
                sleep 2
                echo "$(date): Rebooting after $failures consecutive ping failures (reboot #$reboot_count)."
                /usrdata/quecdeck/atcli 'AT+CFUN=1,1' 2>/dev/null
                exit 0
            fi
        fi
    fi

    sleep "$PING_INTERVAL" & wait $!
done
