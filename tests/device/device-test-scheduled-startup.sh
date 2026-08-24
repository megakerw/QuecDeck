#!/bin/sh
# Scheduled Restart startup-minute validation against the installed service.
#
# Run as root on a configured device:
#
#     sh device-test-scheduled-startup.sh
#
# This test briefly stops the existing worker and atcmd-daemon, replaces the
# scheduled-restart config with the current minute, and restarts the worker.
# Stopping the AT daemon makes the test fail-safe: even if the startup guard
# regresses, no reboot command can reach the modem. The original config and
# daemon state are restored on exit.

CONFIG=/usrdata/quecdeck/var/scheduled_restart.json
BACKUP=/run/quecdeck/scheduled-startup-backup.$$
TMP=${CONFIG}.startup-test.$$
pass=0
fail=0
skip=0
had_config=0
atcmd_was_active=0
restored=0

ok()  { echo "  PASS: $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL: $1"; fail=$((fail + 1)); }
skp() { echo "  SKIP: $1"; skip=$((skip + 1)); }

[ "$(id -u)" = "0" ] || { echo "FATAL: must run as root"; exit 1; }
mkdir -p /run/quecdeck || exit 1

if [ -e "$CONFIG" ]; then
    cp -p "$CONFIG" "$BACKUP" || { echo "FATAL: cannot back up $CONFIG"; exit 1; }
    had_config=1
fi
systemctl is-active atcmd-daemon >/dev/null 2>&1 && atcmd_was_active=1

restore_state() {
    [ "$restored" = "1" ] && return 0
    restored=1
    rm -f "$TMP"
    if [ "$had_config" = "1" ]; then
        cp -p "$BACKUP" "$CONFIG" || {
            echo "FATAL: original schedule could not be restored. Backup retained at $BACKUP" >&2
            return 1
        }
    else
        rm -f "$CONFIG" || return 1
    fi
    rm -f "$BACKUP"
    systemctl restart scheduled_restart >/dev/null 2>&1
    [ "$atcmd_was_active" = "1" ] && systemctl start atcmd-daemon >/dev/null 2>&1
}
trap 'restore_state' EXIT
trap 'exit 1' INT TERM

echo "=================================================================="
echo " Scheduled Restart startup-minute validation"
echo "=================================================================="

systemctl stop scheduled_restart atcmd-daemon >/dev/null 2>&1
if systemctl is-active scheduled_restart >/dev/null 2>&1 \
    || systemctl is-active atcmd-daemon >/dev/null 2>&1; then
    bad "the scheduler or AT daemon could not be stopped. Refusing the startup-minute test"
else
    cursor=$(journalctl -n 0 --show-cursor --no-pager 2>/dev/null | sed -n 's/^-- cursor: //p')
    if [ -z "$cursor" ]; then
        skp "journal cursor support is unavailable. Startup dispatch cannot be observed safely"
    else
        second=$(date +%S); second=${second#0}; [ -n "$second" ] || second=0
        # Do not build the fixture in the final ten seconds of a minute: file
        # writes plus systemd startup could cross the boundary and test the next
        # minute instead of the intended matching startup minute.
        [ "$second" -ge 50 ] && sleep 11
        hour=$(date +%H)
        minute=$(date +%M)
        # 10# is unavailable in some /bin/sh implementations. Strip one leading
        # zero so JSON carries ordinary decimal values.
        hour=${hour#0}; minute=${minute#0}
        [ -n "$hour" ] || hour=0
        [ -n "$minute" ] || minute=0
        printf '{"enabled": true, "type": "daily", "day": 1, "hour": %s, "minute": %s}\n' \
            "$hour" "$minute" > "$TMP" \
            && chown www-data:www-data "$TMP" \
            && chmod 640 "$TMP" \
            && mv "$TMP" "$CONFIG" \
            || { bad "could not install the temporary schedule"; restore_state; }

        if [ "$restored" != "1" ]; then
            systemctl restart scheduled_restart >/dev/null 2>&1
            sleep 3
            new_log=$(journalctl --after-cursor="$cursor" -u scheduled_restart --no-pager 2>/dev/null)
            printf '%s\n' "$new_log" | grep -q 'matching startup minute skipped' \
                && ok "a matching startup minute is explicitly skipped" \
                || bad "the worker did not report the startup-minute guard"
            if printf '%s\n' "$new_log" | grep -q 'scheduled restart triggered'; then
                bad "the worker attempted a scheduled reboot during its startup minute"
            else
                ok "no reboot dispatch was attempted during the startup minute"
            fi
        fi
    fi
fi

restore_state || fail=$((fail + 1))
trap - EXIT INT TERM

echo ""
echo "passes: $pass, failures: $fail, skipped: $skip"
[ "$fail" -eq 0 ]
