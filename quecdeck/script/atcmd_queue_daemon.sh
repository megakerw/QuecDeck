#!/bin/bash
# AT command queue daemon.
#
# Processes AT commands one at a time in submission order — each command is
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
    # Require a tab separator — malformed lines are silently dropped.
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

    # Normal AT command — dispatch via atcli and deliver response.
    # Strip \r — atcli does not strip CR from modem's \r\n line endings.
    _result=$("$_ATCLI" ${_timeout:+-t "$_timeout"} "$_cmd" 2>/dev/null | tr -d '\r')

    if [ -p "$_resp_fifo" ]; then
        exec 6<>"$_resp_fifo"
        printf '%s\n' "$_result" >&6
        exec 6>&-
    fi
done
