#!/bin/bash
# Ping watchdog. Configuration is loaded at startup. The maker CGI restarts the
# unit after every explicit save.

CONFIG=/usrdata/quecdeck/var/watchcat.json
REBOOT_STATE=/usrdata/quecdeck/var/watchcat_reboot_state.json
STATS_PATH=/tmp/quecdeck/watchcat_stats.json
RESTART_LOG=/usrdata/quecdeck/var/restart_log.jsonl
PING_TIMEOUT=3
MAX_REBOOT_INTERVAL=7200
REBOOT_SETTLE=300

for _lib in json-lib.sh at-lib.sh watchcat-coord.sh; do
    . "/usrdata/quecdeck/script/$_lib" || exit 1
done

inactive() {
    echo "watchcat: $1" >&2
    exit 0
}

[ -s "$CONFIG" ] || inactive "config not found or empty: $CONFIG"
config_json=$(cat "$CONFIG")
[ "$(json_get "$config_json" enabled)" = "true" ] || inactive "disabled in config"

TRACK_IPS=$(json_get "$config_json" track_ips | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -6 | tr '\n' ' ')
PING_INTERVAL=$(json_get "$config_json" ping_interval)
PING_FAILURE_COUNT=$(json_get "$config_json" ping_failure_count)
sim=$(json_get "$config_json" disable_on_no_sim)
backoff=$(json_get "$config_json" reboot_backoff)
log=$(json_get "$config_json" log_restarts)

case "$PING_INTERVAL" in ''|*[!0-9]*) inactive "invalid ping_interval" ;; esac
case "$PING_FAILURE_COUNT" in ''|*[!0-9]*) inactive "invalid ping_failure_count" ;; esac
[ "$PING_INTERVAL" -ge 10 ] && [ "$PING_INTERVAL" -le 600 ] || inactive "ping_interval out of range"
[ "$PING_FAILURE_COUNT" -ge 3 ] && [ "$PING_FAILURE_COUNT" -le 10 ] || inactive "ping_failure_count out of range"
[ -n "$TRACK_IPS" ] || inactive "no track_ips in config"
case "$sim" in true) DISABLE_ON_NO_SIM=1 ;; false) DISABLE_ON_NO_SIM=0 ;; *) inactive "invalid disable_on_no_sim" ;; esac
case "$backoff" in true) REBOOT_BACKOFF=1 ;; false) REBOOT_BACKOFF=0 ;; *) inactive "invalid reboot_backoff" ;; esac
case "$log" in true) LOG_RESTARTS=1 ;; false) LOG_RESTARTS=0 ;; *) inactive "invalid log_restarts" ;; esac

# TRACK_IPS contains only dotted decimal tokens by this point, so intentional
# word splitting is safe here.
TRACK_IPS_ARRAY=($TRACK_IPS)
target_count=${#TRACK_IPS_ARRAY[@]}
BOOT_ID=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null)
failures=0
successes=0
reboot_count=0
next_attempt_uptime=0
paused=false
round_start=0

get_uptime() {
    watchcat_uptime
}

log_restart() {
    [ "$LOG_RESTARTS" = "1" ] || return 0
    local detail entry count
    detail=$(printf '%s' "$1" | tr -d '"\\' | tr '\n\r' '  ')
    [ -d "$(dirname "$RESTART_LOG")" ] || (umask 077; mkdir -p "$(dirname "$RESTART_LOG")") || return 1
    entry=$(printf '{"ts":%d,"uptime":%d,"boot_id":"%s","detail":"%s"}' \
        "$(date +%s)" "$(get_uptime)" "$BOOT_ID" "$detail")
    printf '%s\n' "$entry" >> "$RESTART_LOG" || return 1
    count=$(wc -l < "$RESTART_LOG" 2>/dev/null) || return 0
    # Normal logging is append-only. Once the limit is exceeded, keep only the
    # event that crossed it. This avoids rewriting the whole persistent log on
    # every event while still preventing unbounded growth.
    [ "$count" -le 100 ] || watchcat_atomic_write "$RESTART_LOG" "$entry"
}

calc_backoff_delay() {
    backoff_delay=0
    [ "$REBOOT_BACKOFF" = "1" ] && [ "$reboot_count" -gt 0 ] || return 0
    local shift_n=$reboot_count
    [ "$shift_n" -gt 20 ] && shift_n=20
    backoff_delay=$((PING_FAILURE_COUNT * PING_INTERVAL * (1 << shift_n)))
    [ "$backoff_delay" -gt "$MAX_REBOOT_INTERVAL" ] && backoff_delay=$MAX_REBOOT_INTERVAL
}

save_reboot_state() {
    watchcat_atomic_write "$REBOOT_STATE" \
        "{\"reboot_count\":$reboot_count,\"boot_id\":\"$BOOT_ID\",\"not_before\":$next_attempt_uptime}"
}

# Backoff state is relevant only when the option is enabled. Same-boot service
# restarts keep the exact monotonic deadline. A modem reboot starts a fresh
# delay from the new boot's uptime. Wall-clock time is never used here.
if [ "$REBOOT_BACKOFF" = "1" ] && [ -s "$REBOOT_STATE" ]; then
    state_json=$(cat "$REBOOT_STATE")
    reboot_count=$(json_get "$state_json" reboot_count)
    state_not_before=$(json_get "$state_json" not_before)
    state_boot_id=$(json_get "$state_json" boot_id)
    case "$reboot_count" in ''|*[!0-9]*) reboot_count=0 ;; esac
    case "$state_not_before" in ''|*[!0-9]*) state_not_before=0 ;; esac
    if [ "$state_boot_id" = "$BOOT_ID" ]; then
        next_attempt_uptime=$state_not_before
    elif [ "$reboot_count" -gt 0 ]; then
        calc_backoff_delay
        next_attempt_uptime=$(($(get_uptime) + backoff_delay))
    fi
fi

# Wait only for the remainder of the initial boot-settle period.
uptime_secs=$(get_uptime) || exit 1
[ "$uptime_secs" -lt 65 ] && { sleep "$((65 - uptime_secs))" & wait $!; }

mkdir -p /tmp/quecdeck || exit 1
chmod 700 /tmp/quecdeck 2>/dev/null
trap 'exit' INT TERM

# -1 means that a target has not been contacted yet. A successful response ends
# the round, so later targets may legitimately remain unknown.
misses=()
for i in "${!TRACK_IPS_ARRAY[@]}"; do misses[$i]=-1; done

check_sim() {
    local reply rc state
    reply=$(atcmd_run 'AT+QSIMSTAT?')
    rc=$?
    [ "$rc" -eq 0 ] || return 2
    printf '%s\n' "$reply" | grep -qx 'OK' || return 2
    state=$(printf '%s\n' "$reply" | sed -n 's/^+QSIMSTAT: [0-9]\+,\([01]\)$/\1/p')
    case "$state" in 1) return 0 ;; 0) return 1 ;; *) return 2 ;; esac
}

write_stats() {
    local stats="[" first=1 i now remaining=0
    for i in "${!TRACK_IPS_ARRAY[@]}"; do
        [ "$first" = "1" ] && first=0 || stats="$stats,"
        stats="${stats}{\"ip\":\"${TRACK_IPS_ARRAY[$i]}\",\"miss\":${misses[$i]}}"
    done
    stats="$stats]"
    now=$(get_uptime) || return 1
    [ "$next_attempt_uptime" -gt "$now" ] && remaining=$((next_attempt_uptime - now))
    watchcat_atomic_write "$STATS_PATH" \
        "{\"stats\":$stats,\"consecutive_failures\":$failures,\"reboot_count\":$reboot_count,\"failure_threshold\":$PING_FAILURE_COUNT,\"retry_after\":$remaining,\"paused\":$paused}"
}

ping_round() {
    local offset i ip
    overall_success=0
    for ((offset=0; offset<target_count; offset++)); do
        i=$(((round_start + offset) % target_count))
        ip=${TRACK_IPS_ARRAY[$i]}
        if ping -c 1 -W "$PING_TIMEOUT" "$ip" >/dev/null 2>&1; then
            misses[$i]=0
            overall_success=1
            round_start=$(((round_start + 1) % target_count))
            return 0
        fi
        [ "${misses[$i]}" -lt 0 ] && misses[$i]=0
        misses[$i]=$((misses[$i] + 1))
    done
    round_start=$(((round_start + 1) % target_count))
}

attempt_reboot() {
    local now sim_state=0 detail outcome
    # A pause is checked at the start of the round and again below after the SIM
    # query. A marker arriving after the final check may not stop this attempt.
    if watchcat_is_paused; then
        paused=true failures=0 successes=0
        return 0
    fi
    now=$(get_uptime) || return 1
    [ "$REBOOT_BACKOFF" = "1" ] && [ "$now" -lt "$next_attempt_uptime" ] && return 0

    if [ "$DISABLE_ON_NO_SIM" = "1" ]; then
        check_sim
        sim_state=$?
    fi
    if [ "$sim_state" = "1" ]; then
        echo "watchcat: reboot suppressed because the SIM is absent" >&2
        failures=0
        return 0
    fi
    [ "$sim_state" = "2" ] && echo "watchcat: SIM status unavailable. Continuing with reboot" >&2

    # Re-check after the SIM query, which may itself take several seconds.
    if watchcat_is_paused; then
        paused=true failures=0 successes=0
        return 0
    fi

    reboot_count=$((reboot_count + 1))
    calc_backoff_delay
    next_attempt_uptime=$((now + backoff_delay))
    if [ "$REBOOT_BACKOFF" = "1" ] && ! save_reboot_state; then
        reboot_count=$((reboot_count - 1))
        next_attempt_uptime=0
        failures=0
        log_restart "reboot withheld: could not persist backoff state"
        return 0
    fi

    detail="$failures consecutive failed rounds (attempt #$reboot_count)"
    log_restart "$detail"
    sync
    atcmd_fire 'AT+CFUN=1,1' 10000 && outcome="modem stayed up" || outcome="dispatch failed"
    sleep "$REBOOT_SETTLE" & wait $!
    log_restart "no reboot after $detail: $outcome"
    failures=0
}

while :; do
    if watchcat_is_paused; then
        paused=true
        failures=0
        successes=0
        write_stats
        sleep "$PING_INTERVAL" & wait $!
        continue
    fi
    paused=false
    ping_round

    if [ "$overall_success" = "1" ]; then
        failures=0
        successes=$((successes + 1))
        if [ "$reboot_count" -gt 0 ] && [ "$successes" -ge "$PING_FAILURE_COUNT" ]; then
            reboot_count=0
            next_attempt_uptime=0
            [ "$REBOOT_BACKOFF" = "1" ] && save_reboot_state
        fi
    else
        [ "$failures" -lt "$PING_FAILURE_COUNT" ] && failures=$((failures + 1))
        successes=0
    fi

    [ "$failures" -ge "$PING_FAILURE_COUNT" ] && attempt_reboot
    write_stats
    sleep "$PING_INTERVAL" & wait $!
done
