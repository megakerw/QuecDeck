#!/bin/bash
# Shared CGI helpers. Source this at the top of each CGI script:
#   . /usrdata/quecdeck/script/cgi-lib.sh
#
# bash only. BusyBox ash accepts ${var//x/y} and $(<file) here, so a non-bash
# caller looks fine until printf -v, which ash prints to stdout instead of
# assigning: corrupt output rather than an error. Refuse up front.
if [ -z "$BASH_VERSION" ]; then
    echo "cgi-lib.sh requires bash; sourced by a non-bash shell" >&2
    return 1 2>/dev/null || exit 1
fi

# Everything this library writes (cache, logs, lockout counters) is www-data's
# private state, so seal it at the source. umask is a builtin, so this costs no
# fork on the poll path, and unlike a unit's UMask= it holds no matter who
# invokes the caller (sudo, a shell, a future unit that forgets the directive).
# The units set UMask=0077 too, which is what covers auth.lua: it runs inside
# lighttpd as Lua, cannot source this file, and has no chmod. Asserted by
# tests/host/ci-checks.sh and device-test-runsplit.sh.
umask 077

# AT access layer (atcmd_run, atcmd_fire), used by the cache helpers below.
. /usrdata/quecdeck/script/at-lib.sh
# Watchcat pause markers, used by modem-disrupting CGIs.
. /usrdata/quecdeck/script/watchcat-coord.sh

# Reject cross-origin requests. Doubles as CSRF protection: browsers always send
# the Origin header on cross-origin requests (including form POSTs), so a
# malicious page on another origin will be blocked here. Absent Origin (curl,
# wget, same-origin navigation) is allowed. HTTPS only: CGIs are bound to the
# 443 socket, so no legitimate request has an http origin.
# Call before emitting any HTTP headers.
cgi_check_cors() {
    if [ -n "$HTTP_ORIGIN" ]; then
        case "$HTTP_ORIGIN" in
            "https://${HTTP_HOST}") ;;
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

# Print an error message and exit 1. Before cgi_output_text/json: sends a
# real 400 status. After: headers are already committed to 200, so the
# message is body text only.
# Usage: cgi_error "message"
cgi_error() {
    if [ -z "$_cgi_headers_sent" ]; then
        printf 'Status: 400 Bad Request\r\nContent-type: text/plain\r\n\r\n'
    fi
    echo "$*"
    exit 1
}

# Returns 0 if <ip> is a syntactically valid IPv4 address (four 0-255 octets).
# Usage: valid_ipv4 "$ip" || cgi_error "Invalid IP"
# Builtins only, no forks: get_set_lanip calls this three times per read.
valid_ipv4() {
    # Reject anything that isn't digits and dots, and the dot placements that
    # word splitting would otherwise hide: a trailing dot drops an empty field,
    # so "1.2.3.4." would count as four octets.
    case "$1" in
        ''|*[!0-9.]*|.*|*.|*..*) return 1 ;;
    esac
    local o
    local IFS=.
    set -- $1
    [ "$#" -eq 4 ] || return 1
    for o in "$@"; do
        # Length cap first: it bounds the value before the numeric compare, and
        # keeps a 4-digit octet from being read as octal.
        [ "${#o}" -le 3 ] || return 1
        [ "$o" -le 255 ] || return 1
    done
}

# ---------------------------------------------------------------------------
# Modem AP config. The system scripts (lighttpd_prestart.sh, update_sshd_ip.sh,
# firewall.sh) parse this file themselves: they are /bin/sh and do not source
# this library. They deliberately DIVERGE on a missing or malformed LAN IP, and
# must stay that way. The mobileap_lan_ip function explains why.
# ---------------------------------------------------------------------------
MOBILEAP_CFG=/etc/data/mobileap_cfg.xml

# Read one or more tags in a SINGLE pass, setting one variable per tag:
#   mobileap_read APIPAddr UPnP   ->   $mf_APIPAddr, $mf_UPnP
# Absent tags are set empty. The first occurrence wins. Tag names are literals
# supplied by CGIs, never request input.
#
# Call it directly, NOT inside $(...): the variables would die with the subshell.
# Keep the grep: a pure-bash parser measures 2x slower on this ~16 KB config.
mobileap_read() {
    local tag alt line t v seen
    alt=""
    for tag in "$@"; do
        printf -v "mf_$tag" '%s' ''
        printf -v "mfseen_$tag" '%s' ''
        alt="${alt:+$alt|}$tag"
    done
    [ -f "$MOBILEAP_CFG" ] || return 0
    # Heredoc rather than a pipe: a pipe would run the loop in a subshell and
    # the variables set below would be lost.
    #
    # Keep the grep: a pure-bash scan of this 462-line file measured 1.6x to
    # 5.1x slower. A fork beats about 40 lines of bash processing. The threshold
    # and the numbers are in tools/device-costs.md.
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        t="${line%%>*}"; t="${t#<}"
        v="${line#*>}"; v="${v%</*}"
        seen="mfseen_$t"
        [ -n "${!seen}" ] && continue
        printf -v "mfseen_$t" '%s' 1
        printf -v "mf_$t" '%s' "$v"
    done <<EOF
$(grep -oE "<($alt)>[^<]*</($alt)>" "$MOBILEAP_CFG" 2>/dev/null)
EOF
}

# Sets $mf_lan_ip to the configured LAN IP, or empty if absent or malformed.
# Deliberately does NOT default the way lighttpd_prestart.sh does: that fallback
# exists so the server always binds somewhere, whereas a guess here would seed
# the settings form, and saving it would write the guess to the modem for real.
# Reads APIPAddr itself only if the caller has not already batched it in, so it
# stays correct standalone while costing nothing after a mobileap_read.
# Sets a variable rather than echoing, so no caller wraps it in $(...) either.
mobileap_lan_ip() {
    [ -n "${mf_APIPAddr+set}" ] || mobileap_read APIPAddr
    mf_lan_ip=""
    if valid_ipv4 "$mf_APIPAddr"; then
        mf_lan_ip="$mf_APIPAddr"
    fi
}

# Echo "true" if <value> equals <match>, else "false", for building JSON from
# form fields. Usage: enabled=$(json_bool "$ENABLED" enable)
json_bool() {
    [ "$1" = "$2" ] && echo "true" || echo "false"
}

# Atomically write <json> to <path> (temp file + rename) and chmod 640.
# On failure, calls cgi_error (which exits). Used by the config-maker CGIs.
# Usage: write_json_config /usrdata/quecdeck/var/foo.json "$json"
write_json_config() {
    local path="$1" json="$2" tmp
    tmp=$(mktemp "${path}.XXXXXX") || cgi_error "Failed to write config."
    printf '%s\n' "$json" > "$tmp" && mv "$tmp" "$path" \
        || { rm -f "$tmp"; cgi_error "Failed to write config."; }
    chmod 640 "$path"
}

# Serve a JSON file, or <fallback> when it is missing or empty. Emptiness is
# checked, not just existence: a zero-byte file cat'd under a JSON content type
# is an empty body, which the page reads as a failed request rather than as
# "nothing published yet". Usage: cgi_serve_json_file <path> <fallback json>
# Builtin read, not cat: get_watchcat_stats is polled every 2s while the page is
# open and the payload is a few hundred bytes, so the fork+exec cost more than the
# work. Same idiom get_system_status uses. See tools/device-costs.md.
cgi_serve_json_file() {
    cgi_output_json
    if [ -s "$1" ]; then
        local _body
        IFS= read -r -d '' _body < "$1"
        printf '%s' "$_body"
    else
        printf '%s\n' "$2"
    fi
}

# True when <watchcat_config> turns monitoring on. The watchcat unit is
# boot-enabled but exits cleanly when disabled, so configuration and unit state
# answer different questions. Substring match rather than json_get: this runs on polled and
# hot paths and json_get costs up to three grep forks (tools/device-costs.md).
# Both spacings are matched: the makers write ": true", the defaults ":false".
# Usage: watchcat_config_enabled "$config_json"
watchcat_config_enabled() {
    case "$1" in
        *'"enabled":true'*|*'"enabled": true'*) return 0 ;;
    esac
    return 1
}

# Verify a web password via the check_password.sh sudo helper. The htpasswd
# files are root:root 600 and unreadable from the web tier. The helper (root via
# sudo) is the only credential-check path. Password goes over stdin, never
# argv. Usage: validate_password <admin|dev> <username> <password>
validate_password() {
    printf '%s\n' "$3" | /opt/bin/sudo /usrdata/quecdeck/script/check_password.sh "$1" "$2"
}

# Append a JSON log entry to an access log file, capped at 500 lines.
# Usage: log_access_event <log_file> <json_string>
log_access_event() {
    local log_file="$1" entry="$2"
    local log_dir; log_dir=$(dirname "$log_file")
    # umask so the /tmp/quecdeck parent is sealed too, not just the leaf: no
    # root unit pre-creates it any more. Guarded to stay fork-free once created.
    [ -d "$log_dir" ] || { ( umask 077; mkdir -p "$log_dir" ); chmod 700 "$log_dir"; }
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

cgi_flock_available() {
    command -v flock >/dev/null 2>&1
}

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
# 0700. Records older than a day are pruned on about 1% of calls.
# lockouts last 15 min, so a day-old record is always expired.
_bf_file() {
    local dir="$1" ip="$2"
    # The umask seals the /tmp/quecdeck parent as well as the leaf. See cache_write.
    [ -d "$dir" ] || { ( umask 077; mkdir -p "$dir" ); chmod 700 "$dir"; }
    [ $(( RANDOM % 100 )) -eq 0 ] && find "$dir" -maxdepth 1 -type f ! -name '*.lock' -mtime +1 -delete 2>/dev/null
    printf '%s/%s' "$dir" "${ip//:/_}"
}

# Serialize one client's complete authentication decision. Lock files remain
# for the life of the tmpfs so pruning cannot replace an inode that is locked or
# has waiters. Keep the lock across password validation and state updates.
bf_lock() {
    local dir="$1" ip="$2" lock_file
    BF_LOCK_DIR=
    BF_LOCK_IP=
    _bf_file "$dir" probe >/dev/null || return 1
    lock_file="$(_bf_file "$dir" "$ip").lock"
    if ! exec 9>>"$lock_file" || ! flock -x 9; then
        exec 9>&-
        return 1
    fi
    BF_LOCK_DIR=$dir
    BF_LOCK_IP=$ip
}

bf_unlock() {
    BF_LOCK_DIR=
    BF_LOCK_IP=
    exec 9>&-
}

_bf_lock_held() {
    [ -n "${BF_LOCK_DIR:-}" ] && [ "$BF_LOCK_DIR" = "$1" ] \
        && [ -n "${BF_LOCK_IP:-}" ] && [ "$BF_LOCK_IP" = "$2" ]
}

# Returns 0 if <ip> is currently locked out under <dir>.
# The caller must hold bf_lock for <dir>.
# Usage: bf_locked <dir> <ip>
bf_locked() {
    local f lockout_until
    _bf_lock_held "$1" "$2" || return 0
    f=$(_bf_file "$1" "$2")
    [ -f "$f" ] || return 1
    lockout_until=$(grep '^lockout_until=' "$f" | cut -d= -f2)
    [ -n "$lockout_until" ] && [ "$lockout_until" -gt "$(date +%s)" ]
}

# Records a failed attempt for <ip> under <dir>, after a 1s delay. Sets
# BF_FAIL_RESULT to "locked" if this attempt triggered the lockout, otherwise
# "failed". The caller must hold bf_lock for <dir>.
# Usage: bf_fail <dir> <ip>, then read BF_FAIL_RESULT
bf_fail() {
    local f count now
    BF_FAIL_RESULT=locked
    _bf_lock_held "$1" "$2" || return 1
    f=$(_bf_file "$1" "$2")
    sleep 1
    count=$(grep '^count=' "$f" 2>/dev/null | cut -d= -f2)
    count=$(( ${count:-0} + 1 ))
    now=$(date +%s)
    if [ "$count" -ge "$BF_MAX_ATTEMPTS" ]; then
        printf 'count=0\nlockout_until=%s\n' "$(( now + BF_LOCKOUT_SECS ))" > "$f"
        BF_FAIL_RESULT=locked
    else
        printf 'count=%s\nlockout_until=0\n' "$count" > "$f"
        BF_FAIL_RESULT=failed
    fi
}

# Clears the failure record for <ip> under <dir>. Call on a successful auth.
# The caller must hold bf_lock for <dir>.
# Usage: bf_clear <dir> <ip>
bf_clear() {
    _bf_lock_held "$1" "$2" || return 1
    rm -f "$(_bf_file "$1" "$2")"
}

# ---------------------------------------------------------------------------
# On-demand AT response cache.
#
# Read CGIs call cache_get_or_fetch: response is served from a file if fresh,
# otherwise fetched live, cached atomically via temp+mv, and returned.
# Write CGIs call cache_invalidate on every file their change affects. The next
# read fetches live. They do not warm the cache: only a read knows what the
# modem settled on.
# During an active cell scan (qscan.active flag), cached data is served
# unconditionally so AT commands are not sent to a busy modem.
#
# Validation: responses are only cached if the last non-empty line is exactly
# "OK". ERROR/CME/CMS responses and empty results are rejected. Stale cache
# is served instead. Retry policy is documented at cache_get_or_fetch.
#
# File format: first line is the write time in epoch CENTIseconds, rest is the
# AT payload. Age comes from that header, not the mtime, so the read path never
# forks stat(1). Always go through cache_write and cache_read.
# ---------------------------------------------------------------------------
_CACHE_DIR=/tmp/quecdeck/cache

_CACHE_MODEM_ALL="$_CACHE_DIR/modem_stats_all"
_CACHE_DEVICE_INFO="$_CACHE_DIR/device_info"
_CACHE_DEVICE_SIM="$_CACHE_DIR/device_sim"
_CACHE_NEIGHBOUR="$_CACHE_DIR/neighbour_cells"
_CACHE_SETTINGS="$_CACHE_DIR/settings"
_CACHE_NETWORK="$_CACHE_DIR/network"
_CACHE_MODEM_CONN="$_CACHE_DIR/modem_conn"
QSCAN_GUARD_SECS=300

# True while the monotonic cell-scan guard is live. Invalid and expired markers
# are removed. If uptime cannot be read, fail safe: preserving the guard is less
# harmful than sending an AT command into a scan that may still be running.
qscan_is_active() {
    [ -f /tmp/quecdeck/qscan.active ] || return 1
    local expiry="" now
    read -r expiry < /tmp/quecdeck/qscan.active 2>/dev/null || true
    case "$expiry" in
        ''|*[!0-9]*) rm -f /tmp/quecdeck/qscan.active; return 1 ;;
    esac
    now=$(watchcat_uptime) || return 0
    if [ "$expiry" -gt "$now" ] && [ "$expiry" -le "$((now + QSCAN_GUARD_SECS))" ]; then
        return 0
    fi
    rm -f /tmp/quecdeck/qscan.active
    return 1
}

# Sets $_NOW_CS (epoch centiseconds) and $_NOW (epoch seconds) from /proc/uptime
# and /proc/stat's btime. Assigns rather than echoes: a command substitution
# would restore the fork this exists to avoid. $EPOCHSECONDS is bash 5.0, device
# is 3.2.57, and date(1) costs ~3.6x this (tools/device-costs.md). The btime field is
# re-read per call, not memoized, so a clock step is seen.
#
# Compare ages in _NOW_CS, never _NOW. The btime field is device-verified constant (75
# reads, one value), so it cancels in a subtraction, leaving uptime's own
# centiseconds: ages exact to 10 ms. Floored seconds carry +-1 s, which on a 2 s
# TTL flips hits to misses. $_NOW is for whole-second callers, here delete_sms.
#
# Requires 64-bit shell arithmetic: _NOW_CS is ~1.8e11 (38 bits). Verified on
# armv7l/3.2.57. A 32-bit shell would wrap it silently. The date(1) fallback is
# for a host without procfs, which neither the device nor Git Bash is.
_epoch_now() {
    local u= k= v= bt= frac=
    read -r u _ < /proc/uptime 2>/dev/null
    while read -r k v _; do
        [ "$k" = btime ] && { bt=$v; break; }
    done < /proc/stat 2>/dev/null
    if [ -n "$u" ] && [ -n "$bt" ]; then
        # 10# because the kernel prints "%02lu": "08" is an invalid octal
        # literal to bash arithmetic, not the number 8.
        case $u in *.*) frac=${u#*.} ;; *) frac=00 ;; esac
        _NOW_CS=$(( bt * 100 + ${u%.*} * 100 + 10#$frac ))
        _NOW=$(( _NOW_CS / 100 ))
    else
        _NOW=$(date +%s)
        _NOW_CS=$(( _NOW * 100 ))
    fi
}

# Loads a cache file in one open, no fork, into $_CACHE_TS (header,
# centiseconds) and $_CACHE_PAYLOAD. Returns 1 for a missing, empty or
# headerless file.
#
# Invariant: both globals are set if and only if this returns 0. A caller using
# the previous file's values after a failed load would print one resource's AT
# reply as another's, and get_dashboard loads two files per process.
#
# read -d '' is a builtin where $(<f) costs a subshell, ~4x dearer
# (tools/device-costs.md). It differs only in keeping trailing newlines
# (cache_write writes none) and stopping at a NUL (an AT reply is text), and it
# returns 1 at EOF with the variable filled, so its status is ignored.
_cache_load() {
    local all= hdr=
    _CACHE_TS=
    _CACHE_PAYLOAD=
    [ -f "$1" ] || return 1
    IFS= read -r -d '' all < "$1" 2>/dev/null
    case $all in *$'\n'*) ;; *) return 1 ;; esac
    hdr=${all%%$'\n'*}
    # Non-numeric header: unusable file (truncated write, or written before the
    # header existed). Must fail here, because the arithmetic in _cache_ts_fresh
    # is a bash syntax error on a non-numeric operand, not a wrong number.
    case $hdr in ''|*[!0-9]*) return 1 ;; esac
    _CACHE_TS=$hdr
    _CACHE_PAYLOAD=${all#*$'\n'}
}

# Age an already-loaded $_CACHE_TS against ttl SECONDS (the header is
# centiseconds while callers continue working in seconds).
_cache_ts_fresh() {
    local age
    _epoch_now
    age=$(( _NOW_CS - _CACHE_TS ))
    # Negative age = btime moved = the clock stepped backwards (NITZ re-sync
    # after a modem reboot). Must read stale, or caches pin until reboot.
    [ "$age" -ge 0 ] && [ "$age" -lt $(( $1 * 100 )) ]
}

# Returns 0 if an AT response is valid (last non-empty line is exactly OK).
# Runs on every fetch. Trailing blank or padded lines must not mask the OK.
at_response_ok() {
    local s="$1"
    while :; do
        case "$s" in *$'\n'|*$'\r'|*$'\t'|*' ') s=${s%?} ;; *) break ;; esac
    done
    [ "${s##*$'\n'}" = "OK" ]
}

# Turn a write command's AT reply into a result the frontend can positively
# ack: the reply passes through on success when it ends in OK. Otherwise it becomes a
# line CONTAINING "ERROR" (the modem's own error line, or a synthesized one for
# an empty/timed-out reply). So an empty reply - e.g. the daemon restarting -
# reads as failure instead of false success. Callers that must tolerate a
# cut-off reply (modem reboots) should skip this and print optimistically.
# Usage: result=$(atcmd_run "AT+X"); at_result "$result"
at_result() {
    local reply="$1" err
    if at_response_ok "$reply"; then
        printf '%s\n' "$reply"
        return
    fi
    # No \r strip: at-lib guarantees CR-free replies (atcli strips at source),
    # device-probed 2026-08-05 across query, chained, ERROR and PDU-mode output.
    # Re-adding one would be a fourth process on this path for nothing.
    err=$(printf '%s' "$reply" | grep -iE 'ERROR' | head -1)
    printf '%s\n' "${err:-ERROR: no response from the modem}"
}


# Atomically write content to a cache file via temp file + mv.
# Cache dir is 700 and files are created 600 by this library's umask. www-data
# is the sole application reader/writer, and root can inspect them through its
# DAC override. mv remains deliberate: the atomic replace stops readers seeing a
# torn file without adding a per-write chmod fork.
cache_write() {
    local f="$1" content="$2" tmp
    tmp="${f}.tmp.$$"
    # Guarded because the dir exists for every write after the first since boot,
    # and mkdir is a fork on the miss path, which is every dashboard poll.
    # umask, not -m: -m seals the FINAL component only, and no root unit
    # pre-creates the /tmp/quecdeck parent any more, so the first www-data path
    # to arrive owns sealing it. Asserted by tests/device/device-test-runsplit.sh.
    [ -d "$_CACHE_DIR" ] || ( umask 077; mkdir -p "$_CACHE_DIR" )
    _epoch_now
    # No chmod: this library's umask makes the temp 0600 even when a caller runs
    # outside systemd. Unit-level masks cover Lua and standalone service writers.
    # Dropping chmod saves a fork on every dashboard-poll cache miss. Only
    # www-data reads these, and root bypasses DAC.
    if printf '%s\n%s' "$_NOW_CS" "$content" > "$tmp" \
        && mv "$tmp" "$f"; then
        return 0
    fi
    # Keep: the likeliest failure is a full /tmp, where the half-written temp
    # holds the space that ran out.
    rm -f "$tmp"
    return 1
}

# Emit a cache file's payload. Emits nothing and returns 1 for a file with no
# header, so a caller that skips the freshness check (the scan path) cannot
# print a timestamp as modem data.
cache_read() {
    _cache_load "$1" && printf '%s' "$_CACHE_PAYLOAD"
}

# Remove one or more cache files to force a live fetch on next read.
cache_invalidate() {
    rm -f "$@"
}

# Serve from cache if fresh. Otherwise run the AT command, cache it, and serve it.
# Serves existing cache (without refreshing) during an active cell scan.
#
# No per-file locking: concurrent misses each submit an AT command. The daemon
# serialises them. The duplicate round trip is cheaper than an empty result.
# AT batch costs are in tools/device-costs.md.
cache_get_or_fetch() {
    local f="$1" ttl="$2" at_cmd="$3" at_timeout="${4:-3000}"
    local result cached=0
    # One load serves the scan path and the freshness check. The fallback after
    # a failed fetch deliberately re-reads instead. See that function for details.
    _cache_load "$f" && cached=1
    if qscan_is_active; then
        [ "$cached" -eq 1 ] && printf '%s' "$_CACHE_PAYLOAD"
        return
    fi
    if [ "$cached" -eq 1 ] && _cache_ts_fresh "$ttl"; then
        printf '%s' "$_CACHE_PAYLOAD"
        return
    fi
    # No mkdir here: cache_write is the only writer and creates the dir itself.
    # Retry once when the reply was cut short, since a second attempt may
    # complete. Two cases are not retried, both because a retry cannot help:
    # an empty result (timeout, and retrying stacks the delay), and a reply the
    # modem terminated itself. The atcli client exits 0 only on a terminator, so rc 0 with
    # a body that is not OK means the modem's answer *is* an error (no SIM,
    # unsupported command) - final, and asking again costs the serialized port
    # another round trip for the same reply. Only the exit status separates that
    # from a truncated reply. The body alone cannot.
    #
    # An atcli too-long refusal (rc 65, non-empty body) would also take the
    # retry path, which cannot help. Unreachable here: every command below is a
    # fixed literal far under CMD_MAX.
    local attempt=0 rc=0 ok=0
    result=""
    while [ $attempt -lt 2 ]; do
        result=$(atcmd_run "$at_cmd" "$at_timeout"); rc=$?
        if at_response_ok "$result"; then ok=1; break; fi
        [ "$rc" -eq 0 ] && break
        [ -z "$result" ] && break
        attempt=$((attempt + 1))
    done
    if [ "$ok" -eq 1 ]; then
        cache_write "$f" "$result"
        printf '%s' "$result"
    else
        # All attempts failed. Serve stale cache rather than bad data, but
        # RE-READ it: there is no locking and a failing fetch holds the port for
        # up to two timeouts, so a concurrent CGI may have written a newer
        # payload than the one loaded at the top of this function.
        cache_read "$f"
    fi
}

# ---------------------------------------------------------------------------
# Snapshot resource definitions: one source of truth for each source's cache
# key + AT command + TTL. Called by both the standalone read CGIs and the
# bundled snapshots (get_dashboard, get_deviceinfo), so the two can't drift.
# ---------------------------------------------------------------------------

# Modem statistics: temperature, serving cell, CA info, signal, traffic
# counters, SIM slot/status, operator. Cached 2 s under _CACHE_MODEM_ALL,
# 2 s AT timeout.
#
# TTL must stay below the dashboard poll floor (home.js clamps refreshRate to
# 3), never equal it: a poll reads ~290 cs, so ttl 3 would call it fresh and
# re-render the previous snapshot at an effective 6 s. This cache dedupes
# readers in one tick, it does not skip polls.
#
# Measured 2026-08-05: at a 3 s cadence every poll is a miss, ~24 AT commands
# per 11 polls.
modem_stats_fetch() {
    cache_get_or_fetch "$_CACHE_MODEM_ALL" 2 \
        'AT+QTEMP;+QENG="servingcell";+QCAINFO;+CSQ;+QGDNRCNT?;+QGDCNT?;+QUIMSLOT?;+QSPN;+QSIMSTAT?' 2000
}

# Connection info: WWAN IP(s) and APN. Connection-dependent, so it may fail with
# no active bearer. Callers fall back gracefully. Cached for 2 seconds with a
# 2-second AT timeout. The same dashboard-poll constraint as modem_stats_fetch applies.
modem_conn_fetch() {
    cache_get_or_fetch "$_CACHE_MODEM_CONN" 2 'AT+QMAP="WWANIP";+CGCONTRDP' 2000
}

# Device identity: manufacturer, model, firmware, IMEI, build time. Effectively
# static, so cached 1 h under _CACHE_DEVICE_INFO.
device_info_fetch() {
    cache_get_or_fetch "$_CACHE_DEVICE_INFO" 3600 'AT+CGMI;+CGMM;+QGMR;+CGSN;+CVERSION'
}

# SIM identity: IMSI, ICCID, phone number. SIM-dependent, so it errors with no
# SIM. Callers handle absent fields gracefully. Cached 2 s (matching modem_conn
# so the short-lived batches stay on one TTL), 2 s AT timeout.
device_sim_fetch() {
    cache_get_or_fetch "$_CACHE_DEVICE_SIM" 2 'AT+CIMI;+ICCID;+CNUM' 2000
}

# Host stats as JSON: load average, RAM, uptime. Reads /proc and `uptime`
# directly (no AT). The uptime line has no " or \, so it's JSON-safe unescaped.
# Emits the body only (no HTTP header), so callers control framing.
system_stats_json() {
    local load mem_total mem_available mem_used mem_total_mb mem_used_mb mem_percent up
    local _k _v _rest
    # Builtin /proc reads: runs per dashboard poll.
    read -r load _rest < /proc/loadavg
    mem_total=0; mem_available=0
    while read -r _k _v _rest; do
        case "$_k" in
            MemTotal:) mem_total=$_v ;;
            MemAvailable:) mem_available=$_v; break ;;
        esac
    done < /proc/meminfo
    mem_used=$((mem_total - mem_available))
    mem_total_mb=$((mem_total / 1024))
    mem_used_mb=$((mem_used / 1024))
    mem_percent=$((mem_used * 100 / mem_total))
    up=$(uptime)
    printf '{"load_avg":%s,"mem_total_mb":%d,"mem_used_mb":%d,"mem_percent":%d,"uptime":"%s"}' \
        "$load" "$mem_total_mb" "$mem_used_mb" "$mem_percent" "$up"
}
