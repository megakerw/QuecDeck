#!/bin/bash
# Verifies the SEAndroid unix-socket domain pairings the planned atcli
# daemon depends on (see atcli_rust). Run as root:
#   bash /tmp/device-test-sockpairs.sh
# Requires the sockprobe binary (built by atcli_rust/build.sh) at
# /tmp/sockprobe. Pairings, listener always systemd-www-data (the
# daemon's future context):
#   P1  bind in /tmp/quecdeck
#   P2  connect from a root shell (adb)
#   P3  connect from a root systemd service (watchcat's context)
#   P4  connect from a lighttpd CGI (www-data, lighttpd's context)
# P4 needs a logged-in browser; the script installs a temporary CGI and
# waits, then cleans everything up.

set -u
PROBE=/tmp/sockprobe
SOCK=/tmp/quecdeck/probe.sock
CGI=/usrdata/quecdeck/www/cgi-bin/probe_sock

[ -f "$PROBE" ] || { echo "FATAL: $PROBE missing (push it first)"; exit 1; }
chmod 755 "$PROBE"
mkdir -p /tmp/quecdeck

pass=0; fail=0
ok()  { pass=$((pass+1)); echo "PASS: $1"; }
bad() { fail=$((fail+1)); echo "FAIL: $1"; }

# ---- P1: listener as a systemd www-data service ---------------------------
systemctl stop sockprobe-test 2>/dev/null
systemctl reset-failed sockprobe-test 2>/dev/null
rm -f "$SOCK"
systemd-run --unit=sockprobe-test --uid=www-data "$PROBE" --listen "$SOCK" \
    || { echo "FATAL: systemd-run failed"; exit 1; }
sleep 2
if [ -S "$SOCK" ]; then
    ok "P1 bind by systemd-www-data"
else
    bad "P1 bind (no socket; check: journalctl -u sockprobe-test)"
fi

# ---- P2: connect from this root shell -------------------------------------
if out=$("$PROBE" --send "$SOCK" root-shell 2>&1); then
    ok "P2 root-shell connect ($out)"
else
    bad "P2 root-shell connect: $out"
fi

# ---- P3: connect from a root systemd service ------------------------------
if out=$(systemd-run --pipe --wait "$PROBE" --send "$SOCK" root-systemd 2>/dev/null); then
    ok "P3 root-systemd connect ($out)"
else
    bad "P3 root-systemd connect (journalctl for the transient unit)"
fi

# ---- P4: connect from a lighttpd CGI (manual browser step) ----------------
cat > "$CGI" <<'EOF'
#!/bin/bash
printf 'Content-type: text/plain\r\n\r\n'
/tmp/sockprobe --send /tmp/quecdeck/probe.sock cgi 2>&1
EOF
chmod 755 "$CGI"
echo ""
echo "P4: log in to the web UI, then open   /cgi-bin/probe_sock"
echo "    REPLY-OK: echo: cgi        -> pairing works"
echo "    CONNECT-FAIL ... denied    -> SELinux denial (the important signal)"
echo ""
printf "Press enter when done to clean up... "
read -r _

rm -f "$CGI"
systemctl stop sockprobe-test 2>/dev/null
systemctl reset-failed sockprobe-test 2>/dev/null
rm -f "$SOCK"
echo ""
echo "cleaned up (CGI removed, listener stopped, socket deleted)"
echo "pairings: $((pass + fail)) automated, passed: $pass, failed: $fail (P4 read in browser)"
