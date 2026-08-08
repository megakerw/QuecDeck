#!/bin/bash
# Host-side test suite for the pure shell functions and JS structure.
# Runs on the dev machine (Git Bash), no device needed:
#   tests/host/run-tests.sh          # fast set (used by the pre-commit hook)
#   tests/host/run-tests.sh --slow   # adds tests that sleep (brute-force lockout)
#
# Device-coupled code (systemd paths, real AT traffic) is exercised on-device
# only, and the AT daemon in the atcli repo's own harness; this suite covers the
# parsing, arithmetic and state machines where the historical bugs have lived:
# \r endings, shift overflow, JSON extraction, cache freshness and file format,
# and delete_sms's per-slot delete and budget semantics.
#
# Stubs here model STATE, not just the wire. The AT stub remembers which slots
# it deleted, because one that answered OK to any well-formed line hid a real
# bug: it could not represent deleting the same slot twice.

set -u
cd "$(dirname "$0")/../.."

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

# The LAST line must be EXACTLY OK. Everything downstream leans on this:
# get_sms refuses a listing that does not end in OK, and delete_sms and
# at_result read success from it. Loosening this to "contains OK" or "starts
# with OK" would make a reply that merely mentions OK read as complete, which
# is the whole reason get_sms stays in PDU mode.
t "at_response_ok needs OK at the END"    "1" "$(at_response_ok $'OK\n+CSQ: 20,99'; echo $?)"
t "at_response_ok is exact, not substring" "1" "$(at_response_ok $'DATA\nNOT OK'; echo $?)"
t "at_response_ok rejects a longer word"  "1" "$(at_response_ok $'DATA\nOKAY'; echo $?)"
t "at_response_ok whitespace only"        "1" "$(at_response_ok $'   \n\n'; echo $?)"

# at_result is what every write CGI reports through, so a wrong answer here is
# a page claiming a settings change succeeded when it did not. It had one test
# for four behaviours.
t "at_result passes a good reply through" "$(printf '+CSQ: 31,99\nOK')" \
    "$(at_result "$(printf '+CSQ: 31,99\nOK')")"
t "at_result surfaces the modem's error line" "+CME ERROR: 30" \
    "$(at_result "$(printf 'AT+X\n+CME ERROR: 30')")"
t "at_result surfaces a bare ERROR" "ERROR" "$(at_result "$(printf 'AT+X\nERROR')")"
# An empty reply carries no ERROR to find, and silence must not read as success.
t "at_result synthesizes one for silence" "ERROR: no response from the modem" \
    "$(at_result '')"
# head -1: one line, not a pile. The first is the one that stopped the chain.
t "at_result reports only the first error" "+CMS ERROR: 321" \
    "$(at_result "$(printf '+CMS ERROR: 321\n+CMS ERROR: 500')")"
# grep -i: some replies spell it lowercase.
t "at_result matches case-insensitively" "+cms error: 500" \
    "$(at_result "$(printf 'AT+X\n+cms error: 500')")"

# ------------------------------------------------------------------ at-lib --
# Stub is a shell function: at-lib calls "$_ATCLI" and bash resolves functions
# before PATH, so no temp executable is needed. STUB_RC/STUB_OUT set per case.
_atcli_stub() { STUB_ARGS="$*"; [ -n "${STUB_OUT:-}" ] && printf '%s\n' "$STUB_OUT"; return "${STUB_RC:-0}"; }
_ATCLI=_atcli_stub
_ATCLI_SOCK=/nonexistent/atcli.sock
. quecdeck/script/at-lib.sh

STUB_OUT="+CSQ: 20,99"; STUB_RC=0
t "atcmd_run passes the reply through" "+CSQ: 20,99" "$(atcmd_run 'AT+CSQ' 2>/dev/null)"
atcmd_run 'AT+CSQ' >/dev/null 2>&1; t_rc "success status preserved" "0" "$?"

# The timeout has to actually reach the client. Every caller that sizes a
# timeout (delete_sms's budget, the cache fetches) is relying on this argument,
# and nothing else would notice if the ${2:+...} expansion stopped emitting it.
STUB_ARGS=""; atcmd_run 'AT+CSQ' 2500 >/dev/null 2>&1
t "atcmd_run forwards the timeout" "1" "$(printf '%s' "$STUB_ARGS" | grep -c -- '-t 2500')"
t "and the command itself"          "1" "$(printf '%s' "$STUB_ARGS" | grep -c -- 'AT+CSQ')"
STUB_ARGS=""; atcmd_run 'AT+CSQ' >/dev/null 2>&1
t "no timeout means no -t flag"     "0" "$(printf '%s' "$STUB_ARGS" | grep -c -- '-t')"
STUB_ARGS=""; atcmd_fire 'AT+CSQ' 1500 >/dev/null 2>&1
t "atcmd_fire detaches and forwards" "1" \
    "$(printf '%s' "$STUB_ARGS" | grep -c -- '--detach.*-t 1500')"

# The socket must be pinned on every call. The atcli default moved to
# /tmp/atcli.sock at one point; a call that dropped -s would silently talk to
# the wrong path (or nothing) rather than fail loudly here.
STUB_ARGS=""; atcmd_run 'AT+CSQ' >/dev/null 2>&1
t "atcmd_run pins the socket" "1" "$(printf '%s' "$STUB_ARGS" | grep -c -- "-s $_ATCLI_SOCK")"
STUB_ARGS=""; atcmd_fire 'AT+CSQ' >/dev/null 2>&1
t "atcmd_fire pins the socket" "1" "$(printf '%s' "$STUB_ARGS" | grep -c -- "-s $_ATCLI_SOCK")"

# atcli refuses an over-length command itself and says so only on stderr, which
# no page can read. The at-lib layer turns that status into a body line.
#
# This drives the path with the same 65 the code compares against, so it tests
# the MAPPING and cannot detect the constant drifting from atcli's real exit
# code. Only tests/device/device-test-atclid.sh can, by reading the status the real
# client returns; see the note at _AT_E_TOOLONG.
STUB_OUT=""; STUB_RC=65
_at_long=$(atcmd_run 'AT+LONG' 2>/dev/null); _at_long_rc=$?
t "too-long adds a body ERROR" "1" "$(printf '%s' "$_at_long" | grep -c '^ERROR: AT command too long')"
t_rc "too-long status passed through" "65" "$_at_long_rc"
t "too-long also warns on stderr" "1" "$(atcmd_run 'AT+LONG' 2>&1 >/dev/null | grep -c '^ERROR: AT command too long')"
atcmd_fire 'AT+LONG' >/dev/null 2>&1; t_rc "atcmd_fire maps it too" "65" "$?"

# The body line has to read as failure upstream, or it is stated then ignored.
at_response_ok "$_at_long"; t_rc "too-long body fails at_response_ok" "1" "$?"
t "at_result surfaces it" "1" "$(at_result "$_at_long" | grep -c '^ERROR: AT command too long')"

# Only 65 gets the line: a timeout must not be reported as a length problem.
STUB_OUT=""; STUB_RC=1
t "ordinary failure adds nothing" "" "$(atcmd_run 'AT+X' 2>/dev/null)"
atcmd_run 'AT+X' >/dev/null 2>&1; t_rc "ordinary failure status preserved" "1" "$?"
STUB_OUT=""; STUB_RC=0

# --------------------------------------------------- get_sms truncation ----
# A +CMGL listing cut short is a well-formed SHORTER inbox: nothing in the bytes
# says parts are missing, so serving it would silently lose messages. Two
# independent guards, and the tests below must fail if either is removed:
# the exit status, and the reply ending in OK.
eval "$(extract_fn quecdeck/www/cgi-bin/get_sms listing_complete)"
# Built without a command substitution per line: $( ) strips the trailing
# newline, which would glue OK onto the last PDU and make the fixture assert
# the opposite of what it looks like.
_long_pdu=""
_i=1; while [ $_i -le 12 ]; do
    _long_pdu="$_long_pdu+CMGL: $_i,1,,24"$'\n'"07919909000000F00DA1$(printf '%060d' $_i)"$'\n'
    _i=$((_i + 1))
done

listing_complete "${_long_pdu}OK" 0
t_rc "a terminated listing is complete"          "0" "$?"
listing_complete "${_long_pdu}OK" 1
t_rc "rc alone condemns a listing that ends OK"  "1" "$?"
listing_complete "$_long_pdu" 0
t_rc "a listing with no OK is incomplete"        "1" "$?"
listing_complete "" 0
t_rc "an empty listing is incomplete"            "1" "$?"
# A short inbox is the everyday case for a device with few messages, and used
# to be handled by a windowing fallback that no longer exists.
listing_complete "$(printf '+CMGL: 1,1,,24\n07919909000000F00DA1\nOK')" 0
t_rc "a short terminated listing is complete"    "0" "$?"
listing_complete "$(printf 'OK')" 0
t_rc "a bare OK is complete"                     "0" "$?"
listing_complete "$(printf '+CMGL: 1,1,,24\n07919909000000F00DA1')" 0
t_rc "a short listing with no OK is incomplete"  "1" "$?"
unset _long_pdu _i
# ---------------------------------------------------------- delete_sms --
# The per-slot loop, the 321 tolerance and the budget are the parts with edge
# cases, and none is reachable through the CGI on a host. The atcmd_run function is replaced
# by a recorder that logs each AT line to a file (a subshell would lose a var).
eval "$(extract_fn quecdeck/www/cgi-bin/delete_sms delete_sms_indices)"
_AT_LOG=$(mktemp)
_DELETED=$(mktemp)
# Models the store, not just the wire: it walks the chained slots in order,
# remembers what it deleted, and aborts at the first bad one the way the modem
# does. A stub that answered OK for any non-999 line hid a real bug, because it
# could not represent deleting the same slot twice.
#   999 = a slot that never held a message
#   998 = a slot that errors for some OTHER reason (not "nothing there")
#   997 = the CPMS half fails, so no +CPMS: line is emitted at all
#   a repeat of an already-deleted slot = +CMS ERROR: 321, same as 999
#
# The +CPMS: line is emitted because the real reply carries it, and delete_sms
# requires it before trusting a 321. A stub that answered a bare error could not
# tell "this slot is empty" from "the storage selection failed".
atcmd_run() {
    printf '%s\n' "$1" >> "$_AT_LOG"
    local rest="$1" slot
    case "$1" in
        *'+CMGD=997'*) printf '+CMS ERROR: 321\n'; return 0 ;;
    esac
    printf '+CPMS: 117,255,117,255,117,255\n'
    while [ "${rest#*;+CMGD=}" != "$rest" ]; do
        rest=${rest#*;+CMGD=}
        slot=${rest%%;*}
        if [ "$slot" = 998 ]; then
            printf '+CMS ERROR: 500\n'; return 0
        fi
        if [ "$slot" = 999 ] || grep -qx "$slot" "$_DELETED"; then
            printf '+CMS ERROR: 321\n'; return 0
        fi
        printf '%s\n' "$slot" >> "$_DELETED"
    done
    printf 'OK\n'
}
_reset() { : > "$_AT_LOG"; : > "$_DELETED"; }

# One command per slot: 25 slots is 25 lines, each naming exactly one index and
# re-selecting the storage. The chunk boundary these used to test no longer
# exists; what replaces it is that no line can ever carry more than one delete.
_reset
t "25 slots report OK" "OK" "$(delete_sms_indices "$(seq -s, 1 25)")"
t "25 slots take 25 AT lines" "25" "$(wc -l < "$_AT_LOG")"
t "every line holds exactly one slot" "25" "$(awk -F'[+]CMGD=' 'NF==2' "$_AT_LOG" | wc -l)"
t "every line re-selects storage" "25" "$(grep -c '^AT+CPMS="ME";' "$_AT_LOG")"
t "mem2/mem3 are never set" "0" "$(grep -c '"ME","ME"' "$_AT_LOG")"
# The regression that started all of this: a long selection must never become
# one oversized line. Per-slot it cannot, and this pins that.
t "no line approaches CMD_MAX" "0" "$(awk 'length($0) > 64' "$_AT_LOG" | wc -l)"

# An empty slot answers 321, which means the slot holds no message: the end
# state asked for. It is not a failure, and nothing else in the request is
# affected by it, because there is no chain to abort.
_reset
t "an empty slot is not a failure" "OK" \
    "$(delete_sms_indices "1,2,3,4,5,6,7,8,9,10,11,999,13,14,15,16,17,18,19,20,21,22,23,24,25")"
t "an empty slot does not stop the rest" "25" "$(wc -l < "$_AT_LOG")"

# A 321 from the STORAGE SELECTION is not "that slot is empty". Without the
# +CPMS: guard every slot would take the already-empty path, failed would stay
# 0, and the page would be told OK while nothing was deleted.
_reset
t "a 321 without +CPMS: is a real failure" \
    "ERROR: 3 of 3 message parts could not be deleted" \
    "$(delete_sms_indices "997,997,997")"

# A slot that fails for a reason OTHER than being empty is a real failure, and
# only that one is counted: this is what $failed means.
_reset
t "a genuine error is reported" \
    "ERROR: 1 of 25 message parts could not be deleted" \
    "$(delete_sms_indices "1,2,3,4,5,6,7,8,9,10,11,998,13,14,15,16,17,18,19,20,21,22,23,24,25")"
t "and the rest are still attempted" "25" "$(wc -l < "$_AT_LOG")"

# Deleting a selection twice: everything is already gone, so the second run has
# nothing to do and must still report OK rather than "all parts failed".
_reset
delete_sms_indices "1,2,3" >/dev/null
t "re-deleting an erased selection is OK" "OK" "$(delete_sms_indices "1,2,3")"

# The same slot named twice in one request: the first deletes it, the second
# gets 321. Must not count as a failure.
_reset
t "a repeated slot in one request is OK" "OK" "$(delete_sms_indices "5,5,6")"

# The boundary between the page's input and an AT command line. This is the
# only thing standing between a POST parameter and a modem command.
eval "$(extract_fn quecdeck/www/cgi-bin/delete_sms valid_slot_list)"
for good in "1" "1,2" "12,345,6789" "0"; do
    valid_slot_list "$good"; t_rc "slot list accepts [$good]" "0" "$?"
done
for bad in "" "," "1," ",1" "1,,2" "1;2" "1 2" "1,2;+CMGD=3" "-1" "1.2" "abc" \
           "1,2," "\$(id)" "1|2" "1
2"; do
    valid_slot_list "$bad"; t_rc "slot list rejects [$bad]" "1" "$?"
done

# Line count tracks slot count exactly, with no off-by-one at either end.
_reset; delete_sms_indices "1,2,3" >/dev/null
t "3 slots take 3 AT lines"   "3" "$(wc -l < "$_AT_LOG")"
_reset; delete_sms_indices "1" >/dev/null
t "1 slot takes 1 AT line"    "1" "$(wc -l < "$_AT_LOG")"
# The regression that started this: a full store used to become one ~1200-char
# line that the daemon silently dropped. Per-slot it is 128 short lines, and the
# longest possible line is bounded by the width of an index.
_reset; delete_sms_indices "$(seq -s, 1 128)" >/dev/null
t "128 slots take 128 AT lines" "128" "$(wc -l < "$_AT_LOG")"
t "no line is anywhere near CMD_MAX" "0" "$(awk 'length($0) > 64' "$_AT_LOG" | wc -l)"
t "the longest line is tiny" "ok" \
    "$(awk 'length($0)>m{m=length($0)} END{print (m<64 ? "ok" : m" chars")}' "$_AT_LOG")"

# The wall-clock budget, driven by a fake clock: real timeouts only fire when
# the AT port actually stalls, which no host stub can reproduce. 10 s per
# reading against a 45 s budget sets the deadline to 55; slot 4 starts at 50 and
# still fits its 2 s reservation, slot 5 would start at 60 and does not. So 4
# slots are deleted and the untried 124 are reported, not attempted.
_NOW=0
_epoch_now() { _NOW=$((_NOW + 10)); }
_reset
t "budget expiry reports the remainder" \
    "ERROR: hit the 45s time budget with 124 of 128 message parts left" \
    "$(delete_sms_indices "$(seq -s, 1 128)")"
t "budget expiry stops sending" "4" "$(wc -l < "$_AT_LOG")"
rm -f "$_AT_LOG"
# Re-source rather than unset: the stub above OVERWROTE at-lib's atcmd_run and
# cgi-lib's _epoch_now, so unsetting them would leave the rest of the suite with
# no definition at all, and any later case reaching the AT or cache layer would
# fail with "command not found" instead of exercising the real thing. _ATCLI is
# still the stub function, so re-sourcing at-lib costs nothing.
. quecdeck/script/cgi-lib.sh 2>/dev/null
. quecdeck/script/at-lib.sh

# cache_get_or_fetch's retry, counted in AT commands sent. Only the exit status
# separates "the modem terminated an error reply" from "the reply was cut off",
# and retrying the first cannot help: it is the modem's final answer, and the
# port is serialized, so the wasted round trip is charged to every caller queued
# behind it. Device-measured 2026-08-05: AT+BOGUSCMD answers ERROR with rc 0, so
# the old body-only condition sent it twice.
# _CACHE_DIR is a cgi-lib global; save it rather than unset it below, or every
# later caller of cache_write/cache_get_or_fetch trips set -u.
_CACHE_DIR_SAVED=$_CACHE_DIR
_CACHE_DIR=$(mktemp -d)
_FETCH_LOG=$(mktemp)
atcmd_run() { echo "$1" >> "$_FETCH_LOG"; printf '%s' "$_STUB_OUT"; return "$_STUB_RC"; }
# ttl 0 forces a miss, so every call reaches the fetch loop.
fetches() { : > "$_FETCH_LOG"
            cache_get_or_fetch "$_CACHE_DIR/c" 0 "AT+X" 1000 >/dev/null
            wc -l < "$_FETCH_LOG" | tr -d ' '; }

# The point of the whole cache: a HIT must not touch the modem. Every other
# case here uses ttl 0 to force a miss, so without this nothing asserts that a
# fresh entry is served without an AT command at all.
_STUB_OUT=$'+X: hit\nOK'; _STUB_RC=0
: > "$_FETCH_LOG"
cache_get_or_fetch "$_CACHE_DIR/hit" 3600 "AT+X" 1000 >/dev/null
t "priming a cold cache fetches once" "1" "$(wc -l < "$_FETCH_LOG" | tr -d ' ')"
: > "$_FETCH_LOG"
_hit=$(cache_get_or_fetch "$_CACHE_DIR/hit" 3600 "AT+X" 1000)
t "a HIT sends no AT command at all" "0" "$(wc -l < "$_FETCH_LOG" | tr -d ' ')"
t "and still serves the payload" "$(printf '+X: hit\nOK')" "$_hit"

# cache_invalidate is what every write CGI calls after changing a setting. If
# it stopped forcing a refetch, the page would keep showing pre-change values
# until the TTL lapsed, which is exactly the bug it exists to prevent.
cache_invalidate "$_CACHE_DIR/hit"
: > "$_FETCH_LOG"
cache_get_or_fetch "$_CACHE_DIR/hit" 3600 "AT+X" 1000 >/dev/null
t "cache_invalidate forces a refetch" "1" "$(wc -l < "$_FETCH_LOG" | tr -d ' ')"
unset _hit

_STUB_OUT=$'+X: 1\nOK'; _STUB_RC=0
t "a complete reply is fetched once"       "1" "$(fetches)"
_STUB_OUT=$'AT+X\nERROR'; _STUB_RC=0
t "a terminated ERROR is not retried"      "1" "$(fetches)"
_STUB_OUT=$'+CME ERROR: 30'; _STUB_RC=0
t "a terminated +CME ERROR is not retried" "1" "$(fetches)"
_STUB_OUT=$'+X: 1\n+X: 2'; _STUB_RC=1
t "a cut-short reply is retried once"      "2" "$(fetches)"
_STUB_OUT=''; _STUB_RC=1
t "an empty reply is not retried"          "1" "$(fetches)"

# A failed fetch serves the stale payload. It comes from an explicit RE-READ,
# not from the load at the top of cache_get_or_fetch: a concurrent CGI may have
# written a newer one during the fetch. Bad data must never win over it, and the
# next case pins the re-read so this cannot be "optimized" back.
_STUB_OUT=$'+X: cached\nOK'; _STUB_RC=0
cache_get_or_fetch "$_CACHE_DIR/s" 60 "AT+X" 1000 >/dev/null   # populate
_STUB_OUT=''; _STUB_RC=1
t "a failed fetch serves stale cache" "$(printf '+X: cached\nOK')" \
    "$(cache_get_or_fetch "$_CACHE_DIR/s" 0 "AT+X" 1000)"
_STUB_OUT=$'+CME ERROR: 30'; _STUB_RC=0
t "an error reply does not overwrite it" "$(printf '+X: cached\nOK')" \
    "$(cache_get_or_fetch "$_CACHE_DIR/s" 0 "AT+X" 1000)"
# Same failure with no cache at all must emit nothing, not a partial file.
t "a failed fetch with no cache is empty" "" \
    "$(cache_get_or_fetch "$_CACHE_DIR/none" 0 "AT+X" 1000)"

# There is no locking and a failing fetch holds the AT port for up to two
# timeouts, so another CGI can write a newer payload meanwhile. The fallback
# must re-read the file, not serve the copy loaded before the fetch started.
# Simulated by writing the cache from inside the stub, which is where a
# concurrent process would have done it.
atcmd_run() { cache_write "$_CACHE_DIR/s" "$(printf '+X: newer\nOK')"; return 1; }
t "stale fallback re-reads after a concurrent write" "$(printf '+X: newer\nOK')" \
    "$(cache_get_or_fetch "$_CACHE_DIR/s" 0 "AT+X" 1000)"
atcmd_run() { echo "$1" >> "$_FETCH_LOG"; printf '%s' "$_STUB_OUT"; return "$_STUB_RC"; }

# _cache_load's globals must not survive a failed load, or one resource's reply
# can be printed as another's. The get_dashboard function loads two cache files per process.
printf 'not-a-header\npayload' > "$_CACHE_DIR/bad"
_cache_load "$_CACHE_DIR/s" >/dev/null
_cache_load "$_CACHE_DIR/bad" >/dev/null || :
t "a failed load clears the payload" "" "$_CACHE_PAYLOAD"
t "a failed load clears the header"  "" "$_CACHE_TS"

# The scan path skips the freshness check entirely, so it is the one route that
# could print a header as modem data if the payload split were wrong. Its own
# cache file, so the case does not depend on what earlier cases left in a
# shared one.
#
# The flag path is hardcoded in cgi-lib, so these two cases touch the REAL
# /tmp/quecdeck/qscan.active. Run on-device during a live cell scan, clearing it
# would let every CGI resume sending AT commands to a busy modem, which is the
# exact condition the flag exists to prevent. So: refuse to run rather than
# clobber it, and say so loudly instead of skipping into silence.
if [ -e /tmp/quecdeck/qscan.active ]; then
    printf 'SKIP: scan-path cases (a real qscan.active exists, refusing to clobber it)\n' >&2
else
    # -m 700 to match what the daemon unit creates: cache_write's guard now
    # assumes that mode on the parent.
    mkdir -p -m 700 /tmp/quecdeck
    _STUB_OUT=$'+X: scanned\nOK'; _STUB_RC=0
    cache_get_or_fetch "$_CACHE_DIR/q" 60 "AT+X" 1000 >/dev/null
    touch /tmp/quecdeck/qscan.active
    _STUB_OUT=$'+X: fresh\nOK'; _STUB_RC=0
    t "scan path serves payload, not the header" "$(printf '+X: scanned\nOK')" \
        "$(cache_get_or_fetch "$_CACHE_DIR/q" 0 "AT+X" 1000)"
    # Nothing cached yet during a scan: emit nothing rather than reaching for
    # the modem, which is the point of backing off while it is busy.
    : > "$_FETCH_LOG"
    t "scan path with no cache emits nothing" "" \
        "$(cache_get_or_fetch "$_CACHE_DIR/never" 0 "AT+X" 1000)"
    t "and does not touch the modem" "0" "$(wc -l < "$_FETCH_LOG" | tr -d ' ')"

    # A flag older than 5 minutes means the scan process died without cleaning
    # up. That branch must delete the flag and fall through to a live fetch, or
    # every cache pins to whatever it held when the scan started, forever.
    _STUB_OUT=$'+X: after-scan\nOK'; _STUB_RC=0
    touch -d "@$(( $(date +%s) - 600 ))" /tmp/quecdeck/qscan.active
    t "a stale scan flag does not block a fetch" "$(printf '+X: after-scan\nOK')" \
        "$(cache_get_or_fetch "$_CACHE_DIR/q" 0 "AT+X" 1000)"
    t "a stale scan flag is removed" "0" \
        "$([ -f /tmp/quecdeck/qscan.active ] && echo 1 || echo 0)"
    rm -f /tmp/quecdeck/qscan.active
fi
unset -f fetches
. quecdeck/script/at-lib.sh   # restore the real atcmd_run; see the block above
rm -rf "$_CACHE_DIR" "$_FETCH_LOG"
_CACHE_DIR=$_CACHE_DIR_SAVED
unset _CACHE_DIR_SAVED _STUB_OUT _STUB_RC _FETCH_LOG

# The stub blocks above replace at-lib's atcmd_run, and used to unset it on the
# way out, leaving the suite with no definition: a later case touching the AT or
# cache layer would have failed with "command not found" and read as a code bug.
# Assert the real one is back, and that it is at-lib's (which routes through the
# _ATCLI stub) rather than a recorder left behind.
t "atcmd_run survives the stub blocks" "function" "$(type -t atcmd_run)"
STUB_OUT="+CSQ: 9,99"; STUB_RC=0
t "and it is at-lib's, not a leftover stub" "+CSQ: 9,99" "$(atcmd_run 'AT+CSQ' 2>/dev/null)"

# _epoch_now replaces a date(1) fork on the cache-hit path, so it has to agree
# with date(1) or every TTL comparison silently shifts. Two seconds of slack
# covers the tick between the two readings.
_epoch_now
_dnow=$(date +%s)
t "_epoch_now agrees with date(1)" "ok" \
    "$([ "$_NOW" -ge $((_dnow - 2)) ] && [ "$_NOW" -le $((_dnow + 2)) ] && echo ok || echo "off by $((_NOW - _dnow))s")"
t "_NOW is _NOW_CS floored to seconds" "$_NOW" "$(( _NOW_CS / 100 ))"
# Ages are subtractions of two readings, so monotonicity is the property that
# matters: a backwards step would make a live cache read as a clock step.
_cs1=$_NOW_CS; _epoch_now
t "_NOW_CS is monotonic" "ok" \
    "$([ "$_NOW_CS" -ge "$_cs1" ] && echo ok || echo "went back $((_cs1 - _NOW_CS))cs")"
# A fraction the kernel prints as "08" is not a valid octal literal, so the
# reader must force base 10 or _epoch_now dies on ~10% of calls.
t "centisecond fraction parses in base 10" "8" "$(( 10#08 ))"
unset _dnow _cs1

# cache_is_fresh reads the centisecond header, not the mtime, so fixtures are
# written rather than touched. TTLs stay in seconds at the call site.
_cf=$(mktemp)
# Fixtures are written as "this many centiseconds old", off a clock read at
# write time: a timestamp captured once at the top of the block would drift as
# the suite runs and push the boundary cases over the line.
_mkcache() { _epoch_now; printf '%s\n+CSQ: 20,99\nOK' "$(( _NOW_CS - $1 ))" > "$_cf"; }
_mkcache 10000
cache_is_fresh "$_cf" 10;   t_rc "cache stale past ttl"       "1" "$?"
cache_is_fresh "$_cf" 200;  t_rc "cache fresh within ttl"     "0" "$?"
# A future header means btime moved, i.e. the clock stepped backwards (NITZ
# re-sync after a modem reboot). Must read stale, or caches pin forever.
_mkcache -100000
cache_is_fresh "$_cf" 10;   t_rc "cache future header stale"  "1" "$?"

# A header that is not a number would make the age arithmetic a syntax error,
# so it has to be rejected before that, not produce a wrong age.
printf '+QTEMP: 42\nOK' > "$_cf"
cache_is_fresh "$_cf" 10;   t_rc "headerless cache stale"     "1" "$?"
t "cache_read emits nothing for it" "" "$(cache_read "$_cf" 2>/dev/null)"

# The precision that centiseconds buy: the boundary has to be exact, because a
# dashboard poll lands just inside it. A poll at 3 s reads ~290 cs old, which is
# fresh at ttl 3 (so the page re-renders the previous snapshot) and stale at
# ttl 2 (so it refetches). Second granularity could not tell those apart, which
# is the bug this format fixes. Margins are kept well above the few ms the
# suite itself takes between writing a fixture and reading it.
_mkcache 290
cache_is_fresh "$_cf" 3;    t_rc "290cs is fresh at ttl 3"    "0" "$?"
cache_is_fresh "$_cf" 2;    t_rc "290cs is stale at ttl 2"    "1" "$?"
_mkcache 150
cache_is_fresh "$_cf" 2;    t_rc "150cs is fresh at ttl 2"    "0" "$?"
_mkcache 250
cache_is_fresh "$_cf" 2;    t_rc "250cs is stale at ttl 2"    "1" "$?"
_mkcache 0
cache_is_fresh "$_cf" 0;    t_rc "ttl 0 forces a miss"        "1" "$?"
unset -f _mkcache

rm -f "$_cf"
cache_is_fresh "$_cf" 10;   t_rc "cache missing file stale"   "1" "$?"

# cache_write/cache_read round trip: the payload must survive byte for byte,
# the header must be an epoch, and the file must read fresh immediately (the
# regression that ttl 0 and the skew clamp both bear on).
_cwd=$(mktemp -d); _CACHE_DIR_KEEP=$_CACHE_DIR; _CACHE_DIR=$_cwd
_payload=$'+QTEMP: 42\n+CSQ: 20,99\nOK'
cache_write "$_cwd/c" "$_payload"
t "cache_write round-trips payload" "$_payload" "$(cache_read "$_cwd/c")"
t "cache_write writes an epoch header" "ok" \
    "$(read -r h < "$_cwd/c"; case $h in ''|*[!0-9]*) echo bad ;; *) echo ok ;; esac)"
cache_is_fresh "$_cwd/c" 60; t_rc "freshly written cache is fresh" "0" "$?"
cache_read "$_cwd/nosuch" 2>/dev/null; t_rc "cache_read missing file" "1" "$?"

# /tmp is tmpfs, so the cache dir is absent after every boot and cache_write is
# what creates it. The guard skips mkdir when it already exists, so the creation
# path only ever runs once per boot and is easy to break unnoticed.
_fresh=$(mktemp -d)/notyet
_CACHE_DIR_KEEP2=$_CACHE_DIR; _CACHE_DIR=$_fresh
# stderr silenced: mkdir -p -m 700 warns on Git Bash because Windows cannot
# apply the POSIX mode. The directory is still created, and the mode itself is
# asserted on-device by tests/device/device-test-cache.sh where it is meaningful.
cache_write "$_fresh/x" "made-it" 2>/dev/null
t "cache_write creates a missing cache dir" "yes" "$([ -d "$_fresh" ] && echo yes || echo no)"
t "and the payload round-trips through it" "made-it" "$(cache_read "$_fresh/x")"
_CACHE_DIR=$_CACHE_DIR_KEEP2
rm -rf "$_fresh"; unset _fresh _CACHE_DIR_KEEP2

# A header with nothing after it. The cache_write function cannot produce one (at_response_ok
# gates it and mv is atomic), but a truncated or hand-made file can, and an
# empty AT reply is not a cache hit worth serving.
_epoch_now; printf '%s\n' "$_NOW_CS" > "$_cwd/empty"
cache_is_fresh "$_cwd/empty" 60; t_rc "header with no payload reads fresh" "0" "$?"
t "but its payload is empty" "" "$(cache_read "$_cwd/empty")"

# A failed write must not leave its temp file behind: the likeliest cause is a
# full /tmp, where the leftover holds the space that ran out. The mv command is stubbed to
# fail because no portable filesystem trick makes only that step fail; bash
# resolves the function before the external, so cache_write hits it unchanged.
mv() { return 1; }
cache_write "$_cwd/willfail" "payload"; t_rc "cache_write reports a failed write" "1" "$?"
t "cache_write removes its temp file" "0" "$(ls "$_cwd" | grep -c '\.tmp\.')"
t "and did not create the target"     "0" "$([ -f "$_cwd/willfail" ] && echo 1 || echo 0)"
unset -f mv
# The real mv is back, so a normal write still lands.
cache_write "$_cwd/after" "payload"; t_rc "cache_write works again after" "0" "$?"
t "no temp file left by the good write" "0" "$(ls "$_cwd" | grep -c '\.tmp\.')"
_CACHE_DIR=$_CACHE_DIR_KEEP
rm -rf "$_cwd"; unset _cwd _payload _CACHE_DIR_KEEP

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

# The root-owned status file is the one outcome source for both CLI and web.
# systemctl's rc appears only in diagnostics when no valid terminal status was
# committed. It never overrides a committed result.
LOG_FILE=/run/quecdeck/install.log
eval "$(extract_fn update_quecdeck.sh report_install_outcome)"
for _status in failed failed:rollback_ok failed:rollback_failed running '' unexpected; do
    report_install_outcome "$_status" 0 >/dev/null
    t_rc "update outcome rejects '${_status:-missing}'" "1" "$?"
done
report_install_outcome done 1 >/dev/null
t_rc "done status overrides systemctl failure" "0" "$?"
t "bootstrap replaces stale status before systemctl" "yes" \
  "$(_status_line=$(grep -n 'Replace any terminal status from an earlier run' update_quecdeck.sh | cut -d: -f1); _start_line=$(grep -n '^systemctl start \$SERVICE_NAME$' update_quecdeck.sh | cut -d: -f1); [ -n "$_status_line" ] && [ "$_status_line" -lt "$_start_line" ] && echo yes || echo no)"
t "install phase returns computed outcome" "yes" \
  "$(grep -q '^exit "\$_install_rc"$' update_quecdeck.sh && echo yes || echo no)"
t "invalid bootstrap status is committed as failed" "yes" \
  "$(sed -n '/^_final_status=/,$p' update_quecdeck.sh | grep -q 'echo "failed" > "${STATUS_FILE}.tmp"' && echo yes || echo no)"
t "web fetch rejection uses terminal abort" "yes" \
  "$(grep -q 'systemctl start --no-block install_quecdeck_fetch.*|| abort' quecdeck/script/run_update.sh && echo yes || echo no)"
t "installer refuses failed rw remount" "yes" \
  "$(grep -q '^if ! remount_rw; then$' update_quecdeck.sh && echo yes || echo no)"
t "forward unit copy is rollback-gated" "yes" \
  "$(grep -q '^    if ! cp -rf "\$QUECDECK_DIR/systemd/"\* /lib/systemd/system/; then$' update_quecdeck.sh && echo yes || echo no)"
t "rollback requires old-tree move" "yes" \
  "$(sed -n '/^_revert_swap() {/,/^}/p' update_quecdeck.sh | grep -q 'mv "\$OLD_DIR" "\$QUECDECK_DIR" ||' && echo yes || echo no)"
t "rollback requires firewall recovery" "yes" \
  "$(sed -n '/^_revert_swap() {/,/^}/p' update_quecdeck.sh | grep -q 'systemctl restart firewall.*||' && echo yes || echo no)"

# Exercise the real rollback function with command failures injected at each
# mandatory recovery boundary. Optional service failures must remain warnings.
eval "$(extract_fn update_quecdeck.sh _revert_swap)"
_rollback_fixture=$(mktemp -d)
mkdir -p "$_rollback_fixture/old"
_rollback_case() { # _rollback_case <failure-point> -> rc:completion-marker
    (
        _fail=$1
        OLD_DIR="$_rollback_fixture/old"
        QUECDECK_DIR="$_rollback_fixture/current"
        _sudoers_prev=""
        _newly_introduced_units=""
        lean_mode_was_installed=0
        watchcat_was_installed=0
        scheduled_restart_was_installed=0
        rm() { return 0; }
        mv() { [ "$_fail" = move ] && return 1; return 0; }
        cp() {
            case "$*" in
                *systemd*) [ "$_fail" = unit-copy ] && return 1 ;;
            esac
            return 0
        }
        chmod() { return 0; }
        ln() { [ "$_fail" = unit-link ] && return 1; return 0; }
        systemctl() {
            case "$*" in
                "daemon-reload")       [ "$_fail" = daemon-reload ] && return 1 ;;
                "restart firewall")    [ "$_fail" = firewall ] && return 1 ;;
                "start lighttpd")      [ "$_fail" = lighttpd ] && return 1 ;;
                "restart atcmd-daemon"|"restart connection-logger")
                    [ "$_fail" = optional ] && return 1 ;;
            esac
            return 0
        }
        _out=$(_revert_swap 2>&1); _rc=$?
        _marker=$(printf '%s\n' "$_out" | grep -c 'Rollback complete')
        printf '%s:%s\n' "$_rc" "$_marker"
    )
}
for _failure in move unit-copy unit-link daemon-reload firewall lighttpd; do
    t "rollback fails closed on $_failure" "1:0" "$(_rollback_case "$_failure")"
done
t "rollback tolerates optional-service failure" "0:1" "$(_rollback_case optional)"
rm -rf "$_rollback_fixture"
t "web updater requires initial status write" "yes" \
  "$(grep -q '^if ! write_status running; then$' quecdeck/script/run_update.sh && echo yes || echo no)"
t "web updater requires log preparation" "yes" \
  "$(grep -q '^if ! : > "\$LOG" || ! chmod 644 "\$LOG"; then$' quecdeck/script/run_update.sh && echo yes || echo no)"
t "web updater requires fetch-unit reload" "yes" \
  "$(grep -q '^systemctl daemon-reload || abort ' quecdeck/script/run_update.sh && echo yes || echo no)"
t "bootstrap requires install-unit reload" "yes" \
  "$(grep -q '^systemctl daemon-reload || _bootstrap_abort ' update_quecdeck.sh && echo yes || echo no)"
t "preflight rejects unreadable run capacity" "yes" \
  "$(sed -n '/_pf_run_free=/,/Not enough free space on \/run/p' update_quecdeck.sh | grep -q "''|\*\[!0-9\]\*)" && echo yes || echo no)"
t "preflight rejects unreadable usrdata capacity" "yes" \
  "$(sed -n '/_pf_free=/,/Not enough free space on \/usrdata/p' update_quecdeck.sh | grep -q "''|\*\[!0-9\]\*)" && echo yes || echo no)"
t "preflight reserves runtime headroom" "yes" \
  "$(grep -q '_pf_run_needed=\$((_pf_run_needed + 1024))' update_quecdeck.sh && echo yes || echo no)"
t "all updater status renames normalize mode" "0" \
  "$(grep 'mv .*STATUS_FILE' update_quecdeck.sh | grep -vc 'chmod 644')"
t "successful install requires read-only remount" "yes" \
  "$(sed -n '/rm -f "\$SERVICE_FILE" \/lib\/systemd\/system\/install_quecdeck.service/,/exit "\$_install_rc"/p' update_quecdeck.sh | grep -q '^if ! remount_ro; then$' && echo yes || echo no)"
t "staging aborts on unexpected bin contents" "yes" \
  "$(sed -n '/rmdir "\$STAGE_DIR\/bin"/,/^[[:space:]]*}/p' update_quecdeck.sh | grep -q 'return 1' && echo yes || echo no)"
t "updater rejects files absent from manifest" "yes" \
  "$(grep -q 'find "\$STAGE_DIR".*-type f.*-type l' update_quecdeck.sh && grep -q 'diff -u "\$_manifest_inventory" "\$_stage_inventory"' update_quecdeck.sh && echo yes || echo no)"
t "CI enforces release manifest inventory" "yes" \
  "$(grep -q 'git ls-files quecdeck' tests/host/ci-checks.sh && grep -q 'manifest inventory does not cover exactly' tests/host/ci-checks.sh && echo yes || echo no)"
t "pre-commit enforces staged release inventory" "yes" \
  "$(grep -q 'git ls-files --cached quecdeck' .githooks/pre-commit && grep -q 'CHECKSUMMED_FILES must cover every tracked' .githooks/pre-commit && echo yes || echo no)"
t "updater health probe avoids blocked loopback HTTP" "yes" \
  "$(! sed -n '/^    _probe_site() {/,/^    }/p' update_quecdeck.sh | grep -q 'wget' && echo yes || echo no)"
t "updater health probe exercises auth CGI as web uid" "yes" \
  "$( _probe_src=$(sed -n '/^    _probe_site() {/,/^    }/p' update_quecdeck.sh); printf '%s\n' "$_probe_src" | grep -q 'su www-data' && printf '%s\n' "$_probe_src" | grep -q 'auth_login' && echo yes || echo no)"
t "updater health probe requires lighttpd-owned LAN HTTPS socket" "yes" \
  "$( _probe_src=$(sed -n '/^    _probe_site() {/,/^    }/p' update_quecdeck.sh); printf '%s\n' "$_probe_src" | grep -q 'systemctl show -p MainPID' && printf '%s\n' "$_probe_src" | grep -q '_health_hex:01BB' && printf '%s\n' "$_probe_src" | grep -q 'socket:\[\$_https_inode\]' && echo yes || echo no)"
t "pre-commit loads runtime guard from staged index" "yes" \
  "$(sed -n '/tmpguard_defs=$(mktemp)/,/rm -f "\$tmpguard_defs"/p' .githooks/pre-commit | grep -q 'git show :tests/host/tmpwrite-guard.sh' && echo yes || echo no)"
t "uninstall requires writable remount first" "yes" \
  "$(sed -n '/^uninstall_quecdeck_components() {/,/# Remove any transient update unit/p' quecdeck.sh | grep -q '^    if ! remount_rw; then$' && echo yes || echo no)"
t "normalize_bind untouched" 'server.port = 80'                     "$(printf 'server.port = 80\n' | _normalize_bind)"

# ------------------------------------------- runtime-path guard (tmpguard) --
# The guard is the durable half of the /run/quecdeck split: source scanning is
# all that stops a root write drifting back into /tmp. If its regexes silently
# stop matching, nothing else notices, so assert BOTH directions against the
# four bugs it exists to prevent. Callers feed it grep -n output, so the fixture
# prefixes a line number.
. tests/host/tmpwrite-guard.sh
tmpguard_verdict() { # tmpguard_verdict <source-line> [<preceding-line>] -> flag|allow
    # Feeds the real shared scanner, so the fixture cannot drift from what the
    # hook and CI actually run.
    if [ -n "$(printf '%s\n%s\n' "${2:-}" "$1" | awk -v re="$TMPGUARD_RE" "$TMPGUARD_AWK")" ]; then
        echo flag
    else
        echo allow
    fi
}

# Must flag: each line is the shape of a real bug this rule was written for.
t "tmpguard bug1 root log in sticky tmp" "flag" \
  "$(tmpguard_verdict 'LOG=/tmp/install_quecdeck.log')"
t "tmpguard bug2 root trim in www-data tree" "flag" \
  "$(tmpguard_verdict 'ExecStartPre=-/bin/bash -c '\''L=/tmp/quecdeck/logs/atcmd.log; tail -500 "$L" > "$L.tmp"'\''')"
t "tmpguard bug3 root chown in www-data tree" "flag" \
  "$(tmpguard_verdict 'ExecStartPre=/bin/chown www-data /tmp/quecdeck/sessions')"
t "tmpguard bug4 root stages in www-data tree" "flag" \
  "$(tmpguard_verdict 'wget -O /tmp/quecdeck/sshd.service "$URL"')"
t "tmpguard flags any new fixed tmp path" "flag" \
  "$(tmpguard_verdict 'STATUS=/tmp/some_new_thing.status')"
t "tmpguard flags root chmod in www-data tree" "flag" \
  "$(tmpguard_verdict 'chmod 700 /tmp/quecdeck/logs')"

# Intent is declared, never inferred from what the line appears to do. An
# earlier version exempted any line CONTAINING "rm -f", which let a compound
# line smuggle a dangerous operation through. This test covers that regression.
t "tmpguard flags rm compounded with chown" "flag" \
  "$(tmpguard_verdict 'rm -f /tmp/a; chown www-data /tmp/quecdeck/sessions')"
t "tmpguard flags rm compounded with a redirect" "flag" \
  "$(tmpguard_verdict 'sh -c "rm -rf /tmp/a; tail -500 /tmp/quecdeck/logs/x > /tmp/quecdeck/logs/x.tmp"')"
t "tmpguard flags an undeclared bare rm" "flag" \
  "$(tmpguard_verdict 'ExecStartPre=/bin/rm -rf /tmp/quecdeck/auth_failures')"

# The other world-writable dirs carry the same exposure as /tmp.
t "tmpguard covers /dev/shm" "flag" "$(tmpguard_verdict 'echo x > /dev/shm/state')"
t "tmpguard covers /var/volatile" "flag" "$(tmpguard_verdict 'echo x > /var/volatile/state')"

# Bare uses reach the same directory as a full path and must not slip past.
t "tmpguard catches cd"     "flag" "$(tmpguard_verdict 'cd /tmp && wget -O x url')"
t "tmpguard catches TMPDIR" "flag" "$(tmpguard_verdict 'TMPDIR=/tmp mktemp')"
t "tmpguard catches tar -C" "flag" "$(tmpguard_verdict 'tar -C /tmp -xf release.tar.gz')"
# ...but the component must be anchored: /opt/tmp is Entware's own dir under
# root-owned /opt and is unrelated to the world-writable /tmp.
t "tmpguard ignores /opt/tmp"    "allow" "$(tmpguard_verdict 'chmod 1777 /opt/tmp')"
t "tmpguard ignores /opt/tmpfoo" "allow" "$(tmpguard_verdict 'cp a /opt/tmpfiles/b')"

# Must allow: comments, and an explicit reasoned marker on the line or, for
# systemd units where a trailing comment would join the command, above it.
t "tmpguard allows comments" "allow" \
  "$(tmpguard_verdict '    # /tmp/quecdeck belongs to www-data')"
t "tmpguard allows an inline marker" "allow" \
  "$(tmpguard_verdict '_legacy="/tmp/install_quecdeck.log" # tmpguard-ok: only passed to rm')"
t "tmpguard allows a marker on the line above" "allow" \
  "$(tmpguard_verdict 'ExecStopPost=/bin/rm -f /tmp/quecdeck/atcli.sock' '# tmpguard-ok: rm only, no shell')"
t "tmpguard ignores the /run tree" "allow" \
  "$(tmpguard_verdict 'LOG=/run/quecdeck/install.log')"

# Scope is DERIVED, so the failure mode to guard against is it silently
# collapsing (a broken grep would shrink it to nothing and every scan would
# pass vacuously). Assert it stays populated and keeps covering both sources:
# the script that produced bug 1, and the sudoers-reachable root scripts the
# first version of this guard omitted entirely.
_scope=$(tmpguard_root_scripts)
_scope_n=$(printf '%s\n' "$_scope" | grep -c .)
t "tmpguard scope is populated" "yes" "$([ "$_scope_n" -ge 8 ] && echo yes || echo no)"
for _want in quecdeck/script/run_update.sh quecdeck/script/write_htpasswd.sh \
             quecdeck/script/check_password.sh quecdeck/script/lighttpd_prestart.sh \
             quecdeck.sh; do
    t "tmpguard scope derives $_want" "yes" \
      "$(printf '%s\n' "$_scope" | grep -qx "$_want" && echo yes || echo no)"
done
# Units must be classified root-context by the ABSENCE of User=www-data, so a
# new unit is in scope by default rather than silently exempt.
_units_in_scope=0
for _u in "$TMPGUARD_UNIT_DIR"/*.service; do
    [ -f "$_u" ] || continue
    grep -q '^User=www-data' "$_u" || _units_in_scope=$((_units_in_scope + 1))
done
t "tmpguard classifies some units root-context" "yes" \
  "$([ "$_units_in_scope" -gt 0 ] && echo yes || echo no)"
# www-data units must NOT be in scope: their /tmp/quecdeck writes are correct.
t "tmpguard excludes www-data units" "yes" \
  "$(grep -q '^User=www-data' "$TMPGUARD_UNIT_DIR/watchcat.service" && echo yes || echo no)"

# --------------------------------------------- orphaned-unit sweep logic ---
# The sweeps in quecdeck.sh (uninstall) and update_quecdeck.sh (dropped units)
# DELETE systemd units, so a wrong predicate either strands a unit forever or
# removes one the device still needs. Exercised here against a fixture tree.
_sweep_classify() { # _sweep_classify <libdir> <shippeddir> -> "keep|orphan|foreign <name>" per line
    for _f in "$1"/*.service; do
        [ -f "$_f" ] || continue
        _n=$(basename "$_f")
        if ! grep -qE '^Exec(Start|StartPre|StartPost|Reload|Stop|StopPost)=.*/usrdata/quecdeck(/|[[:space:]]|$)' "$_f" 2>/dev/null; then
            echo "foreign $_n"
        elif [ -f "$2/$_n" ]; then
            echo "keep $_n"
        else
            echo "orphan $_n"
        fi
    done
}
_swp=$(mktemp -d); mkdir -p "$_swp/lib" "$_swp/shipped"
printf '[Service]\nExecStart=/usrdata/quecdeck/script/firewall.sh\n' > "$_swp/lib/firewall.service"
: > "$_swp/shipped/firewall.service"
printf '[Service]\nExecStart=/usrdata/quecdeck/script/gone.sh\n'     > "$_swp/lib/dropped.service"
printf '[Service]\nExecStart=/usr/sbin/sshd\n'                       > "$_swp/lib/sshd.service"
printf '[Service]\nExecStart=/vendor/bin/pcie\n'                     > "$_swp/lib/pcie.service"
printf '# old path in a comment only: /usrdata/quecdeck/gone\n[Service]\nExecStart=/vendor/bin/commented\n' > "$_swp/lib/commented.service"
_cls=$(_sweep_classify "$_swp/lib" "$_swp/shipped")
t "sweep keeps a shipped unit"        "keep firewall.service"  "$(printf '%s\n' "$_cls" | grep ' firewall.service$')"
t "sweep flags a dropped unit"        "orphan dropped.service" "$(printf '%s\n' "$_cls" | grep ' dropped.service$')"
# The two that must never be touched: a stock sshd unit and a vendor unit. The
# device carries four failed vendor units, so a loose predicate is destructive.
t "sweep ignores stock sshd"          "foreign sshd.service"   "$(printf '%s\n' "$_cls" | grep ' sshd.service$')"
t "sweep ignores vendor units"        "foreign pcie.service"   "$(printf '%s\n' "$_cls" | grep ' pcie.service$')"
t "sweep ignores comment-only marker" "foreign commented.service" "$(printf '%s\n' "$_cls" | grep ' commented.service$')"
t "sweep removes exactly one here"    "1" "$(printf '%s\n' "$_cls" | grep -c '^orphan ')"
rm -rf "$_swp"

# The fixture above can only stay honest if the shipped code uses the same
# predicate, so assert both sweeps actually grep for the marker.
for _src in quecdeck.sh update_quecdeck.sh; do
    t "sweep predicate present in $_src" "yes" \
      "$(grep -q "grep -qE '\^Exec(Start|StartPre|StartPost|Reload|Stop|StopPost)=" "$_src" && echo yes || echo no)"
done

# ------------------------------------------------ firewall ingress policy ---
# Destination address alone is not a LAN boundary: QCMAP places its rmnet
# drops before QUECDECK in IPPT mode but after it in routed mode. Both modes
# were device-probed and deliver real LAN HTTPS through bridge0.
eval "$(extract_fn quecdeck/script/firewall.sh firmware_settle_delay)"
t "firewall waits to uptime boundary from early boot" "36" "$(firmware_settle_delay 24)"
t "firewall has no delay at uptime boundary"          "0"  "$(firmware_settle_delay 60)"
t "firewall has no delay after boot settles"          "0"  "$(firmware_settle_delay 125)"
t "firewall rejects invalid uptime"                   "1"  "$(firmware_settle_delay invalid >/dev/null 2>&1; echo $?)"
t "firewall orders after late firmware network units" "yes" \
  "$(grep '^After=.*init_sys_mss.service.*ethernet-config.service.*ql-netd.service' quecdeck/systemd/firewall.service >/dev/null && echo yes || echo no)"
t "firewall helper requires LAN bridge and address" "yes" \
  "$(grep -q 'v4_rules+="-A QUECDECK -i bridge0 -d \$LAN_IP -p \$protocol --dport \$port -j ACCEPT' quecdeck/script/firewall.sh && echo yes || echo no)"
t "firewall helper supplies paired catch-all DROP" "yes" \
  "$(grep -q -- '-A QUECDECK -p \$protocol --dport \$port -j DROP' quecdeck/script/firewall.sh && echo yes || echo no)"
t "firewall has no destination-only ACCEPT template" "yes" \
  "$(! grep -q 'v4_rules+="-A QUECDECK -d \$LAN_IP .* -j ACCEPT' quecdeck/script/firewall.sh && echo yes || echo no)"
t "firewall fails closed when bridge0 is absent" "yes" \
  "$(grep -q 'if ! ip link show bridge0' quecdeck/script/firewall.sh && echo yes || echo no)"
t "firewall verifies LAN address belongs to bridge0" "yes" \
  "$(grep -q 'ip -4 addr show dev bridge0.*LAN_IP' quecdeck/script/firewall.sh && echo yes || echo no)"
t "firewall protects UDP DNS through helper" "yes" \
  "$(grep -q '^add_v4_lan_only udp 53$' quecdeck/script/firewall.sh && echo yes || echo no)"
t "firewall protects TCP DNS through helper" "yes" \
  "$(grep -q '^add_v4_lan_only tcp 53$' quecdeck/script/firewall.sh && echo yes || echo no)"
t "firewall permits link-local UDP DNS through IPv6 helper" "yes" \
  "$(grep -q 'v6_rules+="-A QUECDECK6 -i bridge0 -d fe80::/10 -p \$protocol --dport \$port -j ACCEPT' quecdeck/script/firewall.sh && grep -q '^add_v6_lan_only udp 53$' quecdeck/script/firewall.sh && echo yes || echo no)"
t "firewall permits link-local TCP DNS through IPv6 helper" "yes" \
  "$(grep -q '^add_v6_lan_only tcp 53$' quecdeck/script/firewall.sh && echo yes || echo no)"
t "firewall IPv6 helper supplies catch-all DROP" "yes" \
  "$(grep -q -- '-A QUECDECK6 -p \$protocol --dport \$port -j DROP' quecdeck/script/firewall.sh && echo yes || echo no)"
t "firewall requires both IPv6 commands" "yes" \
  "$(grep -q 'iptables iptables-restore ip6tables ip6tables-restore' quecdeck/script/firewall.sh && echo yes || echo no)"
t "firewall treats IPv6 restore failure as fatal" "yes" \
  "$(grep -q 'if ! printf.*v6_rules.*ip6tables-restore' quecdeck/script/firewall.sh && ! grep 'ip6tables-restore' quecdeck/script/firewall.sh | grep -q '|| true' && echo yes || echo no)"
t "firewall verifies IPv6 rule count" "yes" \
  "$(grep -q '\[ "\$actual_v6" -ne "\$expected_v6" \]' quecdeck/script/firewall.sh && echo yes || echo no)"
t "firewall protects every admin TCP port through helper" "yes" \
  "$(grep -q '^[[:space:]]*add_v4_lan_only tcp "\$port"$' quecdeck/script/firewall.sh && echo yes || echo no)"
t "firewall helper updates rule-count check" "yes" \
  "$(grep -q 'expected=\$((expected + 2))' quecdeck/script/firewall.sh && echo yes || echo no)"
t "firewall leaves DHCP outside its policy" "yes" \
  "$(! grep -q -- '--dport 67' quecdeck/script/firewall.sh && echo yes || echo no)"
t "firewall never deletes jumps until absent" "yes" \
  "$(! grep -q 'while .*tables .* -D INPUT' quecdeck/script/firewall.sh && echo yes || echo no)"
t "firewall inserts jump only from zero case" "yes" \
  "$(sed -n '/case "\$jump_count" in/,/esac/p' quecdeck/script/firewall.sh | grep -A2 '0)' | grep -q -- '-I INPUT -j "\$chain"' && echo yes || echo no)"
t "firewall removes jump only from duplicate case" "yes" \
  "$(sed -n '/case "\$jump_count" in/,/esac/p' quecdeck/script/firewall.sh | grep -A2 '\*)' | grep -q -- '-D INPUT -j "\$chain"' && echo yes || echo no)"
t "firewall bounds jump convergence" "yes" \
  "$(grep -q 'while \[ "\$jump_attempts" -lt 10 \]' quecdeck/script/firewall.sh && echo yes || echo no)"
t "firewall verifies exactly one final jump" "yes" \
  "$(grep -q '\[ "\$jump_count" -ne 1 \]' quecdeck/script/firewall.sh && echo yes || echo no)"
t "firewall converges both family jumps" "2" \
  "$(grep -c '^converge_input_jump .* QUECDECK' quecdeck/script/firewall.sh)"
t "firewall uninstall explicitly removes owned rules" "yes" \
  "$(sed -n '/# Uninstall firewall/,/# Uninstall ttyd/p' quecdeck.sh | grep -q 'firewall.sh --remove' && echo yes || echo no)"
t "firewall helper declares remove API" "yes" \
  "$(grep -qx 'QUECDECK_FIREWALL_REMOVE_API=1' quecdeck/script/firewall.sh && echo yes || echo no)"
t "uninstall checks remove API before invoking helper" "yes" \
  "$(_fw_block=$(sed -n '/# Uninstall firewall/,/# Uninstall ttyd/p' quecdeck.sh); _check_line=$(printf '%s\n' "$_fw_block" | grep -n 'QUECDECK_FIREWALL_REMOVE_API=1' | cut -d: -f1); _run_line=$(printf '%s\n' "$_fw_block" | grep -n 'firewall.sh --remove' | cut -d: -f1); [ -n "$_check_line" ] && [ "$_check_line" -lt "$_run_line" ] && echo yes || echo no)"
t "unsupported firewall helper requires reboot" "yes" \
  "$(sed -n '/# Uninstall firewall/,/# Uninstall ttyd/p' quecdeck.sh | grep -q 'result_firewall="REBOOT REQUIRED"' && grep -q 'REBOOT REQUIRED: restart the modem' quecdeck.sh && echo yes || echo no)"
t "uninstall stops UI before firewall cleanup" "yes" \
  "$(_stop_line=$(sed -n '/# Uninstall firewall/,/# Uninstall ttyd/p' quecdeck.sh | grep -n 'systemctl stop lighttpd' | cut -d: -f1); _remove_line=$(sed -n '/# Uninstall firewall/,/# Uninstall ttyd/p' quecdeck.sh | grep -n 'firewall.sh --remove' | cut -d: -f1); [ -n "$_stop_line" ] && [ "$_stop_line" -lt "$_remove_line" ] && echo yes || echo no)"
t "normal firewall service stop does not remove policy" "yes" \
  "$(! grep -q '^ExecStop=.*firewall.sh --remove' quecdeck/systemd/firewall.service && echo yes || echo no)"

# Execute the real convergence function against a stateful iptables mock. The
# The source checks above catch accidental deletion of the design. These scenarios
# prove its behavior and, critically, that a failed duplicate deletion never
# removes the final working jump.
eval "$(extract_fn quecdeck/script/firewall.sh converge_input_jump)"
_jump_case() { # <initial> <fail-insert> <fail-delete> <external-churn>
    (
        _jumps=$1 _fail_i=$2 _fail_d=$3 _churn=$4 _ops=0 _min=$1
        iptables() {
            case "$*" in
                *"-S INPUT"*)
                    _n=0
                    [ "$_churn" = 1 ] && _reported=0 || _reported=$_jumps
                    echo '-P INPUT ACCEPT'
                    while [ "$_n" -lt "$_reported" ]; do
                        echo '-A INPUT -j QUECDECK'
                        _n=$((_n + 1))
                    done
                    ;;
                *"-I INPUT -j QUECDECK"*)
                    [ "$_fail_i" = 1 ] && return 1
                    _jumps=$((_jumps + 1)); _ops=$((_ops + 1))
                    ;;
                *"-D INPUT -j QUECDECK"*)
                    [ "$_fail_d" = 1 ] && return 1
                    [ "$_jumps" -gt 0 ] || return 1
                    _jumps=$((_jumps - 1)); _ops=$((_ops + 1))
                    [ "$_jumps" -lt "$_min" ] && _min=$_jumps
                    ;;
                *) return 2 ;;
            esac
        }
        converge_input_jump >/dev/null 2>&1
        _rc=$?
        [ "$_churn" = 1 ] && _jumps=0
        printf '%s:%s:%s:%s\n' "$_rc" "$_jumps" "$_min" "$_ops"
    )
}
t "firewall jump behavior zero to one"     "0:1:0:1"  "$(_jump_case 0 0 0 0)"
t "firewall jump behavior one is no-op"     "0:1:1:0"  "$(_jump_case 1 0 0 0)"
t "firewall jump behavior three to one"     "0:1:1:2"  "$(_jump_case 3 0 0 0)"
t "firewall jump insert failure is loud"    "1:0:0:0"  "$(_jump_case 0 1 0 0)"
t "firewall duplicate failure preserves all" "1:3:3:0" "$(_jump_case 3 0 1 0)"
t "firewall jump churn is bounded at ten"   "1:0:0:10" "$(_jump_case 0 0 0 1)"

# Execute the real removal helper against a stateful mock. Foreign chains and
# jumps are included in every fixture and must never appear in the operation log.
eval "$(extract_fn quecdeck/script/firewall.sh remove_chain)"
_remove_case() { # <initial-jumps> <chain-exists>
    (
        _jumps=$1 _chain=$2 _ops=""
        iptables() {
            case "$*" in
                *"-S")
                    echo '-P INPUT ACCEPT'
                    echo '-N VENDOR'
                    echo '-A INPUT -j VENDOR'
                    _n=0
                    while [ "$_n" -lt "$_jumps" ]; do
                        echo '-A INPUT -j QUECDECK'
                        _n=$((_n + 1))
                    done
                    [ "$_chain" = 1 ] && echo '-N QUECDECK'
                    return 0
                    ;;
                *"-D INPUT -j QUECDECK") _jumps=$((_jumps - 1)); _ops="${_ops}D" ;;
                *"-F QUECDECK") _ops="${_ops}F" ;;
                *"-X QUECDECK") _chain=0; _ops="${_ops}X" ;;
                *) return 2 ;;
            esac
        }
        remove_chain iptables QUECDECK >/dev/null 2>&1
        printf '%s:%s:%s:%s\n' "$?" "$_jumps" "$_chain" "$_ops"
    )
}
t "firewall removal handles absent state"    "0:0:0:"    "$(_remove_case 0 0)"
t "firewall removal deletes one owned chain" "0:0:0:DFX" "$(_remove_case 1 1)"
t "firewall removal deletes duplicate jumps" "0:0:0:DDFX" "$(_remove_case 2 1)"
t "device ingress regression test uses same bridge policy" "yes" \
  "$(grep -q 'iptables -A QUECDECK -i bridge0 -d "\$LAN_IP"' tests/device/device-test-firewall-ingress.sh && echo yes || echo no)"

# ------------------------------------------ root-home migration lifecycle ---
# The legacy root bin was world-writable. These ordering assertions prevent a
# future cleanup from putting it back in the updater's command search path or
# running the destructive migration before a verified release and rollback
# snapshot exist.
t "installer PATH excludes legacy root bin" "yes" \
  "$(grep '^export PATH=' quecdeck.sh | grep -qv '/usrdata/root/bin' && echo yes || echo no)"
t "updater PATH excludes legacy root bin" "yes" \
  "$(grep '^export PATH=' update_quecdeck.sh | grep -qv '/usrdata/root/bin' && echo yes || echo no)"
_harden_line=$(grep -n '^[[:space:]]*harden_root_home ||' update_quecdeck.sh | cut -d: -f1)
_commit_line=$(grep -n '^[[:space:]]*_swap_committed=1$' update_quecdeck.sh | tail -1 | cut -d: -f1)
_helper_line=$(grep -n 'ln -sf "\$QUECDECK_DIR/atcli" /usrdata/root/bin/atcli' update_quecdeck.sh | head -1 | cut -d: -f1)
t "root home hardens after rollback becomes possible" "yes" \
  "$([ -n "$_harden_line" ] && [ "$_harden_line" -gt "$_commit_line" ] && echo yes || echo no)"
t "root home hardens before helper writes" "yes" \
  "$([ -n "$_harden_line" ] && [ "$_harden_line" -lt "$_helper_line" ] && echo yes || echo no)"
t "rollback restores password helper copies" "2" \
  "$(sed -n '/^_revert_swap() {/,/^}/p' update_quecdeck.sh | grep -c 'cp -f.*quecdeck.*passwd.*usrdata/root/bin')"
t "uninstall clears root-home migration marker" "yes" \
  "$(sed -n '/^uninstall_quecdeck_components() {/,/^}/p' quecdeck.sh | grep -q 'rm -f.*ROOT_HOME_HARDENED' && echo yes || echo no)"

# Every shipped unit must carry the marker or both sweeps go blind to it and it
# stays installed and enabled forever. The ci-checks.sh script also checks this. It is repeated
# here because run-tests.sh is what the pre-commit hook runs, so a marker-less
# unit is blocked at commit time rather than discovered in CI.
for _u in quecdeck/systemd/*.service; do
    [ -f "$_u" ] || continue
    t "unit self-identifies: $(basename "$_u")" "yes" \
      "$(grep -qE '^Exec(Start|StartPre|StartPost|Reload|Stop|StopPost)=.*/usrdata/quecdeck(/|[[:space:]]|$)' "$_u" && echo yes || echo no)"
done

# ---------------------------------------------------------- JS structure ----
js_fail=0
for f in quecdeck/www/js/*.js; do
    case "$f" in *.min.js) continue ;; esac
    out=$(perl tests/host/jscheck.pl "$f")
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
