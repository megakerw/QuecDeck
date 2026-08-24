#!/bin/sh
# Two-phase monitoring acceptance test for a real QuecDeck update.
#
# This test does not start an update. Run it immediately before and after a
# normal update of an already-installed current-generation release:
#
#   sh device-test-update-monitoring.sh prepare
#   # Run the update from the UI or installer and wait for it to finish.
#   sh device-test-update-monitoring.sh verify
#
# Repeat once with both features enabled and once with both disabled. `prepare`
# starts a small read-only observer. Once the old release directory appears, it
# treats the transaction as active and records any monitoring worker that comes
# back before the updater finishes status publication, unit cleanup, and the
# read-only root remount.

STATE_DIR=/usrdata/quecdeck-update-monitoring-test
STATUS=/run/quecdeck/update.status
QUECDECK=/usrdata/quecdeck
WATCHCAT_CONFIG=$QUECDECK/var/watchcat.json
SCHEDULED_CONFIG=$QUECDECK/var/scheduled_restart.json
TRANSIENT_UNIT=/run/systemd/system/install_quecdeck.service

hash_or_missing() {
    [ -f "$1" ] && sha256sum "$1" | awk '{print $1}' || echo missing
}

config_enabled() {
    [ -s "$1" ] && grep -q '"enabled"[[:space:]]*:[[:space:]]*true' "$1"
}

unit_state_matches() { # unit_state_matches <unit> <enabled|disabled>
    state=$(systemctl is-active "$1" 2>/dev/null)
    if [ "$2" = enabled ]; then
        [ "$state" = active ]
    else
        [ "$state" = inactive ] || [ "$state" = failed ] || [ "$state" = unknown ]
    fi
}

root_mode() {
    mount | awk '$3=="/"||$0 ~ / \/ / {print}' | grep -oE '[(,]r[ow]' | head -1 | tr -d '(,'
}

watch_update() { # internal: watch_update <state-dir>
    dir=$1
    transaction_seen=0
    remaining=1800
    while [ "$remaining" -gt 0 ] && [ ! -e "$dir/stop" ]; do
        if [ -d "${QUECDECK}.old" ]; then
            transaction_seen=1
            : > "$dir/transaction-seen"
        fi
        if [ "$transaction_seen" = "1" ]; then
            status=$(cat "$STATUS" 2>/dev/null)
            case "$status" in
                done|failed|failed:rollback_ok|failed:rollback_failed)
                    if [ "$(root_mode)" = ro ] && [ ! -e "$TRANSIENT_UNIT" ]; then
                        : > "$dir/transaction-complete"
                        break
                    fi
                    ;;
            esac
            for unit in watchcat scheduled_restart; do
                if systemctl is-active "$unit" >/dev/null 2>&1; then
                    printf '%s active at uptime %s while status=%s, root=%s, transient=%s\n' \
                        "$unit" "$(cut -d' ' -f1 /proc/uptime)" "${status:-missing}" \
                        "$(root_mode)" "$([ -e "$TRANSIENT_UNIT" ] && echo present || echo absent)" \
                        >> "$dir/violations"
                fi
            done
        fi
        remaining=$((remaining - 1))
        sleep 1
    done
}

if [ "$1" = _watch ]; then
    watch_update "$2"
    : > "$2/observer-stopped"
    exit 0
fi

[ "$(id -u)" = "0" ] || { echo "FATAL: must run as root"; exit 1; }

case "$1" in
    prepare)
        [ -d "$QUECDECK/www" ] || { echo "FATAL: QuecDeck is not installed"; exit 1; }
        [ ! -e "${QUECDECK}.old" ] || {
            echo "FATAL: ${QUECDECK}.old already exists. Resolve the stale update backup first"
            exit 1
        }
        [ ! -e "$STATE_DIR" ] || {
            echo "FATAL: an acceptance run already exists. Run verify or remove $STATE_DIR"
            exit 1
        }
        mkdir -m 700 "$STATE_DIR" || exit 1
        hash_or_missing "$WATCHCAT_CONFIG" > "$STATE_DIR/watchcat.hash"
        hash_or_missing "$SCHEDULED_CONFIG" > "$STATE_DIR/scheduled.hash"
        config_enabled "$WATCHCAT_CONFIG" && echo enabled > "$STATE_DIR/watchcat.expected" \
            || echo disabled > "$STATE_DIR/watchcat.expected"
        config_enabled "$SCHEDULED_CONFIG" && echo enabled > "$STATE_DIR/scheduled.expected" \
            || echo disabled > "$STATE_DIR/scheduled.expected"
        cat /proc/sys/kernel/random/boot_id > "$STATE_DIR/boot-id"
        self=$(readlink -f "$0" 2>/dev/null)
        [ -n "$self" ] || self=$0
        nohup /bin/sh "$self" _watch "$STATE_DIR" >/dev/null 2>&1 &
        echo $! > "$STATE_DIR/watcher.pid"
        sleep 1
        kill -0 "$(cat "$STATE_DIR/watcher.pid")" 2>/dev/null || {
            echo "FATAL: update observer did not start"
            rm -rf "$STATE_DIR"
            exit 1
        }
        echo "Prepared. Run the update now, wait for it to finish, then run:"
        echo "  sh $0 verify"
        ;;

    verify)
        [ -d "$STATE_DIR" ] || { echo "FATAL: no prepared acceptance run"; exit 1; }
        : > "$STATE_DIR/stop"
        pass=0 fail=0
        ok() { echo "  PASS: $1"; pass=$((pass + 1)); }
        bad() { echo "  FAIL: $1"; fail=$((fail + 1)); }

        remaining=5
        while [ "$remaining" -gt 0 ] && [ ! -e "$STATE_DIR/observer-stopped" ]; do
            remaining=$((remaining - 1))
            sleep 1
        done
        [ -e "$STATE_DIR/observer-stopped" ] \
            && ok "the update observer stopped cleanly" \
            || bad "the update observer did not stop cleanly"

        [ "$(cat /proc/sys/kernel/random/boot_id)" = "$(cat "$STATE_DIR/boot-id")" ] \
            && ok "the modem did not reboot during the update" \
            || bad "the boot ID changed during the update"
        [ "$(cat "$STATUS" 2>/dev/null)" = done ] \
            && ok "the updater published done" || bad "update status is not done"
        [ -e "$STATE_DIR/transaction-seen" ] \
            && ok "the observer saw the release transaction" \
            || bad "the release transaction was not observed"
        [ -e "$STATE_DIR/transaction-complete" ] \
            && ok "the observer saw update cleanup complete" \
            || bad "the complete update boundary was not observed"
        [ ! -s "$STATE_DIR/violations" ] \
            && ok "monitoring stayed stopped throughout the transaction" \
            || { bad "a monitoring worker ran before update cleanup completed"; cat "$STATE_DIR/violations"; }
        [ "$(hash_or_missing "$WATCHCAT_CONFIG")" = "$(cat "$STATE_DIR/watchcat.hash")" ] \
            && ok "Watchcat configuration bytes were preserved" \
            || bad "Watchcat configuration changed"
        [ "$(hash_or_missing "$SCHEDULED_CONFIG")" = "$(cat "$STATE_DIR/scheduled.hash")" ] \
            && ok "Scheduled Restart configuration bytes were preserved" \
            || bad "Scheduled Restart configuration changed"

        # Give enabled workers a short final-start allowance after status=done.
        remaining=10
        while [ "$remaining" -gt 0 ]; do
            wc_expected=$(cat "$STATE_DIR/watchcat.expected")
            sr_expected=$(cat "$STATE_DIR/scheduled.expected")
            unit_state_matches watchcat "$wc_expected" \
                && unit_state_matches scheduled_restart "$sr_expected" && break
            remaining=$((remaining - 1))
            sleep 1
        done
        unit_state_matches watchcat "$(cat "$STATE_DIR/watchcat.expected")" \
            && ok "Watchcat final state matches its configuration" \
            || bad "Watchcat final state does not match its configuration"
        unit_state_matches scheduled_restart "$(cat "$STATE_DIR/scheduled.expected")" \
            && ok "Scheduled Restart final state matches its configuration" \
            || bad "Scheduled Restart final state does not match its configuration"
        [ -L /lib/systemd/system/multi-user.target.wants/watchcat.service ] \
            && [ -L /lib/systemd/system/multi-user.target.wants/scheduled_restart.service ] \
            && ok "both monitoring units remain boot-enabled" \
            || bad "a monitoring boot link is missing"
        [ "$(root_mode)" = ro ] && ok "the root filesystem is read-only" \
            || bad "the root filesystem is not read-only"

        echo ""
        echo "passes: $pass, failures: $fail"
        if [ "$fail" -eq 0 ]; then
            rm -rf "$STATE_DIR"
            exit 0
        fi
        echo "Diagnostic state retained at $STATE_DIR"
        exit 1
        ;;

    *)
        echo "Usage: $0 prepare|verify" >&2
        exit 2
        ;;
esac
