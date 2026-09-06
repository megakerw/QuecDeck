#!/bin/bash
# AT command access layer. Only this file may invoke atcli. The pre-commit
# hook rejects atcli calls anywhere else. Source it with:
#   . /usrdata/quecdeck/script/at-lib.sh
#
# atcli serializes every command through its daemon (atcli --daemon, unit
# atcmd-daemon), connection-per-command over a unix socket. Responses arrive
# with \r stripped. Empty output means timeout or a down daemon. A sender that
# dies while queued is skipped (socket hangup detection). The binary is not
# setuid and never falls back to the port on its own, so a down daemon gives
# root and www-data alike empty output until systemd restarts it (~5 s). The
# direct-port path is root-only and must be asked for with --direct.
#
# atcmd_run <cmd> [timeout_ms]  - send, wait, print the response on stdout.
#     The exit status is the failure signal. Non-zero with no output is a
#     timeout or a down daemon. Non-zero with output is a reply the modem began
#     and never terminated, which the bytes themselves cannot show, so whether
#     it is usable belongs at the call site. A pipe masks the status, so a
#     caller that needs it must assign first, then pipe.
# atcmd_fire <cmd> [timeout_ms] - fire-and-forget: the daemon executes even
#     after the caller is gone, which modem reboots (CFUN=1,1) require.
#     timeout_ms bounds only how long --detach waits to drain the response,
#     not whether or when the command executes.
#
# Both turn atcli's "command too long" status into an ERROR line in the body.
# atcli names the length on stderr, correct for it but invisible to a page:
# at_result, at_response_ok and the CGIs look for ERROR in the body, and a
# refusal would otherwise read as "no response from the modem".

# Default-assigned so host tests can override them. CGI environments cannot
# (request headers only surface as HTTP_* variables). _ATCLI_SOCK is also
# the daemon-up probe for pollers: [ -S "$_ATCLI_SOCK" ].
: "${_ATCLI:=/usrdata/quecdeck/atcli}"
: "${_ATCLI_SOCK:=/run/quecdeck-web/atcli.sock}"

# atcli's exit status for a command past the daemon's CMD_MAX (E_CMD_TOO_LONG
# in its src/proto.rs). The limit itself stays there so it has one home. Drift
# only costs the body line below, leaving the generic "no response" message.
# Only tests/device/device-test-atclid.sh can catch that drift: the host suite
# stubs atcli with this same constant.
: "${_AT_E_TOOLONG:=65}"

# Appended after atcli returns, not captured: stdout is empty on a refusal and
# capturing would cost a subshell on every AT command. Status passes through
# untouched. The 2>/dev/null below discards atcli's own message and the daemon
# never sees the command, so nothing else records the refusal.
_atcmd_report() {
    [ "$1" -eq "$_AT_E_TOOLONG" ] || return "$1"
    local msg="ERROR: AT command too long for the daemon. Split it."
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
