# SMS host tests.
# Sourced by tests/host/run-tests.sh.

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
# exists. What replaces it is that no line can ever carry more than one delete.
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
# reading against a 45 s budget sets the deadline to 55. Slot 4 starts at 50 and
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
# _CACHE_DIR is a cgi-lib global, so save it rather than unset it below, or every
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
. quecdeck/script/watchcat-coord.sh
#
# Redirect the production scan marker to the suite's private cache fixture.
_QSCAN_ACTIVE_SAVED=$_QSCAN_ACTIVE
_QSCAN_ACTIVE=$_CACHE_DIR/qscan.active
    _STUB_OUT=$'+X: scanned\nOK'; _STUB_RC=0
    cache_get_or_fetch "$_CACHE_DIR/q" 60 "AT+X" 1000 >/dev/null
    _qscan_now=$(watchcat_uptime)
    printf '%s\n' "$((_qscan_now + QSCAN_GUARD_SECS))" > "$_QSCAN_ACTIVE"
    # Mtime is deliberately nonsense: a network-time correction must not make
    # a live monotonic marker look stale.
    touch -d @0 "$_QSCAN_ACTIVE"
    _STUB_OUT=$'+X: fresh\nOK'; _STUB_RC=0
    t "scan path serves payload, not the header" "$(printf '+X: scanned\nOK')" \
        "$(cache_get_or_fetch "$_CACHE_DIR/q" 0 "AT+X" 1000)"
    # Nothing cached yet during a scan: emit nothing rather than reaching for
    # the modem, which is the point of backing off while it is busy.
    : > "$_FETCH_LOG"
    t "scan path with no cache emits nothing" "" \
        "$(cache_get_or_fetch "$_CACHE_DIR/never" 0 "AT+X" 1000)"
    t "and does not touch the modem" "0" "$(wc -l < "$_FETCH_LOG" | tr -d ' ')"

    # An expired uptime deadline means the scan process died without cleaning
    # up. That branch must delete the flag and fall through to a live fetch, or
    # every cache pins to whatever it held when the scan started, forever.
    _STUB_OUT=$'+X: after-scan\nOK'; _STUB_RC=0
    printf '0\n' > "$_QSCAN_ACTIVE"
    t "a stale scan flag does not block a fetch" "$(printf '+X: after-scan\nOK')" \
        "$(cache_get_or_fetch "$_CACHE_DIR/q" 0 "AT+X" 1000)"
    t "a stale scan flag is removed" "0" \
        "$([ -f "$_QSCAN_ACTIVE" ] && echo 1 || echo 0)"
    t "the scan-status endpoint validates the shared expiry" "yes" \
        "$(grep -q '^qscan_is_active &&' quecdeck/www/cgi-bin/get_scan_status && echo yes || echo no)"
    rm -f "$_QSCAN_ACTIVE"
_QSCAN_ACTIVE=$_QSCAN_ACTIVE_SAVED
unset _QSCAN_ACTIVE_SAVED
unset _qscan_now
unset -f fetches
. quecdeck/script/at-lib.sh   # Restore the real atcmd_run. See the block above.
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

# Freshness reads the centisecond header, not the mtime, so fixtures are
# written rather than touched. TTLs stay in seconds at the call site.
_cf=$(mktemp)
_is_fresh() { _cache_load "$1" && _cache_ts_fresh "$2"; }
# Fixtures are written as "this many centiseconds old", off a clock read at
# write time: a timestamp captured once at the top of the block would drift as
# the suite runs and push the boundary cases over the line.
_mkcache() { _epoch_now; printf '%s\n+CSQ: 20,99\nOK' "$(( _NOW_CS - $1 ))" > "$_cf"; }
_mkcache 10000
_is_fresh "$_cf" 10;   t_rc "cache stale past ttl"       "1" "$?"
_is_fresh "$_cf" 200;  t_rc "cache fresh within ttl"     "0" "$?"
# A future header means btime moved, i.e. the clock stepped backwards (NITZ
# re-sync after a modem reboot). Must read stale, or caches pin forever.
_mkcache -100000
_is_fresh "$_cf" 10;   t_rc "cache future header stale"  "1" "$?"

# A header that is not a number would make the age arithmetic a syntax error,
# so it has to be rejected before that, not produce a wrong age.
printf '+QTEMP: 42\nOK' > "$_cf"
_is_fresh "$_cf" 10;   t_rc "headerless cache stale"     "1" "$?"
t "cache_read emits nothing for it" "" "$(cache_read "$_cf" 2>/dev/null)"

# The precision that centiseconds buy: the boundary has to be exact, because a
# dashboard poll lands just inside it. A poll at 3 s reads ~290 cs old, which is
# fresh at ttl 3 (so the page re-renders the previous snapshot) and stale at
# ttl 2 (so it refetches). Second granularity could not tell those apart, which
# is the bug this format fixes. Margins are kept well above the few ms the
# suite itself takes between writing a fixture and reading it.
_mkcache 290
_is_fresh "$_cf" 3;    t_rc "290cs is fresh at ttl 3"    "0" "$?"
_is_fresh "$_cf" 2;    t_rc "290cs is stale at ttl 2"    "1" "$?"
_mkcache 150
_is_fresh "$_cf" 2;    t_rc "150cs is fresh at ttl 2"    "0" "$?"
_mkcache 250
_is_fresh "$_cf" 2;    t_rc "250cs is stale at ttl 2"    "1" "$?"
_mkcache 0
_is_fresh "$_cf" 0;    t_rc "ttl 0 forces a miss"        "1" "$?"
unset -f _mkcache

rm -f "$_cf"
_is_fresh "$_cf" 10;   t_rc "cache missing file stale"   "1" "$?"

# cache_write/cache_read round trip: the payload must survive byte for byte,
# the header must be an epoch, and the file must read fresh immediately (the
# regression that ttl 0 and the skew clamp both bear on).
_cwd=$(mktemp -d); _CACHE_DIR_KEEP=$_CACHE_DIR; _CACHE_DIR=$_cwd
_payload=$'+QTEMP: 42\n+CSQ: 20,99\nOK'
cache_write "$_cwd/c" "$_payload"
t "cache_write round-trips payload" "$_payload" "$(cache_read "$_cwd/c")"
t "cache_write writes an epoch header" "ok" \
    "$(read -r h < "$_cwd/c"; case $h in ''|*[!0-9]*) echo bad ;; *) echo ok ;; esac)"
_is_fresh "$_cwd/c" 60; t_rc "freshly written cache is fresh" "0" "$?"
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
_is_fresh "$_cwd/empty" 60; t_rc "header with no payload reads fresh" "0" "$?"
t "but its payload is empty" "" "$(cache_read "$_cwd/empty")"

# A failed write must not leave its temp file behind: the likeliest cause is a
# full /tmp, where the leftover holds the space that ran out. The mv command is stubbed to
# fail because no portable filesystem trick makes only that step fail. Bash
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

# The sanitizer keeps hex chars (IPv6) and strips shell/path metacharacters.
REMOTE_ADDR='192.168.1.7<>;$/'
t "cgi_client_ip sanitizes" "192.168.1.7" "$(cgi_client_ip)"
REMOTE_ADDR=''
t "cgi_client_ip never empty" "unknown" "$(cgi_client_ip)"

# validate_htpasswd lives in the check_password.sh sudo helper (not cgi-lib:
# the htpasswd files are root-only and CGIs go through sudo). Extract it so
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
    # Git Bash lacks flock. Provide only its successful-lock contract for the
    # state-machine cases. CI and the device use the real command.
    _bf_real_flock=1
    if ! command -v flock >/dev/null 2>&1; then
        _bf_real_flock=0
        flock() { return 0; }
    fi
    BF_MAX_ATTEMPTS=2
    bf_lock "$_bfd" "10.0.0.1"; t_rc "bf transaction lock acquired" "0" "$?"
    bf_locked "$_bfd" "10.0.0.1"; t_rc "bf not locked initially" "1" "$?"
    bf_fail "$_bfd" "10.0.0.1"; t "bf first failure" "failed" "$BF_FAIL_RESULT"
    bf_unlock
    bf_lock "$_bfd" "10.0.0.1"
    bf_fail "$_bfd" "10.0.0.1"; t "bf lockout trips" "locked" "$BF_FAIL_RESULT"
    bf_unlock
    bf_lock "$_bfd" "10.0.0.1"
    bf_locked "$_bfd" "10.0.0.1"; t_rc "bf locked after trip" "0" "$?"
    bf_clear "$_bfd" "10.0.0.1"
    bf_locked "$_bfd" "10.0.0.1"; t_rc "bf clear unlocks" "1" "$?"
    bf_unlock
    bf_lock "$_bfd" "10.0.0.2"
    t "a client lock does not authorize another client" "no" \
      "$(_bf_lock_held "$_bfd" "10.0.0.1" && echo yes || echo no)"
    bf_unlock
    t "different clients keep different lock inodes" "2" \
      "$(find "$_bfd" -maxdepth 1 -type f -name '*.lock' | wc -l | tr -d ' ')"
    if [ "$_bf_real_flock" = "1" ]; then
        _bf_parallel="$_bfd/parallel"
        mkdir -p "$_bf_parallel"
        BF_MAX_ATTEMPTS=2
        for _attempt in 1 2; do
            (
                . quecdeck/script/cgi-lib.sh
                BF_MAX_ATTEMPTS=2
                if bf_lock "$_bf_parallel" 10.0.0.3; then
                    sleep 1
                    bf_fail "$_bf_parallel" 10.0.0.3
                    printf '%s\n' "$BF_FAIL_RESULT" > "$_bf_parallel/result.$_attempt"
                    bf_unlock
                else
                    printf 'unavailable\n' > "$_bf_parallel/result.$_attempt"
                fi
            ) &
        done
        wait
        t "a parallel request from one client fails without queuing" \
          "$(printf 'failed\nunavailable')" \
          "$(cat "$_bf_parallel"/result.* 2>/dev/null | sort)"
        bf_lock "$_bf_parallel" 10.0.0.3
        bf_locked "$_bf_parallel" 10.0.0.3
        t_rc "an unverified contender does not advance the lockout" 1 "$?"
        bf_unlock

        # Holding one client's lock must not serialize an unrelated client.
        _bf_ready="$_bf_parallel/holder.ready"
        _bf_other="$_bf_parallel/other.ready"
        (
            . quecdeck/script/cgi-lib.sh
            bf_lock "$_bf_parallel" 10.0.0.4 || exit 1
            : > "$_bf_ready"
            sleep 2
            bf_unlock
        ) &
        _bf_holder=$!
        for _wait in 1 2 3 4 5; do
            [ -e "$_bf_ready" ] && break
            sleep 1
        done
        (
            . quecdeck/script/cgi-lib.sh
            bf_lock "$_bf_parallel" 10.0.0.5 || exit 1
            : > "$_bf_other"
            bf_unlock
        ) &
        _bf_other_pid=$!
        wait "$_bf_other_pid"
        t "one client lock does not block another client" yes \
          "$([ -e "$_bf_other" ] && echo yes || echo no)"
        wait "$_bf_holder"
        unset _bf_parallel _bf_ready _bf_other _bf_holder _bf_other_pid _attempt _wait
    fi
    # A present command that cannot acquire the transaction lock must fail.
    flock() { return 1; }
    bf_lock "$_bfd" "10.0.0.1"; t_rc "bf lock failure is fail-closed" "1" "$?"
    unset -f flock
    rm -rf "$_bfd"
    unset _bf_real_flock
fi
