#!/bin/sh
# Can a process running as www-data mint an admin session for itself?
#
# auth.lua (the verifier) and every CGI (the attack surface) run as the SAME
# uid, and the session directory is www-data-writable by design. So a www-data
# process can write a session file and present it as a cookie. If auth.lua
# accepts it, the dev-password gate is a UI speed bump rather than a boundary
# against a web-tier compromise, and any CGI code-execution bug is immediately
# full admin with no password.
#
# This is a DESIGN QUESTION, not a regression test. It is expected to hold by
# design today. The open decision is whether to accept or fix it:
#
#   accept: record it as a known tradeoff (any www-data RCE == admin), which is
#           defensible because ttyd.service runs the web console as root, so an
#           authenticated admin already has root by design.
#   fix:    split identity from liveness. Identity (user/role) in a root-owned,
#           www-data-readable file minted by a sudo helper that re-validates the
#           password itself. Liveness (last_access) stays in the www-data-writable
#           sibling, refreshed fork-free per request. Touches auth.lua,
#           auth_login, auth_dev, sudoers, and host/integration/auth-lua.sh.
#
# Run as ROOT on a CONFIGURED device (setup complete):
#
#     sh device-test-session-forgery.sh
#
# Non-destructive: writes one short-lived session file and deletes it. Makes one
# authenticated request, so unlike device-test-authgate.sh it DOES touch the
# access log. That is why it is a separate file: authgate guarantees pure
# unauthenticated GETs and must stay that way.
#
# Scope note: the fixed-path /tmp write checks that used to live here are gone.
# They are covered properly at runtime by tests/device/device-test-runsplit.sh,
# and at commit time by tests/host/guards/runtime-path.sh, which catches a
# reintroduced /tmp path before it can ever reach a device.

SUDO=/opt/bin/sudo
SESSIONS=/tmp/quecdeck/sessions
PROOF_TOKEN="QDHARDPROOF000000000000000000000"

pass=0; fail=0; warn=0
ok()   { echo "  SAFE: $1"; pass=$((pass+1)); }
bad()  { echo "  VULNERABLE: $1"; fail=$((fail+1)); }
note() { echo "  NOTE: $1"; warn=$((warn+1)); }

IP=$(grep -o '<APIPAddr>[^<]*</APIPAddr>' /etc/data/mobileap_cfg.xml 2>/dev/null | sed 's/<[^>]*>//g')
IP=${IP:-192.168.225.1}

cleanup() { rm -f "$SESSIONS/$PROOF_TOKEN" 2>/dev/null; }
trap cleanup EXIT INT TERM

echo "=================================================================="
echo " QuecDeck session-forgery check against $IP"
echo "=================================================================="

[ "$(id -u)" = "0" ] || { echo "FATAL: run as root."; exit 1; }
[ -x "$SUDO" ]        || { echo "FATAL: $SUDO missing -- is QuecDeck installed?"; exit 1; }
id www-data >/dev/null 2>&1 || { echo "FATAL: www-data user missing."; exit 1; }

echo ""
echo "[Facts]"
echo "  $SESSIONS : $(ls -ld "$SESSIONS" 2>/dev/null | awk '{print $1, $3, $4}')"
for _h in /opt/etc/.htpasswd /opt/etc/.htpasswd_dev; do
    echo "  $_h : $(ls -l "$_h" 2>/dev/null | awk '{print $1, $3, $4}')"
done

echo ""
echo "[Prop 1] www-data writes a session file; auth.lua accepts it as admin"
_now=$(date +%s)
if "$SUDO" -u www-data sh -c "printf 'user=admin\nrole=admin\ncreated=%s\nlast_access=%s\n' $_now $_now > $SESSIONS/$PROOF_TOKEN" 2>/dev/null; then
    _code=$(/opt/bin/wget -S --max-redirect=0 -O /dev/null --no-check-certificate \
        --header="Cookie: session=$PROOF_TOKEN" "https://$IP/cgi-bin/get_system_status" 2>&1 \
        | grep -m1 -oE 'HTTP/[0-9.]+ [0-9]+' | awk '{print $2}')
    case "$_code" in
        200) bad "a www-data-authored session file was accepted (HTTP 200 on a gated CGI). The web tier can self-authorize admin; the dev gate is not a boundary against a www-data compromise." ;;
        30[0-9]) ok "the forged session was rejected (HTTP $_code -> login). Session files are not trusted on content alone." ;;
        *)  note "inconclusive: gated CGI returned '${_code:-none}' (network/cert issue?). Re-run with the device reachable at $IP." ;;
    esac
    rm -f "$SESSIONS/$PROOF_TOKEN"
else
    note "could not write the test session file as www-data -- $SESSIONS may not be www-data-writable on this build; that alone would REFUTE prop 1."
fi

echo ""
echo "=================================================================="
echo " Results: $pass safe, $fail vulnerable, $warn notes"
if [ "$fail" -eq 0 ]; then
    echo " VERDICT: forged sessions are rejected."
else
    echo " VERDICT: forgery succeeded. This is the EXPECTED result today and"
    echo "          reflects an open design decision, not a new regression."
    echo "          See the accept-or-fix options in this file's header."
fi
echo "=================================================================="
