#!/bin/bash
# Host-side test suite for the pure shell functions and JS structure.
# Runs on the dev machine (Git Bash), no device needed:
#   tools/run-tests.sh          # fast set (used by the pre-commit hook)
#   tools/run-tests.sh --slow   # adds tests that sleep (brute-force lockout)
#
# Device-coupled code (queue daemon I/O, caches, systemd paths) is exercised
# on-device only; this suite covers the parsing and arithmetic where the
# historical bugs (\r endings, shift overflow, JSON extraction) have lived.

set -u
cd "$(dirname "$0")/.."

SLOW=0
[ "${1:-}" = "--slow" ] && SLOW=1

pass=0; fail=0
t() { # t <name> <expected> <actual>
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"
    fi
}
t_rc() { # t_rc <name> <expected_rc> <actual_rc>
    t "$1 (rc)" "$2" "$3"
}

# Pull a top-level function out of a script that can't be sourced on the host
# (device paths, daemon loops), so tests always run the current source.
extract_fn() { sed -n "/^$2() {/,/^}/p" "$1"; }

# ---------------------------------------------------------------- json-lib --
. quecdeck/script/json-lib.sh

t "json_get string"        "daily"  "$(json_get '{"type": "daily", "day": 3}' type)"
t "json_get number"        "3"      "$(json_get '{"type": "daily", "day": 3}' day)"
t "json_get bool"          "false"  "$(json_get '{"enabled": false}' enabled)"
t "json_get array intact"  '["8.8.8.8", "1.1.1.1"]' "$(json_get '{"track_ips": ["8.8.8.8", "1.1.1.1"], "n": 1}' track_ips)"
t "json_get no substring collision" "3" "$(json_get '{"dayofweek": 9, "day": 3}' day)"
json_get '{"a": 1}' missing >/dev/null; t_rc "json_get missing key" "1" "$?"

# ----------------------------------------------------------------- cgi-lib --
# The at-lib source line targets a device path; absent on the host, bash
# reports it and continues, which is exactly what we want here.
. quecdeck/script/cgi-lib.sh 2>/dev/null

t "urldecode plus and hex"  "a b&c=d" "$(urldecode 'a+b%26c%3Dd')"
t "urldecode passthrough"   "plain"   "$(urldecode 'plain')"
t "urldecode no backslash interp" 'a\nb' "$(urldecode 'a%5Cnb')"

post_data='user=admin&msg=hello%20world&empty='
t "get_post_param decodes"  "hello world" "$(get_post_param msg)"
t "get_post_param first"    "admin"       "$(get_post_param user)"
t "get_post_param missing"  ""            "$(get_post_param nope)"

valid_ipv4 "192.168.1.1";  t_rc "valid_ipv4 accepts"        "0" "$?"
valid_ipv4 "256.1.1.1";    t_rc "valid_ipv4 octet range"    "1" "$?"
valid_ipv4 "1.2.3";        t_rc "valid_ipv4 three octets"   "1" "$?"
valid_ipv4 "a.b.c.d";      t_rc "valid_ipv4 letters"        "1" "$?"

t "json_bool match"    "true"  "$(json_bool enable enable)"
t "json_bool mismatch" "false" "$(json_bool disable enable)"

t "at_response_ok clean"      "0" "$(at_response_ok $'+QSIMSTAT: 1,1\nOK'; echo $?)"
t "at_response_ok trailing"   "0" "$(at_response_ok $'DATA\nOK\n\n'; echo $?)"
t "at_response_ok error"      "1" "$(at_response_ok $'+CME ERROR: 3'; echo $?)"
t "at_response_ok empty"      "1" "$(at_response_ok ''; echo $?)"

# The sanitizer keeps hex chars (IPv6); it strips shell/path metacharacters.
REMOTE_ADDR='192.168.1.7<>;$/'
t "cgi_client_ip sanitizes" "192.168.1.7" "$(cgi_client_ip)"
REMOTE_ADDR=''
t "cgi_client_ip never empty" "unknown" "$(cgi_client_ip)"

if printf 'x' | openssl passwd -6 -salt s -stdin >/dev/null 2>&1; then
    _hash=$(printf 'hunter22' | openssl passwd -6 -salt testsalt -stdin)
    _htf=$(mktemp)
    printf 'admin:%s\n' "$_hash" > "$_htf"
    validate_htpasswd "$_htf" admin hunter22; t_rc "htpasswd correct pw"  "0" "$?"
    validate_htpasswd "$_htf" admin wrongpw;  t_rc "htpasswd wrong pw"    "1" "$?"
    validate_htpasswd "$_htf" other hunter22; t_rc "htpasswd wrong user"  "1" "$?"
    rm -f "$_htf"
else
    echo "SKIP: openssl passwd -6 unavailable"
fi

if [ "$SLOW" = "1" ]; then
    _bfd=$(mktemp -d)
    bf_locked "$_bfd" "10.0.0.1"; t_rc "bf not locked initially" "1" "$?"
    BF_MAX_ATTEMPTS=2
    t "bf first failure"    "failed" "$(bf_fail "$_bfd" "10.0.0.1")"
    t "bf lockout trips"    "locked" "$(bf_fail "$_bfd" "10.0.0.1")"
    bf_locked "$_bfd" "10.0.0.1"; t_rc "bf locked after trip" "0" "$?"
    bf_clear "$_bfd" "10.0.0.1"
    bf_locked "$_bfd" "10.0.0.1"; t_rc "bf clear unlocks" "1" "$?"
    rm -rf "$_bfd"
fi

# ------------------------------------------------- watchcat calc_threshold --
eval "$(extract_fn quecdeck/script/watchcat.sh calc_threshold)"

PING_FAILURE_COUNT=3; PING_INTERVAL=30; MAX_REBOOT_INTERVAL=7200
seq_out=""
for reboot_count in 0 1 2 3 4 5 6 7 8; do seq_out="$seq_out$(calc_threshold) "; done
t "threshold doubles then caps" "3 6 12 24 48 96 192 240 240 " "$seq_out"
reboot_count=200
t "threshold shift overflow clamped" "240" "$(calc_threshold)"
PING_INTERVAL=600; PING_FAILURE_COUNT=10; reboot_count=1
t "threshold caps at 2h of pings" "12" "$(calc_threshold)"
PING_FAILURE_COUNT=15
t "threshold never below base" "15" "$(calc_threshold)"

# --------------------------------------------- connection_logger parse_qeng --
eval "$(extract_fn quecdeck/script/connection_logger.sh parse_lte_fields)"
eval "$(extract_fn quecdeck/script/connection_logger.sh parse_qeng)"

parse_qeng '+QENG: "servingcell","CONNECT","LTE","FDD",240,01,1A2B3C,123,1300,3,5,5,2AF7,-95,-8,-60,15'
t "qeng primary state"   "CONNECT" "$sc_state"
t "qeng primary mode"    "LTE"     "$sc_mode"
t "qeng primary cell"    "1A2B3C"  "$sc_cell_id"
t "qeng primary pci"     "123"     "$sc_pci"
t "qeng primary earfcn"  "1300"    "$sc_earfcn"
t "qeng primary band"    "3"       "$sc_band"

parse_qeng '+QENG: "servingcell","NOCONN"
+QENG: "LTE","FDD",240,01,2F0A1B,17,6300,20,5,5,2AF7,-95,-8,-60,15
+QENG: "NR5G-NSA",240,01,843,-95,20,-11,528030,41,8,1'
t "qeng truncated NSA mode" "NR5G-NSA" "$sc_mode"
t "qeng truncated cell"     "2F0A1B"   "$sc_cell_id"
t "qeng truncated pci"      "17"       "$sc_pci"

parse_qeng '+QENG: "LTE","FDD",240,01,3C4D5E,42,6300,20'
t "qeng fallback state"  "CONNECT" "$sc_state"
t "qeng fallback cell"   "3C4D5E"  "$sc_cell_id"
t "qeng fallback band"   "20"      "$sc_band"

parse_qeng 'garbage with no QENG lines at all'
t "qeng no service state" "NOSERVICE" "$sc_state"
t "qeng no service pci"   "0"         "$sc_pci"

parse_qeng '+QENG: "servingcell","CONNECT","EVIL\"injection","FDD",240,01,AA,1,2,3'
t "qeng mode whitelist blocks injection" "" "$sc_mode"

# ------------------------------------------ daemon notify line parsing -----
eval "$(extract_fn quecdeck/script/atcmd_queue_daemon.sh _parse_notify)"

_parse_notify $'123_4_5\tAT+CSQ\t3000\t8642'
t_rc "notify 4-field parses" "0" "$?"
t "notify 4-field id"       "123_4_5" "$_id"
t "notify 4-field cmd"      "AT+CSQ"  "$_cmd"
t "notify 4-field timeout"  "3000"    "$_timeout"
t "notify 4-field deadline" "8642"    "$_deadline"

_parse_notify $'77_1_2\tAT+QGMR\t5000'
t_rc "notify 3-field (old client) parses" "0" "$?"
t "notify 3-field deadline empty" "" "$_deadline"
t "notify 3-field timeout kept"   "5000" "$_timeout"

_parse_notify $'..\/evil\tAT+CSQ\t3000\t1'
t_rc "notify bad id rejected" "1" "$?"
_parse_notify 'no-tabs-at-all'
t_rc "notify malformed rejected" "1" "$?"
_parse_notify $'9_9_9\tAT+CSQ\tgarbage\talso-garbage'
t_rc "notify garbage fields parse" "0" "$?"
t "notify garbage timeout cleared"  "" "$_timeout"
t "notify garbage deadline cleared" "" "$_deadline"

# ------------------------------------------- restart log time source logic --
# Mirrors get_restart_log's per-entry decision (kept in sync by this test:
# if the CGI's rules change, update both).
pick_ts() { # pick_ts <ts> <uptime> <entry_boot> <current_boot> <boot_ts>
    local ts="$1" up="$2" eb="$3" cb="$4" boot_ts="$5"
    case "$ts" in ''|*[!0-9]*) ts=0 ;; esac
    if [ "$ts" -lt 1700000000 ]; then
        case "$up" in ''|*[!0-9]*) up="" ;; esac
        if [ -n "$up" ] && [ -n "$eb" ] && [ "$eb" = "$cb" ]; then
            ts=$((boot_ts + up))
        else
            ts=0
        fi
    fi
    echo "$ts"
}
t "logts synced wall clock wins"   "1751650000" "$(pick_ts 1751650000 300 old cur 1751600000)"
t "logts same boot reconstructs"   "1751600300" "$(pick_ts 94608300 300 cur cur 1751600000)"
t "logts old boot goes unknown"    "0"          "$(pick_ts 94608300 300 old cur 1751600000)"
t "logts legacy entry goes unknown" "0"         "$(pick_ts '' 2500 '' cur 1751600000)"

# ---------------------------------------------------------- JS structure ----
js_fail=0
for f in quecdeck/www/js/*.js; do
    case "$f" in *.min.js) continue ;; esac
    out=$(perl tools/jscheck.pl "$f")
    if [ "${out%: OK}" != "${out%": OK"}" ] || [[ "$out" == *": OK" ]]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1)); js_fail=1
        echo "FAIL: jscheck $out"
    fi
done

# -------------------------------------------------------------- summary ----
echo ""
echo "tests: $((pass + fail)), passed: $pass, failed: $fail"
[ "$fail" = "0" ] || exit 1
exit 0
