#!/bin/bash
# AT command queue daemon.
#
# Processes AT commands one at a time in submission order: each command is
# fully sent to the modem and its response received before the next begins.
#
# Normal AT commands are dispatched via atcli (setuid root), which opens
# /dev/smd11 directly. The daemon itself runs as www-data with no special
# privileges or group memberships required.
#
# Client protocol (implemented in atcmd_run in at-lib.sh):
#   1. mkfifo /tmp/quecdeck/queue/<id>.resp.fifo          (response pipe)
#   2. exec 8<> <id>.resp.fifo                               (hold open before notify)
#   3. printf <id>\t<cmd>\t<timeout_ms>\t<deadline>\n > atcmd.notify
#   4. read loop on fd 8 until OK/ERROR                      (block for response)
# deadline is uptime seconds; lines past it are skipped, not dispatched.

# FIFO and atcli paths come from at-lib.sh so both ends of the protocol
# cannot drift. ATLIB override is for the host-side test only.
. "${ATLIB:-/usrdata/quecdeck/script/at-lib.sh}"

# Parse one notify line into _id/_cmd/_timeout/_deadline; returns 1 to drop
# it. Tolerates older 3-field clients (deadline empty = never expires) and
# clears non-numeric fields.
_parse_notify() {
    _id=""; _cmd=""; _timeout=""; _deadline=""
    case "$1" in *$'\t'*) ;; *) return 1 ;; esac
    _id="${1%%$'\t'*}"
    # Reject IDs that could escape the queue directory.
    case "$_id" in ''|*[!0-9_]*) return 1 ;; esac
    local _rest="${1#*$'\t'}"
    _cmd="${_rest%%$'\t'*}"
    [ -z "$_cmd" ] && return 1
    _rest="${_rest#*$'\t'}"
    [ "$_rest" = "$_cmd" ] && _rest=""
    _timeout="${_rest%%$'\t'*}"
    _deadline="${_rest#*$'\t'}"
    [ "$_deadline" = "$_rest" ] && _deadline=""
    case "$_timeout" in ''|*[!0-9]*) _timeout="" ;; esac
    case "$_deadline" in ''|*[!0-9]*) _deadline="" ;; esac
    return 0
}

# Backstop for a hung atcli. atcli has its own -t, but if it ever blocks past
# that (e.g. stuck on device I/O), the daemon is serial so the whole queue
# stalls. Wrap each call in `timeout` as an independent watchdog. Degrade to no
# wrapper if timeout is unavailable rather than failing every command.
_TIMEOUT=""
if command -v timeout >/dev/null 2>&1; then
    _TIMEOUT=timeout
elif [ -x /opt/bin/timeout ]; then
    _TIMEOUT=/opt/bin/timeout
fi

mkdir -p "$_ATCMD_QUEUE" && chmod 700 "$_ATCMD_QUEUE"
# Lock the base dir if this daemon created it before lighttpd's ExecStartPre did.
chmod 700 /tmp/quecdeck 2>/dev/null
rm -f "$_ATCMD_NOTIFY"
rm -f "$_ATCMD_QUEUE"/*.resp.fifo 2>/dev/null
mkfifo -m 600 "$_ATCMD_NOTIFY"

# Keep notify FIFO open O_RDWR so client O_WRONLY opens never block.
exec 5<>"$_ATCMD_NOTIFY" || exit 1

_cleanup() {
    trap - EXIT INT TERM
    rm -f "$_ATCMD_NOTIFY"
    rm -f "$_ATCMD_QUEUE"/*.resp.fifo 2>/dev/null
    exit 0
}
trap _cleanup EXIT INT TERM

while IFS= read -r _line <&5; do
    [ -z "$_line" ] && continue

    # Opportunistically reap response FIFOs orphaned by clients killed before
    # their own cleanup ran (otherwise they count against the queue limit and
    # can eventually wedge it). 10 min is safely past the longest possible
    # client lifetime (queue-wait + read, each bounded by the 215s cell-scan
    # timeout), so a live client is never reaped. ~2% of iterations.
    [ $(( RANDOM % 50 )) -eq 0 ] && \
        find "$_ATCMD_QUEUE" -maxdepth 1 -name '*.resp.fifo' -mmin +10 -delete 2>/dev/null

    _parse_notify "$_line" || continue

    # Expired deadline: the sender has stopped waiting; dispatching now would
    # be orphan work against the modem.
    [ -n "$_deadline" ] && [ "$(_atq_uptime)" -gt "$_deadline" ] && continue

    _resp_fifo="$_ATCMD_QUEUE/${_id}.resp.fifo"

    # Normal AT command: dispatch via atcli and deliver response.
    # Strip \r (atcli does not strip CR from modem's \r\n line endings).
    # Wrap in `timeout` (kill ~5s past atcli's own -t) so a hung atcli can't
    # stall the whole serial queue; fall back to a bare call if unavailable.
    if [ -n "$_TIMEOUT" ]; then
        if [ -n "$_timeout" ]; then
            _result=$("$_TIMEOUT" "$(( _timeout / 1000 + 5 ))" "$_ATCLI" -t "$_timeout" "$_cmd" 2>/dev/null | tr -d '\r')
        else
            _result=$("$_TIMEOUT" 30 "$_ATCLI" "$_cmd" 2>/dev/null | tr -d '\r')
        fi
    else
        _result=$("$_ATCLI" ${_timeout:+-t "$_timeout"} "$_cmd" 2>/dev/null | tr -d '\r')
    fi

    if [ -p "$_resp_fifo" ]; then
        exec 6<>"$_resp_fifo"
        printf '%s\n' "$_result" >&6
        exec 6>&-
    fi
done
