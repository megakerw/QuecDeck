#!/bin/sh
# Runtime assertion of the ownership rule that tests/host/guards/runtime-path.sh
# enforces in source form. The guard reads code, this checks the filesystem.
#
# THE RULE: a directory's owner is the only uid that writes inside it.
#
#   /run/quecdeck       root:root          root writes, www-data reads
#   /run/quecdeck-web   www-data:www-data  web runtime state
#   /usrdata/root     root:root  root's private home
#
# The guard cannot check any of this: a mode is a runtime fact, not a source
# pattern. Every mode bug in this codebase came from the same cause -- relying
# on the ambient umask for a security-relevant mode -- and none of them were
# visible to a source scan. Hence this file.
#
# Run as ROOT on a CONFIGURED device (setup complete):
#
#     sh device-test-runsplit.sh [/tmp/test_update.sh]
#
# Passing the candidate updater also exercises its real root-home migration
# function against an isolated fixture. It never points that test at /usrdata.
#
# Self-cleaning: it writes only throwaway probes, and the one update it triggers
# uses a non-existent tag that aborts before anything is staged.

SUDO=/opt/bin/sudo
RUN_UPDATE=/usrdata/quecdeck/script/run_update.sh
RUNDIR=/run/quecdeck
WEBDIR=/run/quecdeck-web
OLD_LOG=/tmp/install_quecdeck.log
OLD_STATUS=/tmp/quecdeck_update.status
PROBE=qdsplit-probe
CANDIDATE_UPDATER=${1:-}
HARDEN_FIXTURE=/run/qdsplit-root-home
HARDEN_OUTSIDE=/run/qdsplit-outside
MODE_FIXTURE=/run/qdsplit-stage-modes

pass=0; fail=0; warn=0
ok()   { echo "  PASS: $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL: $1"; fail=$((fail+1)); }
note() { echo "  NOTE: $1"; warn=$((warn+1)); }

cleanup() {
    rm -f "$OLD_LOG" "$OLD_STATUS" /tmp/qdsplit-decoy 2>/dev/null
    for _d in "$RUNDIR" "$WEBDIR" /usrdata/root /usrdata/root/bin; do
        rm -f "$_d/$PROBE" 2>/dev/null
    done
    "$SUDO" "$RUN_UPDATE" --clear-status >/dev/null 2>&1
    # Clear BOTH layouts unconditionally. "running" is not a terminal state, so
    # --clear-status will not remove it. A half-cleaned status leaves the UI
    # stuck on an update banner it can never dismiss.
    rm -f "$RUNDIR/update.status" "$OLD_STATUS" 2>/dev/null
    systemctl reset-failed install_quecdeck_fetch >/dev/null 2>&1
    systemctl reset-failed install_quecdeck >/dev/null 2>&1
    rm -rf "$HARDEN_FIXTURE" "$HARDEN_OUTSIDE" "$MODE_FIXTURE" 2>/dev/null
}
trap cleanup EXIT INT TERM

echo "=================================================================="
echo " QuecDeck ownership-rule check"
echo "=================================================================="
[ "$(id -u)" = "0" ] || { echo "FATAL: run as root."; exit 1; }
[ -x "$SUDO" ] || { echo "FATAL: $SUDO missing -- is QuecDeck installed?"; exit 1; }
id www-data >/dev/null 2>&1 || { echo "FATAL: www-data user missing."; exit 1; }

# The mutating sections assume the split is DEPLOYED. Against an older install
# they would report failures that only mean "not deployed", and section C would
# wedge the UI on a non-terminal "running" status written to the old path.
DEPLOYED=0
grep -q '/run/quecdeck-web' /usrdata/quecdeck/script/at-lib.sh 2>/dev/null && DEPLOYED=1
# Sections A2/A3 assert 0600 on www-data's files. That mode comes from a umask
# rather than a chmod, so gate on the installed library actually carrying it:
# against an older build the checks would report a regression that only means
# "not deployed".
UMASK_DEPLOYED=0
grep -qx 'umask 077' /usrdata/quecdeck/script/cgi-lib.sh 2>/dev/null && UMASK_DEPLOYED=1
[ "$DEPLOYED" = "0" ] && {
    echo ""
    echo "  !! Installed at-lib.sh does not use /run/quecdeck-web: the split is"
    echo "     NOT deployed. Running read-only checks only. Section C is skipped"
    echo "     to avoid a misleading verdict."
}

echo ""
echo "[Facts]"
for s in protected_symlinks protected_regular; do
    echo "  fs.$s = $(cat /proc/sys/fs/$s 2>/dev/null || echo unknown)"
done

# ---- U: loaded service masks ---------------------------------------------
# Source checks prove the unit files contain UMask=. This proves systemd has
# parsed and loaded the policy on the device. A copied unit without a matching
# daemon-reload would otherwise pass CI but leave the running service loose.
echo ""
echo "[U] loaded www-data service masks"
for _u in lighttpd connection-logger watchcat scheduled_restart; do
    _loaded_umask=$(systemctl show "$_u" -p UMask --value 2>/dev/null)
    if [ "$_loaded_umask" = "0077" ]; then
        ok "$_u loaded UMask=0077"
    elif [ "$UMASK_DEPLOYED" = "0" ]; then
        note "$_u loaded UMask=${_loaded_umask:-unknown}: expected until the umask release is deployed"
    else
        bad "$_u loaded UMask=${_loaded_umask:-unknown}, expected 0077 (unit missing, rejected, or not daemon-reloaded)"
    fi
done

# ---- A: the ownership rule, as a table -----------------------------------
# One check, applied uniformly. Written three times by hand it drifted: an
# earlier version accepted mode 775 for a root-owned boundary dir, which is
# group-writable and defeats the entire point.
#
# check_dir <path> <expected-owner> <deny|own>
#   deny = www-data must NOT be able to create a name here (root's trees)
#   own  = www-data owns it, so a write probe would trivially pass. The mode
#          check still has to hold, because "owner only" cuts both ways.
check_dir() {
    _p="$1"; _want_owner="$2"; _probe="$3"
    if [ ! -d "$_p" ]; then
        note "$_p absent"
        return
    fi
    _owner=$(ls -ld "$_p" | awk '{print $3}')
    _mode=$(stat -c %a "$_p" 2>/dev/null)
    [ "$_owner" = "$_want_owner" ] && ok "$_p owned by $_owner" \
        || bad "$_p owned by '$_owner', expected $_want_owner"

    # The invariant, stated once: nobody but the owner may write. Group and
    # other write bits are what turn any of these into a plantable directory.
    case "$_mode" in
        *[2367]) bad "$_p mode $_mode: OTHER can write. Any uid can plant a name the owner will later open." ;;
        *[2367]?) bad "$_p mode $_mode: GROUP can write. Any group member can plant a name the owner will later open." ;;
        *) ok "$_p mode $_mode (owner-only write)" ;;
    esac

    # DAC bits can mislead, so prove the restriction with a write attempt.
    if [ "$_probe" = "deny" ]; then
        if $SUDO -u www-data sh -c "echo x > $_p/$PROBE" 2>/dev/null; then
            bad "www-data WROTE into $_p despite the mode above"
            rm -f "$_p/$PROBE"
        else
            ok "www-data cannot write into $_p"
        fi
    fi
}

echo ""
echo "[A] directory ownership rule"
check_dir "$RUNDIR"           root     deny
check_dir "$WEBDIR"           www-data own
# Root's home is the one place this is PERSISTENT: /usrdata survives reboots
# and updates, so a writable root home turns a momentary www-data compromise
# into a permanent root backdoor (rewrite .profile, or a helper root runs).
check_dir /usrdata/root       root     deny
check_dir /usrdata/root/bin   root     deny

# Root writing into www-data's tree is the bug class the split removed. The
# atcli socket is www-data-owned because atcli drops privileges before binding.
if [ -d "$WEBDIR" ]; then
    _rootowned=$(find "$WEBDIR" -user root 2>/dev/null | head -5)
    [ -n "$_rootowned" ] \
        && bad "root-owned entries inside www-data's tree: $(printf '%s ' $_rootowned)" \
        || ok "no root-owned entries under $WEBDIR"
fi

# ---- A2: the creators produce the right mode on a FRESH tree --------------
# Section A only proves the current state. These directories may have been
# created long ago and would still pass if every creator were broken. This
# exercises the real shipped
# functions against a throwaway parent, which is what actually tests the fix.
# Non-destructive: nothing touches the live /run/quecdeck-web.
echo ""
echo "[A2] www-data creators seal a fresh parent (not just the existing one)"
FRESH=/tmp/qdfresh
$SUDO -u www-data rm -rf "$FRESH" 2>/dev/null; rm -rf "$FRESH" 2>/dev/null
# Exercise the cache and authentication-state creators as www-data. Run them
# www-data with their targets redirected, so a missing umask shows up as a
# loose parent or file. Exercising bf_fail here avoids a vacuous glob over a
# directory that _bf_file alone would leave empty.
$SUDO -u www-data bash -c "
    . /usrdata/quecdeck/script/cgi-lib.sh 2>/dev/null
    _CACHE_DIR=$FRESH/cache
    cache_write \"\$_CACHE_DIR/probe\" 'x' >/dev/null 2>&1
    bf_lock $FRESH/auth_failures 10.0.0.1 && bf_fail $FRESH/auth_failures 10.0.0.1
    bf_unlock
" >/dev/null 2>&1
if [ -d "$FRESH" ]; then
    for _d in "$FRESH" "$FRESH/cache" "$FRESH/auth_failures"; do
        [ -d "$_d" ] || continue
        _fm=$(stat -c %a "$_d" 2>/dev/null)
        case "$_fm" in
            *[2367]|*[2367]?)
                if [ "$DEPLOYED" = "0" ]; then
                    note "fresh $_d came out $_fm: the installed build still uses 'mkdir -p -m', which seals the leaf but not the parent. Expected until the split is deployed."
                else
                    bad "fresh $_d came out $_fm: a creator is missing its umask (mkdir -m seals the FINAL component only, so the parent takes the ambient umask)"
                fi ;;
            *) ok "fresh $_d created $_fm (owner-only write)" ;;
        esac
    done
    # The FILE mode, not just its parent. cache_write no longer chmods, so this
    # is what catches a lost umask. The probe ran under sudo, outside any unit,
    # so it can only pass if cgi-lib.sh sets the mask itself: a mode that came
    # from a unit's UMask= would show up here as 644.
    for _f in "$FRESH/cache/probe" "$FRESH/auth_failures"/*; do
        [ -f "$_f" ] || continue
        _ffm=$(stat -c %a "$_f" 2>/dev/null)
        if [ "$_ffm" = "600" ]; then
            ok "fresh $_f created 600 (holds without a unit UMask)"
        elif [ "$UMASK_DEPLOYED" = "0" ]; then
            note "fresh $_f came out $_ffm: installed cgi-lib.sh has no 'umask 077'. Expected until deployed."
        else
            bad "fresh $_f came out $_ffm, expected 600: cgi-lib.sh lost its 'umask 077', so the mode now depends on which unit invoked the caller"
        fi
    done

    # Two requests from one address must serialize around both the lockout
    # check and counter update. Without the transaction lock both can record a
    # first failure and the threshold is bypassed.
    _bf_parallel="$FRESH/auth_parallel"
    for _attempt in 1 2; do
        $SUDO -u www-data bash -c "
            . /usrdata/quecdeck/script/cgi-lib.sh 2>/dev/null
            BF_MAX_ATTEMPTS=2
            bf_lock $_bf_parallel 10.0.0.2 || exit 1
            bf_fail $_bf_parallel 10.0.0.2
            printf '%s\\n' \"\$BF_FAIL_RESULT\" > $_bf_parallel/result.$_attempt
            bf_unlock
        " &
    done
    wait
    _bf_results=$(cat "$_bf_parallel"/result.* 2>/dev/null | sort)
    if [ "$_bf_results" = "$(printf 'failed\nlocked')" ]; then
        ok "parallel failures from one client serialize and trigger lockout"
    else
        bad "parallel failures produced '$(printf '%s' "$_bf_results")', expected one failed and one locked"
    fi
    unset _bf_parallel _bf_results _attempt
else
    note "creators did not run. cgi-lib.sh may not be installed at the expected path"
fi
rm -rf "$FRESH" 2>/dev/null

# ---- A3: the live files, written by the real units ------------------------
# A2 covers the shell side under sudo. Only this covers auth.lua: it is Lua
# inside lighttpd, cannot source cgi-lib.sh and has no chmod, so its session
# rewrite is sealed by lighttpd.service's UMask= alone. The session filename IS
# the bearer token, so its mode is the second layer under the 0700 dir.
#
# sessions/ and cache/ only: both are written temp-file + rename, so a fresh
# mode appears on the next write. Appended files (logs/) keep whatever mode they
# were created with until /run clears at reboot, so a correct but recently
# updated device would fail there for no real reason.
echo ""
echo "[A3] live www-data files are owner-only"
_a3=0
for _d in "$WEBDIR/sessions" "$WEBDIR/cache"; do
    [ -d "$_d" ] || continue
    for _f in "$_d"/*; do
        [ -f "$_f" ] || continue
        _a3=$((_a3+1))
        _lm=$(stat -c %a "$_f" 2>/dev/null)
        if [ "$_lm" = "600" ]; then
            ok "$_f is 600"
        elif [ "$UMASK_DEPLOYED" = "0" ]; then
            note "$_f is $_lm: predates the umask change. Expected until deployed."
        else
            bad "$_f is $_lm, expected 600 (a session token or cached modem data)"
        fi
    done
done
[ "$_a3" = "0" ] && note "no session or cache files yet. Log in to the UI and load the dashboard, then re-run"
for _f in "$WEBDIR/logs"/*; do
    [ -f "$_f" ] || continue
    _lm=$(stat -c %a "$_f" 2>/dev/null)
    [ "$_lm" = "600" ] || note "$_f is $_lm: appended files keep their creation mode until /run clears at reboot"
done

# ---- C: the old paths are dead -------------------------------------------
echo ""
echo "[C] pre-split paths are no longer used"
if [ "$DEPLOYED" = "0" ]; then
    note "skipped: split not deployed on this device"
else
rm -f "$OLD_LOG" "$OLD_STATUS"
# Squat both old paths as www-data. Before the split this wedged updates
# permanently: fs.protected_regular denied root its own write, the fetch unit
# never started, and the status stuck at "running" with nothing to clear it.
$SUDO -u www-data sh -c "echo SQUATTED > $OLD_LOG" 2>/dev/null
$SUDO -u www-data sh -c "echo SQUATTED > $OLD_STATUS" 2>/dev/null
echo "  squatted both pre-split paths as www-data"

_missing_tag="v999999999.$(date +%s).$$"
$SUDO -u www-data "$SUDO" "$RUN_UPDATE" "$_missing_tag" >/tmp/qdsplit-out 2>&1
_rc=$?
grep -qi "permission denied" /tmp/qdsplit-out \
    && { bad "run_update.sh hit a permission error with the old paths squatted:"; sed 's/^/      /' /tmp/qdsplit-out; } \
    || ok "run_update.sh ran clean with both old paths squatted (rc=$_rc)"
rm -f /tmp/qdsplit-out
sleep 2
[ -f "$RUNDIR/install.log" ] \
    && ok "the run wrote $RUNDIR/install.log, not the squatted /tmp path" \
    || bad "no $RUNDIR/install.log after a trigger -- is the update still using /tmp?"
[ "$(cat "$OLD_LOG" 2>/dev/null)" = "SQUATTED" ] \
    && ok "the squatted $OLD_LOG was left untouched" \
    || bad "$OLD_LOG changed: something still writes the pre-split path"

# Poll rather than sample once. With no data session the fetch sits in
# wget --timeout=30 --tries=2 for up to a minute, so a single early read would
# see "running" and misreport the wedge. The wedge is specifically "running
# with NO unit alive to finish it", so test that, not the bare string.
_st=""; _i=0
while [ "$_i" -lt 45 ]; do
    _st=$(cat "$RUNDIR/update.status" 2>/dev/null)
    case "$_st" in failed*|done) break ;; esac
    _fetch=$(systemctl is-active install_quecdeck_fetch 2>/dev/null)
    _inst=$(systemctl is-active install_quecdeck 2>/dev/null)
    case "$_fetch$_inst" in *activating*|*active*) ;; *) [ "$_i" -gt 3 ] && break ;; esac
    _i=$((_i + 1)); sleep 2
done
case "$_st" in
    failed*|done) ok "status reached a terminal state ('$_st') in ~$((_i * 2))s" ;;
    running)
        case "$_fetch$_inst" in
            *activating*|*active*) note "still 'running' with a live unit: a slow or offline fetch, not a wedge" ;;
            *) bad "status 'running' with NO unit alive: the wedge is back" ;;
        esac ;;
    "") bad "no status file written -- run_update.sh could not write $RUNDIR" ;;
    *)  note "unexpected status '$_st'" ;;
esac
fi

# ---- C2: www-data can still READ what root writes ------------------------
# After C, so the log it asserts on actually exists: run before it, this could
# only ever emit notes.
echo ""
echo "[C2] www-data can read root's runtime files (the UI depends on it)"
for f in "$RUNDIR/atcmd.log" "$RUNDIR/install.log"; do
    if [ -f "$f" ]; then
        $SUDO -u www-data sh -c "cat $f" >/dev/null 2>&1 \
            && ok "www-data reads $(basename "$f") ($(ls -l "$f" | awk '{print $1, $3}'))" \
            || bad "www-data CANNOT read $f -- the UI log view will be empty"
    else
        note "$f not present yet"
    fi
done

# ---- E: one-time root-home migration ------------------------------------
echo ""
echo "[E] candidate updater safely migrates a legacy root home"
if [ -z "$CANDIDATE_UPDATER" ]; then
    note "skipped: pass a candidate update_quecdeck.sh to test its migration function"
elif [ ! -f "$CANDIDATE_UPDATER" ]; then
    bad "candidate updater not found: $CANDIDATE_UPDATER"
else
    rm -rf "$HARDEN_FIXTURE" "$HARDEN_OUTSIDE"
    mkdir -p "$HARDEN_FIXTURE" "$HARDEN_OUTSIDE/bin-target"
    printf 'BIN-CANARY\n' > "$HARDEN_OUTSIDE/bin-target/canary"
    printf 'PROFILE-CANARY\n' > "$HARDEN_OUTSIDE/profile-target"
    chmod 777 "$HARDEN_FIXTURE"
    ln -s "$HARDEN_OUTSIDE/bin-target" "$HARDEN_FIXTURE/bin"
    ln -s "$HARDEN_OUTSIDE/profile-target" "$HARDEN_FIXTURE/.profile"

    _fn=$(sed -n '/^harden_root_home() {/,/^}/p' "$CANDIDATE_UPDATER")
    if [ -z "$_fn" ]; then
        bad "candidate updater has no extractable harden_root_home function"
    else
        eval "$_fn"
        if harden_root_home "$HARDEN_FIXTURE"; then
            [ "$(cat "$HARDEN_OUTSIDE/bin-target/canary" 2>/dev/null)" = "BIN-CANARY" ] && \
                [ "$(cat "$HARDEN_OUTSIDE/profile-target" 2>/dev/null)" = "PROFILE-CANARY" ] \
                && ok "migration did not follow either planted symlink" \
                || bad "migration changed a target outside the fixture"
            [ ! -L "$HARDEN_FIXTURE/bin" ] && [ -d "$HARDEN_FIXTURE/bin" ] && \
                [ "$(stat -c %a "$HARDEN_FIXTURE/bin" 2>/dev/null)" = "755" ] \
                && ok "legacy bin replaced by a real 0755 directory" \
                || bad "replacement bin is not a real 0755 directory"
            [ ! -L "$HARDEN_FIXTURE/.quecdeck-home-hardened" ] && \
                [ "$(stat -c '%U %a' "$HARDEN_FIXTURE/.quecdeck-home-hardened" 2>/dev/null)" = "root 600" ] && \
                [ "$(cat "$HARDEN_FIXTURE/.quecdeck-home-hardened" 2>/dev/null)" = "1" ] \
                && ok "trusted root:600 migration marker created" \
                || bad "migration marker owner, mode, type, or content is wrong"
            _before=$(find "$HARDEN_FIXTURE" -maxdepth 1 -name 'bin.pre-quecdeck-hardening.*' | wc -l)
            harden_root_home "$HARDEN_FIXTURE" >/dev/null 2>&1
            _after=$(find "$HARDEN_FIXTURE" -maxdepth 1 -name 'bin.pre-quecdeck-hardening.*' | wc -l)
            [ "$_before" = "1" ] && [ "$_after" = "1" ] \
                && ok "second run is idempotent and keeps one quarantine" \
                || bad "second run repeated or lost the quarantine ($_before -> $_after)"
        else
            bad "candidate harden_root_home rejected the isolated legacy fixture"
        fi
    fi
fi

# ---- F: candidate staged-mode normalization ------------------------------
echo ""
echo "[F] candidate updater normalizes archive modes and fails closed"
if [ -z "$CANDIDATE_UPDATER" ]; then
    note "skipped: pass a candidate update_quecdeck.sh to test its mode-normalization function"
elif [ ! -f "$CANDIDATE_UPDATER" ]; then
    bad "candidate updater not found: $CANDIDATE_UPDATER"
else
    grep -q '^[[:space:]]*if ! normalize_stage_modes "$STAGE_DIR"; then$' "$CANDIDATE_UPDATER" \
        && ok "stage_release invokes normalize_stage_modes and checks its result" \
        || bad "stage_release does not fail on normalize_stage_modes failure"
    _mode_fn=$(sed -n '/^normalize_stage_modes() {/,/^}/p' "$CANDIDATE_UPDATER")
    if [ -z "$_mode_fn" ]; then
        bad "candidate updater has no extractable normalize_stage_modes function"
    else
        eval "$_mode_fn"
        rm -rf "$MODE_FIXTURE"
        mkdir -p "$MODE_FIXTURE/sub"
        : > "$MODE_FIXTURE/plain"
        : > "$MODE_FIXTURE/sub/plain"
        chmod 775 "$MODE_FIXTURE" "$MODE_FIXTURE/sub"
        chmod 664 "$MODE_FIXTURE/plain" "$MODE_FIXTURE/sub/plain"
        if normalize_stage_modes "$MODE_FIXTURE"; then
            _mode_bad=$(find "$MODE_FIXTURE" -type d ! -perm 755 -o -type f ! -perm 644 2>/dev/null | head -1)
            [ -z "$_mode_bad" ] \
                && ok "archive-style 775/664 tree normalized to 755/644" \
                || bad "mode normalization left an unexpected mode on $_mode_bad"
        else
            bad "candidate normalize_stage_modes rejected a valid fixture"
        fi
        if normalize_stage_modes "$MODE_FIXTURE/missing" >/dev/null 2>&1; then
            bad "candidate normalize_stage_modes accepted a missing stage tree"
        else
            ok "missing stage tree is rejected (update fails closed)"
        fi
        rm -rf "$MODE_FIXTURE"
    fi
fi

echo ""
echo "=================================================================="
echo " Results: $pass passed, $fail failed, $warn notes"
[ "$fail" -eq 0 ] \
    && echo " VERDICT: the ownership rule holds on this device." \
    || echo " VERDICT: a property FAILED. Each FAIL line names what broke."
echo "=================================================================="
