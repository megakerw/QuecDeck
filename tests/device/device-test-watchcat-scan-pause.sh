#!/bin/sh
# Watchcat pause validation against a real cell scan.
#
# Run as root on a configured device after deploying the candidate files:
#
#     sh device-test-watchcat-scan-pause.sh
#
# DISRUPTIVE. This runs an actual AT+QSCAN, which drops the cellular connection
# for roughly a minute and can take up to the CGI's 215s timeout. Do not run it
# on a modem anyone is relying on.
#
# It covers the one property no host test can reach: that run_cell_scan pauses
# the running daemon for the duration of a real scan, that the pause survives a
# settings save restarting the unit mid-scan, and that the trap lifts it
# afterwards. Stopping the unit, which is what this replaced, could not survive
# that restart, and the reboot it prevents is the reason the mechanism exists.
#
# Targets are real internet addresses so the scan genuinely makes them fail. The
# interval is 30s and the failure count its maximum of 10, so even if every ping
# fails immediately the nine guaranteed gaps need 270s, beyond the scan's 215s
# timeout. Ping execution only widens that margin.

CONFIG=/usrdata/quecdeck/var/watchcat.json
STATS=/tmp/quecdeck/watchcat_stats.json
PAUSE_DIR=/tmp/quecdeck/watchcat.pause.d
SCAN_CGI=/usrdata/quecdeck/www/cgi-bin/run_cell_scan
MAKER=/usrdata/quecdeck/www/cgi-bin/watchcat_maker
BACKUP=/run/quecdeck/watchcat-scanpause-backup.$$
TMP=${CONFIG}.scanpause.$$
pass=0
fail=0
skip=0
had_config=0
restored=0

ok()  { echo "  PASS: $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL: $1"; fail=$((fail + 1)); }
skp_n() { echo "  SKIP: $2 ($1 checks)"; skip=$((skip + $1)); }
bad_n() { echo "  FAIL: $2 ($1 checks not run)"; fail=$((fail + $1)); }

[ "$(id -u)" = "0" ] || { echo "FATAL: must run as root"; exit 1; }
mkdir -p /run/quecdeck 2>/dev/null

if [ -e "$CONFIG" ]; then
    cp -p "$CONFIG" "$BACKUP" || { echo "FATAL: cannot back up $CONFIG"; exit 1; }
    had_config=1
fi

cleanup() {
    rm -f "$TMP"
    # Never leave a marker behind: it would park the real watchdog until expiry.
    rm -f "$PAUSE_DIR"/scan "$PAUSE_DIR"/scanpause
    rm -f /tmp/quecdeck/qscan.active
    if [ "$restored" != "1" ]; then
        if [ "$had_config" = "1" ]; then
            cp -p "$BACKUP" "$CONFIG" 2>/dev/null || \
                echo "FATAL: could not restore $CONFIG, backup at $BACKUP" >&2
        else
            rm -f "$CONFIG"
        fi
        restored=1
        rm -f "$BACKUP"
    fi
    systemctl restart watchcat >/dev/null 2>&1
}
trap 'cleanup' EXIT
trap 'exit 1' INT TERM

as_www_data=""
if su -s /bin/bash www-data -c "true" >/dev/null 2>&1; then
    as_www_data="su -s /bin/bash www-data -c"
fi

# CONTENT_LENGTH is computed, never counted by hand: cgi_read_post reads exactly
# that many bytes, so a value short of the body silently truncates the params.
post_to() { # post_to <cgi> <body>
    printf '%s' "$2" | $as_www_data "REQUEST_METHOD=POST CONTENT_LENGTH=${#2} $1"
}

paused_now() { grep -q '"paused":true' "$STATS" 2>/dev/null; }
failures_now() { grep -o '"consecutive_failures":[0-9]*' "$STATS" 2>/dev/null | sed 's/.*://'; }
stamp() { systemctl show -p ExecMainStartTimestampMonotonic --value watchcat 2>/dev/null; }

wait_for_stats() {
    remaining=${1:-75}
    while [ "$remaining" -gt 0 ]; do
        [ -s "$STATS" ] && return 0
        sleep 1
        remaining=$((remaining - 1))
    done
    return 1
}

# Waits for a NEW publication, not merely for the file to exist. The daemon only
# writes once per interval, so reading straight after the scan returns the last
# paused write and reports a resume that has not happened yet.
wait_for_fresh_stats() {
    previous=$(stat -c %Y "$STATS" 2>/dev/null)
    remaining=${1:-45}
    while [ "$remaining" -gt 0 ]; do
        current=$(stat -c %Y "$STATS" 2>/dev/null)
        [ -n "$current" ] && [ "$current" != "$previous" ] && return 0
        sleep 1
        remaining=$((remaining - 1))
    done
    return 1
}

echo "=================================================================="
echo " Watchcat pause across a real cell scan"
echo "=================================================================="

if ! command -v flock >/dev/null 2>&1; then
    bad_n 7 "flock is unavailable; safe scan and authentication locking cannot be verified"
elif [ -z "$as_www_data" ]; then
    skp_n 7 "cannot drop to www-data on this device"
elif [ ! -x "$SCAN_CGI" ] || [ ! -x "$MAKER" ]; then
    skp_n 7 "the scan or maker CGI is not executable"
else
    ok "flock is available for scan and authentication serialization"
    # Real targets, so the scan actually makes them fail. Failure count at its
    # maximum keeps the reboot threshold beyond the longest possible scan.
    printf '%s\n' '{"enabled":true,"track_ips":["8.8.8.8","1.1.1.1"],"ping_interval":30,"ping_failure_count":10,"disable_on_no_sim":false,"reboot_backoff":false,"log_restarts":false}' > "$TMP"
    chown www-data:www-data "$TMP" && chmod 640 "$TMP" && mv "$TMP" "$CONFIG"
    rm -f "$STATS"
    systemctl restart watchcat

    if ! wait_for_stats; then
        bad_n 6 "watchcat published no stats before the scan"
    else
        paused_now && bad "watchcat was already paused before the scan" \
            || ok "watchcat is not paused before the scan"

        # The scan runs for its full duration, so drive it in the background.
        # Driven off state, never wall-clock offsets. Scan duration is not
        # predictable: 55s and 7s were both measured on this device, and the
        # CGI's own ceiling is 215s. Sleeping a fixed interval and asserting
        # "during the scan" reports whatever the scan happened to be doing.
        post_to "$SCAN_CGI" 'mode=3' >/tmp/qd-scan.out 2>&1 &
        scan_pid=$!

        # The CGI writes the marker before starting the scan, so this appears
        # almost at once or not at all.
        n=0
        while [ "$n" -lt 15 ] && [ ! -s "$PAUSE_DIR/scan" ]; do
            sleep 1
            n=$((n + 1))
        done
        [ -s "$PAUSE_DIR/scan" ] && ok "the scan created a pause marker" \
            || bad "the scan created no pause marker"

        # The whole point of the design: a settings save restarts the unit and
        # the pause has to outlive it, which stopping the unit could not. Done
        # while the marker is still up, and reported as inconclusive rather than
        # failed if the scan has already ended.
        if [ ! -s "$PAUSE_DIR/scan" ]; then
            skp_n 2 "the scan ended before a restart could be attempted"
        else
            before=$(stamp)
            post_to "$MAKER" 'WATCHCAT_ENABLED=enable&TRACK_IP_1=8.8.8.8&TRACK_IP_2=1.1.1.1&PING_INTERVAL=31&PING_FAILURE_COUNT=10&DISABLE_ON_NO_SIM=0&REBOOT_BACKOFF=0&LOG_RESTARTS=0' >/dev/null 2>&1
            n=0
            while [ "$n" -lt 15 ] && [ "$(stamp)" = "$before" ]; do
                sleep 1
                n=$((n + 1))
            done
            [ "$(stamp)" != "$before" ] && ok "the settings save restarted the worker mid-scan" \
                || bad "the settings save did not restart the worker"
            # The marker is the mechanism. A stop would have been undone by the
            # restart above. A file cannot be.
            [ -s "$PAUSE_DIR/scan" ] && ok "the pause outlived the restart" \
                || bad "the pause was lost when the worker restarted"
        fi

        # Wait the scan out, then confirm its trap lifted the pause and that no
        # failures were banked against a disruption we caused ourselves.
        wait "$scan_pid" 2>/dev/null
        [ ! -e "$PAUSE_DIR/scan" ] && ok "the scan lifted its own pause on exit" \
            || bad "the scan left its pause marker behind"
        if wait_for_fresh_stats 45 && ! paused_now; then
            f=$(failures_now)
            [ "$f" = "0" ] && ok "no failures were banked across the scan" \
                || bad "watchcat banked ${f:-?} failures across the scan"
        else
            bad "watchcat did not resume publishing unpaused stats after the scan"
        fi
    fi
fi

rm -f /tmp/qd-scan.out
cleanup
trap - EXIT INT TERM

echo ""
echo "passes: $pass, failures: $fail, skipped: $skip"
[ "$fail" -eq 0 ]
