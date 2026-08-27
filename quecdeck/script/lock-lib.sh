#!/bin/bash
# Bounded exclusive locking for the root-only credential helpers.
#
# BusyBox flock accepts only -s, -x, -u and -n. The -w timeout is a util-linux
# extension, and Entware does not install util-linux by default, so a device
# falls back to /usr/bin/flock from BusyBox and every -w call fails on a usage
# error. Emulating the wait with -n keeps one behaviour on both builds.
#
# The bound matters: a blocking lock would queue CGI processes for as long as
# an attacker keeps a credential lock busy. Callers report the timeout as
# temporarily unavailable instead.

# Take an exclusive lock on an already-open descriptor, waiting up to <seconds>.
# Returns 0 once held, 1 on timeout. Tries immediately, then once per second.
# Usage: exec 9>>"$lock"; flock_wait 9 5 || exit 75
flock_wait() { # flock_wait <fd> <seconds>
    local _fd="$1" _left="$2"
    case "$_left" in ''|*[!0-9]*) return 1 ;; esac
    while :; do
        flock -n -x "$_fd" && return 0
        [ "$_left" -gt 0 ] || return 1
        _left=$((_left - 1))
        sleep 1
    done
}
