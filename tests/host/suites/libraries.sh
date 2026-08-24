# Shared library host tests.
# Sourced by tests/host/run-tests.sh.

# ---------------------------------------------------------------- json-lib --
. quecdeck/script/json-lib.sh

t "json_get string"        "daily"  "$(json_get '{"type": "daily", "day": 3}' type)"
t "json_get number"        "3"      "$(json_get '{"type": "daily", "day": 3}' day)"
t "json_get bool"          "false"  "$(json_get '{"enabled": false}' enabled)"
t "json_get array intact"  '["8.8.8.8", "1.1.1.1"]' "$(json_get '{"track_ips": ["8.8.8.8", "1.1.1.1"], "n": 1}' track_ips)"
t "json_get no substring collision" "3" "$(json_get '{"dayofweek": 9, "day": 3}' day)"
json_get '{"a": 1}' missing >/dev/null; t_rc "json_get missing key" "1" "$?"

# ----------------------------------------------------------------- cgi-lib --
# The at-lib source line targets a device path. Absent on the host, bash
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
# /tmp/atcli.sock at one point. A call that dropped -s would silently talk to
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
# client returns. See the note at _AT_E_TOOLONG.
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
