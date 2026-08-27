# Security and lifecycle guard host tests.
# Sourced by tests/host/run-tests.sh.

# ------------------------------------------- runtime-path guard (tmpguard) --
# The guard is the durable half of the runtime split: source scanning stops a
# root write drifting into world-writable storage or the web-owned tree. If its regexes silently
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
t "tmpguard flags root access in current web tree" "flag" \
  "$(tmpguard_verdict 'tail /run/quecdeck-web/logs/access_events.jsonl')"

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
  "$(tmpguard_verdict '    # /run/quecdeck-web belongs to www-data')"
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
# www-data units must not be in scope because their web-runtime writes are correct.
t "tmpguard excludes www-data units" "yes" \
  "$(grep -q '^User=www-data' "$TMPGUARD_UNIT_DIR/watchcat.service" && echo yes || echo no)"

# The daemon establishes only the two top-level ownership boundaries. Web
# services then create their own private children after that initializer runs.
_at_unit=quecdeck/systemd/atcmd-daemon.service
t "atcmd unit rejects symlinked runtime boundaries" "yes" \
  "$(grep -q 'for D in /run/quecdeck /run/quecdeck-web.*\[ ! -L' "$_at_unit" && echo yes || echo no)"
t "atcmd unit owns the web runtime as www-data 0700" "yes" \
  "$(grep -q 'chown www-data:www-data /run/quecdeck-web.*chmod 700 /run/quecdeck-web' "$_at_unit" && echo yes || echo no)"
t "atcmd socket lives in the web runtime" "yes" \
  "$(grep -q '^ExecStart=.*-s /run/quecdeck-web/atcli.sock ' "$_at_unit" && echo yes || echo no)"
t "atcmd daemon owns live log rollover" "yes" \
  "$(grep -q -- '--log-bytes 65536' "$_at_unit" && ! grep -q 'tail -500.*atcmd.log' "$_at_unit" && echo yes || echo no)"
for _runtime_unit in connection-logger watchcat scheduled_restart lighttpd; do
  t "$_runtime_unit starts after the runtime initializer" "yes" \
    "$(grep -q '^After=.*atcmd-daemon.service' "quecdeck/systemd/$_runtime_unit.service" && echo yes || echo no)"
done
unset _at_unit _runtime_unit

# Authentication must serialize the complete decision, not only the counter
# write: otherwise queued requests can pass bf_locked and then erase a lockout.
t "brute-force transaction requires a successful per-client flock" "yes" \
  "$( _bf=$(extract_fn quecdeck/script/cgi-lib.sh bf_lock); printf '%s\n' "$_bf" | grep -q '\.lock' && printf '%s\n' "$_bf" | grep -q '! flock -x 9' && echo yes || echo no)"
for _auth in quecdeck/www/cgi-bin/auth_login quecdeck/www/cgi-bin/auth_dev; do
    _guard=$(grep -n '^if ! cgi_flock_available; then$' "$_auth" | cut -d: -f1)
    _lock=$(grep -n '^if ! bf_lock .*"\$client_ip"' "$_auth" | cut -d: -f1)
    _validate=$(grep -n '^validate_password' "$_auth" | cut -d: -f1)
    _fail=$(grep -n '^    bf_fail ' "$_auth" | cut -d: -f1)
    _unlock=$(grep -n '^    bf_unlock$' "$_auth" | tail -1 | cut -d: -f1)
    t "$(basename "$_auth") locks the complete password decision" "yes" \
      "$([ -n "$_guard" ] && [ -n "$_lock" ] && [ "$_guard" -lt "$_lock" ] \
          && [ "$_lock" -lt "$_validate" ] && [ "$_validate" -lt "$_fail" ] \
          && [ "$_fail" -lt "$_unlock" ] && echo yes || echo no)"
done
unset _guard _lock _validate _fail _unlock _auth

# Logout writes a tombstone before removing the live session. auth.lua checks
# that tombstone after its atomic refresh, which prevents an overlapping
# authenticated request from recreating a session that logout just removed.
_logout_marker=$(grep -n 'mv -f.*\.revoked' quecdeck/www/cgi-bin/auth_logout | cut -d: -f1)
_logout_remove=$(grep -n 'rm -f "\$session_file"' quecdeck/www/cgi-bin/auth_logout | head -1 | cut -d: -f1)
_auth_refresh=$(grep -n 'os.rename(tmp, sf)' quecdeck/auth.lua | cut -d: -f1)
_auth_revoke=$(grep -n '^if session_revoked() then$' quecdeck/auth.lua | cut -d: -f1)
t "logout tombstone precedes session removal" "yes" \
  "$([ -n "$_logout_marker" ] && [ -n "$_logout_remove" ] && [ "$_logout_marker" -lt "$_logout_remove" ] && echo yes || echo no)"
t "logout creates a tombstone only for an existing session" "yes" \
  "$([ "$(grep -n '^    if \[ -f "\$session_file" \]; then$' quecdeck/www/cgi-bin/auth_logout | cut -d: -f1)" -lt "$_logout_marker" ] && echo yes || echo no)"
t "auth checks logout tombstone after refresh" "yes" \
  "$([ -n "$_auth_refresh" ] && [ -n "$_auth_revoke" ] && [ "$_auth_refresh" -lt "$_auth_revoke" ] && echo yes || echo no)"

# Initial setup is one root-side transaction. The lock must cover both the
# existence checks and installation, and the administrator file is written
# last because its presence marks setup complete to auth.lua.
_setup_lock=$(grep -n '^flock_wait 9 5' quecdeck/script/write_htpasswd.sh | cut -d: -f1)
_setup_exists=$(grep -n '\[ ! -s /opt/etc/\.htpasswd \]' quecdeck/script/write_htpasswd.sh | head -1 | cut -d: -f1)
_setup_dev=$(grep -n 'install_line /opt/etc/\.htpasswd_dev' quecdeck/script/write_htpasswd.sh | cut -d: -f1)
_setup_admin=$(grep -n 'install_line /opt/etc/\.htpasswd "\$ADMIN_LINE"' quecdeck/script/write_htpasswd.sh | cut -d: -f1)
t "setup lock covers credential existence checks" "yes" \
  "$([ -n "$_setup_lock" ] && [ -n "$_setup_exists" ] && [ "$_setup_lock" -lt "$_setup_exists" ] && echo yes || echo no)"
t "setup commits administrator credential last" "yes" \
  "$([ -n "$_setup_dev" ] && [ -n "$_setup_admin" ] && [ "$_setup_dev" -lt "$_setup_admin" ] && echo yes || echo no)"
t "administrator recovery preserves an existing developer credential" "yes" \
  "$(grep -q '^        \[ -z "\$DEV_LINE" \] || \[ ! -s /opt/etc/\.htpasswd_dev \] || exit 1$' quecdeck/script/write_htpasswd.sh && echo yes || echo no)"
t "administrator recovery skips the existing developer credential" "yes" \
  "$(grep -q 'developer_configured' quecdeck/www/cgi-bin/init_setup quecdeck/www/js/setup.js && grep -q '^      if (this.developerConfigured) {' quecdeck/www/js/setup.js && grep -q '^        this.submitExistingDev();' quecdeck/www/js/setup.js && echo yes || echo no)"
# A developer credential is mandatory: SSH key management is gated on it, so an
# install without one cannot reach that feature. Enforced at the root boundary
# too, because the web tier can call the helper directly.
t "setup requires a developer credential when none exists" "yes" \
  "$(grep -q '^        \[ -n "\$DEV_LINE" \] || \[ -s /opt/etc/\.htpasswd_dev \] || exit 1$' quecdeck/script/write_htpasswd.sh && grep -q 'A developer password is required' quecdeck/www/cgi-bin/init_setup && echo yes || echo no)"
t "setup wizard offers no developer skip" "yes" \
  "$(! grep -q 'skipDev' quecdeck/www/js/setup.js quecdeck/www/setup.html && ! grep -qi '>Skip<' quecdeck/www/setup.html && echo yes || echo no)"
t "setup CGI submits one credential transaction" "yes" \
  "$(grep -q 'write_htpasswd\.sh setup' quecdeck/www/cgi-bin/init_setup && ! grep -q 'write_htpasswd\.sh admin' quecdeck/www/cgi-bin/init_setup && echo yes || echo no)"
unset _logout_marker _logout_remove _auth_refresh _auth_revoke
unset _setup_lock _setup_exists _setup_dev _setup_admin

# Web security changes cross the privilege boundary through fixed-operation
# helpers. They accept credentials and key data on stdin, never a destination
# path, and must stay root-owned in the staged release.
_root_helpers=$(sed -n '/for _s in lighttpd_prestart.sh/,/; do/p' update_quecdeck.sh)
_sudo_rule=$(grep '_sudoers_rule=' update_quecdeck.sh)
_expected_sudo_rule='www-data ALL = (root) NOPASSWD: /bin/systemctl restart watchcat, /bin/systemctl reset-failed watchcat, /bin/systemctl restart scheduled_restart, /bin/systemctl reset-failed scheduled_restart, /usrdata/quecdeck/script/write_htpasswd.sh, /usrdata/quecdeck/script/change_password.sh, /usrdata/quecdeck/script/ssh_keys.sh, /usrdata/quecdeck/script/check_password.sh, /usrdata/quecdeck/script/run_update.sh'
t "sudoers root surface matches the reviewed exact list" "yes" \
  "$([ "$(printf '%s\n' "$_sudo_rule" | sed 's/^[^=]*="//;s/"$//')" = "$_expected_sudo_rule" ] && echo yes || echo no)"
t "sudo helpers enforce fixed argument counts" "yes" \
  "$(grep -q '\[ "\$#" -eq 2 \]' quecdeck/script/check_password.sh && grep -q '\[ "\$#" -eq 1 \]' quecdeck/script/write_htpasswd.sh && grep -q '\[ "\$#" -eq 2 \]' quecdeck/script/ssh_keys.sh && grep -q -- '--fetch).*\[ "\$#" -eq 2 \]' quecdeck/script/run_update.sh && echo yes || echo no)"
for _helper in change_password.sh ssh_keys.sh; do
    t "$_helper is staged root-only" "yes" \
      "$(printf '%s\n' "$_root_helpers" | grep -q "$_helper" && echo yes || echo no)"
    t "$_helper has an explicit sudo grant" "yes" \
      "$(printf '%s\n' "$_sudo_rule" | grep -q "/usrdata/quecdeck/script/$_helper" && echo yes || echo no)"
done
t "password helper verifies current password before replacement" "yes" \
  "$([ "$(grep -n 'check_password.sh admin admin' quecdeck/script/change_password.sh | cut -d: -f1)" -lt "$(grep -n 'mv -f.*HTPASSWD' quecdeck/script/change_password.sh | cut -d: -f1)" ] && echo yes || echo no)"
t "root-side web password verification is serialized and paced" "yes" \
  "$(grep -q '^LIMIT_DIR=/run/quecdeck/auth-limit$' quecdeck/script/check_password.sh && grep -q '^flock_wait 9 5 || exit 75$' quecdeck/script/check_password.sh && grep -q '^sleep 1$' quecdeck/script/check_password.sh && echo yes || echo no)"
t "password pacing availability tradeoff is documented" "yes" \
  "$(grep -q 'Root-side password pacing trades availability for brute-force resistance' README.md && grep -q 'availability cost is accepted deliberately' README.md && echo yes || echo no)"
t "privileged security mutation locks have bounded waits" "4" \
  "$(grep -h '^[[:space:]]*flock_wait 9 5 || exit 75$' quecdeck/script/change_password.sh quecdeck/script/ssh_keys.sh | wc -l | tr -d ' ')"
t "initial setup lock has a bounded wait" "yes" \
  "$(grep -q '^flock_wait 9 5 || exit 75$' quecdeck/script/write_htpasswd.sh && echo yes || echo no)"
t "web startup verifies the Entware credential boundary" "yes" \
  "$( _guard=$(extract_fn quecdeck/script/lighttpd_prestart.sh secure_entware_config_dir); grep -q '^PATH=.*opt/bin' quecdeck/script/lighttpd_prestart.sh && grep -q 'command -v stat' quecdeck/script/lighttpd_prestart.sh && printf '%s\n' "$_guard" | grep -q '\[ ! -L "\$_etc_dir" \]' && printf '%s\n' "$_guard" | grep -q 'stat -c %u' && printf '%s\n' "$_guard" | grep -q '& 022' && grep -q '^if ! secure_entware_config_dir; then$' quecdeck/script/lighttpd_prestart.sh && echo yes || echo no)"
t "SSH key upload trims pasted whitespace" "yes" \
  "$(grep -q 'const publicKey = this.publicKey.trim()' quecdeck/www/js/security.js && grep -q 'public_key: publicKey' quecdeck/www/js/security.js && echo yes || echo no)"
t "password policy is consistently 12 to 256 characters" "yes" \
  "$(grep -q 'minimum of 12 characters' README.md && grep -q 'between 12 and 256' README.md quecdeck/quecdeckpasswd quecdeck/quecdeckdevpasswd quecdeck/www/cgi-bin/init_setup quecdeck/www/cgi-bin/manage_security quecdeck/www/js/security.js && [ "$(grep -c 'minlength="12" maxlength="256"' quecdeck/www/setup.html)" -eq 4 ] && [ "$(grep -c 'minlength="12" maxlength="256"' quecdeck/www/security.html)" -eq 2 ] && echo yes || echo no)"
t "sudo payload parsers reject even blank extra lines" "5" \
  "$(grep -h 'IFS= read -r EXTRA && exit 1' quecdeck/script/write_htpasswd.sh quecdeck/script/change_password.sh quecdeck/script/ssh_keys.sh | wc -l | tr -d ' ')"
t "password pacing applies only after failed verification" "yes" \
  "$([ "$(grep -n '^if validate_htpasswd' quecdeck/script/check_password.sh | cut -d: -f1)" -lt "$(grep -n '^sleep 1$' quecdeck/script/check_password.sh | tail -1 | cut -d: -f1)" ] && echo yes || echo no)"
t "credential callers preserve temporary-unavailable status" "yes" \
  "$(grep -q '\[ "\$password_rc" != 75 \]' quecdeck/script/change_password.sh && grep -q '\[ "\$credential_rc" != 75 \]' quecdeck/script/ssh_keys.sh && grep -q '\[ "\$password_rc" = 75 \]' quecdeck/www/cgi-bin/auth_login quecdeck/www/cgi-bin/auth_dev && grep -q '\[ "\$rc" = 75 \]' quecdeck/www/cgi-bin/manage_security && grep -q '\[ "\$write_rc" = 75 \]' quecdeck/www/cgi-bin/init_setup && echo yes || echo no)"
t "CGI lockout accounting does not duplicate root-side pacing" "yes" \
  "$(! extract_fn quecdeck/script/cgi-lib.sh bf_fail | grep -q '^ *sleep ' && echo yes || echo no)"
t "password verifier accepts only fixed account pairs" "yes" \
  "$(grep -q 'admin).*USERNAME=admin' quecdeck/script/check_password.sh && grep -q 'dev).*USERNAME=devadmin' quecdeck/script/check_password.sh && grep -q '^if \[ "\${2:-}" != "\$USERNAME" \]; then$' quecdeck/script/check_password.sh && [ "$(grep -n '^flock_wait 9 5' quecdeck/script/check_password.sh | cut -d: -f1)" -lt "$(grep -n '^if \[ "\${2:-}" != "\$USERNAME" \]; then$' quecdeck/script/check_password.sh | cut -d: -f1)" ] && echo yes || echo no)"
t "dual-credential SSH checks do not short-circuit" "yes" \
  "$( _verify=$(extract_fn quecdeck/script/ssh_keys.sh verify_credentials); [ "$(printf '%s\n' "$_verify" | grep -c 'check_password.sh')" = 2 ] && printf '%s\n' "$_verify" | grep -q 'admin_rc=' && printf '%s\n' "$_verify" | grep -q 'dev_rc=' && echo yes || echo no)"
t "sudo credential helpers bound stdin before parsing" "yes" \
  "$( _bounded=yes; for _h in quecdeck/script/write_htpasswd.sh quecdeck/script/change_password.sh quecdeck/script/ssh_keys.sh; do grep -q 'head -c ' "$_h" && grep -Fq 'PAYLOAD=${PAYLOAD%.}' "$_h" && grep -q '\${#PAYLOAD}.*-le' "$_h" || _bounded=no; done; printf '%s' "$_bounded")"
t "initial credential helper exposes setup mode only" "yes" \
  "$(! grep -q 'admin|dev)' quecdeck/script/write_htpasswd.sh && grep -q '^    setup)' quecdeck/script/write_htpasswd.sh && echo yes || echo no)"
t "SSH helper fixes the authorized-keys destination" "yes" \
  "$(grep -q '^KEYS=\$SSH_DIR/authorized_keys$' quecdeck/script/ssh_keys.sh && ! grep -qE 'KEYS=.*\$[123]' quecdeck/script/ssh_keys.sh && echo yes || echo no)"
t "SSH helper rejects symlinked key storage" "yes" \
  "$(grep -q '\[ ! -L "\$SSH_DIR" \]' quecdeck/script/ssh_keys.sh && grep -q '\[ ! -L "\$KEYS" \]' quecdeck/script/ssh_keys.sh && echo yes || echo no)"
t "SSH helper validates keys before authorized_keys replacement" "yes" \
  "$([ "$(grep -n 'valid_key_syntax "\$KEY_LINE"' quecdeck/script/ssh_keys.sh | cut -d: -f1)" -lt "$(grep -n 'mv -f.*KEYS' quecdeck/script/ssh_keys.sh | head -1 | cut -d: -f1)" ] && echo yes || echo no)"
t "SSH key validation accepts an empty comment" "yes" \
  "$(eval "$(extract_fn quecdeck/script/ssh_keys.sh valid_key_syntax)"; valid_key_syntax 'ssh-ed25519 AAAA' && echo yes || echo no)"
t "SSH helper normalizes existing key line endings before append" "yes" \
  "$(grep -q 'while IFS= read -r existing || \[ -n "\$existing" \]' quecdeck/script/ssh_keys.sh && ! grep -q 'cat "\$KEYS"; printf.*KEY_LINE' quecdeck/script/ssh_keys.sh && echo yes || echo no)"
t "SSH helper requires administrator and developer credentials" "yes" \
  "$(grep -q 'check_password.sh admin admin' quecdeck/script/ssh_keys.sh && grep -q 'check_password.sh dev devadmin' quecdeck/script/ssh_keys.sh && grep -q 'developer_password' quecdeck/www/cgi-bin/manage_security quecdeck/www/js/security.js && echo yes || echo no)"
t "SSH key management requires a configured developer credential" "yes" \
  "$(grep -q '\[ -s /opt/etc/\.htpasswd_dev \] || exit 8' quecdeck/script/ssh_keys.sh && grep -q '8) json_result false "Set a developer access password' quecdeck/www/cgi-bin/manage_security && grep -q 'developer_configured' quecdeck/www/cgi-bin/get_security quecdeck/www/js/security.js && echo yes || echo no)"
t "missing developer credential does not count as password failure" "yes" \
  "$([ "$(grep -n '^if \[ "\$rc" = 2 \]; then$' quecdeck/www/cgi-bin/manage_security | cut -d: -f1)" -lt "$(grep -n '^if \[ "\$rc" != 0 \]; then$' quecdeck/www/cgi-bin/manage_security | cut -d: -f1)" ] && grep -q '^        8) json_result false' quecdeck/www/cgi-bin/manage_security && echo yes || echo no)"
t "SSH key status distinguishes incompatible root home permissions" "yes" \
  "$(grep -q 'safe_root_home || exit 9' quecdeck/script/ssh_keys.sh && grep -q 'root_home_ready' quecdeck/www/cgi-bin/get_security quecdeck/www/js/security.js && grep -q '^        9) json_result false' quecdeck/www/cgi-bin/manage_security && echo yes || echo no)"
t "SSH status JSON has a stable root-home field" "yes" \
  "$([ "$(grep -c 'root_home_ready' quecdeck/www/cgi-bin/get_security)" -eq 3 ] && echo yes || echo no)"
t "SSH status failures remain parseable and actionable" "yes" \
  "$(grep -q 'Status: 500 Internal Server Error' quecdeck/www/cgi-bin/get_security && grep -Fq '"ok":false' quecdeck/www/cgi-bin/get_security && grep -q 'data.ok === false' quecdeck/www/js/security.js && grep -q 'err.message' quecdeck/www/js/security.js && echo yes || echo no)"
t "SSH key JSON sanitizes imported key types" "yes" \
  "$(grep -q "type=.*tr -cd 'A-Za-z0-9@._+-'" quecdeck/www/cgi-bin/get_security && echo yes || echo no)"
t "SSH key JSON escapes every emitted string" "3" \
  "$(grep -c '=\$(json_escape ' quecdeck/www/cgi-bin/get_security)"
t "setup submission is guarded against repeated clicks" "yes" \
  "$(grep -q '^      if (this.submitting) return;$' quecdeck/www/js/setup.js && grep -q ':disabled="submitting || !adminPass' quecdeck/www/setup.html && echo yes || echo no)"
t "session cleanup recognizes temporary and developer siblings" "yes" \
  "$(grep -q '%.new\$' quecdeck/auth.lua && grep -q '%.dev\$' quecdeck/auth.lua && grep -q '%.dev%.tmp%.%d+\$' quecdeck/auth.lua && grep -q '%.revoked%.tmp%.%d+\$' quecdeck/auth.lua && grep -q 'dev_unlocked=1.*created=%s' quecdeck/www/cgi-bin/auth_dev && echo yes || echo no)"
t "setup validates method and origin before JSON headers" "yes" \
  "$([ "$(grep -n '^    cgi_check_cors$' quecdeck/www/cgi-bin/init_setup | cut -d: -f1)" -lt "$(grep -n '^    cgi_output_json$' quecdeck/www/cgi-bin/init_setup | cut -d: -f1)" ] && [ "$(grep -n '^cgi_require_post$' quecdeck/www/cgi-bin/init_setup | cut -d: -f1)" -lt "$(grep -n '^cgi_output_json$' quecdeck/www/cgi-bin/init_setup | tail -1 | cut -d: -f1)" ] && echo yes || echo no)"
t "security POST allowance covers encoded key input" "yes" \
  "$(grep -q '^cgi_read_post 32768$' quecdeck/www/cgi-bin/manage_security && echo yes || echo no)"
t "existing authorized_keys formats do not brick key loading" "yes" \
  "$( _load=$(extract_fn quecdeck/script/ssh_keys.sh load_store); ! printf '%s\n' "$_load" | grep -q 'valid_key_syntax.*return 1' && printf '%s\n' "$_load" | grep -q 'fingerprint_line.*|| fp=' && echo yes || echo no)"
t "SSH key listing batches fingerprints on the normal path" "yes" \
  "$( _load=$(extract_fn quecdeck/script/ssh_keys.sh load_store); [ "$(printf '%s\n' "$_load" | grep -c 'ssh-keygen -lf "\$KEYS"')" = 1 ] && printf '%s\n' "$_load" | grep -q '#batch_fingerprints\[@\].*-eq.*KEY_COUNT' && echo yes || echo no)"
t "SSH key listing keeps a malformed-line fallback" "yes" \
  "$( _load=$(extract_fn quecdeck/script/ssh_keys.sh load_store); printf '%s\n' "$_load" | grep -q 'fingerprint_line "\$line".*|| fp=' && echo yes || echo no)"
t "SSH fingerprint fallback uses volatile runtime storage" "yes" \
  "$( _fingerprint=$(extract_fn quecdeck/script/ssh_keys.sh fingerprint_line); printf '%s\n' "$_fingerprint" | grep -q 'mktemp "\$RUNTIME_DIR/ssh-key\.XXXXXX"' && ! printf '%s\n' "$_fingerprint" | grep -q '\$ROOT_HOME' && echo yes || echo no)"
t "adding a key starts SSH only while the server is enabled" "yes" \
  "$( _add=$(sed -n '/^    add)/,/^        ;;/p' quecdeck/script/ssh_keys.sh); printf '%s\n' "$_add" | grep -q 'enabled_marker_safe' && printf '%s\n' "$_add" | grep -q 'systemctl start sshd' && echo yes || echo no)"
t "SSH settings stay inside the existing privileged helper" "yes" \
  "$(grep -q '^    settings)' quecdeck/script/ssh_keys.sh && grep -q 'ssh_keys.sh settings' quecdeck/www/cgi-bin/manage_security && ! grep -qE 'sudo .*systemctl.*sshd|sudo .*firewall' quecdeck/www/cgi-bin/manage_security && echo yes || echo no)"
t "SSH settings require both credentials at the root boundary" "yes" \
  "$( _settings=$(sed -n '/^    settings)/,/^        ;;/p' quecdeck/script/ssh_keys.sh); printf '%s\n' "$_settings" | grep -q 'verify_credentials' && printf '%s\n' "$_settings" | grep -q '\[ -s /opt/etc/\.htpasswd_dev \] || exit 8' && echo yes || echo no)"
t "SSH settings accept only a Boolean and the reviewed port range" "yes" \
  "$( _settings=$(sed -n '/^    settings)/,/^        ;;/p' quecdeck/script/ssh_keys.sh); _ports=$(extract_fn quecdeck/script/ssh_keys.sh valid_ssh_port); printf '%s\n' "$_settings" | grep -q 'case "\$SSH_ENABLED" in 0|1)' && printf '%s\n' "$_settings" | grep -q 'valid_ssh_port "\$SSH_PORT"' && printf '%s\n' "$_ports" | grep -q '\$1.*= 22' && printf '%s\n' "$_ports" | grep -q '\$1.*-ge 1024' && echo yes || echo no)"
t "SSH config is validated before its atomic replacement" "yes" \
  "$( _apply=$(extract_fn quecdeck/script/ssh_keys.sh apply_settings); [ "$(printf '%s\n' "$_apply" | grep -n 'validate_sshd_config' | cut -d: -f1)" -lt "$(printf '%s\n' "$_apply" | grep -n 'mv -f.*SSHD_CONFIG' | cut -d: -f1)" ] && echo yes || echo no)"
t "SSH starts only after the firewall accepts the new port" "yes" \
  "$( _act=$(extract_fn quecdeck/script/ssh_keys.sh activate_settings); _fw=$(printf '%s\n' "$_act" | grep -n 'firewall.sh' | head -1 | cut -d: -f1); _start=$(printf '%s\n' "$_act" | grep -n 'systemctl start sshd' | head -1 | cut -d: -f1); [ -n "$_fw" ] && [ -n "$_start" ] && [ "$_fw" -lt "$_start" ] && ! printf '%s\n' "$_act" | grep -q 'systemctl restart firewall' && echo yes || echo no)"
t "SSH activation has one firewall and daemon path" "yes" \
  "$( _apply=$(extract_fn quecdeck/script/ssh_keys.sh apply_settings); printf '%s\n' "$_apply" | grep -q 'activate_settings' && ! printf '%s\n' "$_apply" | grep -q 'firewall.sh' && ! printf '%s\n' "$_apply" | grep -q 'systemctl start sshd' && echo yes || echo no)"
t "SSH enable marker is fixed, root-only, and shared with the unit" "yes" \
  "$(grep -q '^ENABLED_MARKER=/opt/etc/ssh/quecdeck_enabled$' quecdeck/script/ssh_keys.sh && grep -q 'chmod 600 "\$ENABLED_MARKER"' quecdeck/script/ssh_keys.sh && grep -q '^ConditionPathExists=/opt/etc/ssh/quecdeck_enabled$' optional/sshd/sshd.service && echo yes || echo no)"
t "SSH settings API and UI expose enabled state and port" "yes" \
  "$(grep -q 'ssh_enabled' quecdeck/www/cgi-bin/get_security quecdeck/www/js/security.js && grep -q 'ssh_port' quecdeck/www/cgi-bin/get_security quecdeck/www/cgi-bin/manage_security quecdeck/www/js/security.js && grep -q 'form-check form-switch' quecdeck/www/security.html && echo yes || echo no)"
t "pending SSH settings block key mutations in the UI" "yes" \
  "$(grep -q 'get sshSettingsChanged' quecdeck/www/js/security.js && [ "$(grep -c 'Save the SSH settings before managing public keys' quecdeck/www/js/security.js)" = 2 ] && [ "$(grep -c 'sshSettingsChanged' quecdeck/www/security.html)" -ge 2 ] && echo yes || echo no)"
t "password-change reports success with an invalidation warning" "yes" \
  "$(grep -q 'session_invalidation_failed=1' quecdeck/www/cgi-bin/manage_security && grep -q '"ok":true,"warning":"session_invalidation"' quecdeck/www/cgi-bin/manage_security && grep -q 'session_warning=1' quecdeck/www/js/security.js quecdeck/www/js/login.js && echo yes || echo no)"
t "hidden unsupported SSH entries do not consume the UI key limit" "yes" \
  "$(grep -q '\[ "\$KEY_USABLE_COUNT" -lt "\$MAX_KEYS" \]' quecdeck/script/ssh_keys.sh && echo yes || echo no)"
t "SSH readiness enforces effective key-only policy" "yes" \
  "$(grep -q 'sshd -T' quecdeck/script/ssh_keys.sh && grep -q "authenticationmethods publickey" quecdeck/script/ssh_keys.sh && grep -q "passwordauthentication no" quecdeck/script/ssh_keys.sh && ! grep -q 'usepam' quecdeck/script/ssh_keys.sh && echo yes || echo no)"
t "SSH stops when the final key is removed" "yes" \
  "$(grep -q 'KEY_COUNT.*= 0' quecdeck/script/ssh_keys.sh && grep -q 'systemctl stop sshd' quecdeck/script/ssh_keys.sh && echo yes || echo no)"
t "explicit SSH stops terminate sessions" "yes" \
  "$(grep -q '^KillMode=control-group$' optional/sshd/sshd.service && grep -q '^TimeoutStopSec=10$' optional/sshd/sshd.service && grep -q 'systemctl restart sshd' quecdeck/script/ssh_keys.sh && echo yes || echo no)"
t "full uninstall removes SSH before firewall" "yes" \
  "$(_uninstall=$(sed -n '/^uninstall_quecdeck_components() {/,/^}/p' quecdeck.sh); _ssh_stop=$(printf '%s\n' "$_uninstall" | grep -n 'systemctl stop sshd' | head -1 | cut -d: -f1); _fw_remove=$(printf '%s\n' "$_uninstall" | grep -n '# Uninstall firewall' | cut -d: -f1); [ -n "$_ssh_stop" ] && [ -n "$_fw_remove" ] && [ "$_ssh_stop" -lt "$_fw_remove" ] && echo yes || echo no)"
_security_lock=$(grep -n 'bf_lock "\$FAILURE_DIR"' quecdeck/www/cgi-bin/manage_security | cut -d: -f1)
_security_sudo=$(grep -n '/opt/bin/sudo' quecdeck/www/cgi-bin/manage_security | head -1 | cut -d: -f1)
t "security mutations lock authentication before sudo" "yes" \
  "$([ -n "$_security_lock" ] && [ -n "$_security_sudo" ] && [ "$_security_lock" -lt "$_security_sudo" ] && echo yes || echo no)"
unset _helper _root_helpers _sudo_rule _expected_sudo_rule _security_lock _security_sudo

# Access events come from several independent CGI processes. Exercise the real
# writer around its rollover boundary so a future lock or atomic-replace
# regression cannot silently discard overlapping login and logout events.
eval "$(extract_fn quecdeck/script/cgi-lib.sh log_access_event)"
_access_umask=$(umask)
umask 077
_access_fixture=$(mktemp -d)
_access_log="$_access_fixture/access_events.jsonl"
_access_results="$_access_fixture/results"
mkdir "$_access_results"
_access_real_flock=1
if ! command -v flock >/dev/null 2>&1; then
    _access_real_flock=0
    flock() { return 0; }
fi
ACCESS_LOG_LIMIT=100
if [ "$_access_real_flock" = "1" ]; then
    for _i in $(seq 1 40); do
        (log_access_event "$_access_log" "{\"id\":$_i}" && touch "$_access_results/$_i") &
    done
    wait
    t "every concurrent access-log append succeeds" "40" \
      "$(find "$_access_results" -type f | wc -l | tr -d ' ')"
    t "concurrent access-log appends are not lost" "40" "$(wc -l < "$_access_log" | tr -d ' ')"
    t "concurrent access-log entries stay intact" "40" "$(grep -c '^{"id":[0-9][0-9]*}$' "$_access_log")"
else
    for _i in $(seq 1 40); do
        log_access_event "$_access_log" "{\"id\":$_i}"
    done
fi

ACCESS_LOG_LIMIT=25
if [ "$_access_real_flock" = "1" ]; then
    for _i in $(seq 41 100); do
        (log_access_event "$_access_log" "{\"id\":$_i}" && touch "$_access_results/$_i") &
    done
    wait
    t "every append through concurrent rollover succeeds" "100" \
      "$(find "$_access_results" -type f | wc -l | tr -d ' ')"
else
    for _i in $(seq 41 100); do
        log_access_event "$_access_log" "{\"id\":$_i}"
    done
fi
t "access log remains at its configured limit" "25" "$(wc -l < "$_access_log" | tr -d ' ')"
t "access-log rollover leaves complete entries" "25" "$(grep -c '^{"id":[0-9][0-9]*}$' "$_access_log")"
t "access-log rollover leaves no temporary files" "0" \
  "$(find "$_access_fixture" -name 'access_events.jsonl.tmp.*' | wc -l | tr -d ' ')"
t "access log is created owner-only" "600" "$(stat -c %a "$_access_log")"
t "access-log lock is created owner-only" "600" \
  "$(stat -c %a "$_access_fixture/access_events.lock")"

flock() { return 1; }
log_access_event "$_access_log" '{"id":101}' >/dev/null 2>&1
t_rc "access-log lock failure is reported" 1 "$?"
if [ "$_access_real_flock" = "1" ]; then
    unset -f flock
else
    flock() { return 0; }
fi

tail() { return 1; }
log_access_event "$_access_log" '{"id":102}' >/dev/null 2>&1
t_rc "access-log trim failure is reported" 1 "$?"
unset -f tail
t "failed access-log trim removes its temporary file" "0" \
  "$(find "$_access_fixture" -name 'access_events.jsonl.tmp.*' | wc -l | tr -d ' ')"

mv() { return 1; }
log_access_event "$_access_log" '{"id":103}' >/dev/null 2>&1
t_rc "access-log replacement failure is reported" 1 "$?"
unset -f mv
t "failed access-log replacement removes its temporary file" "0" \
  "$(find "$_access_fixture" -name 'access_events.jsonl.tmp.*' | wc -l | tr -d ' ')"

log_access_event "$_access_fixture" '{"id":104}' >/dev/null 2>&1
t_rc "access-log append failure is reported" 1 "$?"
rm -rf "$_access_fixture"
umask "$_access_umask"
if [ "$_access_real_flock" = "0" ]; then
    unset -f flock
fi
unset ACCESS_LOG_LIMIT _access_fixture _access_log _access_results _access_real_flock _access_umask _i

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

# BusyBox flock accepts only -sxun. The -w timeout is util-linux only, and a
# device without it fails every credential lock on a usage error, which breaks
# login, setup, password change and SSH key management at once.
t "no shipped script depends on the util-linux flock timeout" "yes" \
  "$(! grep -rn 'flock -w' quecdeck/ update_quecdeck.sh quecdeck.sh >/dev/null 2>&1 && echo yes || echo no)"
_lock_lib=$(extract_fn quecdeck/script/lock-lib.sh flock_wait)
t "flock_wait bounds its wait without -w" "yes" \
  "$(printf '%s\n' "$_lock_lib" | grep -q 'flock -n -x' && printf '%s\n' "$_lock_lib" | grep -q '_left - 1' && printf '%s\n' "$_lock_lib" | grep -q 'sleep 1' && ! printf '%s\n' "$_lock_lib" | grep -q '\-w' && echo yes || echo no)"
for _h in check_password.sh write_htpasswd.sh change_password.sh ssh_keys.sh; do
    t "$_h takes its lock through flock_wait" "yes" \
      "$(grep -q '^\. /usrdata/quecdeck/script/lock-lib.sh ||' "quecdeck/script/$_h" && grep -q 'flock_wait 9 5 || exit 75' "quecdeck/script/$_h" && echo yes || echo no)"
done
t "lock library is installed root-only" "yes" \
  "$(sed -n '/for _s in lighttpd_prestart.sh/,/done/p' update_quecdeck.sh | grep -q 'lock-lib.sh' && grep -q '  quecdeck/script/lock-lib.sh$' .githooks/pre-commit && echo yes || echo no)"
unset _lock_lib
