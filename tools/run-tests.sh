#!/bin/bash
# Host-side test suite for the pure shell functions and JS structure.
# Runs on the dev machine (Git Bash), no device needed:
#   tools/run-tests.sh          # fast set (used by the pre-commit hook)
#   tools/run-tests.sh --slow   # adds tests that sleep (brute-force lockout)
#
# Device-coupled code (caches, systemd paths) is exercised on-device only,
# and the AT daemon in the atcli repo's own harness; this suite covers the
# parsing and arithmetic where the historical bugs (\r endings, shift
# overflow, JSON extraction) have lived.

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

# cache_is_fresh: a future mtime (clock stepped backwards, e.g. NITZ
# re-sync after a modem reboot) must read as stale, or caches pin forever.
_cf=$(mktemp)
touch -d "@$(( $(date +%s) - 100 ))" "$_cf"
cache_is_fresh "$_cf" 10;   t_rc "cache stale past ttl"       "1" "$?"
cache_is_fresh "$_cf" 200;  t_rc "cache fresh within ttl"     "0" "$?"
touch -d "@$(( $(date +%s) + 1000 ))" "$_cf"
cache_is_fresh "$_cf" 10;   t_rc "cache future mtime stale"   "1" "$?"
rm -f "$_cf"
cache_is_fresh "$_cf" 10;   t_rc "cache missing file stale"   "1" "$?"

# The sanitizer keeps hex chars (IPv6); it strips shell/path metacharacters.
REMOTE_ADDR='192.168.1.7<>;$/'
t "cgi_client_ip sanitizes" "192.168.1.7" "$(cgi_client_ip)"
REMOTE_ADDR=''
t "cgi_client_ip never empty" "unknown" "$(cgi_client_ip)"

# validate_htpasswd lives in the check_password.sh sudo helper (not cgi-lib:
# the htpasswd files are root-only and CGIs go through sudo); extract it so
# the comparison logic is still tested on the host.
eval "$(extract_fn quecdeck/script/check_password.sh validate_htpasswd)"
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

# --------------------------------------------- updater pure helpers --------
# The updater's install phase is now plain committed code (no generated
# heredoc), so its pure helpers can be extracted and tested directly.
eval "$(extract_fn update_quecdeck.sh _tag_to_version)"
# v-strip for the version file; regression guard for the bug the de-heredoc
# equivalence diff caught (would have written "v1.0.15" instead of "1.0.15").
t "tag_to_version strips v"   "1.0.15" "$(_tag_to_version v1.0.15)"
t "tag_to_version idempotent" "1.0.15" "$(_tag_to_version 1.0.15)"
t "tag_to_version branch"     "main"   "$(_tag_to_version main)"

eval "$(extract_fn update_quecdeck.sh _version_lt)"
# Downgrade guard compare; numeric per field, not lexical (1.0.9 < 1.0.10).
_version_lt 1.0.9  1.0.10; t_rc "version_lt numeric not lexical" "0" "$?"
_version_lt 1.0.10 1.0.9;  t_rc "version_lt greater patch"      "1" "$?"
_version_lt 1.0.5  1.0.5;  t_rc "version_lt equal"              "1" "$?"
_version_lt 1.9.9  2.0.0;  t_rc "version_lt major"              "0" "$?"
_version_lt 2.0.0  1.9.9;  t_rc "version_lt greater major"      "1" "$?"
_version_lt 1.2.3  1.10.0; t_rc "version_lt minor numeric"      "0" "$?"

eval "$(extract_fn update_quecdeck.sh _normalize_bind)"
# Both the live-IP-patched and repo (0.0.0.0) conf must normalize identically,
# or a mere IP patch forces an unnecessary lighttpd restart during updates.
t "normalize_bind LAN ip"    'server.bind = "0.0.0.0"'              "$(printf 'server.bind = "192.168.225.1"\n' | _normalize_bind)"
t "normalize_bind 443 sock"  '$SERVER["socket"] == "0.0.0.0:443" {' "$(printf '$SERVER["socket"] == "192.168.8.1:443" {\n' | _normalize_bind)"
t "normalize_bind untouched" 'server.port = 80'                     "$(printf 'server.port = 80\n' | _normalize_bind)"

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
