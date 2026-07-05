#!/bin/bash
# Runs the auth.lua test harness (tools/test-auth.lua) against the real
# session/htpasswd paths, so it needs a DISPOSABLE root environment (CI
# runner or container). Self-skips when that isn't the case:
#   - no Lua interpreter (dev machine)
#   - /opt/etc/.htpasswd already exists (a real install; never clobber it)
#   - not running as root (can't create /opt/etc)

set -u
cd "$(dirname "$0")/.."

LUA=""
for c in lua5.1 lua5.3 lua5.4 lua luajit; do
    command -v "$c" >/dev/null 2>&1 && { LUA=$c; break; }
done
[ -z "$LUA" ] && { echo "SKIP: no Lua interpreter"; exit 0; }
[ -e /opt/etc/.htpasswd ] && { echo "SKIP: real /opt/etc/.htpasswd present"; exit 0; }
[ "$(id -u)" = "0" ] || { echo "SKIP: not root"; exit 0; }

"$LUA" tools/test-auth.lua
rc=$?
rm -f /opt/etc/.htpasswd
rm -rf /tmp/quecdeck/sessions
exit $rc
