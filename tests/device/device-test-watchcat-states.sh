#!/bin/sh
# Watchcat state validation against the installed service.
#
# Run as root on a configured device after deploying the candidate files:
#
#     sh device-test-watchcat-states.sh
#
# This test temporarily replaces the Watchcat configuration and restarts the
# service several times. It covers the properties the host suite can only
# assert against source: that an uncontacted target is reported as such, that a
# disabled Watchcat exits cleanly, that target-first order rotates, that a pause
# marker written by the web tier holds the running daemon off the connection,
# that every explicit save reloads or disables a stale worker, and that the
# monitoring sudoers entries are exactly the ones the CGIs now use.
#
# The settings section drives the real watchcat_maker CGI as www-data, since the
# skip-the-restart check compares against the exact bytes the maker writes.
#
# Every section sets the failure count to its maximum of ten, so no section can
# accumulate enough failed rounds to reach a reboot before it restores the
# original configuration.

CONFIG=/usrdata/quecdeck/var/watchcat.json
STATS=/run/quecdeck-web/watchcat/stats.json
CGI_LIB=/usrdata/quecdeck/script/cgi-lib.sh
BACKUP=/run/quecdeck/watchcat-states-backup.$$
TMP=${CONFIG}.states.$$
DEAD_A=198.51.100.1
DEAD_B=198.51.100.2
pass=0
fail=0
skip=0
had_config=0
original_hash=""
restored=0

ok()  { echo "  PASS: $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL: $1"; fail=$((fail + 1)); }
skp() { echo "  SKIP: $1"; skip=$((skip + 1)); }

# A precondition failing costs a whole section, so these account for the checks
# that never ran in one line. Repeating the same message once per check keeps
# the totals right but reads as a copy-paste slip. Usage: skp_n <count> <why>
skp_n() { echo "  SKIP: $2 ($1 checks)"; skip=$((skip + $1)); }
bad_n() { echo "  FAIL: $2 ($1 checks not run)"; fail=$((fail + $1)); }

[ "$(id -u)" = "0" ] || { echo "FATAL: must run as root"; exit 1; }

mkdir -p /run/quecdeck 2>/dev/null

if [ -e "$CONFIG" ]; then
    cp -p "$CONFIG" "$BACKUP" || { echo "FATAL: cannot back up $CONFIG"; exit 1; }
    had_config=1
    original_hash=$(sha256sum "$CONFIG" | awk '{print $1}')
fi

restore_config() {
    rm -f "$TMP"
    if [ "$restored" != "1" ]; then
        if [ "$had_config" = "1" ]; then
            if [ ! -f "$BACKUP" ] || ! cp -p "$BACKUP" "$CONFIG"; then
                echo "FATAL: could not restore $CONFIG, backup retained at $BACKUP" >&2
                return 1
            fi
        else
            rm -f "$CONFIG" || return 1
        fi
        restored=1
        rm -f "$BACKUP"
    fi
    systemctl restart watchcat >/dev/null 2>&1
}
trap 'restore_config' EXIT
trap 'exit 1' INT TERM

# Store a configuration with the ownership and mode used by watchcat_maker.
store_config() {
    printf '%s\n' "$1" > "$TMP" || return 1
    chown www-data:www-data "$TMP" && chmod 640 "$TMP" && mv "$TMP" "$CONFIG" || return 1
}

# Install a configuration and restart the daemon onto it.
apply_config() {
    store_config "$1" || return 1
    rm -f "$STATS"
    systemctl restart watchcat
}

wait_for_stats() {
    remaining=${1:-75}
    while [ "$remaining" -gt 0 ]; do
        [ -s "$STATS" ] && return 0
        sleep 1
        remaining=$((remaining - 1))
    done
    return 1
}

wait_for_change() {
    previous=$1
    remaining=30
    while [ "$remaining" -gt 0 ]; do
        current=$(stat -c %Y "$STATS" 2>/dev/null)
        [ -n "$current" ] && [ "$current" != "$previous" ] && return 0
        sleep 1
        remaining=$((remaining - 1))
    done
    return 1
}

# Miss count for one IP, including the negative sentinel. The character class
# rather than an escaped optional: BRE support for \? Is not portable across
# the greps this device may ship.
miss_for() {
    grep -o "\"ip\":\"$1\",\"miss\":[-0-9]*" "$STATS" 2>/dev/null | sed 's/.*"miss"://'
}

# bash, not sh: cgi-lib.sh guards on BASH_VERSION, so sourcing it under a POSIX
# shell fails for reasons that have nothing to do with what is being tested.
# The CGIs themselves run under bash.
as_www_data=""
if su -s /bin/bash www-data -c "true" >/dev/null 2>&1; then
    as_www_data="su -s /bin/bash www-data -c"
fi

echo "=================================================================="
echo " Watchcat state validation"
echo "=================================================================="

# ---------------------------------------------------------------------------
echo ""
echo "-- an uncontacted target is not reported as responding --"
# Loopback is first in the initial round, so that round answers immediately and
# the two documentation addresses are not contacted. The next round starts at
# the next target and proves that the first-target position rotates.
if apply_config "{\"enabled\":true,\"track_ips\":[\"127.0.0.1\",\"$DEAD_A\",\"$DEAD_B\"],\"ping_interval\":10,\"ping_failure_count\":10,\"disable_on_no_sim\":false,\"reboot_backoff\":false,\"log_restarts\":false}"; then
    if wait_for_stats; then
        first_mtime=$(stat -c %Y "$STATS" 2>/dev/null)
        loop_miss=$(miss_for 127.0.0.1)
        a_miss=$(miss_for "$DEAD_A")
        b_miss=$(miss_for "$DEAD_B")
        [ "$loop_miss" = "0" ] && ok "the answering target reports zero misses" \
            || bad "loopback miss count is ${loop_miss:-missing}, expected 0"
        if [ "$a_miss" = "-1" ] && [ "$b_miss" = "-1" ]; then
            ok "targets the round never reached report the not-contacted sentinel"
        else
            bad "uncontacted targets report ${a_miss:-missing}/${b_miss:-missing}, expected -1/-1"
        fi

        if [ -n "$first_mtime" ] && wait_for_change "$first_mtime"; then
            a_miss=$(miss_for "$DEAD_A")
            b_miss=$(miss_for "$DEAD_B")
            [ "$a_miss" = "1" ] && [ "$b_miss" = "1" ] \
                && ok "the next round rotates first position and contacts skipped targets" \
                || bad "rotated round reported misses ${a_miss:-missing}/${b_miss:-missing}, expected 1/1"
        else
            bad "second round did not publish stats"
        fi
    else
        bad "first round did not publish stats"
    fi
else
    bad "could not apply the uncontacted-target configuration"
fi

# ---------------------------------------------------------------------------
echo ""
echo "-- a disabled Watchcat exits cleanly --"
# Restart=on-failure does not restart a clean exit, so a boot-enabled unit can
# stay inactive until the maker restarts it with an enabled configuration.
if apply_config '{"enabled":false,"track_ips":["127.0.0.1"],"ping_interval":10,"ping_failure_count":10,"disable_on_no_sim":false,"reboot_backoff":false,"log_restarts":false}'; then
    sleep 8
    state=$(systemctl is-active watchcat 2>/dev/null)
    [ "$state" = "inactive" ] && ok "a disabled Watchcat is cleanly inactive" \
        || bad "disabled Watchcat unit state is ${state:-unknown}, expected inactive"

    n_restarts=$(systemctl show -p NRestarts --value watchcat 2>/dev/null)
    sleep 12
    n_restarts_after=$(systemctl show -p NRestarts --value watchcat 2>/dev/null)
    if [ -n "$n_restarts" ] && [ "$n_restarts" = "$n_restarts_after" ]; then
        ok "a disabled Watchcat is not restart-looping"
    else
        bad "restart count moved from ${n_restarts:-unknown} to ${n_restarts_after:-unknown}"
    fi

    [ ! -e "$STATS" ] && ok "an inactive Watchcat publishes no ping statistics" \
        || bad "a disabled Watchcat wrote $STATS"
else
    bad "could not apply the disabled configuration"
fi

# ---------------------------------------------------------------------------
echo ""
echo "-- a pause marker holds the running daemon off the connection --"
# Modem operations pause watchcat with a marker instead of stopping the unit, so
# the pause survives a settings save restarting it. The daemon must honour the
# marker written by the web tier, and resume once it goes.
if [ -z "$as_www_data" ]; then
    skp_n 3 "cannot drop to www-data on this device"
elif [ ! -r "$CGI_LIB" ]; then
    skp_n 3 "$CGI_LIB not readable"
elif apply_config '{"enabled":true,"track_ips":["198.51.100.1"],"ping_interval":10,"ping_failure_count":10,"disable_on_no_sim":false,"reboot_backoff":false,"log_restarts":false}'; then
    # One unreachable target, so every round fails and the counters move. The
    # failure count is its maximum, so the test cannot reach a reboot.
    if wait_for_stats; then
        mtime=$(stat -c %Y "$STATS" 2>/dev/null)
        # Written as www-data through the real helper, exactly as a CGI does.
        $as_www_data ". $CGI_LIB >/dev/null 2>&1; watchcat_pause devtest 120" >/dev/null 2>&1
        [ -s /run/quecdeck-web/watchcat/pause.d/devtest ] \
            && ok "the web tier can write a pause marker without privilege" \
            || bad "watchcat_pause did not create a marker"

        if wait_for_change "$mtime"; then
            grep -q '"paused":true' "$STATS" \
                && ok "the running daemon honours a marker written under it" \
                || bad "stats do not report paused while a marker is present"
            paused_failures=$(grep -o '"consecutive_failures":[0-9]*' "$STATS" | sed 's/.*://')
            [ "$paused_failures" = "0" ] \
                && ok "a paused round clears the failure streak" \
                || bad "consecutive_failures is ${paused_failures:-missing} while paused, expected 0"
        else
            bad_n 2 "no stats were published while paused"
        fi

        mtime=$(stat -c %Y "$STATS" 2>/dev/null)
        $as_www_data ". $CGI_LIB >/dev/null 2>&1; watchcat_resume devtest" >/dev/null 2>&1
        if wait_for_change "$mtime"; then
            grep -q '"paused":false' "$STATS" \
                && ok "removing the marker resumes the daemon" \
                || bad "stats still report paused after the marker was removed"
        else
            bad "no stats were published after resuming"
        fi
    else
        bad_n 3 "no stats were published for the pause test"
    fi
    rm -f /run/quecdeck-web/watchcat/pause.d/devtest
else
    bad_n 3 "could not apply the pause-test configuration"
fi

# ---------------------------------------------------------------------------
echo ""
echo "-- every explicit save reloads the worker --"
# The config file can already contain the requested bytes while the live process
# still holds an older configuration (for example, after a failed restart).
# Every Save therefore reloads the unit, even when the file itself is unchanged.
#
# Driven through the real CGI as www-data, because the comparison is against the
# exact bytes the maker itself writes: a hand-written config would never match.
MAKER=/usrdata/quecdeck/www/cgi-bin/watchcat_maker
POST_BASE='WATCHCAT_ENABLED=enable&TRACK_IP_1=127.0.0.1&PING_FAILURE_COUNT=10&DISABLE_ON_NO_SIM=0&REBOOT_BACKOFF=1&LOG_RESTARTS=0'

save_settings() { # save_settings <body>
    printf '%s' "$1" | $as_www_data "REQUEST_METHOD=POST CONTENT_LENGTH=${#1} $MAKER" >/dev/null 2>&1
}
# Monotonic, so it moves on every start and never on a clock change.
start_stamp() { systemctl show -p ExecMainStartTimestampMonotonic --value watchcat 2>/dev/null; }

if [ -z "$as_www_data" ]; then
    skp_n 6 "cannot drop to www-data on this device"
elif [ ! -x "$MAKER" ]; then
    skp_n 6 "$MAKER not executable"
else
    # Establish the config in the maker's own format first.
    save_settings "${POST_BASE}&PING_INTERVAL=30"
    sleep 6
    before=$(start_stamp)

    save_settings "${POST_BASE}&PING_INTERVAL=30"
    sleep 6
    [ -n "$before" ] && [ "$(start_stamp)" != "$before" ] \
        && ok "resubmitting identical settings reloads the worker" \
        || bad "an unchanged explicit save did not reload the worker"

    # The repair path: config still matches, but the worker is down.
    systemctl stop watchcat >/dev/null 2>&1
    sleep 2
    save_settings "${POST_BASE}&PING_INTERVAL=30"
    sleep 6
    [ "$(systemctl is-active watchcat 2>/dev/null)" = "active" ] \
        && ok "saving unchanged settings restarts a stopped worker" \
        || bad "Save did not repair a stopped worker"

    before=$(start_stamp)
    save_settings "${POST_BASE}&PING_INTERVAL=40"
    sleep 6
    [ -n "$before" ] && [ "$(start_stamp)" != "$before" ] \
        && ok "a real settings change restarts the worker" \
        || bad "a changed save did not restart the worker"

    grep -q '"ping_interval": 40' "$CONFIG" \
        && ok "the changed setting reached the stored configuration" \
        || bad "the stored configuration does not carry the changed setting"

    # Reproduce the dangerous stale-active case: disk says disabled while the
    # currently running process still holds the enabled configuration. The
    # identical disabled save must restart it onto the file and make it exit.
    disabled_json='{"enabled": false, "track_ips": ["127.0.0.1"], "ping_interval": 40, "ping_failure_count": 10, "disable_on_no_sim": false, "reboot_backoff": true, "log_restarts": false}'
    disabled_post='WATCHCAT_ENABLED=disable&TRACK_IP_1=127.0.0.1&PING_INTERVAL=40&PING_FAILURE_COUNT=10&DISABLE_ON_NO_SIM=0&REBOOT_BACKOFF=1&LOG_RESTARTS=0'
    if store_config "$disabled_json" && [ "$(systemctl is-active watchcat 2>/dev/null)" = "active" ]; then
        ok "the fixture created a stale enabled worker over a disabled file"
        save_settings "$disabled_post"
        sleep 6
        [ "$(systemctl is-active watchcat 2>/dev/null)" = "inactive" ] \
            && ok "an identical disabled save terminates the stale worker" \
            || bad "the stale worker remained active after the disabled save"
    else
        bad_n 2 "could not create the stale-disabled fixture"
    fi
fi

# ---------------------------------------------------------------------------
echo ""
echo "-- rapid saves cannot leave the watchdog dead --"
# systemd's default start limit is 5 starts in 10s, and neither unit overrides
# it. Every Save now restarts, so reset-failed must also clear the rate-limit
# counters before each restart and keep a hammered UI from parking the worker.
if [ -z "$as_www_data" ]; then
    skp_n 2 "cannot drop to www-data on this device"
elif [ ! -x "$MAKER" ]; then
    skp_n 2 "$MAKER not executable"
else
    save_settings "${POST_BASE}&PING_INTERVAL=30"
    sleep 6
    before=$(start_stamp)
    n=0
    while [ "$n" -lt 8 ]; do
        save_settings "${POST_BASE}&PING_INTERVAL=30"
        n=$((n + 1))
    done
    sleep 4
    if [ "$(start_stamp)" != "$before" ] && [ "$(systemctl is-active watchcat)" = "active" ]; then
        ok "eight identical saves reload the worker without leaving it failed"
    else
        bad "rapid identical saves did not reload the worker cleanly"
    fi

    # Six genuine changes inside the limit window. Whatever systemd does, the
    # watchdog must not be left dead: that is the outcome that matters.
    n=0
    while [ "$n" -lt 6 ]; do
        save_settings "${POST_BASE}&PING_INTERVAL=3${n}"
        n=$((n + 1))
    done
    sleep 12
    state=$(systemctl is-active watchcat 2>/dev/null)
    if [ "$state" = "active" ]; then
        ok "six rapid changes leave the worker running"
    else
        # Asserted, not repaired-then-passed: the maker clears a failed unit
        # before restarting it, so reaching here means that path did not work.
        # The device is still put back, since a test must not leave the watchdog
        # down, but the result stands as a failure.
        bad "six rapid changes left the worker '$state'"
        systemctl reset-failed watchcat >/dev/null 2>&1
        systemctl start watchcat >/dev/null 2>&1
        sleep 4
    fi
fi

# ---------------------------------------------------------------------------
echo ""
echo "-- the monitoring sudoers entries match what the CGIs now call --"
# The maker CGIs stopped calling create_/remove_ helpers and now restart the
# units directly, so the allowlist has to have moved with them.
if [ -z "$as_www_data" ]; then
    skp "cannot drop to www-data on this device"
else
    # reset-failed as well as restart: the maker calls it unchecked and silenced,
    # so a missing allowlist entry is a silent sudo denial that only shows up as
    # a worker that will not come back after the start limit trips.
    for unit in watchcat scheduled_restart; do
        for verb in restart reset-failed; do
            if $as_www_data "/opt/bin/sudo -n /bin/systemctl $verb $unit" >/dev/null 2>&1; then
                ok "www-data may $verb $unit"
            else
                bad "www-data cannot $verb $unit through sudo"
            fi
        done
    done

    # The retired helpers must not remain reachable: they are gone from the
    # release, and an allowlist entry for a missing root script is a hole
    # waiting for the next file to appear at that path.
    helper_reachable=0
    for helper in create_watchcat remove_watchcat create_scheduled_restart remove_scheduled_restart; do
        [ -e "/usrdata/quecdeck/script/${helper}.sh" ] && helper_reachable=1
        $as_www_data "/opt/bin/sudo -n /usrdata/quecdeck/script/${helper}.sh --version" >/dev/null 2>&1 \
            && helper_reachable=1
    done
    [ "$helper_reachable" = "0" ] && ok "the retired monitoring helpers are gone and not permitted" \
        || bad "a retired monitoring helper is still present or still allowed by sudo"

    grep -q 'create_watchcat\|remove_watchcat\|create_scheduled_restart\|remove_scheduled_restart' \
        /opt/etc/sudoers.d/www-data 2>/dev/null \
        && bad "the sudoers rule still names a retired monitoring helper" \
        || ok "the sudoers rule names no retired monitoring helper"
fi

# ---------------------------------------------------------------------------
echo ""
if restore_config; then
    trap - EXIT INT TERM
    if [ "$had_config" = "1" ]; then
        restored_hash=$(sha256sum "$CONFIG" 2>/dev/null | awk '{print $1}')
        [ "$restored_hash" = "$original_hash" ] && ok "original Watchcat configuration restored" \
            || bad "original Watchcat configuration was not restored"
    else
        [ ! -e "$CONFIG" ] && ok "missing Watchcat configuration state restored" \
            || bad "temporary Watchcat configuration remains"
    fi
else
    bad "Watchcat configuration restore failed"
fi

echo ""
echo "passes: $pass, failures: $fail, skipped: $skip"
[ "$fail" -eq 0 ]
