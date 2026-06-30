#!/bin/bash
# Shared CGI helpers. Source this at the top of each CGI script:
#   . /usrdata/quecdeck/script/cgi-lib.sh

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
    _cgi_headers_sent=1
}

# Emit an application/json Content-Type header. Call once before any output.
cgi_output_json() {
    printf 'Content-type: application/json\r\n\r\n'
    _cgi_headers_sent=1
}

# Print an error message and exit 1.
# If called before cgi_output_text/json, sends a real 400 status so the
# client can detect failure via the response status rather than having to
# parse the body text. If called after (the older, still-supported pattern
# many scripts use), headers are already committed to 200, so the message
# is just the body text as before.
# Usage: cgi_error "message"
cgi_error() {
    if [ -z "$_cgi_headers_sent" ]; then
        printf 'Status: 400 Bad Request\r\nContent-type: text/plain\r\n\r\n'
    fi
    echo "$*"
    exit 1
}

# Verify a password against an htpasswd file (SHA-512 crypt format).
# Usage: validate_htpasswd <htpasswd_file> <username> <password>
validate_htpasswd() {
    local htpasswd_file="$1" username="$2" password="$3"
    [ -f "$htpasswd_file" ] || return 1
    local line
    line=$(grep "^${username}:" "$htpasswd_file" 2>/dev/null | head -1)
    [ -n "$line" ] || return 1
    local stored_hash="${line#*:}"
    local salt computed
    salt=$(printf '%s' "$stored_hash" | awk -F'[$]' '{print $3}')
    computed=$(printf '%s' "$password" | openssl passwd -6 -salt "$salt" -stdin 2>/dev/null)
    [ "$computed" = "$stored_hash" ]
}

# Append a JSON log entry to an access log file, capped at 500 lines.
# Usage: log_access_event <log_file> <json_string>
log_access_event() {
    local log_file="$1" entry="$2"
    mkdir -p "$(dirname "$log_file")" && chmod 700 "$(dirname "$log_file")"
    printf '%s\n' "$entry" >> "$log_file"
    local count
    count=$(wc -l < "$log_file" 2>/dev/null || echo 0)
    if [ "$count" -gt 500 ]; then
        tail -500 "$log_file" > "${log_file}.tmp" && mv "${log_file}.tmp" "$log_file"
    fi
}

# ---------------------------------------------------------------------------
# Client identity + per-IP brute-force lockout. Shared by auth_login and
# auth_dev so the lockout policy lives in one place. Each failure record is one
# file per IP under a caller-supplied dir: "count=<n>\nlockout_until=<epoch>".
# After BF_MAX_ATTEMPTS failures a BF_LOCKOUT_SECS lockout is applied.
# ---------------------------------------------------------------------------
BF_MAX_ATTEMPTS=5
BF_LOCKOUT_SECS=900

# Sanitized client IP, safe to embed in a filename or JSON. Never empty.
cgi_client_ip() {
    local ip
    ip=$(printf '%s' "${REMOTE_ADDR:-unknown}" | tr -cd 'A-Fa-f0-9.:')
    printf '%s' "${ip:-unknown}"
}

# WAN IP from the bridge0 link route. May be empty (no bearer).
cgi_wan_ip() {
    /sbin/ip route show dev bridge0 2>/dev/null | awk '/scope link/{print $1; exit}'
}

# Map a client IP to its failure-record path under <dir>, ensuring <dir> exists
# 0700. Opportunistically prunes records older than a day (~1% of calls);
# lockouts last 15 min, so a day-old record is always expired.
_bf_file() {
    local dir="$1" ip="$2"
    mkdir -p "$dir" && chmod 700 "$dir"
    [ $(( RANDOM % 100 )) -eq 0 ] && find "$dir" -maxdepth 1 -type f -mtime +1 -delete 2>/dev/null
    printf '%s/%s' "$dir" "${ip//:/_}"
}

# Returns 0 if <ip> is currently locked out under <dir>.
# Usage: bf_locked <dir> <ip>
bf_locked() {
    local f lockout_until
    f=$(_bf_file "$1" "$2")
    [ -f "$f" ] || return 1
    lockout_until=$(grep '^lockout_until=' "$f" | cut -d= -f2)
    [ -n "$lockout_until" ] && [ "$lockout_until" -gt "$(date +%s)" ]
}

# Records a failed attempt for <ip> under <dir>, after a 1s delay. Echoes
# "locked" if this attempt triggered the lockout, else "failed".
# Usage: result=$(bf_fail <dir> <ip>)
bf_fail() {
    local f count now
    f=$(_bf_file "$1" "$2")
    sleep 1
    count=0
    [ -f "$f" ] && count=$(grep '^count=' "$f" | cut -d= -f2)
    count=$(( ${count:-0} + 1 ))
    now=$(date +%s)
    if [ "$count" -ge "$BF_MAX_ATTEMPTS" ]; then
        printf 'count=0\nlockout_until=%s\n' "$(( now + BF_LOCKOUT_SECS ))" > "$f"
        echo "locked"
    else
        printf 'count=%s\nlockout_until=0\n' "$count" > "$f"
        echo "failed"
    fi
}

# Clears the failure record for <ip> under <dir>. Call on a successful auth.
# Usage: bf_clear <dir> <ip>
bf_clear() {
    rm -f "$(_bf_file "$1" "$2")"
}

# ---------------------------------------------------------------------------
# On-demand AT response cache.
#
# Read CGIs call cache_get_or_fetch: response is served from a file if fresh,
# otherwise fetched live, cached atomically via temp+mv, and returned.
# Write CGIs call cache_refresh on directly affected files (so the next page
# render sees immediate results) and cache_invalidate on secondary files.
# During an active cell scan (qscan.active flag), cached data is served
# unconditionally so AT commands are not sent to a busy modem.
#
# Validation: responses are only cached if the last non-empty line is exactly
# "OK". ERROR/CME/CMS responses and empty results are rejected; stale cache
# is served instead.
#
# Retry: cache_get_or_fetch retries once if the response is non-empty but
# didn't end with OK (transient modem error). Empty results (where the modem
# is silent and the handler timed out) are not retried to avoid stacking up
# timeout delays that would exceed the client request timeout.
# ---------------------------------------------------------------------------
_CACHE_DIR=/tmp/quecdeck/cache

_CACHE_MODEM_ALL="$_CACHE_DIR/modem_stats_all"
_CACHE_DEVICE_INFO="$_CACHE_DIR/device_info"
_CACHE_DEVICE_SIM="$_CACHE_DIR/device_sim"
_CACHE_NEIGHBOUR="$_CACHE_DIR/neighbour_cells"
_CACHE_SETTINGS="$_CACHE_DIR/settings"
_CACHE_NETWORK="$_CACHE_DIR/network"
_CACHE_MODEM_CONN="$_CACHE_DIR/modem_conn"

# Returns 0 if cache file exists and is younger than ttl seconds.
cache_is_fresh() {
    local f="$1" ttl="$2" mtime age now
    [ -f "$f" ] || return 1
    mtime=$(stat -c %Y "$f" 2>/dev/null) || return 1
    # $EPOCHSECONDS (bash 5+) avoids a date(1) fork on the hot cache-hit path;
    # falls back to date(1) on older bash where it's empty (else age goes
    # negative and stale cache is served forever).
    now=${EPOCHSECONDS:-$(date +%s)}
    age=$(( now - mtime ))
    [ "$age" -lt "$ttl" ]
}

# Returns 0 if an AT response is valid (last non-empty line is exactly OK).
at_response_ok() {
    local last
    last=$(printf '%s' "$1" | awk 'NF{last=$0} END{print last}')
    [ "$last" = "OK" ]
}


# Atomically write content to a cache file via temp file + mv.
# Cache dir is 700 so only its owner can enter, but files inside are 644 so that
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
    local f="$1" at_cmd="$2" at_timeout="${3:-3000}"
    local result
    result=$(atcmd_run "$at_cmd" "$at_timeout")
    at_response_ok "$result" && cache_write "$f" "$result"
}

# Serve from cache if fresh; otherwise run AT command, cache, and serve.
# Serves existing cache (without refreshing) during an active cell scan.
# Retries once on a non-empty invalid response before falling back to stale
# cache; see block comment above for the retry/validation policy.
#
# No per-file locking: concurrent misses each submit an AT command; the daemon
# serialises them. Duplicate cost is ~50-100 ms, cheaper than an empty result.
cache_get_or_fetch() {
    local f="$1" ttl="$2" at_cmd="$3" at_timeout="${4:-3000}"
    local result
    if [ -f /tmp/quecdeck/qscan.active ]; then
        # Treat as stale if older than 5 minutes (max scan is 215 s), so a
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
    # Retry once if the modem returned a non-empty response that didn't end with
    # OK: those are transient errors where a second attempt may succeed.
    # Empty results (timeout) are not retried to avoid stacking timeout delays.
    local attempt=0
    result=""
    while [ $attempt -lt 2 ]; do
        result=$(atcmd_run "$at_cmd" "$at_timeout")
        at_response_ok "$result" && break
        [ -z "$result" ] && break
        attempt=$((attempt + 1))
    done
    if at_response_ok "$result"; then
        cache_write "$f" "$result"
        printf '%s' "$result"
    else
        # All attempts failed. Serve stale cache rather than bad data.
        [ -f "$f" ] && cat "$f"
    fi
}

# ---------------------------------------------------------------------------
# Snapshot resource definitions: one source of truth for each source's cache
# key + AT command + TTL. Called by both the standalone read CGIs and the
# bundled snapshots (get_dashboard, get_deviceinfo), so the two can't drift.
# ---------------------------------------------------------------------------

# Modem statistics: temperature, serving cell, CA info, signal, traffic
# counters, SIM slot/status, operator. Cached 3 s under _CACHE_MODEM_ALL,
# 2 s AT timeout.
modem_stats_fetch() {
    cache_get_or_fetch "$_CACHE_MODEM_ALL" 3 \
        'AT+QTEMP;+QENG="servingcell";+QCAINFO;+CSQ;+QGDNRCNT?;+QGDCNT?;+QUIMSLOT?;+QSPN;+QSIMSTAT?' 2000
}

# Connection info: WWAN IP(s) and APN. Connection-dependent, so it may fail with
# no active bearer; callers fall back gracefully. Cached 3 s, 2 s AT timeout.
modem_conn_fetch() {
    cache_get_or_fetch "$_CACHE_MODEM_CONN" 3 'AT+QMAP="WWANIP";+CGCONTRDP' 2000
}

# Device identity: manufacturer, model, firmware, IMEI, build time. Effectively
# static, so cached 1 h under _CACHE_DEVICE_INFO.
device_info_fetch() {
    cache_get_or_fetch "$_CACHE_DEVICE_INFO" 3600 'AT+CGMI;+CGMM;+QGMR;+CGSN;+CVERSION'
}

# SIM identity: IMSI, ICCID, phone number. SIM-dependent, so it errors with no
# SIM; callers handle absent fields gracefully. Cached 3 s (matching
# modem_conn so the two short-lived batches refresh together), 2 s AT timeout.
device_sim_fetch() {
    cache_get_or_fetch "$_CACHE_DEVICE_SIM" 3 'AT+CIMI;+ICCID;+CNUM' 2000
}

# Host stats as JSON: load average, RAM, uptime. Reads /proc and `uptime`
# directly (no AT). The uptime line has no " or \, so it's JSON-safe unescaped.
# Emits the body only (no HTTP header), so callers control framing.
system_stats_json() {
    local load mem_total mem_available mem_used mem_total_mb mem_used_mb mem_percent up
    load=$(cut -d' ' -f1 /proc/loadavg)
    mem_total=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
    mem_available=$(awk '/MemAvailable/ {print $2}' /proc/meminfo)
    mem_used=$((mem_total - mem_available))
    mem_total_mb=$((mem_total / 1024))
    mem_used_mb=$((mem_used / 1024))
    mem_percent=$((mem_used * 100 / mem_total))
    up=$(uptime)
    printf '{"load_avg":%s,"mem_total_mb":%d,"mem_used_mb":%d,"mem_percent":%d,"uptime":"%s"}' \
        "$load" "$mem_total_mb" "$mem_used_mb" "$mem_percent" "$up"
}

# Send an AT command to the modem via the queue daemon (if running) and return
# the response on stdout with \r stripped. Falls back to atcli directly if the
# daemon is not up. Blocks if the queue is full; returns empty on timeout.
#
# Usage: atcmd_run <cmd> [at_timeout_ms]
_ATCMD_NOTIFY=/tmp/quecdeck/atcmd.notify
_ATCMD_QUEUE=/tmp/quecdeck/queue
_ATCMD_QUEUE_LIMIT=10


atcmd_run() {
    local cmd="$1"
    local at_timeout="${2:-3000}"
    local _id _resp _waited _queued _f _line _resp_data _to_secs

    # Whole-second timeout for read/sleep loops, floored at 1: integer division
    # of a sub-1000 ms timeout yields 0, and "read -t 0" returns immediately
    # without reading instead of waiting.
    _to_secs=$(( at_timeout / 1000 ))
    [ "$_to_secs" -lt 1 ] && _to_secs=1

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
            [ "$_waited" -ge "$_to_secs" ] && return
        done

        _id="${$}_${SECONDS}_${RANDOM}"
        _resp="$_ATCMD_QUEUE/${_id}.resp.fifo"

        mkfifo "$_resp" 2>/dev/null || return

        # Open before notifying; if the daemon responds before we're scheduled,
        # holding fd 8 keeps the pipe buffer alive so the response is not lost.
        exec 8<>"$_resp"

        # Notify daemon: id\tcmd\ttimeout_ms in a single atomic write (under PIPE_BUF).
        # On failure, clean up and return empty.
        printf '%s\t%s\t%s\n' "$_id" "$cmd" "$at_timeout" > "$_ATCMD_NOTIFY" || {
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
        /usrdata/quecdeck/atcli -t "$at_timeout" "$cmd" 2>/dev/null | tr -d '\r'
    fi
}
