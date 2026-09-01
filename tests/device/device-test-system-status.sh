#!/bin/sh
# get_system_status validation: confirms the batched `systemctl is-active`
# call is safe to map positionally, that the mobileap_cfg.xml helpers agree
# with the parsers they replaced, and that batching actually bought latency.
# Run as root on a CONFIGURED device:
#
#     sh device-test-system-status.sh
#
# Non-destructive: every check is a read. No units are started or stopped, no
# config is written, no AT commands are sent.
#
# It checks:
#   1. `systemctl is-active <all units>` emits exactly one line per unit, in
#      argument order, including for units that are not installed. The CGI maps
#      the output positionally, so a skipped line would report the wrong
#      service's state. Each batched answer is compared against the same unit
#      queried on its own.
#   2. Batched vs one-call-per-unit latency, to confirm the premise that one
#      D-Bus round trip to PID 1 per unit was the cost.
#   3. The real mobileap_cfg.xml matches what mobileap_read expects: each tag
#      present exactly once, spelled as the CGI spells it.
#   4. The mobileap_lan_ip function agrees with the legacy inline parse and rule
#      lighttpd_prestart.sh applies, EXCEPT that it reports nothing rather than
#      defaulting (deliberate: its output seeds a form that writes back).
#   5. The get_system_status CGI runs and emits the merged fields, with lan_ip
#      matching the XML, and the retired get_upnp_status is gone.

CGI=/usrdata/quecdeck/www/cgi-bin/get_system_status
CGI_DIR=/usrdata/quecdeck/www/cgi-bin
CFG=/etc/data/mobileap_cfg.xml
ITERS=20
pass=0; fail=0; warn=0

ok()   { echo "  PASS: $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL: $1"; fail=$((fail+1)); }
note() { echo "  WARN: $1"; warn=$((warn+1)); }

# BusyBox date has no %N (it prints a literal "%N"), so seconds are the only
# clock this shell has and they are far too coarse. Time the loops in bash
# instead, which reports to the millisecond via TIMEFORMAT.
# _time_loop <iterations> <command...> -> elapsed seconds, e.g. "1.506"
_time_loop() {
    _n="$1"; shift
    bash -c 'TIMEFORMAT=%R; N=$1; shift
             time ( i=0; while [ $i -lt $N ]; do "$@" >/dev/null 2>&1; i=$((i+1)); done )' \
        _ "$_n" "$@" 2>&1
}

echo "=================================================================="
echo " QuecDeck get_system_status validation"
echo "=================================================================="

[ -f "$CGI" ] || { echo "FATAL: $CGI missing -- is QuecDeck installed?"; exit 1; }

# The unit list is read out of the CGI rather than duplicated here, so this
# test cannot silently drift from what the endpoint actually queries.
UNITS=$(sed -n 's/^SERVICE_UNITS="\(.*\)"$/\1/p' "$CGI")
if [ -z "$UNITS" ]; then
    echo "FATAL: could not parse SERVICE_UNITS from $CGI (was it restructured?)"
    exit 1
fi
UNIT_COUNT=$(echo $UNITS | wc -w)
echo ""
echo "Units under test ($UNIT_COUNT): $UNITS"

# ---- Check 1: one line per unit, in order -------------------------------
echo ""
echo "[Check 1] Batched is-active emits one line per unit, in argument order"
batch=$(systemctl is-active $UNITS 2>/dev/null)
batch_lines=$(printf '%s\n' "$batch" | grep -c '')
if [ "$batch_lines" -ne "$UNIT_COUNT" ]; then
    bad "batch returned $batch_lines lines for $UNIT_COUNT units -- positional mapping is UNSAFE"
    note "the CGI's count guard catches this and falls back to per-unit calls, so"
    note "output stays correct, but the latency win is lost. Keep the guard."
else
    ok "batch returned $batch_lines lines for $UNIT_COUNT units"
    # Order matters as much as count: compare each slot to a solo query.
    _i=1
    _mismatch=0
    for _u in $UNITS; do
        _batched=$(printf '%s\n' "$batch" | sed -n "${_i}p")
        _solo=$(systemctl is-active "$_u" 2>/dev/null)
        if [ "$_batched" != "$_solo" ]; then
            bad "slot $_i ($_u): batched='$_batched' but solo='$_solo' -- ORDER MISMATCH"
            _mismatch=1
        else
            echo "        slot $_i  $_u = $_batched"
        fi
        _i=$((_i+1))
    done
    [ "$_mismatch" -eq 0 ] && ok "every slot matches its unit queried individually"
fi

# ---- Check 2: latency, batched vs per-unit ------------------------------
echo ""
echo "[Check 2] Latency over $ITERS iterations"
_batch_s=$(_time_loop "$ITERS" systemctl is-active $UNITS)
_solo_s=$(bash -c 'TIMEFORMAT=%R; N=$1; shift
                   time ( i=0; while [ $i -lt $N ]; do
                            for u in "$@"; do systemctl is-active "$u" >/dev/null 2>&1; done
                            i=$((i+1)); done )' _ "$ITERS" $UNITS 2>&1)
# seconds.mmm -> ms per call, without needing floating point
_batch_ms=$(echo "$_batch_s $ITERS" | awk '{printf "%d", ($1*1000)/$2}')
_solo_ms=$(echo "$_solo_s $ITERS" | awk '{printf "%d", ($1*1000)/$2}')
echo "        batched:  ${_batch_s}s total  (~${_batch_ms}ms per call)"
echo "        per-unit: ${_solo_s}s total  (~${_solo_ms}ms per call)"
if [ "$_solo_ms" -gt "$_batch_ms" ]; then
    ok "batching saves ~$((_solo_ms - _batch_ms))ms per request"
else
    note "batching showed no gain -- the latency is NOT systemd IPC. Look at TLS,"
    note "CGI spawn, or lighttpd before optimising this endpoint further."
fi

# ---- Check 3: the real XML matches what the helper expects ---------------
echo ""
echo "[Check 3] mobileap_cfg.xml tag shapes"
if [ ! -f "$CFG" ]; then
    note "$CFG absent -- checks 3 and 4 skipped (helpers correctly report nothing)"
else
    for _tag in APIPAddr StartIP EndIP UPnP; do
        # Exactly the pattern mobileap_read uses.
        _n=$(grep -o "<$_tag>[^<]*</$_tag>" "$CFG" 2>/dev/null | grep -c '')
        # Case-insensitive, attribute-tolerant search, to catch a spelling the
        # strict pattern would miss entirely.
        _loose=$(grep -oiE "<$_tag[^>]*>" "$CFG" 2>/dev/null | grep -c '')
        if [ "$_n" -eq 1 ]; then
            ok "<$_tag> matched exactly once: $(grep -o "<$_tag>[^<]*</$_tag>" "$CFG" | sed "s|</*$_tag>||g")"
        elif [ "$_n" -eq 0 ] && [ "$_loose" -gt 0 ]; then
            bad "<$_tag> not matched by the strict pattern but $_loose loose match(es) exist -- attributes or different casing. mobileap_read would return nothing"
        elif [ "$_n" -eq 0 ]; then
            note "<$_tag> absent from the config (helper returns empty, which callers handle)"
        else
            bad "<$_tag> matched $_n times -- mobileap_read takes the first. Confirm that is the right one"
        fi
    done
fi

# ---- Check 4: helper vs the parsers it replaced --------------------------
echo ""
echo "[Check 4] LAN IP: helper vs legacy parse vs prestart rule"
if [ -f "$CFG" ]; then
    # The pipeline get_set_lanip used before the helper existed.
    _legacy=$(grep -o '<APIPAddr>[^<]*</APIPAddr>' "$CFG" | sed 's/<APIPAddr>//;s/<\/APIPAddr>//' | tr -cd '0-9.')
    # The validate-or-default rule lighttpd_prestart.sh and update_sshd_ip.sh use.
    _prestart="$_legacy"
    if ! printf '%s' "$_prestart" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || \
       ! printf '%s' "$_prestart" | awk -F. '$1>255||$2>255||$3>255||$4>255{exit 1}'; then
        _prestart="192.168.225.1"
    fi
    # What the helper now returns (empty when invalid, by design). Sourced under
    # bash, not this shell: cgi-lib.sh uses printf -v and ${!var}, which busybox
    # ash does not support. Every CGI is #!/bin/bash, so that is the real path.
    _helper=$(bash -c '. /usrdata/quecdeck/script/cgi-lib.sh >/dev/null 2>&1
                       mobileap_lan_ip; printf "%s" "$mf_lan_ip"')
    echo "        legacy inline parse: '${_legacy}'"
    echo "        prestart rule:       '${_prestart}'  (binds lighttpd/sshd)"
    echo "        mobileap_lan_ip:     '${_helper}'"
    if [ -n "$_helper" ] && [ "$_helper" = "$_prestart" ]; then
        ok "helper agrees with the address lighttpd and sshd actually bind to"
    elif [ -z "$_helper" ]; then
        note "helper reports nothing: the stored LAN IP is absent or malformed."
        note "This is the intended behaviour (no guess reaches the settings form),"
        note "but lighttpd/sshd are meanwhile binding to $_prestart -- worth a look."
    else
        bad "helper '$_helper' disagrees with the bound address '$_prestart'"
    fi
fi

# ---- Check 5: the endpoint itself ----------------------------------------
echo ""
echo "[Check 5] get_system_status output"
if [ -f "$CGI_DIR/get_upnp_status" ]; then
    bad "get_upnp_status still present -- the retired endpoint survived the update"
else
    ok "retired get_upnp_status is absent"
fi
# Run as www-data where possible: the CGI reads $CFG and talks to systemd as
# that user, and a root-only pass would hide a permission problem.
# Executed directly, NOT via `sh`: the CGI is #!/bin/bash and uses arrays and a
# herestring, neither of which busybox ash supports. The lighttpd process executes it the same
# way, so `sh $CGI` would fail here while production works fine.
if su -s /bin/sh www-data -c "true" 2>/dev/null; then
    body=$(su -s /bin/sh www-data -c "$CGI" 2>/dev/null | tail -1)
    _as="www-data"
else
    body=$("$CGI" 2>/dev/null | tail -1)
    _as="root"
    note "could not drop to www-data. Ran as root, so permission faults are NOT covered"
fi
echo "        (ran as $_as)"
if [ -z "$body" ]; then
    bad "endpoint produced no output"
else
    for _f in '"upnp":' '"lan_ip":' '"quecdeck_version":' '"firewall":' '"sshd":'; do
        case "$body" in
            *"$_f"*) ;;
            *) bad "response is missing field $_f" ;;
        esac
    done
    case "$body" in
        *'"upnp":'*) ok "merged fields present" ;;
    esac
    if [ ! -f /lib/systemd/system/sshd.service ]; then
        case "$body" in
            *'"sshd":null'*) ok "sshd stays null when it is not installed" ;;
            *) bad "sshd is not null when it is not installed" ;;
        esac
    fi
    # lan_ip must be the XML's value, or null -- never a fabricated default.
    _json_ip=$(printf '%s' "$body" | sed -n 's/.*"lan_ip":\("[^"]*"\|null\).*/\1/p')
    echo "        lan_ip in response: $_json_ip"
    if [ -n "$_helper" ]; then
        [ "$_json_ip" = "\"$_helper\"" ] && ok "lan_ip matches the config" \
            || bad "lan_ip is $_json_ip but the config says '$_helper'"
    else
        [ "$_json_ip" = "null" ] && ok "lan_ip is null with no readable config (no fabricated default)" \
            || bad "lan_ip is $_json_ip but the config is unreadable -- a value was invented"
    fi
    echo ""
    echo "        full response:"
    echo "        $body"
fi

# ---- verdict --------------------------------------------------------------
echo ""
echo "=================================================================="
echo " Results: $pass passed, $fail failed, $warn warnings"
echo "=================================================================="
if [ "$fail" -eq 0 ]; then
    echo " VERDICT: get_system_status is sound. Positional mapping is safe,"
    echo "          the config helpers agree with the parsers they replaced,"
    echo "          and no LAN IP is fabricated."
else
    echo " VERDICT: failures above. A Check 1 order mismatch means the endpoint"
    echo "          can report the WRONG service's state. A Check 4/5 failure"
    echo "          means a guessed LAN IP can reach the settings form."
fi
echo "=================================================================="
