#!/bin/bash
# AT command access layer. Only this file may invoke atcli; the pre-commit
# hook rejects atcli calls anywhere else. Source it with:
#   . /usrdata/quecdeck/script/at-lib.sh
#
# atcli serializes all commands through its own daemon side (atcli --daemon,
# unit atcmd-daemon): connection-per-command over a unix socket. Responses
# arrive \r-stripped; empty output means timeout OR the daemon is down. A
# waiting sender that dies while queued is skipped by the daemon (socket
# hangup detection). atcli is NOT setuid and does NOT auto-fall-back to the
# port: when the daemon is down every caller (root and www-data alike) gets
# empty output until systemd restarts it (within ~5 s). The direct-port path
# is root-only and must be requested explicitly with --direct (break-glass).
#
# atcmd_run <cmd> [timeout_ms]  - send, wait for the response on stdout.
#     Prints whatever arrived; the exit status is the failure signal. Non-zero
#     with no output is a timeout or a down daemon; non-zero WITH output is a
#     reply the modem began and never terminated (no OK/ERROR within the
#     timeout), which the bytes themselves cannot show.
#     Whether a partial reply is usable depends on the command, so that call
#     belongs at the call site. A pipe masks the status ($? is the last
#     stage), so a caller that needs it must assign first, then pipe.
#     Root callers use it too; root reaches the socket (device-verified
#     via tools/device-test-sockpairs.sh).
# atcmd_fire <cmd> [timeout_ms] - fire-and-forget: the daemon executes even
#     after the caller is gone. REQUIRED for modem reboots (CFUN=1,1); a
#     plain atcmd_run whose sender exits early is skipped, not executed.
#     timeout_ms bounds only how long --detach waits to drain the response,
#     not whether or when the command executes.

# Default-assigned so host tests can override them; CGI environments can't
# (request headers only surface as HTTP_* variables). _ATCLI_SOCK is also
# the daemon-up probe for pollers: [ -S "$_ATCLI_SOCK" ].
: "${_ATCLI:=/usrdata/quecdeck/atcli}"
: "${_ATCLI_SOCK:=/tmp/quecdeck/atcli.sock}"

atcmd_run() {
    # atcli last: the function's exit status is atcli's, and callers check it.
    "$_ATCLI" -s "$_ATCLI_SOCK" ${2:+-t "$2"} "$1" 2>/dev/null
}

atcmd_fire() {
    "$_ATCLI" --detach -s "$_ATCLI_SOCK" ${2:+-t "$2"} "$1" 2>/dev/null
}
