#!/bin/bash
# Shared CGI helpers — source this at the top of each CGI script:
#   . /usrdata/quecdeck/www/cgi-bin/cgi-lib.sh

# Reject cross-origin requests. Doubles as CSRF protection: browsers always send
# the Origin header on cross-origin requests (including form POSTs), so a
# malicious page on another origin will be blocked here. Absent Origin (curl,
# wget, same-origin navigation) is allowed. Call before emitting any HTTP headers.
cgi_check_cors() {
    if [ -n "$HTTP_ORIGIN" ]; then
        case "$HTTP_ORIGIN" in
            "https://${HTTP_HOST}"|"http://${HTTP_HOST}") ;;
            *)
                printf "Status: 403 Forbidden\r\nContent-type: text/plain\r\n\r\nForbidden\n"
                exit 1
                ;;
        esac
    fi
}

# Exit 405 if request method is not POST. Also enforces same-origin (CSRF guard)
# automatically so POST handlers cannot accidentally skip the check.
cgi_require_post() {
    cgi_check_cors
    if [ "$REQUEST_METHOD" != "POST" ]; then
        printf "Status: 405 Method Not Allowed\r\nAllow: POST\r\nContent-type: text/plain\r\n\r\nMethod Not Allowed\n"
        exit 1
    fi
}

# Read POST body into $post_data, capped at max_bytes (default 4096).
# Usage: cgi_read_post [max_bytes]
cgi_read_post() {
    local max="${1:-4096}"
    post_data=""
    if [ -n "$CONTENT_LENGTH" ] && [ "$CONTENT_LENGTH" -gt 0 ] && [ "$CONTENT_LENGTH" -le "$max" ]; then
        post_data=$(head -c "$CONTENT_LENGTH")
    fi
}

# URL-decode a string (application/x-www-form-urlencoded).
# Uses awk rather than printf '%b' to avoid interpreting escape sequences
# such as \c (stop output) or \0 (null byte) in caller-supplied input.
urldecode() {
    printf '%s' "${*//+/ }" | awk '
    BEGIN { for (i=0; i<=255; i++) _h[sprintf("%02X",i)] = sprintf("%c",i) }
    { s=$0; o=""
      while (match(s, /%[0-9A-Fa-f][0-9A-Fa-f]/)) {
          o = o substr(s,1,RSTART-1) _h[toupper(substr(s,RSTART+1,2))]
          s = substr(s,RSTART+RLENGTH)
      }
      printf "%s%s", o, s }'
}

# Extract and URL-decode a named parameter from $post_data.
# Usage: val=$(get_post_param name)
get_post_param() {
    urldecode "$(printf '%s' "$post_data" | tr '&' '\n' | grep "^${1}=" | head -1 | cut -d'=' -f2-)"
}

# Emit a text/plain Content-Type header. Call once before any output.
cgi_output_text() {
    printf 'Content-type: text/plain\r\n\r\n'
}

# Emit an application/json Content-Type header. Call once before any output.
cgi_output_json() {
    printf 'Content-type: application/json\r\n\r\n'
}

# Print an error message and exit 1. cgi_output_text/json must be called first.
# Usage: cgi_error "message"
cgi_error() {
    echo "$*"
    exit 1
}

# ---------------------------------------------------------------------------
# On-demand AT response cache.
#
# Read CGIs call cache_get_or_fetch — response is served from a file if fresh,
# otherwise fetched live, cached atomically via temp+mv, and returned.
# Write CGIs call cache_refresh on directly affected files (so the next page
# render sees immediate results) and cache_invalidate on secondary files.
# During an active cell scan (qscan.active flag), cached data is served
# unconditionally so AT commands are not sent to a busy modem.
#
# Validation: responses are only cached if the last non-empty line is exactly
# "OK" AND the response contains every required pattern string supplied by the
# caller. Patterns are passed as positional args after sock_timeout; zero
# patterns means only the OK check applies. This catches the case where a
# stale response from a different AT command leaks in and still ends with OK.
# ERROR/CME/CMS responses and empty results are rejected; stale cache is
# served instead.
#
# Retry: cache_get_or_fetch retries once if the response fails validation but
# is non-empty (modem returned ERROR or wrong content). Empty results — where
# the modem is silent and the handler timed out — are not retried to avoid
# stacking up timeout delays that would exceed the client request timeout.
# ---------------------------------------------------------------------------
_CACHE_DIR=/tmp/quecdeck/cache

_CACHE_MODEM_ALL="$_CACHE_DIR/modem_stats_all"
_CACHE_DEVICE_INFO="$_CACHE_DIR/device_info"
_CACHE_NEIGHBOUR="$_CACHE_DIR/neighbour_cells"
_CACHE_SETTINGS="$_CACHE_DIR/settings"
_CACHE_NETWORK="$_CACHE_DIR/network"

# Returns 0 if cache file exists and is younger than ttl seconds.
cache_is_fresh() {
    local f="$1" ttl="$2" mtime age
    [ -f "$f" ] || return 1
    mtime=$(stat -c %Y "$f" 2>/dev/null) || return 1
    age=$(( $(date +%s) - mtime ))
    [ "$age" -lt "$ttl" ]
}

# Returns 0 if an AT response is valid (last non-empty line is exactly OK).
at_response_ok() {
    local last
    last=$(printf '%s' "$1" | awk 'NF{last=$0} END{print last}')
    [ "$last" = "OK" ]
}

# Returns 0 if response ends with OK and contains every required pattern.
# Usage: _at_result_ok <response> [pattern ...]
_at_result_ok() {
    local _res="$1"; shift
    at_response_ok "$_res" || return 1
    local _p
    for _p in "$@"; do
        printf '%s' "$_res" | grep -qF "$_p" || return 1
    done
}

# Atomically write content to a cache file via temp file + mv.
# Cache dir is 700 so only its owner can enter — files inside are 644 so that
# root (debug) and www-data (CGI) can both read them regardless of which user
# created the file. The directory's 700 is the security boundary.
cache_write() {
    local f="$1" content="$2" tmp
    tmp="${f}.tmp.$$"
    mkdir -p "$_CACHE_DIR" && chmod 700 "$_CACHE_DIR"
    printf '%s' "$content" > "$tmp" && chmod 644 "$tmp" && mv "$tmp" "$f"
}

# Remove one or more cache files to force a live fetch on next read.
cache_invalidate() {
    rm -f "$@"
}

# Run an AT command unconditionally, cache the result silently.
# Used by write CGIs to warm the cache after changing modem settings.
# Accepts the same required-pattern varargs as cache_get_or_fetch.
cache_refresh() {
    local f="$1" at_cmd="$2" at_timeout="${3:-5000}"
    shift 3 2>/dev/null || shift "$#"
    local result
    result=$(atcmd_run "$at_cmd" "$at_timeout")
    _at_result_ok "$result" "$@" && cache_write "$f" "$result"
}

# Serve from cache if fresh; otherwise run AT command, cache, and serve.
# Serves existing cache (without refreshing) during an active cell scan.
# Retries once on a non-empty invalid response before falling back to stale
# cache; see block comment above for the retry/validation policy.
#
# No per-file locking: concurrent misses for the same file each submit an AT
# command to the daemon queue. The daemon serialises them; the result is the
# same for all callers and the cost of a duplicate command is one extra
# 50-100 ms round trip — cheaper than returning empty on first boot.
cache_get_or_fetch() {
    local f="$1" ttl="$2" at_cmd="$3"
    shift 3 2>/dev/null || shift "$#"
    # $@ now holds the required patterns (zero or more).
    # Note: shift 3 fails silently if fewer than 3 args were supplied; the
    # fallback shift "$#" clears all positional params so $@ is empty rather
    # than leaking the fixed args (f, ttl, at_cmd) into the pattern-check loop.
    local result
    if [ -f /tmp/quecdeck/qscan.active ]; then
        # Treat as stale if older than 5 minutes — max scan is 215 s, so a
        # flag this old means the scan process was killed without cleanup.
        if find /tmp/quecdeck/qscan.active -mmin +5 2>/dev/null | grep -q .; then
            rm -f /tmp/quecdeck/qscan.active
        else
            [ -f "$f" ] && cat "$f"
            return
        fi
    fi
    if cache_is_fresh "$f" "$ttl"; then
        cat "$f"
        return
    fi
    # Ensure cache dir exists (tmpfs is empty after boot).
    # 700: cache files contain sensitive modem data (IPs, APN, cell info).
    mkdir -p "$_CACHE_DIR" && chmod 700 "$_CACHE_DIR"
    # Retry once only if the modem returned a non-empty response that didn't end
    # with OK — those are transient errors where a second attempt may succeed.
    # If the result is empty (timeout) or ended with OK but failed pattern checks
    # (wrong content), retrying won't help and only adds latency.
    local attempt=0
    result=""
    while [ $attempt -lt 2 ]; do
        result=$(atcmd_run "$at_cmd" 5000)
        _at_result_ok "$result" "$@" && break
        [ -z "$result" ] && break
        at_response_ok "$result" && break
        attempt=$((attempt + 1))
    done
    if _at_result_ok "$result" "$@"; then
        cache_write "$f" "$result"
        printf '%s' "$result"
    else
        # All attempts failed — serve stale cache rather than bad data.
        [ -f "$f" ] && cat "$f"
    fi
}

# Send an AT command (or semicolon-joined batch) to the modem and return the
# response on stdout, with \r stripped from each line.
#
# When the atcmd-queue-daemon is running (/tmp/quecdeck/atcmd.notify exists
# as a named pipe), the command is submitted to the daemon's FIFO queue.
# Commands are processed strictly in submission order; each command is fully
# sent and its response received before the next begins. The response is
# delivered via a per-request named pipe — zero extra latency, no polling.
#
# Queue depth limit: if _ATCMD_QUEUE_LIMIT requests are already pending, the
# call blocks (sleeping 1 s per retry) until a slot opens or at_timeout
# elapses, at which point it returns empty.
#
# The notify FIFO is kept open O_RDWR by the daemon so client O_WRONLY opens
# (plain shell redirects) always complete immediately without blocking.
#
# Fallback (no daemon): atcli directly on /dev/smd11.
#
# Usage: atcmd_run <cmd> [at_timeout_ms]
_ATCMD_NOTIFY=/tmp/quecdeck/atcmd.notify
_ATCMD_QUEUE=/tmp/quecdeck/queue
_ATCMD_QUEUE_LIMIT=10


atcmd_run() {
    local cmd="$1"
    local at_timeout="${2:-5000}"
    local _id _resp _waited _queued _f _line _resp_data

    if [ -p "$_ATCMD_NOTIFY" ]; then
        # Wait for a free slot in the queue.
        _waited=0
        while true; do
            _queued=0
            for _f in "$_ATCMD_QUEUE"/*.resp.fifo; do
                [ -p "$_f" ] && _queued=$((_queued + 1))
            done
            [ "$_queued" -lt "$_ATCMD_QUEUE_LIMIT" ] && break
            sleep 1
            _waited=$((_waited + 1))
            [ "$_waited" -ge "$(( at_timeout / 1000 ))" ] && return
        done

        _id="${$}_${SECONDS}_${RANDOM}"
        _resp="$_ATCMD_QUEUE/${_id}.resp.fifo"

        mkfifo "$_resp" 2>/dev/null || return

        # Open response FIFO before notifying the daemon. The daemon may
        # process the command and close its fd before this process is
        # scheduled again — holding our own fd open keeps the pipe buffer
        # alive so the response is not lost.
        exec 8<>"$_resp"

        # Notify daemon: write id\tcmd\ttimeout_ms in a single atomic write (well
        # under PIPE_BUF so no interleaving with concurrent clients). Timeout is
        # in milliseconds and forwarded directly to atcli -t. Long-running commands
        # (e.g. QSCAN at 215000 ms) get the right deadline this way. The daemon
        # holds the notify FIFO open O_RDWR so this O_WRONLY open always completes
        # immediately — no blocking, no fork.
        # On failure, clean up and return empty rather than falling back to
        # atcli, which would race against the daemon for /dev/smd11.
        printf '%s\t%s\t%s\n' "$_id" "$cmd" "$at_timeout" > "$_ATCMD_NOTIFY" || {
            exec 8>&-
            rm -f "$_resp"
            return
        }
        _resp_data=''

        # Block until the first line arrives (up to at_timeout converted to seconds).
        # All subsequent lines are already buffered at this point and drain
        # without delay.
        if IFS= read -r -t "$(( at_timeout / 1000 ))" _line <&8; then
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
        /usrdata/quecdeck/atcli -t "$at_timeout" "$cmd" 2>/dev/null | tr -d '\r'
    fi
}
