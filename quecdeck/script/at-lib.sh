#!/bin/bash
# AT command access layer. Only this file may invoke atcli. The pre-commit
# hook rejects atcli calls anywhere else. Source it with:
#   . /usrdata/quecdeck/script/at-lib.sh
#
# atcli serializes all commands through its own daemon side (atcli --daemon,
# unit atcmd-daemon): connection-per-command over a unix socket. Responses
# arrive with \r stripped. Empty output means timeout or the daemon is down. A
# waiting sender that dies while queued is skipped by the daemon (socket
# hangup detection). The atcli binary is not setuid and does not automatically fall back to the
# port: when the daemon is down every caller (root and www-data alike) gets
# empty output until systemd restarts it (within ~5 s). The direct-port path
# is root-only and must be requested explicitly with --direct (break-glass).
#
# atcmd_run <cmd> [timeout_ms]  - send, wait for the response on stdout.
#     Prints whatever arrived. The exit status is the failure signal. Non-zero
#     with no output is a timeout or a down daemon. Non-zero with output is a
#     reply the modem began and never terminated (no OK/ERROR within the
#     timeout), which the bytes themselves cannot show.
#     Whether a partial reply is usable depends on the command, so that call
#     belongs at the call site. A pipe masks the status ($? is the last
#     stage), so a caller that needs it must assign first, then pipe.
#     Root callers use it too. Root reaches the socket (device-verified
#     via tests/device/device-test-atclid.sh, which exercises the live daemon).
# atcmd_fire <cmd> [timeout_ms] - fire-and-forget: the daemon executes even
#     after the caller is gone. This is required for modem reboots (CFUN=1,1). A
#     plain atcmd_run whose sender exits early is skipped, not executed.
#     timeout_ms bounds only how long --detach waits to drain the response,
#     not whether or when the command executes.
#
# Both turn atcli's "command too long" status into an ERROR line in the body.
# atcli names the length on stderr, which is right for it (stdout is the modem's
# reply) but invisible to a page: at_result, at_response_ok and the CGIs all
# look for ERROR in the body, and without this a refusal reads as "no response
# from the modem", blaming a modem that was never asked.

# Default-assigned so host tests can override them. CGI environments cannot
# (request headers only surface as HTTP_* variables). _ATCLI_SOCK is also
# the daemon-up probe for pollers: [ -S "$_ATCLI_SOCK" ].
: "${_ATCLI:=/usrdata/quecdeck/atcli}"
: "${_ATCLI_SOCK:=/tmp/quecdeck/atcli.sock}"

# atcli's exit status for a command past the daemon's CMD_MAX (E_CMD_TOO_LONG
# in its src/proto.rs). The limit itself is deliberately not copied here, only
# the outcome, so the number has one home. If this constant ever drifts from
# atcli's, the cost is just the body line below going missing and the caller
# seeing the generic "no response from the modem". Degraded, not wrong.
#
# Verified against the real client by tests/device/device-test-atclid.sh, which is the
# only place that can: the host suite stubs atcli with this same code, so it
# asserts the constant against itself and cannot detect drift.
: "${_AT_E_TOOLONG:=65}"

# Appended after atcli returns rather than captured: stdout is empty on a
# refusal, and capturing would cost a subshell on every AT command. Status
# passes through untouched.
# stderr too: atcli's own message is discarded by the 2>/dev/null below, and
# the daemon never sees the command, so nothing else records the refusal.
_atcmd_report() {
    [ "$1" -eq "$_AT_E_TOOLONG" ] || return "$1"
    local msg="ERROR: AT command too long for the daemon; split it"
    printf '%s\n' "$msg" >&2
    printf '%s\n' "$msg"
    return "$1"
}

atcmd_run() {
    "$_ATCLI" -s "$_ATCLI_SOCK" ${2:+-t "$2"} "$1" 2>/dev/null
    _atcmd_report $?
}

atcmd_fire() {
    "$_ATCLI" --detach -s "$_ATCLI_SOCK" ${2:+-t "$2"} "$1" 2>/dev/null
    _atcmd_report $?
}
