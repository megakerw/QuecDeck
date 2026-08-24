#!/bin/bash
# On-device timings for atcli. Run as root, before and after deploying a new
# binary, and compare the two runs:
#   /tmp/device-perf-atcli.sh                        # whatever is deployed
#   /tmp/device-perf-atcli.sh /usrdata/quecdeck/atcli /tmp/atcli-new
# Dev tool, not deployed. Copy it to the device manually. Sends only 'AT' and
# one read-only list command.
#
# The second form is the useful one before a deploy: the wire protocol has not
# changed, so a candidate binary can be measured as a *client* against the
# daemon that is already running, without replacing anything. What that cannot
# measure is the daemon side - the resident-memory figures below always
# describe the binary the unit is currently running, whichever binaries are
# passed here. To get daemon-side numbers for a candidate, deploy it, restart
# the unit, and run this again with no arguments.
#
# What the numbers mean:
#   exec       process startup alone (--help touches no socket and no port).
#              The figure that matters most: every AT command in QuecDeck is a
#              fresh client spawn, so this is paid per command.
#   round trip exec + socket + queue + modem, i.e. what a caller actually
#              waits for. Subtract exec to see the modem's share.
#   big reply  bytes and elapsed for one multi-line response, so a change in
#              the reader's line handling shows up as throughput.
#   resident   the daemon's own memory. Flat across a run is the property that
#              matters. The reader's channel is bounded, so growth here is a
#              regression, not load.
#
# Timings are steady-state (warm page cache) because that is the state a
# spawn-per-command consumer lives in. They are also noisy if the web UI is
# polling AT commands while this runs - stop lighttpd for a quiet baseline, or
# just run it twice and keep the lower numbers.

set -u
ATLIB=/usrdata/quecdeck/script/at-lib.sh
[ -f "$ATLIB" ] || { echo "FATAL: $ATLIB missing"; exit 1; }
. "$ATLIB"

EXEC_N=${EXEC_N:-200}          # execs per exec measurement
RT_N=${RT_N:-50}               # round trips per round-trip measurement
# Assigned in a branch, not with :-, because the default carries quotes that
# ${BIG_CMD:-...} would strip on the way through. AT+CGDCONT? Is the default
# because every modem answers it, at length, and ends it with OK.
if [ -z "${BIG_CMD:-}" ]; then BIG_CMD='AT+CGDCONT?'; fi
# Short, because a command that never terminates costs this in full, twice over
# when two binaries are compared.
BIG_TIMEOUT=${BIG_TIMEOUT:-5000}

BINS=${*:-$_ATCLI}

# One line of "binary exec_ms round_trip_ms" per measured binary, for the
# comparison at the end.
ROWS=$(mktemp)
trap 'rm -f "$ROWS"' EXIT

# /proc/uptime rather than date +%s%N or EPOCHREALTIME: it is the one clock
# every one of these firmwares has. Resolution is 10 ms, which is why
# everything below times a batch and divides rather than timing one call.
now_cs() { awk '{printf "%d", $1 * 100}' /proc/uptime; }
per_ms()  { awk -v cs="$1" -v n="$2" 'BEGIN {printf "%.2f", (cs * 10) / n}'; }

# ---- daemon side (the running unit, not the binaries passed in) ------------
daemon_pid=$(systemctl show -p MainPID --value atcmd-daemon 2>/dev/null)
echo "=== daemon (unit atcmd-daemon, pid ${daemon_pid:-none}) ==="
if [ -n "${daemon_pid:-}" ] && [ -r "/proc/$daemon_pid/status" ]; then
    running=$(readlink "/proc/$daemon_pid/exe" 2>/dev/null)
    echo "  binary:      ${running:-unknown}"
    echo "  uptime:      $("$_ATCLI" --status -s "$_ATCLI_SOCK" 2>/dev/null |
                            awk '$1 == "uptime_s" {print $2 " s"}')"
    echo "  resident:    $(awk '/^VmRSS:/ {print $2 " KB"}' "/proc/$daemon_pid/status")" \
         "(peak $(awk '/^VmHWM:/ {print $2}' "/proc/$daemon_pid/status") KB)"
    # Pss is the honest number for a static binary - no shared libc pages to
    # discount - but smaps_rollup is missing on older kernels.
    pss=$(awk '/^Pss:/ {print $2}' "/proc/$daemon_pid/smaps_rollup" 2>/dev/null)
    [ -n "${pss:-}" ] && echo "  pss:         $pss KB"
    echo "  threads:     $(awk '/^Threads:/ {print $2}' "/proc/$daemon_pid/status")"
else
    echo "  not running. Client round trips below will fail. Start atcmd-daemon."
fi
echo

# ---- client side (one block per binary) ------------------------------------
for bin in $BINS; do
    echo "=== $bin ==="
    if [ ! -x "$bin" ]; then
        echo "  not executable - skipped"; echo; continue
    fi
    echo "  file size:   $(stat -c %s "$bin") bytes"
    if ! "$bin" --help >/dev/null 2>&1; then
        echo "  does not start on this hardware - skipped (wrong arch?)"; echo; continue
    fi

    # Warm the page cache first: the first exec of a freshly deployed binary
    # reads it off flash, and that one-off is not what a per-command consumer
    # pays all day.
    i=0; while [ "$i" -lt 10 ]; do "$bin" --help >/dev/null 2>&1; i=$((i + 1)); done
    t0=$(now_cs)
    i=0; while [ "$i" -lt "$EXEC_N" ]; do "$bin" --help >/dev/null 2>&1; i=$((i + 1)); done
    t1=$(now_cs)
    e=$(per_ms $((t1 - t0)) "$EXEC_N")
    echo "  exec:        $e ms  (mean of $EXEC_N)"

    r="n/a"
    if [ -S "$_ATCLI_SOCK" ] && [ -n "$("$bin" -s "$_ATCLI_SOCK" -t 3000 AT 2>/dev/null)" ]; then
        t0=$(now_cs)
        i=0
        while [ "$i" -lt "$RT_N" ]; do
            "$bin" -s "$_ATCLI_SOCK" -t 3000 AT >/dev/null 2>&1; i=$((i + 1))
        done
        t1=$(now_cs)
        r=$(per_ms $((t1 - t0)) "$RT_N")
        echo "  round trip:  $r ms  (mean of $RT_N, 'AT' through the running daemon)"
        echo "  modem share: $(awk -v a="$r" -v b="$e" 'BEGIN {printf "%.2f", a - b}') ms"

        t0=$(now_cs); big=$("$bin" -s "$_ATCLI_SOCK" -t "$BIG_TIMEOUT" "$BIG_CMD" 2>/dev/null); t1=$(now_cs)
        bytes=$(printf '%s' "$big" | wc -c)
        ms=$(( (t1 - t0) * 10 ))
        echo "  big reply:   $bytes bytes in $ms ms  ($BIG_CMD)"
        # Elapsed at or past the deadline means no terminator was seen, so the
        # figure is the deadline and not the modem's throughput. Some commands
        # never answer with one: AT+CLAC on the RM520N-GL ends its list without
        # an OK.
        if [ "$ms" -ge "$BIG_TIMEOUT" ]; then
            echo "               (hit the ${BIG_TIMEOUT}ms deadline: no terminator, so not a"
            echo "                throughput figure - and it leaves the port desynced, which"
            echo "                costs the next command a resync. Pick another BIG_CMD.)"
        elif [ "$bytes" -lt 32 ]; then
            echo "               (small reply - set BIG_CMD= to something this device answers"
            echo "                at length, e.g. BIG_CMD='AT+CGDCONT?')"
        fi
    else
        echo "  round trip:  n/a (no daemon on $_ATCLI_SOCK)"
    fi
    echo
    printf '%s %s %s\n' "$bin" "$e" "$r" >> "$ROWS"
done

# ---- comparison, when more than one binary was measured -------------------
if [ "$(grep -c . "$ROWS")" -gt 1 ]; then
    echo "=== relative to the first binary measured ==="
    awk 'NR == 1 {base_e = $2; base_r = $3}
         {
             d = ""
             if (NR > 1) d = sprintf("  (%+.2f ms, %+.1f%%)", $2 - base_e,
                                     ($2 - base_e) * 100 / base_e)
             else d = "  (baseline)"
             printf "  %s\n    exec %s ms%s\n", $1, $2, d
             # Round trips include the modem, which varies command to command,
             # so they are printed for context but not turned into a percentage
             # anyone should read as a speedup.
             if ($3 != "n/a") printf "    round trip %s ms\n", $3
         }' "$ROWS"
    echo
    echo "Note: exec and round trip above are valid for a binary that is not yet"
    echo "deployed - the wire protocol is unchanged, so a candidate can act as a"
    echo "client against the running daemon. The daemon block, however, always"
    echo "describes the unit's current binary. Deploy, restart, re-run for that."
fi
