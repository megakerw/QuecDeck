#!/bin/sh
# Post-install invariants for a configured device. Read-only: writes nothing
# outside /tmp and changes no service state.
#
# These are the assertions host tests cannot make, because they depend on what
# this firmware actually ships rather than on what the source says. Each section
# exists because of a real defect:
#
#   1. PLATFORM. BusyBox flock has no -w. Every credential helper called
#      flock -w once, so login, setup, password change and SSH key management
#      all failed with "temporarily unavailable" on a device without
#      util-linux. Nothing in the source revealed it.
#   2. BIND. lighttpd shipped server.bind = "0.0.0.0" and rewrote it at every
#      boot. A skipped rewrite meant binding every interface, so assert the
#      running daemons hold the LAN address and nothing holds the wildcard.
#   3. IMMUTABILITY. Both daemons now read their bind address from tmpfs, so
#      their configuration files must stay byte-identical to the manifest for
#      the life of the install. Boot-time rewriting is the regression.
#   4. PRIVILEGE. The sudo-reachable root helpers must stay root-only. One of
#      them becoming group-writable is a direct root escalation for www-data.
#
# Usage: sh device-test-install-invariants.sh

QD=/usrdata/quecdeck
MANIFEST=$QD/checksums.sha256
pass=0
fail=0
skip=0
ok()   { echo "  PASS: $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL: $1"; fail=$((fail + 1)); }
note() { echo "  SKIP: $1"; skip=$((skip + 1)); }

[ "$(id -u)" = 0 ] || { echo "FATAL: run as root"; exit 1; }
[ -d "$QD" ] || { echo "FATAL: QuecDeck is not installed"; exit 1; }

echo "== 1. platform tooling =="
# Documents WHY lock-lib.sh exists. If a future image ships util-linux flock
# this turns informational, but flock_wait must keep working either way.
if flock -w 5 -x 9 2>/dev/null 9>/tmp/inv.lock; then
    note "flock -w is accepted here (util-linux); flock_wait must still work"
else
    ok "flock -w rejected by this build, which is why flock_wait exists"
fi
rm -f /tmp/inv.lock
if [ -f "$QD/script/lock-lib.sh" ]; then
    . "$QD/script/lock-lib.sh"
    if ( exec 9>>/tmp/inv2.lock; flock_wait 9 2 ); then
        ok "flock_wait acquires a free lock"
    else
        bad "flock_wait FAILED on an uncontended lock"
    fi
    # A held lock must time out rather than block forever.
    ( exec 8>>/tmp/inv2.lock; flock -n -x 8; sleep 4 ) &
    sleep 1
    if ( exec 9>>/tmp/inv2.lock; flock_wait 9 1 ); then
        bad "flock_wait acquired a lock already held"
    else
        ok "flock_wait times out on a held lock instead of blocking"
    fi
    wait
    rm -f /tmp/inv2.lock
else
    bad "lock-lib.sh is missing"
fi
# has_usable_key depends on this: a malformed line must be skipped, not fatal.
if [ -x /opt/bin/ssh-keygen ]; then
    rm -rf /tmp/inv-kb; mkdir -p /tmp/inv-kb
    /opt/bin/ssh-keygen -t ed25519 -f /tmp/inv-kb/k -N '' -q 2>/dev/null
    cat /tmp/inv-kb/k.pub > /tmp/inv-kb/mixed
    echo 'ssh-ed25519 NOTVALIDBASE64!! broken' >> /tmp/inv-kb/mixed
    cat /tmp/inv-kb/k.pub >> /tmp/inv-kb/mixed
    n=$(/opt/bin/ssh-keygen -lf /tmp/inv-kb/mixed -E sha256 2>/dev/null | grep -c .)
    [ "$n" = 2 ] &&
        ok "ssh-keygen -lf skips a malformed line and still lists the rest" ||
        bad "ssh-keygen -lf returned $n fingerprints for 2 good keys, so has_usable_key is unsafe"
    rm -rf /tmp/inv-kb
else
    note "ssh-keygen absent, skipping the malformed-line contract"
fi

echo "== 2. bind addresses =="
LAN=$(sed -n 's/^var\.lan_ip = "\(.*\)"$/\1/p' /run/quecdeck/lighttpd-listen.conf 2>/dev/null)
if [ -n "$LAN" ]; then
    ok "lighttpd bind fragment published: $LAN"
    [ "$(stat -c '%U %a' /run/quecdeck/lighttpd-listen.conf)" = "root 644" ] &&
        ok "lighttpd fragment is root-owned" ||
        bad "lighttpd fragment is $(stat -c '%U %a' /run/quecdeck/lighttpd-listen.conf)"
else
    bad "lighttpd bind fragment missing or unparseable"
fi
if netstat -ltn 2>/dev/null | grep -qE '(^|[^0-9.])0\.0\.0\.0:(80|443)([^0-9]|$)'; then
    bad "a WILDCARD listener is bound on 80 or 443"
else
    ok "no wildcard listener on 80 or 443"
fi
if [ -n "$LAN" ]; then
    netstat -ltn 2>/dev/null | grep -q "$LAN:443" &&
        ok "lighttpd listens on $LAN:443" ||
        bad "nothing listening on $LAN:443"
fi
if [ -x /opt/sbin/sshd ]; then
    grep -q '^ListenAddress ' /run/quecdeck/sshd-listen.conf 2>/dev/null &&
        ok "sshd bind fragment published" ||
        bad "sshd bind fragment missing"
else
    note "OpenSSH not installed, skipping its bind fragment"
fi

echo "== 3. configuration immutability =="
# The old prestart rewrote these at every boot, which moved the installed copy
# away from its manifest hash and made verification impossible.
for rel in lighttpd.conf auth.lua script/firewall.sh script/lighttpd_prestart.sh \
           script/lan-ip-lib.sh script/lock-lib.sh; do
    want=$(awk -v p="*quecdeck/$rel" '$2 == p {print $1}' "$MANIFEST" 2>/dev/null)
    if [ -z "$want" ]; then
        note "$rel absent from the manifest"
        continue
    fi
    got=$(sha256sum "$QD/$rel" 2>/dev/null | awk '{print $1}')
    [ "$want" = "$got" ] && ok "$rel matches the manifest" || bad "$rel DIFFERS from the manifest"
done
grep -q '^ListenAddress' "$QD/lighttpd.conf" 2>/dev/null &&
    bad "a ListenAddress was written into lighttpd.conf" ||
    ok "lighttpd.conf carries no written-in bind address"
if [ -f /opt/etc/ssh/sshd_config ]; then
    grep -q '^ListenAddress' /opt/etc/ssh/sshd_config &&
        bad "a ListenAddress was written into sshd_config" ||
        ok "sshd_config carries no written-in bind address"
fi

echo "== 4. privilege boundaries =="
for s in install_sshd.sh ssh_access.sh change_password.sh check_password.sh \
         write_htpasswd.sh lock-lib.sh lan-ip-lib.sh sshd-policy-lib.sh \
         firewall.sh lighttpd_prestart.sh run_update.sh; do
    [ -e "$QD/script/$s" ] || { note "script/$s not installed"; continue; }
    m=$(stat -c '%U:%G %a' "$QD/script/$s")
    [ "$m" = "root:root 700" ] && ok "script/$s $m" || bad "script/$s is $m, want root:root 700"
done
for f in /opt/etc/.htpasswd /opt/etc/.htpasswd_dev; do
    [ -f "$f" ] || { note "$f absent"; continue; }
    m=$(stat -c '%U:%G %a' "$f")
    [ "$m" = "root:root 600" ] && ok "$f $m" || bad "$f is $m, want root:root 600"
done
g=/opt/etc/.htpasswd_dev.generation
if [ -f "$g" ]; then
    m=$(stat -c '%U:%G %a' "$g")
    # auth.lua runs as www-data and must read it, but nothing needs it world readable.
    [ "$m" = "root:www-data 640" ] && ok "$g $m" || bad "$g is $m, want root:www-data 640"
else
    note "$g absent"
fi
# lighttpd_prestart refuses to start the web tier unless this holds.
m=$(stat -c '%U %a' /opt/etc 2>/dev/null)
case "$m" in
    "root 755"|"root 750"|"root 700") ok "/opt/etc is $m" ;;
    *) bad "/opt/etc is $m, which would let www-data reset credentials" ;;
esac

echo ""
echo "Result: $pass passed, $fail failed, $skip skipped"
[ "$fail" = 0 ]
