#!/bin/sh
# Verifies the assumptions the self-updater depends on for its transient install
# unit. The updater writes install_quecdeck.service to /run/systemd/system
# (tmpfs) and lets that service do the rootfs writes for the swap; this script
# confirms that whole path works on the device. Run as root:
#
#     sh device-test-rununit.sh
#
# Re-run this when it might no longer hold: after a firmware or systemd update
# (SELinux policy / systemd behaviour can change), or when bringing QuecDeck up
# on a different modem than the RM520N-GL it is tested on. A failure here means
# the updater cannot install unit changes and would need a fix before shipping.
#
# It checks:
#   1. Can a HAND-WRITTEN unit in /run/systemd/system load and start under this
#      device's SELinux? (The risk: systemd-run works via the D-Bus API, which
#      sets the SELinux context; a plain `cat >` file may not.)
#   2. Can a service launched from such a unit remount / rw and write /lib
#      (the installer's actual job)?
#   3. Does `systemd-run` work for the same write, as a fallback if (1) fails?
#   4. Does `systemctl is-active <name>` work for a /run unit (mutual exclusion)?
#
# Non-destructive: creates only uniquely-named test units and /tmp sentinels,
# removes them, and restores / to read-only on every exit path (including Ctrl-C).

PREFIX="qdrwtest"
RUNDIR="/run/systemd/system"
SENTINEL="/tmp/${PREFIX}.out"
LIBPROBE="/lib/systemd/system/.${PREFIX}.probe"
pass=0; fail=0; warn=0

ok()   { echo "  PASS: $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL: $1"; fail=$((fail+1)); }
note() { echo "  WARN: $1"; warn=$((warn+1)); }

cleanup() {
    rm -f "$RUNDIR/${PREFIX}"*.service 2>/dev/null
    rm -f "$SENTINEL" "$LIBPROBE" 2>/dev/null
    systemctl reset-failed "${PREFIX}-run" 2>/dev/null
    systemctl daemon-reload 2>/dev/null
    # Always leave the rootfs read-only, whatever the tests did.
    mount -o remount,ro / 2>/dev/null
    echo ""
    echo "Cleaned up. / is now: $(rootfs_state)"
}
rootfs_state() {
    mount | awk '$3=="/"||$0 ~ / \/ / {print}' | grep -oE '[(,]r[ow]' | head -1 | tr -d '(,'
}
trap 'cleanup' EXIT INT TERM

echo "=================================================================="
echo " QuecDeck /run-unit + rootfs-write verification"
echo "=================================================================="

# ---- environment -------------------------------------------------------
echo ""
echo "[Environment]"
if command -v getenforce >/dev/null 2>&1; then
    echo "  SELinux: $(getenforce)"
elif [ -r /sys/fs/selinux/enforce ]; then
    e=$(cat /sys/fs/selinux/enforce 2>/dev/null)
    [ "$e" = "1" ] && echo "  SELinux: Enforcing (/sys/fs/selinux/enforce=1)" || echo "  SELinux: Permissive/other (enforce=$e)"
else
    echo "  SELinux: no getenforce and no /sys/fs/selinux/enforce (likely disabled)"
fi
echo "  systemd: $(systemctl --version 2>/dev/null | head -1)"
echo "  rootfs mount state: $(rootfs_state)"
if [ -d "$RUNDIR" ]; then
    echo "  $RUNDIR exists"
else
    echo "  $RUNDIR MISSING -- creating (systemd normally provides it)"
    mkdir -p "$RUNDIR" 2>/dev/null || echo "  (could not create $RUNDIR)"
fi
if [ -e /lib/systemd/system/install_quecdeck.service ]; then
    echo "  NOTE: leftover /lib/systemd/system/install_quecdeck.service present (inert; from a prior run)"
fi

# ---- Test 1: hand-written /run unit loads and runs ---------------------
echo ""
echo "[Test 1] Hand-written unit in $RUNDIR loads and starts"
U1="${PREFIX}-run"
rm -f "$SENTINEL"
if cat > "$RUNDIR/${U1}.service" <<EOF
[Unit]
Description=QuecDeck rununit test 1
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'echo ran > $SENTINEL'
EOF
then
    ok "wrote $RUNDIR/${U1}.service (no remount needed -- tmpfs)"
else
    bad "could not write to $RUNDIR (tmpfs write failed)"
fi
systemctl daemon-reload 2>/dev/null
if systemctl start "${U1}.service" 2>/tmp/${PREFIX}.err; then
    ok "systemctl start succeeded (rc 0)"
else
    bad "systemctl start failed (rc $?) -- see below"
    sed 's/^/        /' /tmp/${PREFIX}.err 2>/dev/null
fi
if [ "$(cat "$SENTINEL" 2>/dev/null)" = "ran" ]; then
    ok "the unit actually executed (sentinel written)"
else
    bad "unit did not execute (no sentinel) -- SELinux may have blocked load/exec"
fi

# ---- Test 4: is-active works by name for a /run unit -------------------
echo ""
echo "[Test 4] 'systemctl is-active' resolves the /run unit by name"
st=$(systemctl is-active "${U1}.service" 2>/dev/null)
# oneshot with no RemainAfterExit reports inactive after a clean run; the point
# is that is-active RESOLVES it (not 'unknown'), which the mutex logic relies on.
case "$st" in
    inactive|active|failed|activating) ok "is-active returns a real state: '$st'" ;;
    *) note "is-active returned '$st' (mutex uses is-active; confirm this still gates correctly)" ;;
esac
rm -f "$SENTINEL" /tmp/${PREFIX}.err

# ---- Test 2: a /run-launched service can remount rw and write /lib -----
echo ""
echo "[Test 2] Service from a /run unit remounts / rw and writes /lib"
U2="${PREFIX}-write"
rm -f "$SENTINEL" "$LIBPROBE"
cat > "$RUNDIR/${U2}.service" <<EOF
[Unit]
Description=QuecDeck rununit test 2 (rootfs write)
[Service]
Type=oneshot
ExecStart=/bin/sh -c 'mount -o remount,rw / && touch $LIBPROBE && echo wrote > $SENTINEL && rm -f $LIBPROBE; mount -o remount,ro /'
EOF
systemctl daemon-reload 2>/dev/null
systemctl start "${U2}.service" 2>/dev/null
if [ "$(cat "$SENTINEL" 2>/dev/null)" = "wrote" ]; then
    ok "the service remounted rw and wrote /lib (this is the installer's core op under B)"
else
    bad "the service could NOT write /lib -- B would fail; use the systemd-run fallback"
fi
if [ "$(rootfs_state)" = "ro" ]; then
    ok "the service restored / to read-only"
else
    note "/ not read-only after the test service (cleanup will fix it, but note the service's own remount ro)"
fi
rm -f "$SENTINEL"

# ---- Test 3: systemd-run fallback path --------------------------------
echo ""
echo "[Test 3] Fallback: systemd-run (D-Bus API) can do the same write"
rm -f "$SENTINEL"
if command -v systemd-run >/dev/null 2>&1; then
    systemd-run --wait --collect --unit="${PREFIX}-srun" /bin/sh -c \
        "mount -o remount,rw / && touch $LIBPROBE && echo wrote > $SENTINEL && rm -f $LIBPROBE; mount -o remount,ro /" \
        >/dev/null 2>&1
    if [ "$(cat "$SENTINEL" 2>/dev/null)" = "wrote" ]; then
        ok "systemd-run write succeeded (fallback is available if Test 1/2 fail)"
    else
        note "systemd-run did not complete the write (check 'journalctl' if available)"
    fi
else
    note "systemd-run not present -- fallback unavailable; Test 1/2 must pass for B"
fi
rm -f "$SENTINEL"

# ---- verdict ----------------------------------------------------------
echo ""
echo "=================================================================="
echo " Results: $pass passed, $fail failed, $warn warnings"
echo "=================================================================="
if [ "$fail" -eq 0 ]; then
    echo " VERDICT: Approach B is SAFE on this device -- a hand-written /run unit"
    echo "          loads under SELinux and can perform the rootfs writes."
else
    echo " VERDICT: Approach B (hand-written /run unit) has a FAILURE above."
    echo "          If Test 3 (systemd-run) passed, use that fallback to create"
    echo "          the install unit instead of a hand-written file."
fi
echo "=================================================================="
# cleanup() runs on EXIT.
