#!/bin/sh
# Automated release gate for the updater: drives the REAL updater on the live
# device and asserts the outcomes of tools/release-gate-updater.md steps 1-6.
# Browser-side checks (login, session survival, update-page ack) and the
# post-tag web-path smoke test (step 7) remain manual.
#
# THIS PERFORMS REAL (RE)INSTALLS of the running system. Expect 10-25 minutes
# and a working network. The updater's own rollback protects each run, but do
# not start this on a device you cannot recover over ADB/SSH if the worst
# happens.
#
# Usage (as root, after: adb push update_quecdeck.sh /tmp/test_update.sh):
#
#     sh device-test-updategate.sh <current-tag> [older-tag] [term-only]
#
#     <current-tag>  tag matching the installed version, e.g. v1.0.16
#     [older-tag]    any earlier published tag; enables the downgrade-block
#                    test (3). The downgrade-OVERRIDE test (6) is deliberately
#                    not automated: it leaves the device on the older release
#                    mid-run, so a crash strands it there. Run it manually.
#     term-only      skip tests 1-4 and run only the SIGTERM-mid-swap test
#                    (plus its restore install), for re-runs after a WARN.

CURRENT="${1:-}"
OLDER="${2:-}"
TERM_ONLY=0
[ "$OLDER" = "term-only" ] && { TERM_ONLY=1; OLDER=""; }
[ "${3:-}" = "term-only" ] && TERM_ONLY=1
UPDATER=/tmp/test_update.sh
LOG=/tmp/install_quecdeck.log
STATUS=/tmp/quecdeck_update.status
PLOG=/usrdata/quecdeck_last_update.log
ACCESS=/tmp/quecdeck/logs/access_events.jsonl
pass=0; fail=0; warn=0

ok()   { echo "  PASS: $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL: $1"; fail=$((fail+1)); }
note() { echo "  WARN: $1"; warn=$((warn+1)); }

rootfs_state() {
    mount | awk '$3=="/"||$0 ~ / \/ / {print}' | grep -oE '[(,]r[ow]' | head -1 | tr -d '(,'
}

reset_state() {
    systemctl reset-failed install_quecdeck 2>/dev/null
    rm -f "$STATUS"
}

_bg_pid=""
cleanup() {
    [ -n "$_bg_pid" ] && kill "$_bg_pid" 2>/dev/null
    reset_state
    echo ""
    echo "Cleaned up. / is: $(rootfs_state); status file cleared."
}
trap 'cleanup' EXIT INT TERM

# Wait until the status file holds a terminal value; echoes it. Empty on timeout.
wait_terminal() { # wait_terminal <timeout-seconds>
    _wt_i=0
    while [ "$_wt_i" -lt "$1" ]; do
        case "$(cat "$STATUS" 2>/dev/null)" in
            done|failed|failed:rollback_ok|failed:rollback_failed)
                cat "$STATUS"; return 0 ;;
        esac
        sleep 1; _wt_i=$((_wt_i+1))
    done
    return 1
}

[ "$(id -u)" = "0" ] || { echo "FATAL: run as root."; exit 1; }
[ -f "$UPDATER" ] || { echo "FATAL: $UPDATER missing (adb push update_quecdeck.sh /tmp/test_update.sh)."; exit 1; }
case "$CURRENT" in
    v[0-9]*.[0-9]*.[0-9]*) ;;
    *) echo "Usage: sh device-test-updategate.sh <current-tag> [older-tag]"; exit 1 ;;
esac
_installed=$(cat /usrdata/quecdeck/version 2>/dev/null)
if [ "v$_installed" != "$CURRENT" ]; then
    echo "FATAL: installed version is '$_installed' but <current-tag> is '$CURRENT'."
    echo "Pass the tag that matches the installed version."
    exit 1
fi

IP=$(grep -o '<APIPAddr>[^<]*</APIPAddr>' /etc/data/mobileap_cfg.xml 2>/dev/null | sed 's/<[^>]*>//g')
IP=${IP:-192.168.225.1}

echo "=================================================================="
echo " QuecDeck updater release gate (current=$CURRENT older=${OLDER:-none})"
echo "=================================================================="

if [ "$TERM_ONLY" = "1" ]; then
    echo ""
    echo "term-only: skipping tests 1-4."
fi
# Tests 1-4 (skipped in term-only mode; body kept at original indent).
if [ "$TERM_ONLY" = "0" ]; then

# ---- Test 1: health probe in isolation, no side effects ----------------
echo ""
echo "[Test 1] Health probe standalone against $IP"
_acc_before=$(wc -l < "$ACCESS" 2>/dev/null || echo 0)
if /opt/bin/wget -q -O /dev/null --no-check-certificate "https://$IP/cgi-bin/auth_login"; then
    ok "probe rc=0 (303 chain followed to a 200)"
else
    bad "probe failed (rc $?) -- the post-swap health check WILL fail; stop here"
fi
_acc_after=$(wc -l < "$ACCESS" 2>/dev/null || echo 0)
[ "$_acc_before" = "$_acc_after" ] && ok "no access-log side effect" || bad "probe wrote to $ACCESS (GET branch must be side-effect free)"

# ---- Test 2: preflight failure (nonexistent tag) ------------------------
echo ""
echo "[Test 2] Nonexistent tag fails cleanly"
reset_state
bash "$UPDATER" v9.9.9 >/dev/null 2>&1
st=$(wait_terminal 120)
[ "$st" = "failed" ] && ok "status 'failed'" || bad "status '$st' (expected failed)"
grep -q "FATAL: Could not download release files" "$LOG" 2>/dev/null && ok "preflight FATAL logged" || bad "expected preflight FATAL not in log"
[ -e /usrdata/quecdeck.new ] && bad "stage dir left behind" || ok "nothing staged"
if [ -f "$PLOG" ] && cmp -s "$PLOG" "$LOG"; then
    ok "log persisted to $PLOG and matches"
else
    bad "persisted log missing or differs from $LOG"
fi
_pm=$(stat -c '%a %U' "$PLOG" 2>/dev/null)
[ "$_pm" = "600 root" ] && ok "persisted log is 600 root" || bad "persisted log perms '$_pm' (expected '600 root')"
[ "$(rootfs_state)" = "ro" ] && ok "/ back to read-only" || bad "/ left read-write"

# ---- Test 3: downgrade guard blocks -------------------------------------
echo ""
if [ -n "$OLDER" ]; then
    echo "[Test 3] Downgrade to $OLDER is refused"
    reset_state
    bash "$UPDATER" "$OLDER" >/dev/null 2>&1
    st=$(wait_terminal 120)
    [ "$st" = "failed" ] && ok "status 'failed'" || bad "status '$st' (expected failed)"
    grep -q "older than the installed" "$LOG" 2>/dev/null && ok "guard FATAL names the versions" || bad "guard FATAL not in log"
    grep -q "QUECDECK_ALLOW_DOWNGRADE" "$LOG" 2>/dev/null && ok "override hint present" || bad "override hint missing"
    [ "$(cat /usrdata/quecdeck/version 2>/dev/null)" = "$_installed" ] && ok "installed version untouched" || bad "version changed during a BLOCKED downgrade"
    [ "$(rootfs_state)" = "ro" ] && ok "/ back to read-only" || bad "/ left read-write"
else
    echo "[Test 3] SKIPPED: no older tag supplied"
    note "downgrade-block untested this run"
fi

# ---- Test 4: happy-path reinstall of the current tag --------------------
echo ""
echo "[Test 4] Full reinstall of $CURRENT (takes a few minutes)"
reset_state
bash "$UPDATER" "$CURRENT" >/dev/null 2>&1
st=$(wait_terminal 900)
[ "$st" = "done" ] && ok "status 'done'" || bad "status '$st' (expected done)"
grep -q "All checksums verified OK." "$LOG" && ok "staged checksums verified" || bad "checksum-verified marker missing"
grep -q "Switch complete." "$LOG" && ok "swap completed" || bad "'Switch complete.' missing"
if grep -q "lighttpd stayed up through the swap" "$LOG"; then
    ok "content-only run took the stays-up branch (CGI probe passed)"
elif grep -q "Verifying the new site responds" "$LOG"; then
    note "restart branch ran (conf/unit/pkg change or opkg upgrade) -- health check still passed"
else
    bad "no health-check marker in log"
fi
grep -q "ttyd installed." "$LOG" && ok "ttyd install + local-manifest verify passed" || note "ttyd not reinstalled cleanly (see log)"
grep -qi "download checksums for ttyd" "$LOG" && bad "ttyd fetched the manifest from the network (should use the local copy)" || ok "no network manifest fetch for ttyd"
[ "$(cat /usrdata/quecdeck/version 2>/dev/null)" = "${CURRENT#v}" ] && ok "version file is ${CURRENT#v}" || bad "version file wrong"
[ -s /usrdata/quecdeck/checksums.sha256 ] && ok "manifest retained on disk" || bad "manifest missing after install"
cmp -s "$PLOG" "$LOG" && ok "persisted log updated for this run" || bad "persisted log stale"
[ "$(rootfs_state)" = "ro" ] && ok "/ back to read-only" || bad "/ left read-write"
for _s in lighttpd atcmd-daemon firewall; do
    systemctl is-active "$_s" >/dev/null 2>&1 && ok "$_s active" || bad "$_s NOT active"
done
/opt/bin/wget -q -O /dev/null --no-check-certificate "https://$IP/cgi-bin/auth_login" && ok "site serving post-install" || bad "site NOT serving post-install"

fi # end of tests 1-4

# ---- Test 5: TERM mid-swap triggers the trap rollback -------------------
# Stop the install unit the moment the swap starts. Too early (before the
# marker) yields a plain 'failed' with the site untouched; too late yields
# 'done'. Both are harmless -- retry up to 3 attempts total.
echo ""
echo "[Test 5] SIGTERM mid-swap -> trap rollback (up to 3 attempts)"
_t5_result=""
_attempt=1
while [ "$_attempt" -le 3 ]; do
    reset_state
    # Clear the log BEFORE launching: it still holds the previous run's
    # "Preparing for swap" marker, which the watch loop below would match
    # instantly, firing the stop before the unit even starts.
    rm -f "$LOG"
    bash "$UPDATER" "$CURRENT" >/dev/null 2>&1 &
    _bg_pid=$!
    # Wait for the swap marker (staging can take minutes), then stop the unit.
    _w=0
    while [ "$_w" -lt 900 ]; do
        grep -q "Preparing for swap" "$LOG" 2>/dev/null && break
        # A terminal status before the marker means the run failed in staging.
        case "$(cat "$STATUS" 2>/dev/null)" in failed*) break ;; esac
        sleep 1; _w=$((_w+1))
    done
    systemctl stop install_quecdeck 2>/dev/null
    wait "$_bg_pid" 2>/dev/null
    _bg_pid=""
    st=$(wait_terminal 120)
    case "$st" in
        failed:rollback_ok) _t5_result="rolled_back"; break ;;
        done)   echo "  (attempt $_attempt: stop landed after completion; retrying)" ;;
        failed) echo "  (attempt $_attempt: stop landed before the swap; retrying)" ;;
        *)      _t5_result="broken:$st"; break ;;
    esac
    _attempt=$((_attempt+1))
done
if [ "$_t5_result" = "rolled_back" ]; then
    ok "status 'failed:rollback_ok'"
    grep -q "Install interrupted mid-swap; attempting rollback." "$LOG" && ok "trap rollback path ran (not the main-flow one)" || note "rollback ran via the main flow (stop landed after swap returned); trap path untested"
    grep -q "Rollback complete. Previous version restored." "$LOG" && ok "rollback completed" || bad "rollback-complete marker missing"
elif [ -z "$_t5_result" ]; then
    note "could not land the stop inside the swap window in 3 attempts; trap rollback untested (try manually)"
else
    bad "unexpected terminal state '$_t5_result' -- inspect the device before doing anything else"
fi
[ "$(cat /usrdata/quecdeck/version 2>/dev/null)" = "${CURRENT#v}" ] && ok "still on ${CURRENT#v}" || bad "version drifted"
[ "$(rootfs_state)" = "ro" ] && ok "/ back to read-only" || bad "/ left read-write"
for _s in lighttpd atcmd-daemon firewall; do
    systemctl is-active "$_s" >/dev/null 2>&1 && ok "$_s active" || bad "$_s NOT active"
done
/opt/bin/wget -q -O /dev/null --no-check-certificate "https://$IP/cgi-bin/auth_login" && ok "site serving after rollback test" || bad "site NOT serving after rollback test"

# If the rollback test left the previous content in place, the device content
# may predate $CURRENT's tree; re-assert with one final clean reinstall.
if [ "$_t5_result" = "rolled_back" ]; then
    echo ""
    echo "[Restore] Clean reinstall of $CURRENT after the rollback test"
    reset_state
    bash "$UPDATER" "$CURRENT" >/dev/null 2>&1
    st=$(wait_terminal 900)
    [ "$st" = "done" ] && ok "device restored to a clean $CURRENT install" || bad "restore install ended '$st' -- fix before release"
fi

# ---- verdict ------------------------------------------------------------
echo ""
echo "=================================================================="
echo " Results: $pass passed, $fail failed, $warn warnings"
echo "=================================================================="
if [ "$fail" -eq 0 ]; then
    echo " VERDICT: automated gate PASSED for $CURRENT."
    echo "          Remaining manual: browser login/session/UI-ack checks,"
    echo "          the downgrade-override test (gate doc step 6), and the"
    echo "          post-tag web-path smoke test (step 7)."
else
    echo " VERDICT: gate FAILED -- do not tag. See FAIL lines above."
fi
echo "=================================================================="
# cleanup() runs on EXIT.
