#!/bin/sh
# Watchcat ping watchdog — reads config from watchcat.json at startup.
# Run as www-data by systemd; config is written by watchcat_maker CGI.

CONFIG=/usrdata/quecdeck/var/watchcat.json

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
[ "$_enabled" = "false" ] && { echo "watchcat: disabled in config, exiting." >&2; exit 0; }
[ "$_sim" = "true" ] && DISABLE_ON_NO_SIM=1 || DISABLE_ON_NO_SIM=0

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
    /usrdata/quecdeck/atcli 'AT+CIMI' 2>/dev/null | grep -qv 'ERROR'
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
    echo "{\"stats\":$stats,\"consecutive_failures\":$failures}" > "$STATS_PATH"
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
    else
        failures=$((failures + 1))
    fi

    write_stats

    if [ "$failures" -ge "$PING_FAILURE_COUNT" ]; then
        # Last line of defence: don't reboot if there's no SIM — pings will
        # always fail without one and a reboot won't help.
        if [ "$DISABLE_ON_NO_SIM" = "1" ] && ! check_sim; then
            failures=0
        else
            echo "$(date): Rebooting after $failures consecutive ping failures."
            /usrdata/quecdeck/atcli 'AT+CFUN=1,1' 2>/dev/null
            exit 0
        fi
    fi

    sleep "$PING_INTERVAL" & wait $!
done
