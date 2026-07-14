#!/bin/sh
# STATUS: the design this validates is NOT in use. The A/B release-slot idea
# was evaluated and rejected (2026-07-14) as more complexity than it fixes at
# the project's current scale; the shipped updater keeps the stage/mv-swap
# design in update_quecdeck.sh, and crash-mid-swap recovery is accepted as a
# manual ADB/SSH job. This script is retained as the ready-made go/no-go
# gate in case A/B is ever revisited (e.g. a much larger install base, or
# trial/commit auto-revert wanted as a feature). It has never been run on a
# device. See the update-system notes for the full decision record.
#
# Verifies the device assumptions behind the proposed A/B release-slot design,
# where /usrdata/quecdeck becomes a symlink to a versioned release directory
# and an update/rollback is a single atomic rename of that symlink. Run as root:
#
#     sh device-test-symlinkswap.sh
#
# Run it when evaluating A/B, and re-run when the answers might have changed:
# after a firmware update (SELinux policy, busybox/coreutils, sudo can all
# change), or on a different modem than the RM520N-GL it targets. A failure in
# Test 1 or Test 3 blocks the A/B design as drafted; the verdict says what to do.
#
# It checks:
#   1. Some mv on this device does a true rename() onto an existing symlink
#      (mv -T semantics) instead of moving the source INTO the link's target.
#   2. Rapid flips are gap-free: a concurrent reader never sees a moment where
#      a path through the symlink fails to resolve (best-effort probe; shell
#      granularity can miss nanosecond gaps, but unlink+recreate shows up).
#   3. A sudoers rule naming a path THROUGH the symlink still matches after
#      the link is flipped to a different release dir (www-data -> root, the
#      updater/watchcat sudo pattern). If this fails, rules must name resolved
#      slot paths and be rewritten at flip time.
#   4. www-data can read a file through the symlink under SEAndroid (the
#      lighttpd docroot / CGI sourcing path after a flip).
#
# Non-destructive: everything lives under /usrdata/.qdsymtest plus one
# uniquely-named sudoers fragment; both are removed on every exit path
# (including Ctrl-C). The sudoers fragment only whitelists a root-owned 700
# probe script inside the test dir, and is deleted before the dirs are.

BASE=/usrdata/.qdsymtest
SUDOERS_FILE=/opt/etc/sudoers.d/qdsymtest
SUDO=/opt/bin/sudo
pass=0; fail=0; warn=0

ok()   { echo "  PASS: $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL: $1"; fail=$((fail+1)); }
note() { echo "  WARN: $1"; warn=$((warn+1)); }

cleanup() {
    # Sudoers fragment first: never leave a rule pointing at a removable path.
    rm -f "$SUDOERS_FILE" 2>/dev/null
    [ -n "$reader_pid" ] && kill "$reader_pid" 2>/dev/null
    rm -rf "$BASE" 2>/dev/null
    echo ""
    echo "Cleaned up ($BASE and $SUDOERS_FILE removed)."
}
reader_pid=""
trap 'cleanup' EXIT INT TERM

echo "=================================================================="
echo " QuecDeck A/B symlink-flip assumption verification"
echo "=================================================================="

# ---- environment -------------------------------------------------------
echo ""
echo "[Environment]"
if command -v getenforce >/dev/null 2>&1; then
    echo "  SELinux: $(getenforce)"
elif [ -r /sys/fs/selinux/enforce ]; then
    echo "  SELinux: enforce=$(cat /sys/fs/selinux/enforce 2>/dev/null)"
else
    echo "  SELinux: no getenforce / enforce node (likely disabled)"
fi
for c in mv /opt/bin/mv; do
    command -v "$c" >/dev/null 2>&1 || continue
    echo "  $c -> $($c --version 2>/dev/null | head -1 || echo 'no --version (busybox?)')"
done
[ -x "$SUDO" ] && echo "  sudo: $SUDO present" || echo "  sudo: $SUDO MISSING (Test 3 will fail)"
id www-data >/dev/null 2>&1 && echo "  user www-data exists" || echo "  user www-data MISSING (Tests 3/4 will fail)"

# ---- setup -------------------------------------------------------------
rm -rf "$BASE"
mkdir -m 755 "$BASE" || { echo "FATAL: cannot create $BASE"; exit 1; }
mkdir -m 755 "$BASE/relA" "$BASE/relB"
echo A > "$BASE/relA/marker"; echo B > "$BASE/relB/marker"
chmod 644 "$BASE/relA/marker" "$BASE/relB/marker"
ln -s relA "$BASE/current" || { echo "FATAL: cannot create symlink on /usrdata"; exit 1; }

# ---- Test 1: atomic rename onto an existing symlink --------------------
echo ""
echo "[Test 1] mv -T renames a temp symlink OVER the live one (no nesting)"
MV_T=""
for c in mv /opt/bin/mv; do
    command -v "$c" >/dev/null 2>&1 || continue
    ln -s relB "$BASE/current.tmp" 2>/dev/null
    if "$c" -T "$BASE/current.tmp" "$BASE/current" 2>/dev/null; then
        target=$(readlink "$BASE/current" 2>/dev/null)
        if [ "$target" = "relB" ] && [ ! -e "$BASE/relA/current.tmp" ]; then
            ok "'$c -T' replaced the symlink in place (current -> relB)"
            MV_T="$c"
            # Reset to relA for the next candidate / later tests.
            ln -s relA "$BASE/current.tmp" && "$c" -T "$BASE/current.tmp" "$BASE/current"
            continue
        fi
        bad "'$c -T' ran but left wrong state (current -> ${target:-?}; check for nesting)"
    else
        note "'$c' does not support -T (busybox mv nests into the target dir)"
    fi
    rm -f "$BASE/current.tmp" "$BASE/relA/current.tmp" "$BASE/relB/current.tmp" 2>/dev/null
    # Re-point at relA in case a candidate left it flipped.
    rm -f "$BASE/current"; ln -s relA "$BASE/current"
done
if [ -z "$MV_T" ]; then
    bad "no mv candidate performs an atomic symlink replace; A/B needs coreutils mv (opkg install coreutils-mv)"
fi

# ---- Test 2: concurrent reader sees no resolution gap ------------------
echo ""
echo "[Test 2] 200 rapid flips with a concurrent reader (gap probe)"
if [ -n "$MV_T" ]; then
    GAPFILE="$BASE/gaps"
    ( while [ -d "$BASE" ]; do
          [ -e "$BASE/current/marker" ] || echo gap >> "$GAPFILE"
      done ) &
    reader_pid=$!
    i=0
    while [ "$i" -lt 200 ]; do
        [ $((i % 2)) -eq 0 ] && t=relB || t=relA
        ln -s "$t" "$BASE/current.tmp"
        "$MV_T" -T "$BASE/current.tmp" "$BASE/current" || { bad "flip $i failed"; break; }
        i=$((i+1))
    done
    kill "$reader_pid" 2>/dev/null; wait "$reader_pid" 2>/dev/null; reader_pid=""
    if [ -s "$GAPFILE" ]; then
        bad "reader saw $(wc -l < "$GAPFILE" | tr -d ' ') unresolvable moments across 200 flips (NOT atomic)"
    else
        ok "no resolution gap observed across 200 flips (best-effort; consistent with rename())"
    fi
    # Leave current -> relA for the sudo tests.
    rm -f "$BASE/current"; ln -s relA "$BASE/current"
else
    note "skipped (no working mv -T)"
fi

# ---- Test 3: sudoers rule matches through the symlink ------------------
echo ""
echo "[Test 3] sudoers rule naming the symlink path survives a flip"
if [ -x "$SUDO" ] && id www-data >/dev/null 2>&1; then
    # The test drops to www-data via root's own sudo; verify that hop first so
    # a failure below unambiguously means the RULE didn't match.
    if [ "$("$SUDO" -u www-data id -un 2>/dev/null)" != "www-data" ]; then
        bad "root cannot 'sudo -u www-data' on this device; run the inner command as www-data another way (su?)"
    fi
    printf '#!/bin/sh\necho probe-A\n' > "$BASE/relA/probe.sh"
    printf '#!/bin/sh\necho probe-B\n' > "$BASE/relB/probe.sh"
    chown root:root "$BASE/relA/probe.sh" "$BASE/relB/probe.sh"
    chmod 700 "$BASE/relA/probe.sh" "$BASE/relB/probe.sh"
    printf 'www-data ALL = (root) NOPASSWD: %s/current/probe.sh\n' "$BASE" > "$SUDOERS_FILE"
    chmod 440 "$SUDOERS_FILE"

    out=$("$SUDO" -u www-data "$SUDO" -n "$BASE/current/probe.sh" 2>/dev/null)
    if [ "$out" = "probe-A" ]; then
        ok "www-data ran the probe through the symlink (slot A)"
    else
        bad "sudo denied or failed through the symlink path (got '${out:-nothing}')"
    fi

    if [ -n "$MV_T" ]; then
        ln -s relB "$BASE/current.tmp" && "$MV_T" -T "$BASE/current.tmp" "$BASE/current"
        out=$("$SUDO" -u www-data "$SUDO" -n "$BASE/current/probe.sh" 2>/dev/null)
        if [ "$out" = "probe-B" ]; then
            ok "same rule still matches after the flip and runs the NEW slot's script"
        else
            bad "rule no longer matches after flip (got '${out:-nothing}'); rules would need rewriting per release"
        fi
    else
        note "flip half skipped (no working mv -T)"
    fi
    rm -f "$SUDOERS_FILE"
else
    bad "prerequisites missing ($SUDO and user www-data); cannot verify the sudo path"
fi

# ---- Test 4: www-data reads through the symlink (SELinux/DAC) ----------
echo ""
echo "[Test 4] www-data can read file content through the symlink"
if [ -x "$SUDO" ] && id www-data >/dev/null 2>&1; then
    got=$("$SUDO" -u www-data cat "$BASE/current/marker" 2>/dev/null)
    if [ "$got" = "A" ] || [ "$got" = "B" ]; then
        ok "www-data read through the link (got '$got'; lighttpd docroot path is fine)"
    else
        bad "www-data could not read through the link (SELinux label or DAC issue)"
    fi
else
    note "skipped (needs $SUDO and www-data)"
fi

# ---- verdict ----------------------------------------------------------
echo ""
echo "=================================================================="
echo " Results: $pass passed, $fail failed, $warn warnings"
echo "=================================================================="
if [ "$fail" -eq 0 ]; then
    echo " VERDICT: A/B symlink flip is SAFE on this device."
    [ -n "$MV_T" ] && echo "          Use '$MV_T -T' for the flip."
else
    echo " VERDICT: an A/B assumption FAILED above."
    echo "          Test 1 fail: install coreutils mv (opkg) or find another"
    echo "          atomic-rename primitive before building the design."
    echo "          Test 3 fail: sudoers must name resolved slot paths and be"
    echo "          rewritten at flip time (costs the single-pointer elegance)."
fi
echo "=================================================================="
# cleanup() runs on EXIT.
