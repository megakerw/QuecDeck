# Security and lifecycle guard host tests.
# Sourced by tests/host/run-tests.sh.

# ------------------------------------------- runtime-path guard (tmpguard) --
# The guard is the durable half of the /run/quecdeck split: source scanning is
# all that stops a root write drifting back into /tmp. If its regexes silently
# stop matching, nothing else notices, so assert BOTH directions against the
# four bugs it exists to prevent. Callers feed it grep -n output, so the fixture
# prefixes a line number.
. tests/host/guards/runtime-path.sh
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

# Authentication must serialize the complete decision, not only the counter
# write: otherwise queued requests can pass bf_locked and then erase a lockout.
t "brute-force transaction requires a successful per-client flock" "yes" \
  "$( _bf=$(extract_fn quecdeck/script/cgi-lib.sh bf_lock); printf '%s\n' "$_bf" | grep -q '\.lock' && printf '%s\n' "$_bf" | grep -q '! flock -x 9' && echo yes || echo no)"
for _auth in quecdeck/www/cgi-bin/auth_login quecdeck/www/cgi-bin/auth_dev; do
    _guard=$(grep -n '^if ! cgi_flock_available; then$' "$_auth" | cut -d: -f1)
    _lock=$(grep -n '^if ! bf_lock .*"\$client_ip"' "$_auth" | cut -d: -f1)
    _validate=$(grep -n '^if validate_password' "$_auth" | cut -d: -f1)
    _fail=$(grep -n '^    bf_fail ' "$_auth" | cut -d: -f1)
    _unlock=$(grep -n '^    bf_unlock$' "$_auth" | tail -1 | cut -d: -f1)
    t "$(basename "$_auth") locks the complete password decision" "yes" \
      "$([ -n "$_guard" ] && [ -n "$_lock" ] && [ "$_guard" -lt "$_lock" ] \
          && [ "$_lock" -lt "$_validate" ] && [ "$_validate" -lt "$_fail" ] \
          && [ "$_fail" -lt "$_unlock" ] && echo yes || echo no)"
done
unset _guard _lock _validate _fail _unlock _auth

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
