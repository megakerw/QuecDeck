#!/bin/bash
# Narrows down why atcmd_run works from root/systemd-www-data contexts but
# produces nothing inside real lighttpd CGIs. Run as root:
#   bash /tmp/device-debug-atlighttpd.sh
# It collects baseline facts, runs a control probe as systemd-www-data, then
# installs a temporary CGI and waits for you to open it in a LOGGED-IN
# browser:  https://<device-ip>/cgi-bin/at_debug
# Everything is cleaned up on exit. Dev tool, not deployed.

set -u
CGI=/usrdata/quecdeck/www/cgi-bin/at_debug
OUT=/tmp/quecdeck/at_debug.out
ATCLI=/usrdata/quecdeck/atcli
SOCK=/tmp/quecdeck/atcli.sock

_teardown() { rm -f "$CGI"; }
trap _teardown EXIT

sec() { echo; echo "==== $1 ===================================="; }

# ---------------------------------------------------------------- baseline --
sec "binary, socket, dirs"
ls -la "$ATCLI" "$SOCK" /tmp/quecdeck /tmp/quecdeck/cache 2>&1 | sed 's/^/  /'
ls -Z "$ATCLI" "$SOCK" 2>/dev/null | sed 's/^/  /' || echo "  (ls -Z unsupported)"

sec "mount flags for /usrdata and /tmp (noexec/nosuid would matter)"
mount 2>/dev/null | grep -E ' /usrdata | /tmp | / ' | sed 's/^/  /'

sec "process SELinux domains"
for name in lighttpd atcli-rs atcli; do
    for pid in $(pidof "$name" 2>/dev/null); do
        printf '  %s (pid %s): %s\n' "$name" "$pid" \
            "$(cat /proc/$pid/attr/current 2>/dev/null || echo unknown)"
    done
done
dpid=$(systemctl show -p MainPID --value atcmd-daemon 2>/dev/null)
[ -n "$dpid" ] && [ "$dpid" != "0" ] && \
    printf '  atcmd-daemon (pid %s): %s\n' "$dpid" \
        "$(cat /proc/$dpid/attr/current 2>/dev/null || echo unknown)"

sec "daemon status counters (before)"
"$ATCLI" --status -s "$SOCK" 2>&1 | sed 's/^/  /'

# --------------------------------------------- control: systemd www-data ----
sec "control probe as systemd-www-data (expected to work)"
systemd-run --uid=www-data --pipe --wait -q /bin/bash -c '
    echo "id: $(id)"
    echo "domain: $(cat /proc/self/attr/current 2>/dev/null)"
    out=$(/usrdata/quecdeck/atcli --help 2>&1 | head -1); echo "exec: rc=$? [$out]"
    out=$(/usrdata/quecdeck/atcli -t 3000 AT 2>&1); echo "AT: rc=$? [$out]"
' 2>&1 | sed 's/^/  /'

# ------------------------------------------------- lighttpd CGI probe -------
rm -f "$OUT"
cat > "$CGI" <<'EOF'
#!/bin/bash
printf 'Content-type: text/plain\n\n'
{
    echo "id: $(id)"
    echo "domain: $(cat /proc/self/attr/current 2>/dev/null)"
    echo "ppid: $PPID ($(cat /proc/$PPID/comm 2>/dev/null))"
    ls -la /usrdata/quecdeck/atcli /tmp/quecdeck/atcli.sock 2>&1
    out=$(/usrdata/quecdeck/atcli --help 2>&1 | head -1); echo "exec: rc=$? [$out]"
    out=$(/usrdata/quecdeck/atcli -t 3000 --status 2>&1); echo "status: rc=$? [$out]"
    out=$(/usrdata/quecdeck/atcli -t 3000 AT 2>&1); echo "AT: rc=$? [$out]"
    . /usrdata/quecdeck/script/cgi-lib.sh 2>/dev/null
    out=$(atcmd_run AT 2>&1); echo "atcmd_run: rc=$? [$out]"
    echo "ulimit -a:"; ulimit -a 2>&1
} > /tmp/quecdeck/at_debug.out 2>&1
cat /tmp/quecdeck/at_debug.out
EOF
chmod 755 "$CGI"

sec "waiting for browser"
echo "  Open in a LOGGED-IN browser:  https://<device-ip>/cgi-bin/at_debug"
echo "  (waiting up to 120 s for the CGI to run...)"
i=0
while [ $i -lt 120 ]; do
    [ -f "$OUT" ] && break
    sleep 1; i=$((i + 1))
done

if [ -f "$OUT" ]; then
    sec "lighttpd CGI probe result"
    sed 's/^/  /' "$OUT"
else
    sec "TIMED OUT waiting for the CGI"
    echo "  Either the browser never hit it, or the CGI could not write"
    echo "  $OUT. Check the browser network tab for the at_debug request"
    echo "  status (403 would mean auth.lua blocked an unknown endpoint)."
fi

sec "daemon status counters (after)"
"$ATCLI" --status -s "$SOCK" 2>&1 | sed 's/^/  /'

sec "kernel messages (last 10, any avc/denial)"
dmesg 2>/dev/null | grep -iE 'avc|denied|atcli' | tail -10 | sed 's/^/  /'
echo
echo "Done. The temporary CGI has been removed."
