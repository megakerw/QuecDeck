#!/bin/sh
# Auth-gating smoke test: verifies that NO CGI endpoint is reachable without a
# session except the deliberate pre-auth allowlist. This is a security
# regression detector: the failure it catches is "a CGI was added or renamed
# and accidentally became reachable pre-auth", which is invisible in review
# and catastrophic in effect. Run as root on a CONFIGURED device (setup done):
#
#     sh device-test-authgate.sh
#
# Non-destructive: pure unauthenticated GETs, no logins attempted, so no
# lockout counters or access-log entries are created. Run it after any change
# to auth.lua, lighttpd.conf, or the cgi-bin population -- and any time as a
# post-release health check; it takes seconds.
#
# It checks:
#   1. The test's expected pre-auth allowlist matches auth.lua's exempt list
#      exactly (a NEW exempt endpoint must be added here deliberately).
#   2. Every other file in /www/cgi-bin/ answers an unauthenticated GET with
#      a redirect to the login page -- never a 200 (executed!) or a 500.
#   3. The allowlisted endpoints respond as designed; auth_login's GET must be
#      an immediate 303 to / (the updater's health probe contract).
#   4. Static pages are gated too (/ redirects to login) and traversal probes
#      never yield a 200.

CGI_DIR=/usrdata/quecdeck/www/cgi-bin
AUTH_LUA=/usrdata/quecdeck/auth.lua
# Deliberate pre-auth endpoints. Keep in sync with auth.lua's exempt list;
# check 1 fails loudly if the two ever diverge.
ALLOWLIST="auth_login auth_logout"
pass=0; fail=0; warn=0

ok()   { echo "  PASS: $1"; pass=$((pass+1)); }
bad()  { echo "  FAIL: $1"; fail=$((fail+1)); }
note() { echo "  WARN: $1"; warn=$((warn+1)); }

IP=$(grep -o '<APIPAddr>[^<]*</APIPAddr>' /etc/data/mobileap_cfg.xml 2>/dev/null | sed 's/<[^>]*>//g')
IP=${IP:-192.168.225.1}

# probe <path>: prints "<status>|<location>" of the FIRST response (redirects
# are not followed, so a 302 is seen as a 302, not its destination's 200).
probe() {
    _out=$(/opt/bin/wget -S --max-redirect=0 -O /dev/null --no-check-certificate "https://$IP$1" 2>&1)
    _st=$(printf '%s\n' "$_out" | grep -m1 -oE 'HTTP/[0-9.]+ [0-9]+' | awk '{print $2}')
    _loc=$(printf '%s\n' "$_out" | grep -m1 -iE '^ *Location:' | awk '{print $2}')
    printf '%s|%s' "${_st:-none}" "$_loc"
}

echo "=================================================================="
echo " QuecDeck auth-gating smoke test against $IP"
echo "=================================================================="

[ -d "$CGI_DIR" ] || { echo "FATAL: $CGI_DIR missing -- is QuecDeck installed?"; exit 1; }

# Refuse to run pre-setup: auth.lua redirects everything to /setup.html then,
# so every endpoint would look "gated" while the gating logic under test
# (session checks) never runs.
case "$(probe /cgi-bin/get_settings)" in
    *setup.html*) echo "FATAL: device is in setup mode; complete setup first."; exit 1 ;;
esac

# ---- Check 1: allowlist matches auth.lua's exempt list ------------------
echo ""
echo "[Check 1] Test allowlist vs auth.lua exempt list"
_lua_exempt=$(sed -n '/^local exempt = {/,/^}/p' "$AUTH_LUA" 2>/dev/null | grep -oE '/cgi-bin/[a-z_]+' | sed 's|/cgi-bin/||')
if [ -z "$_lua_exempt" ]; then
    bad "could not parse auth.lua's exempt list (structure changed? update this test)"
fi
for _e in $_lua_exempt; do
    case " $ALLOWLIST " in
        *" $_e "*) ;;
        *) bad "auth.lua exempts /cgi-bin/$_e but this test does not expect it -- if intentional, add it to ALLOWLIST here deliberately" ;;
    esac
done
for _e in $ALLOWLIST; do
    printf '%s\n' "$_lua_exempt" | grep -qx "$_e" || bad "test expects /cgi-bin/$_e pre-auth but auth.lua no longer exempts it"
done
[ "$fail" -eq 0 ] && ok "allowlist and auth.lua agree: $ALLOWLIST"

# ---- Check 2: every non-allowlisted CGI redirects to login --------------
echo ""
echo "[Check 2] Unauthenticated GET to every gated CGI"
_tested=0
_gated_ok=1
for _f in "$CGI_DIR"/*; do
    [ -f "$_f" ] || continue
    _name=$(basename "$_f")
    case " $ALLOWLIST " in *" $_name "*) continue ;; esac
    _r=$(probe "/cgi-bin/$_name")
    _tested=$((_tested+1))
    case "$_r" in
        302\|*/login.html*|302\|/login.html*) ;;  # gated correctly
        200\|*) bad "/cgi-bin/$_name answered 200 UNAUTHENTICATED (CGI executed!)"; _gated_ok=0 ;;
        *)      bad "/cgi-bin/$_name unexpected response '$_r' (want 302 -> /login.html)"; _gated_ok=0 ;;
    esac
done
if [ "$_tested" -lt 10 ]; then
    bad "only $_tested CGIs enumerated -- wrong path or empty cgi-bin, result not trustworthy"
elif [ "$_gated_ok" = "1" ]; then
    ok "all $_tested gated endpoints redirect to login"
fi

# ---- Check 3: allowlisted endpoints respond as designed -----------------
echo ""
echo "[Check 3] Pre-auth endpoints behave per contract"
_r=$(probe /cgi-bin/auth_login)
# The updater's post-swap health probe depends on exactly this (see the
# CONTRACT comment in auth_login): immediate 303 to /, no side effects.
[ "$_r" = "303|/" ] && ok "auth_login GET is an immediate 303 to / (updater probe contract)" || bad "auth_login GET returned '$_r' (updater health probe expects 303 -> /)"
_r=$(probe /cgi-bin/auth_logout)
case "$_r" in
    30[23]\|*) ok "auth_logout responds with a redirect ($_r)" ;;
    *)         bad "auth_logout unexpected response '$_r'" ;;
esac

# ---- Check 4: static gating + traversal probes ---------------------------
echo ""
echo "[Check 4] Static pages gated; traversal never yields 200"
_r=$(probe /)
case "$_r" in
    302\|*/login.html*|302\|/login.html*) ok "/ redirects to login" ;;
    *) bad "/ unexpected response '$_r'" ;;
esac
for _p in '/cgi-bin/../auth.lua' '/cgi-bin/%2e%2e/auth.lua' '/..%2fauth.lua'; do
    _r=$(probe "$_p")
    case "$_r" in
        200\|*) bad "traversal probe '$_p' answered 200" ;;
        *)      ok "traversal probe '$_p' blocked ($_r)" ;;
    esac
done

# ---- verdict ------------------------------------------------------------
echo ""
echo "=================================================================="
echo " Results: $pass passed, $fail failed, $warn warnings"
echo "=================================================================="
if [ "$fail" -eq 0 ]; then
    echo " VERDICT: auth gating intact -- no CGI reachable pre-auth beyond"
    echo "          the deliberate allowlist ($ALLOWLIST)."
else
    echo " VERDICT: auth-gating FAILURE above. Treat a 200 line as a live"
    echo "          unauthenticated endpoint: fix before any release."
fi
echo "=================================================================="
