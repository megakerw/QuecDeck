#!/bin/bash
# On-device verification of the atcli daemon (atcli --daemon, unit
# atcmd-daemon). Run as root:
#   /tmp/device-test-atclid.sh
# Dev tool, not deployed; copy it to the device manually. Sends only fast,
# read-only AT commands. The wire contract itself is covered by the atcli
# repo's harness; this checks what only the device can: SELinux domain
# pairings on the live socket, the privilege drop, and systemd wiring.
#
# It also covers the parts of the daemon that are calibrated against a real
# modem rather than a socat fake, and so cannot be settled on a host at all:
# the post-timeout resync window (see the resync section - that one is a
# measurement, not just an assertion), non-UTF-8 modem output from stored SMS,
# and the socket-directory adoption path the unit file's ExecStartPre creates.
# For timings rather than pass/fail, see device-perf-atcli.sh.

set -u
ATLIB=/usrdata/quecdeck/script/at-lib.sh
pass=0; fail=0; skip=0
ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1${2:+ ($2)}"; }
skp() { skip=$((skip+1)); echo "SKIP: $1"; }
# Measured facts that are worth reading but have no right answer to assert.
note() { echo "NOTE: $1"; }

# The unit binds the socket after the privilege drop, so a restart's socket
# appears some way into startup; every wait for it goes through here. Whole
# seconds only: busybox sleep here may not take a fraction, and a rejected
# argument would spin this loop out instantly and report a daemon that never
# bound. The socket normally appears within one.
wait_sock() {
    for _ in $(seq 10); do
        [ -S "$_ATCLI_SOCK" ] && return 0
        sleep 1
    done
    return 1
}

# One counter out of --status. Read through a function because the resync
# section below reads several across a loop.
counter() { "$_ATCLI" --status -s "$_ATCLI_SOCK" 2>/dev/null | awk -v k="$1" '$1 == k {print $2}'; }

[ -f "$ATLIB" ] || { echo "FATAL: $ATLIB missing"; exit 1; }
. "$ATLIB"

# ---- pick a way to run shell as www-data (lighttpd's uid) ------------------
RUNNER=""
if systemd-run --uid=www-data --pipe --wait -q /bin/true >/dev/null 2>&1; then
    RUNNER=systemd
elif su www-data -s /bin/sh -c true >/dev/null 2>&1; then
    RUNNER=su
fi
as_www() {
    case "$RUNNER" in
        systemd) systemd-run --uid=www-data --pipe --wait -q /bin/bash -c "$1" 2>/dev/null ;;
        su)      su www-data -s /bin/bash -c "$1" ;;
        *)       return 99 ;;
    esac
}

# ---- preflight -------------------------------------------------------------
if systemctl is-active atcmd-daemon >/dev/null 2>&1; then
    ok "daemon unit active"
else
    bad "daemon unit active" "start atcmd-daemon first"; echo "aborting"; exit 1
fi

# ---- the binary itself runs here -------------------------------------------
# Device binaries are statically linked against musl, and qemu-user (the atcli
# repo's smoke test) exercises the target ABI but not this kernel or its
# SELinux policy. So assert the cheapest thing that can only be answered here:
# the binary starts. --help touches no socket and no port, so a failure is the
# process itself - wrong architecture, a libc syscall this kernel refuses -
# and not any part of the daemon.
if "$_ATCLI" --help >/dev/null 2>&1; then
    ok "binary starts on this hardware"
else
    bad "binary starts on this hardware" "rc=$? - wrong arch, or a libc this kernel rejects"
    echo "aborting"; exit 1
fi
# Which libc, for the record: a static glibc build carries its NSS and locale
# tables, and 'GNU C Library' with them. Not an assertion - a glibc build is
# still a valid build (LIBC=glibc in atcli's build.sh) - but if the daemon is
# ever slow to exec, this is the first thing to read.
if grep -aq 'GNU C Library' "$_ATCLI" 2>/dev/null; then libc=glibc; else libc="musl (no glibc marker)"; fi
note "binary: $(stat -c %s "$_ATCLI" 2>/dev/null) bytes, libc: $libc"

# ---- privilege drop and socket modes ---------------------------------------
daemon_pid=$(systemctl show -p MainPID --value atcmd-daemon)
# The running daemon must be the same binary this script is testing as a
# client, or every result below describes two different builds.
running=$(readlink "/proc/$daemon_pid/exe" 2>/dev/null)
case "$running" in
    "$_ATCLI") ok "running daemon is $_ATCLI" ;;
    # The deploy overwrote the file while the old process kept the unlinked
    # inode: the client here is the new build and the daemon is not, which is
    # the one state that would make every result below a mix of two builds.
    *"(deleted)")
        bad "running daemon is the deployed binary" \
            "binary was replaced without a restart - run 'systemctl restart atcmd-daemon'" ;;
    '') skp "cannot read /proc/$daemon_pid/exe (is the unit running?)" ;;
    *)  bad "running daemon is $_ATCLI" "unit is running $running" ;;
esac
if [ "$(stat -c %U "/proc/$daemon_pid" 2>/dev/null)" = "www-data" ]; then
    ok "daemon runs as www-data (dropped from root)"
else
    bad "daemon runs as www-data" "uid: $(stat -c %U "/proc/$daemon_pid" 2>/dev/null)"
fi
# setgroups(0) runs before setgid/setuid, and nothing observable afterwards
# reflects it: a daemon still carrying root's supplementary groups reports uid
# www-data and passes every other check here. On this device that would mean an
# AT-capable process holding root's group memberships.
groups_line=$(awk '/^Groups:/ {$1 = ""; gsub(/^ +| +$/, ""); print}' \
                  "/proc/$daemon_pid/status" 2>/dev/null)
if [ -z "$groups_line" ]; then
    ok "supplementary groups cleared on drop"
else
    bad "supplementary groups cleared on drop" "still in: $groups_line"
fi
[ -S "$_ATCLI_SOCK" ] && ok "socket present" || bad "socket present" "$_ATCLI_SOCK"
mode=$(stat -c %a "$_ATCLI_SOCK" 2>/dev/null)
[ "$mode" = "660" ] && ok "socket mode 660" || bad "socket mode 660" "is $mode"
if [ -u "$_ATCLI" ]; then
    bad "binary not setuid (zero-setuid policy)" "$(stat -c %a "$_ATCLI")"
else
    ok "binary not setuid (zero-setuid policy)"
fi

# ---- socket directory adoption across a restart ----------------------------
# The daemon seals the socket's parent at 0700 and refuses to adopt a directory
# that is neither its own creation nor already owned by its drop target. Which
# branch it takes now depends on who got there first: the unit's ExecStartPre no
# longer creates the tree (root must not write inside www-data's), so a CGI
# usually creates it and the daemon adopts, but on a boot where the daemon wins
# it creates the directory itself. Both paths are valid. The invariant is the
# sealed end state asserted below, not the branch.
SOCKDIR=$(dirname "$_ATCLI_SOCK")
systemctl restart atcmd-daemon
if wait_sock; then
    ok "daemon rebinds after restart (socket dir adopted)"
else
    bad "daemon rebinds after restart" "check: journalctl -u atcmd-daemon | tail"
    echo "aborting"; exit 1
fi
dirinfo=$(stat -c '%a %U' "$SOCKDIR" 2>/dev/null)
if [ "$dirinfo" = "700 www-data" ]; then
    ok "socket dir sealed 0700 www-data ($SOCKDIR)"
else
    bad "socket dir sealed 0700 www-data" "is '$dirinfo'"
fi
# Informational only: which branch was taken. Not a failure either way, since
# the daemon legitimately creates the dir when it starts before any CGI.
ATLOG=/run/quecdeck/atcmd.log
if [ -f "$ATLOG" ]; then
    if grep -q 'adopting existing socket dir' "$ATLOG"; then
        ok "log shows the adoption branch (the existing dir was owned by www-data)"
    else
        skp "no adoption line in $ATLOG: the daemon created the dir itself this boot (also correct)"
    fi
else
    skp "no $ATLOG to read the adoption line from"
fi
# The restart zeroed the daemon's counters, so everything that reads them has
# to come after this point.
daemon_pid=$(systemctl show -p MainPID --value atcmd-daemon)

# ---- root path (watchcat/scheduled_restart context) ------------------------
resp=$(atcmd_run 'AT+QGMR')
case "$resp" in
    *OK) ok "root atcmd_run round trip" ;;
    *)   bad "root atcmd_run round trip" "$resp" ;;
esac

status=$("$_ATCLI" --status -s "$_ATCLI_SOCK")
served0=$(printf '%s\n' "$status" | awk '$1 == "served" {print $2}')
case "$served0" in
    ''|*[!0-9]*) bad "STATUS served counter" "$status" ;;
    *)           ok  "STATUS served counter ($served0)" ;;
esac
# Every counter the resync section below reads, asserted as a set: --status is
# the only window into the daemon's guesses, so a missing or renamed key would
# leave that section silently measuring an empty string. `unresolved` is the
# newest and the one that matters most here.
missing=""
for k in served timeouts stale unresolved skipped detached denied uid; do
    printf '%s\n' "$status" | awk -v k="$k" '$1 == k {found=1} END {exit !found}' \
        || missing="$missing $k"
done
[ -z "$missing" ] && ok "STATUS reports every expected counter" \
                  || bad "STATUS counter set" "missing:$missing"
case "$(printf '%s\n' "$status" | tail -1)" in
    OK) ok "STATUS terminated by OK" ;;
    *)  bad "STATUS terminated by OK" "$(printf '%s\n' "$status" | tail -1)" ;;
esac

# ---- www-data path (CGI context) -------------------------------------------
if [ -n "$RUNNER" ]; then
    resp=$(as_www ". $ATLIB; atcmd_run 'AT+QGMR'")
    case "$resp" in
        *OK) ok "www-data atcmd_run round trip (via $RUNNER)" ;;
        *)   bad "www-data atcmd_run round trip" "$resp" ;;
    esac
else
    skp "www-data round trip (no systemd-run/su runner)"
fi

# ---- detach ----------------------------------------------------------------
atcmd_fire 'AT'
sleep 1
served1=$("$_ATCLI" --status -s "$_ATCLI_SOCK" | awk '$1 == "served" {print $2}')
if [ -n "$served1" ] && [ "$served1" -gt "${served0:-0}" ]; then
    ok "detached command executed after client exit"
else
    bad "detached command executed" "served $served0 -> $served1"
fi

# A detached command that times out leaves the port desynced with nobody waiting
# for its reply, so the resync is charged to whoever comes next. Uses the same
# no-terminator command as the resync section below, since a short -t cannot
# force a timeout on this port.
atcmd_fire "${DESYNC_CMD:-AT+CLAC}" 1000
sleep 1.5
case "$(atcmd_run 'AT+CSQ' 3000)" in
    *'+CSQ:'*OK) ok "reply after a detached command timed out is clean" ;;
    *) bad "reply after a detached command timed out is clean" \
           "$(atcmd_run 'AT+CSQ' 3000 | tr '\n' '|')" ;;
esac

# ---- atcli's too-long exit code ----------------------------------------------
# at-lib keeps a copy of this number (_AT_E_TOOLONG) to decide when to
# synthesize its body line, and the host suite can only assert that copy against
# itself: it stubs atcli with the very code it is checking. The real client can
# settle it, because _atcmd_report returns atcli's status untouched, so the rc
# below is atcli's own. The literal 65 here is deliberate; asserting against
# $_AT_E_TOOLONG alone would be the same circular test.
at_long="AT+CGMM"; i=0
while [ "$i" -lt 90 ]; do at_long="$at_long;+CGMM"; i=$((i + 1)); done   # 547 chars
# stderr silenced only to keep this report readable: at-lib deliberately writes
# the refusal to both streams, and the body copy is what is asserted below.
at_out=$(atcmd_run "$at_long" 2000 2>/dev/null); at_rc=$?
if [ "$at_rc" -eq 65 ]; then
    ok "atcli exits 65 for a command past CMD_MAX"
else
    bad "atcli exits 65 for a command past CMD_MAX" "rc=$at_rc"
fi
# The two below read the INSTALLED at-lib, which can predate the repo: this is
# a dev tool run against whatever is deployed. Skip rather than fail there, and
# never let an unset variable abort the rest of the run under set -u.
if [ -z "${_AT_E_TOOLONG:-}" ]; then
    skp "at-lib's _AT_E_TOOLONG matches atcli (installed at-lib predates it)"
    skp "at-lib puts the refusal in the body (installed at-lib predates it)"
else
    if [ "$at_rc" -eq "$_AT_E_TOOLONG" ]; then
        ok "at-lib's _AT_E_TOOLONG matches atcli"
    else
        bad "at-lib's _AT_E_TOOLONG matches atcli" "at-lib=$_AT_E_TOOLONG atcli=$at_rc"
    fi
    case $at_out in
        *"ERROR: AT command too long"*) ok "at-lib puts the refusal in the body" ;;
        *) bad "at-lib puts the refusal in the body" "$(printf '%s' "$at_out" | tr '\n' '|')" ;;
    esac
fi
# The daemon must not have seen it: atcli refuses before connecting.
unset at_long at_out at_rc

# ---- post-timeout resync -----------------------------------------------------
# After a timeout a reply is still owed, so the daemon waits for its terminator
# before writing the next command, bounded by DRAIN_CAP_MS (1400 ms). Past that
# it guesses "no reply is coming" and counts the guess as `unresolved`; a wrong
# guess puts the owed reply in the next client's window, where its terminator
# ends that response and shifts every reply after it.
#
# Forcing that state needs a command that leaves a reply owed. A short -t does
# not do it: the deadline is per line, and this port answers each line in well
# under a millisecond, so even -t 1 completes. AT+CLAC does, because on this
# modem it lists commands and never sends a terminator, so the read loop always
# reaches its deadline. Override with DESYNC_CMD if a firmware terminates it.
DESYNC_CMD=${DESYNC_CMD:-AT+CLAC}
RESYNC_REPS=${RESYNC_REPS:-4}
stale0=$(counter stale);       stale0=${stale0:-0}
unres0=$(counter unresolved);  unres0=${unres0:-0}
tmo0=$(counter timeouts);      tmo0=${tmo0:-0}
shifted=0; probes=0
i=0
while [ "$i" -lt "$RESYNC_REPS" ]; do
    i=$((i + 1)); probes=$((probes + 1))
    atcmd_run "$DESYNC_CMD" 1000 >/dev/null
    # The reply that must not carry the abandoned command's output. Contains
    # rather than starts-with, because command echo is on here so a reply opens
    # with the echoed line; a shifted reply has no '+CSQ:' in it at all.
    resp=$(atcmd_run 'AT+CSQ' 3000)
    case "$resp" in
        *'+CSQ:'*OK) ;;
        *) shifted=$((shifted + 1))
           echo "  shift after probe $i: $(printf '%s' "$resp" | tr '\n' '|')" ;;
    esac
done
tmo_d=$(( $(counter timeouts) - tmo0 ))
unres_d=$(( $(counter unresolved) - unres0 ))
if [ "$tmo_d" -eq 0 ]; then
    # Without a timeout there was no desync, so a pass here would mean nothing.
    skp "resync not exercised: '$DESYNC_CMD' terminated normally (set DESYNC_CMD)"
elif [ "$shifted" -eq 0 ]; then
    ok "no reply shift across $probes forced timeouts"
else
    bad "reply shift after a timeout" "$shifted of $probes probes"
fi
note "resync: timeouts +$tmo_d, stale drained +$(( $(counter stale) - stale0 )), unresolved +$unres_d over $probes probes"
# A command that never answers can only ever exhaust the window, so growth here
# is the expected outcome of this probe and says nothing about the bound. Expect
# roughly *two* per timeout, not one: the daemon spends a budget of resync
# attempts (RESYNC_TRIES) on each owed reply, because a single attempt that
# guesses wrong leaves the displaced command's own reply owed in turn. Measured
# 2026-07-30 on an RM520N-GL (SDX62): unresolved +8 over 4 probes.
# Measuring the bound needs a command that answers *late*: set SLOW_CMD to one
# (AT+COPS=? scans for tens of seconds) and read the warning below.
if [ -n "${SLOW_CMD:-}" ]; then
    u0=$(counter unresolved); u0=${u0:-0}
    atcmd_run "$SLOW_CMD" 2000 >/dev/null
    resp=$(atcmd_run 'AT+CSQ' 3000)
    case "$resp" in
        *'+CSQ:'*OK) ok "no reply shift after a late-answering command" ;;
        *) bad "reply shift after a late-answering command" \
               "$(printf '%s' "$resp" | tr '\n' '|')" ;;
    esac
    if [ "$(( $(counter unresolved) - u0 ))" -gt 0 ]; then
        echo "WARNING: '$SLOW_CMD' answers later than DRAIN_CAP_MS (1400 ms), so the daemon"
        echo "         guessed, and its reply can land in a later command's window."
        echo "         How late decides what to do about it. A reply a few hundred ms past"
        echo "         the cap is worth raising DRAIN_CAP_MS for, together with"
        echo "         CLIENT_SLACK_MS which the const-assert in daemon.rs requires. A"
        echo "         network scan answers tens of seconds late (~43 s on an RM520N-GL),"
        echo "         which no cap can cover: give such commands a -t long enough that they"
        echo "         never time out, up to the 300 s maximum. Closing it in the daemon"
        echo "         needs the end-of-reply marker, which is a protocol change."
    else
        note "'$SLOW_CMD' resolved inside DRAIN_CAP_MS (1400 ms)"
    fi
fi

# ---- exit-code contract ------------------------------------------------------
# get_sms, run_cell_scan, user_atcommand and the updater's health probe all
# judge a reply by atcmd_run's status alone, because a truncated reply and a
# complete one read the same. The contract they rest on:
#
#   terminated reply (OK or ERROR)  -> exit 0
#   no terminator inside the window -> non-zero, partial bytes still on stdout
#   nothing at all                  -> non-zero, empty stdout
#
# Only a real modem decides which commands terminate, so this cannot move to
# the host harness.
ec_out=$(atcmd_run 'AT+CSQ' 3000); ec_rc=$?
case "$ec_out" in
    *'+CSQ:'*OK)
        if [ "$ec_rc" -eq 0 ]; then
            ok "a terminated OK reply exits 0"
        else
            bad "a terminated OK reply exits 0" \
                "rc=$ec_rc - every caller would treat good data as truncated"
        fi ;;
    *) skp "no clean AT+CSQ reply to judge the status against: $(printf '%s' "$ec_out" | tr '\n' '|')" ;;
esac

# Well-formed for the daemon (starts AT, under CMD_MAX) so it reaches the modem
# and comes back rejected, rather than being refused locally as malformed - a
# different path with its own status.
ec_out=$(atcmd_run 'AT+ZZZZ' 3000); ec_rc=$?
case "$ec_out" in
    *ERROR*)
        if [ "$ec_rc" -eq 0 ]; then
            ok "a terminated ERROR reply exits 0"
        else
            bad "a terminated ERROR reply exits 0" \
                "rc=$ec_rc - user_atcommand will mislabel every rejected command"
        fi ;;
    *) skp "'AT+ZZZZ' did not answer ERROR on this firmware: $(printf '%s' "$ec_out" | tr '\n' '|')" ;;
esac

# DESYNC_CMD reaches its deadline with bytes already in hand, which is the
# contract's middle row. See the resync section for why AT+CLAC is the default.
ec_out=$(atcmd_run "$DESYNC_CMD" 1000); ec_rc=$?
if [ "$ec_rc" -eq 0 ]; then
    skp "unterminated reply not exercised: '$DESYNC_CMD' terminated normally (set DESYNC_CMD)"
elif [ -n "$ec_out" ]; then
    ok "an unterminated reply exits non-zero with its bytes on stdout (rc=$ec_rc)"
else
    # Status is right, bytes were dropped: the developer console is the caller
    # that breaks, since AT+CLAC's partial reply is all there is.
    bad "an unterminated reply keeps its bytes" "rc=$ec_rc but stdout was empty"
fi

# The no-daemon row, forced without stopping the unit: a socket path nothing is
# bound to. Subshell so the override cannot leak into the sections below.
# at-lib.sh reads _ATCLI_SOCK at call time, so assigning it here is enough.
ec_out=$( _ATCLI_SOCK=/tmp/quecdeck/atcli-absent.sock; atcmd_run 'AT' 2000 ); ec_rc=$?
if [ "$ec_rc" -ne 0 ] && [ -z "$ec_out" ]; then
    ok "an unreachable socket exits non-zero with empty stdout (rc=$ec_rc)"
elif [ "$ec_rc" -eq 0 ]; then
    bad "an unreachable socket exits non-zero" \
        "rc=0 - the updater's health probe would call a dead daemon healthy"
else
    bad "an unreachable socket writes nothing to stdout" \
        "$(printf '%s' "$ec_out" | tr '\n' '|')"
fi

# ---- non-UTF-8 modem output (stored SMS) -----------------------------------
# Modem output is not guaranteed UTF-8: text-mode SMS carries the 8-bit GSM
# alphabet. The reader substitutes bad bytes rather than failing, because a
# read error would end the reader thread and take the daemon with it - and it
# would restart into the same buffered bytes. Only real stored messages
# exercise this; the host harness can only fake it with a fixed byte pair.
# Text mode is the state change that puts those bytes on the wire, so it is
# read first and restored afterwards.
# Anchored, because command echo puts 'AT+CMGF?' in the reply too and that line
# has no colon to split on.
cmgf0=$(atcmd_run 'AT+CMGF?' 3000 | awk -F: '/^\+CMGF:/ {gsub(/[^0-9]/, "", $2); print $2}')
case "$cmgf0" in
    0|1)
        atcmd_run 'AT+CMGF=1' 3000 >/dev/null
        sms=$(atcmd_run 'AT+CMGL="ALL"' 15000)
        n=$(printf '%s\n' "$sms" | grep -c '^+CMGL:')
        case "$sms" in
            *OK) if [ "$n" -gt 0 ]; then
                     ok "text-mode SMS list terminated normally ($n message(s) read)"
                 else
                     skp "no stored messages; 8-bit SMS text never reached the reader"
                 fi ;;
            *)   bad "text-mode SMS list terminated normally" \
                     "$(printf '%s' "$sms" | tail -1)" ;;
        esac
        # The daemon surviving is the real assertion: a fatal read error kills
        # the reader thread, and the next command is what notices.
        case "$(atcmd_run 'AT+CSQ' 3000)" in
            *'+CSQ:'*OK) ok "daemon alive after reading stored SMS" ;;
            *)          bad "daemon alive after reading stored SMS" ;;
        esac
        atcmd_run "AT+CMGF=$cmgf0" 3000 >/dev/null ;;
    *)  skp "AT+CMGF? gave no mode; skipped SMS read rather than guess at it" ;;
esac

# ---- explicit --direct + no implicit fallback (daemon must be stopped: its
# reader thread and a --direct client would race for the same port's
# responses, so it has to be down for this section) --------------------------
systemctl stop atcmd-daemon
resp=$("$_ATCLI" --direct -t 3000 'AT' 2>/dev/null)
case "$resp" in
    *OK) ok "--direct with daemon stopped (root port access)" ;;
    *)   bad "--direct with daemon stopped" "$resp" ;;
esac
# No implicit fallback: a plain atcmd_run must NOT reach the modem when the
# daemon is down; it returns empty (matching the www-data experience).
resp=$(atcmd_run 'AT')
case "$resp" in
    '') ok "atcmd_run empty while daemon down (no implicit direct fallback)" ;;
    *)  bad "atcmd_run must not reach the modem without the daemon" "$resp" ;;
esac
systemctl start atcmd-daemon
sleep 2
if systemctl is-active atcmd-daemon >/dev/null 2>&1 && [ -S "$_ATCLI_SOCK" ]; then
    ok "daemon back up after direct-path test"
else
    bad "daemon back up after direct-path test"
fi

echo "----"
echo "PASS=$pass FAIL=$fail SKIP=$skip"
[ "$fail" -eq 0 ]
