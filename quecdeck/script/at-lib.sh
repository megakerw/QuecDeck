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
#     Root callers use it too; root reaches the socket (device-verified
#     via tools/device-test-sockpairs.sh).
# atcmd_fire <cmd> [timeout_ms] - fire-and-forget: the daemon executes even
#     after the caller is gone. REQUIRED for modem reboots (CFUN=1,1); a
#     plain atcmd_run whose sender exits early is skipped, not executed.

# Default-assigned so host tests can override them; CGI environments can't
# (request headers only surface as HTTP_* variables). _ATCLI_SOCK is also
# the daemon-up probe for pollers: [ -S "$_ATCLI_SOCK" ].
: "${_ATCLI:=/usrdata/quecdeck/atcli}"
: "${_ATCLI_SOCK:=/tmp/quecdeck/atcli.sock}"

atcmd_run() {
    "$_ATCLI" -s "$_ATCLI_SOCK" ${2:+-t "$2"} "$1" 2>/dev/null
}

atcmd_fire() {
    "$_ATCLI" --detach -s "$_ATCLI_SOCK" ${2:+-t "$2"} "$1" 2>/dev/null
}
