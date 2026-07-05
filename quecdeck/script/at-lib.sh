#!/bin/bash
# AT command access layer. Only this file and the queue daemon (the
# dispatcher) may invoke atcli directly; the pre-commit hook rejects atcli
# calls anywhere else. Source it with:
#   . /usrdata/quecdeck/script/at-lib.sh
#
# atcli emits raw modem \r\n line endings; both wrappers strip \r.
#
# atcmd_run <cmd> [timeout_ms]    - serialized via the queue daemon; falls
#     back to direct atcli when the daemon is down.
# atcli_direct <cmd> [timeout_ms] - bypasses the queue, for root-context
#     callers: keeps root independent of the www-data queue and of whether
#     cross-domain FIFO writes are permitted on a given firmware build.

# Default-assigned so the host-side daemon test (tools/host-test-atqueue.sh)
# can point them at a temp dir and a stub atcli. Not settable via HTTP: CGI
# request headers only surface as HTTP_* variables.
: "${_ATCMD_NOTIFY:=/tmp/quecdeck/atcmd.notify}"
: "${_ATCMD_QUEUE:=/tmp/quecdeck/queue}"
: "${_ATCLI:=/usrdata/quecdeck/atcli}"

# Uptime, not wall clock: deadlines must survive the clock stepping when
# NITZ/NTP first syncs. Both FIFO ends are in the same boot by definition.
_atq_uptime() { awk '{print int($1)}' /proc/uptime; }

atcli_direct() {
    "$_ATCLI" ${2:+-t "$2"} "$1" 2>/dev/null | tr -d '\r'
}

# Send an AT command to the modem via the queue daemon (if running) and return
# the response on stdout with \r stripped. Falls back to atcli directly if the
# daemon is not up. Returns empty on timeout.
#
# Usage: atcmd_run <cmd> [at_timeout_ms]
atcmd_run() {
    local cmd="$1"
    local at_timeout="${2:-3000}"
    local _id _resp _line _resp_data _to_secs

    # The notify protocol is tab/newline framed; strip both from the command
    # (user_atcommand accepts URL-decoded input that may contain them).
    cmd="${cmd//$'\t'/ }"; cmd="${cmd//$'\n'/ }"; cmd="${cmd//$'\r'/ }"

    # Whole-second timeout for read/sleep loops, floored at 1: integer division
    # of a sub-1000 ms timeout yields 0, and "read -t 0" returns immediately
    # without reading instead of waiting.
    _to_secs=$(( at_timeout / 1000 ))
    [ "$_to_secs" -lt 1 ] && _to_secs=1

    if [ -p "$_ATCMD_NOTIFY" ]; then
        _id="${$}_${SECONDS}_${RANDOM}"
        _resp="$_ATCMD_QUEUE/${_id}.resp.fifo"

        mkfifo "$_resp" 2>/dev/null || return

        # Open before notifying; if the daemon responds before we're scheduled,
        # holding fd 8 keeps the pipe buffer alive so the response is not lost.
        exec 8<>"$_resp"

        # Notify daemon: id\tcmd\ttimeout_ms\tdeadline_uptime in one atomic
        # write (under PIPE_BUF). The daemon skips lines whose deadline has
        # passed, so a command's timeout doubles as its right-to-execute:
        # senders that must run even after they stop waiting (reboots) pass a
        # timeout covering the longest possible queue occupant.
        printf '%s\t%s\t%s\t%s\n' "$_id" "$cmd" "$at_timeout" "$(( $(_atq_uptime) + _to_secs ))" > "$_ATCMD_NOTIFY" || {
            exec 8>&-
            rm -f "$_resp"
            return
        }
        _resp_data=''

        # Block until the first line arrives (up to at_timeout converted to seconds).
        # All subsequent lines are already buffered at this point and drain
        # without delay.
        if IFS= read -r -t "$_to_secs" _line <&8; then
            _resp_data="$_line"
            case "$_line" in OK|ERROR|'+CME ERROR:'*|'+CMS ERROR:'*) : ;;
            *)
                while IFS= read -r -t 1 _line <&8; do
                    _resp_data="${_resp_data}${_resp_data:+$'\n'}${_line}"
                    case "$_line" in OK|ERROR|'+CME ERROR:'*|'+CMS ERROR:'*) break ;; esac
                done
            esac
        fi

        exec 8>&-
        rm -f "$_resp"
        printf '%s\n' "$_resp_data"
    else
        atcli_direct "$cmd" "$at_timeout"
    fi
}
