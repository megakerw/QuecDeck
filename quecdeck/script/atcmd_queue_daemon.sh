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
# Client protocol (implemented in atcmd_run in cgi-lib.sh):
#   1. mkfifo /tmp/quecdeck/queue/<id>.resp.fifo          (response pipe)
#   2. exec 8<> <id>.resp.fifo                               (hold open before notify)
#   3. printf <id>\t<cmd>\t<timeout_ms>\n > atcmd.notify     (wake daemon)
#   4. read loop on fd 8 until OK/ERROR                      (block for response)

_ATCLI=/usrdata/quecdeck/atcli
_QUEUE_DIR=/tmp/quecdeck/queue
_NOTIFY=/tmp/quecdeck/atcmd.notify

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

mkdir -p "$_QUEUE_DIR" && chmod 700 "$_QUEUE_DIR"
rm -f "$_NOTIFY"
rm -f "$_QUEUE_DIR"/*.resp.fifo 2>/dev/null
mkfifo -m 600 "$_NOTIFY"

# Keep notify FIFO open O_RDWR so client O_WRONLY opens never block.
exec 5<>"$_NOTIFY" || exit 1

_cleanup() {
    trap - EXIT INT TERM
    rm -f "$_NOTIFY"
    rm -f "$_QUEUE_DIR"/*.resp.fifo 2>/dev/null
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
        find "$_QUEUE_DIR" -maxdepth 1 -name '*.resp.fifo' -mmin +10 -delete 2>/dev/null

    # Require a tab separator. Malformed lines are silently dropped.
    case "$_line" in *$'\t'*) ;; *) continue ;; esac
    _id="${_line%%$'\t'*}"

    # Reject IDs that could escape the queue directory.
    case "$_id" in *[!0-9_]*) continue ;; esac

    _rest="${_line#*$'\t'}"
    _cmd="${_rest%%$'\t'*}"
    _timeout="${_rest#*$'\t'}"
    # Clear timeout if missing or non-numeric; atcli will use its built-in default.
    case "$_timeout" in ''|"$_cmd"|*[!0-9]*) _timeout= ;; esac

    [ -z "$_cmd" ] && continue

    _resp_fifo="$_QUEUE_DIR/${_id}.resp.fifo"

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
