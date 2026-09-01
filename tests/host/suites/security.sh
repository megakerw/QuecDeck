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
# write. Contending requests fail immediately instead of occupying CGI workers.
t "brute-force transaction requires a nonblocking per-client flock" "yes" \
  "$( _bf=$(extract_fn quecdeck/script/cgi-lib.sh bf_lock); printf '%s\n' "$_bf" | grep -q '\.lock' && printf '%s\n' "$_bf" | grep -q '! flock -n -x 9' && echo yes || echo no)"
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
_expected_sudo_rule='www-data ALL = (root) NOPASSWD: /bin/systemctl restart watchcat, /bin/systemctl reset-failed watchcat, /bin/systemctl restart scheduled_restart, /bin/systemctl reset-failed scheduled_restart, /usrdata/quecdeck/script/write_htpasswd.sh, /usrdata/quecdeck/script/change_password.sh, /usrdata/quecdeck/script/ssh_access.sh, /usrdata/quecdeck/script/check_password.sh, /usrdata/quecdeck/script/run_update.sh'
t "sudoers root surface matches the reviewed exact list" "yes" \
  "$([ "$(printf '%s\n' "$_sudo_rule" | sed 's/^[^=]*="//;s/"$//')" = "$_expected_sudo_rule" ] && echo yes || echo no)"
t "sudo helpers enforce fixed argument counts" "yes" \
  "$(grep -q '\[ "\$#" -eq 2 \]' quecdeck/script/check_password.sh && grep -q '\[ "\$#" -eq 1 \]' quecdeck/script/write_htpasswd.sh && grep -q '\[ "\$#" -eq 2 \]' quecdeck/script/ssh_access.sh && grep -q -- '--fetch).*\[ "\$#" -eq 2 \]' quecdeck/script/run_update.sh && echo yes || echo no)"
for _helper in change_password.sh ssh_access.sh; do
    t "$_helper is staged root-only" "yes" \
      "$(printf '%s\n' "$_root_helpers" | grep -q "$_helper" && echo yes || echo no)"
    t "$_helper has an explicit sudo grant" "yes" \
      "$(printf '%s\n' "$_sudo_rule" | grep -q "/usrdata/quecdeck/script/$_helper" && echo yes || echo no)"
done
t "installed SSH component helper is staged root-only" "yes" \
  "$(printf '%s\n' "$_root_helpers" | grep -q 'install_sshd.sh' && grep -q '^    _helper="\$QUECDECK_DIR/script/install_sshd.sh"$' quecdeck.sh && grep -q 'stat -c.*0 700' quecdeck.sh && echo yes || echo no)"
t "password helper verifies current password before replacement" "yes" \
  "$([ "$(grep -n 'check_password.sh "\$SELF_KIND" "\$SELF_USER"' quecdeck/script/change_password.sh | cut -d: -f1)" -lt "$(grep -n 'mv -f.*HTPASSWD' quecdeck/script/change_password.sh | head -1 | cut -d: -f1)" ] && echo yes || echo no)"
t "initial setup rejects matching administrator and developer passwords" "yes" \
  "$(grep -q '\[ "$admin_pass" = "$dev_pass" \]' quecdeck/www/cgi-bin/init_setup && grep -q 'this.devPass === this.adminPass' quecdeck/www/js/setup.js && echo yes || echo no)"
t "root console password setters reject the other credential" "yes" \
  "$(grep -q 'check_password.sh dev devadmin' quecdeck/quecdeckpasswd && grep -q 'check_password.sh admin admin' quecdeck/quecdeckdevpasswd && echo yes || echo no)"
# Each password change asks only for the credential it replaces. The two must
# still never become equal, or knowing the administrator password would clear
# the developer gate too, so the replacement is tested against the OTHER stored
# hash instead of the caller supplying that password.
_ms=quecdeck/www/cgi-bin/manage_security
_pw_payloads=$(grep -cF 'printf '"'"'%s\n%s\n'"'"' "$current" "$new" |' "$_ms")
_change_src=$(cat quecdeck/script/change_password.sh)
t "a password change asks only for the credential it replaces" "yes" \
  "$([ "$_pw_payloads" = 2 ] && printf '%s\n' "$_change_src" | grep -q 'check_password.sh "\$SELF_KIND" "\$SELF_USER"' && ! printf '%s\n' "$_change_src" | grep -q 'DEVELOPER' && echo yes || echo no)"
t "the two credentials are kept distinct at the root boundary" "yes" \
  "$( _c=$(cat quecdeck/script/change_password.sh); printf '%s\n' "$_c" | grep -q 'check_password.sh "\$OTHER_KIND" "\$OTHER_USER"' && printf '%s\n' "$_c" | grep -q '\[ "\$other_rc" != 0 \] || exit 13' && [ "$(printf '%s\n' "$_c" | grep -n 'OTHER_KIND" "\$OTHER_USER' | cut -d: -f1)" -lt "$(printf '%s\n' "$_c" | grep -n 'mv -f.*HTPASSWD' | head -1 | cut -d: -f1)" ] && echo yes || echo no)"
_both_cred=0
for _b in add_key remove_key; do
    sed -n "/^    $_b)/,/^        ;;/p" "$_ms" | grep -q 'developer_password' && _both_cred=$((_both_cred + 1))
done
t "SSH key operations still require both credentials" "2" "$_both_cred"
t "SSH key operations verify both at the root boundary" "yes" \
  "$(grep -q 'verify_credentials' quecdeck/script/ssh_access.sh && echo yes || echo no)"
unset _ms _pw_payloads _change_src _both_cred _b
t "developer unlocks are bound to the credential generation" "yes" \
  "$(grep -q '^GENERATION_FILE=/opt/etc/\.htpasswd_dev\.generation$' quecdeck/www/cgi-bin/auth_dev && grep -q 'generation_before.*generation_after' quecdeck/www/cgi-bin/auth_dev && grep -q 'dev.generation == generation' quecdeck/auth.lua && echo yes || echo no)"
t "every developer credential writer rotates the generation" "3" \
  "$(grep -l '\.htpasswd_dev\.generation' quecdeck/script/write_htpasswd.sh quecdeck/script/change_password.sh quecdeck/quecdeckdevpasswd | wc -l | tr -d ' ')"
t "root-side web password verification is serialized and paced" "yes" \
  "$(grep -q '^LIMIT_DIR=/run/quecdeck/auth-limit$' quecdeck/script/check_password.sh && grep -q '^flock_wait 9 5 || exit 75$' quecdeck/script/check_password.sh && grep -q '^sleep 1$' quecdeck/script/check_password.sh && echo yes || echo no)"
t "password pacing availability tradeoff is documented" "yes" \
  "$(grep -q 'Root-side password pacing trades availability for brute-force resistance' README.md && grep -q 'availability cost is accepted deliberately' README.md && echo yes || echo no)"
t "privileged security mutation locks have bounded waits" "4" \
  "$(grep -h '^[[:space:]]*flock_wait 9 5 || exit 75$' quecdeck/script/change_password.sh quecdeck/script/ssh_access.sh | wc -l | tr -d ' ')"
t "initial setup lock has a bounded wait" "yes" \
  "$(grep -q '^flock_wait 9 5 || exit 75$' quecdeck/script/write_htpasswd.sh && echo yes || echo no)"
t "web startup verifies the Entware credential boundary" "yes" \
  "$( _guard=$(extract_fn quecdeck/script/lighttpd_prestart.sh secure_entware_config_dir); grep -q '^PATH=.*opt/bin' quecdeck/script/lighttpd_prestart.sh && grep -q 'command -v stat' quecdeck/script/lighttpd_prestart.sh && printf '%s\n' "$_guard" | grep -q '\[ ! -L "\$_etc_dir" \]' && printf '%s\n' "$_guard" | grep -q 'stat -c %u' && printf '%s\n' "$_guard" | grep -q '& 022' && grep -q '^if ! secure_entware_config_dir; then$' quecdeck/script/lighttpd_prestart.sh && echo yes || echo no)"
t "SSH key upload trims pasted whitespace" "yes" \
  "$(grep -q 'const publicKey = this.publicKey.trim()' quecdeck/www/js/security.js && grep -q 'public_key: publicKey' quecdeck/www/js/security.js && echo yes || echo no)"
t "password policy is consistently 12 to 256 characters" "yes" \
  "$(grep -q 'minimum of 12 characters' README.md && grep -q 'between 12 and 256' README.md quecdeck/quecdeckpasswd quecdeck/quecdeckdevpasswd quecdeck/www/cgi-bin/init_setup quecdeck/www/cgi-bin/manage_security quecdeck/www/js/security.js && [ "$(grep -c 'minlength="12" maxlength="256"' quecdeck/www/setup.html)" -eq 4 ] && [ "$(grep -c 'minlength="12" maxlength="256"' quecdeck/www/security.html)" -eq 4 ] && echo yes || echo no)"
t "sudo payload parsers reject even blank extra lines" "5" \
  "$(grep -h 'IFS= read -r EXTRA && exit 1' quecdeck/script/write_htpasswd.sh quecdeck/script/change_password.sh quecdeck/script/ssh_access.sh | wc -l | tr -d ' ')"
t "password pacing applies only after failed verification" "yes" \
  "$([ "$(grep -n '^if validate_htpasswd' quecdeck/script/check_password.sh | cut -d: -f1)" -lt "$(grep -n '^sleep 1$' quecdeck/script/check_password.sh | tail -1 | cut -d: -f1)" ] && echo yes || echo no)"
t "credential callers preserve temporary-unavailable status" "yes" \
  "$(grep -q '\[ "\$password_rc" != 75 \]' quecdeck/script/change_password.sh && grep -q '\[ "\$credential_rc" != 75 \]' quecdeck/script/ssh_access.sh && grep -q '\[ "\$password_rc" = 75 \]' quecdeck/www/cgi-bin/auth_login quecdeck/www/cgi-bin/auth_dev && grep -q '\[ "\$rc" = 75 \]' quecdeck/www/cgi-bin/manage_security && grep -q '\[ "\$write_rc" = 75 \]' quecdeck/www/cgi-bin/init_setup && echo yes || echo no)"
t "CGI lockout accounting does not duplicate root-side pacing" "yes" \
  "$(! extract_fn quecdeck/script/cgi-lib.sh bf_fail | grep -q '^ *sleep ' && echo yes || echo no)"
t "password verifier accepts only fixed account pairs" "yes" \
  "$(grep -q 'admin).*USERNAME=admin' quecdeck/script/check_password.sh && grep -q 'dev).*USERNAME=devadmin' quecdeck/script/check_password.sh && grep -q '^if \[ "\${2:-}" != "\$USERNAME" \]; then$' quecdeck/script/check_password.sh && [ "$(grep -n '^flock_wait 9 5' quecdeck/script/check_password.sh | cut -d: -f1)" -lt "$(grep -n '^if \[ "\${2:-}" != "\$USERNAME" \]; then$' quecdeck/script/check_password.sh | cut -d: -f1)" ] && echo yes || echo no)"
t "dual-credential SSH checks do not short-circuit" "yes" \
  "$( _verify=$(extract_fn quecdeck/script/ssh_access.sh verify_credentials); [ "$(printf '%s\n' "$_verify" | grep -c 'check_password.sh')" = 2 ] && printf '%s\n' "$_verify" | grep -q 'admin_rc=' && printf '%s\n' "$_verify" | grep -q 'dev_rc=' && echo yes || echo no)"
t "sudo credential helpers bound stdin before parsing" "yes" \
  "$( _bounded=yes; for _h in quecdeck/script/write_htpasswd.sh quecdeck/script/change_password.sh quecdeck/script/ssh_access.sh; do grep -q 'head -c ' "$_h" && grep -Fq 'PAYLOAD=${PAYLOAD%.}' "$_h" && grep -q '\${#PAYLOAD}.*-le' "$_h" || _bounded=no; done; printf '%s' "$_bounded")"
t "initial credential helper exposes setup mode only" "yes" \
  "$(! grep -q 'admin|dev)' quecdeck/script/write_htpasswd.sh && grep -q '^    setup)' quecdeck/script/write_htpasswd.sh && echo yes || echo no)"
t "SSH helper fixes the authorized-keys destination" "yes" \
  "$(grep -q '^KEYS=\$SSH_DIR/authorized_keys$' quecdeck/script/ssh_access.sh && ! grep -qE 'KEYS=.*\$[123]' quecdeck/script/ssh_access.sh && echo yes || echo no)"
t "SSH helper rejects symlinked key storage" "yes" \
  "$(grep -q '\[ ! -L "\$SSH_DIR" \]' quecdeck/script/ssh_access.sh && grep -q '\[ ! -L "\$KEYS" \]' quecdeck/script/ssh_access.sh && echo yes || echo no)"
t "SSH helper validates keys before authorized_keys replacement" "yes" \
  "$([ "$(grep -n 'valid_key_syntax "\$KEY_LINE"' quecdeck/script/ssh_access.sh | cut -d: -f1)" -lt "$(grep -n 'mv -f.*KEYS' quecdeck/script/ssh_access.sh | head -1 | cut -d: -f1)" ] && echo yes || echo no)"
t "SSH key validation accepts an empty comment" "yes" \
  "$(eval "$(extract_fn quecdeck/script/ssh_access.sh valid_key_syntax)"; valid_key_syntax 'ssh-ed25519 AAAA' && echo yes || echo no)"
t "SSH helper normalizes existing key line endings before append" "yes" \
  "$(grep -q 'while IFS= read -r existing || \[ -n "\$existing" \]' quecdeck/script/ssh_access.sh && ! grep -q 'cat "\$KEYS"; printf.*KEY_LINE' quecdeck/script/ssh_access.sh && echo yes || echo no)"
t "SSH helper requires administrator and developer credentials" "yes" \
  "$(grep -q 'check_password.sh admin admin' quecdeck/script/ssh_access.sh && grep -q 'check_password.sh dev devadmin' quecdeck/script/ssh_access.sh && grep -q 'developer_password' quecdeck/www/cgi-bin/manage_security quecdeck/www/js/security.js && echo yes || echo no)"
t "SSH key management requires a configured developer credential" "yes" \
  "$(grep -q '\[ -s /opt/etc/\.htpasswd_dev \] || exit 8' quecdeck/script/ssh_access.sh && grep -q '8) json_result false "Set a developer access password' quecdeck/www/cgi-bin/manage_security && grep -q 'developer_configured' quecdeck/www/cgi-bin/get_security quecdeck/www/js/security.js && echo yes || echo no)"
t "missing developer credential does not count as password failure" "yes" \
  "$([ "$(grep -n '^if \[ "\$rc" = 2 \] || \[ "\$rc" = 13 \]; then$' quecdeck/www/cgi-bin/manage_security | cut -d: -f1)" -lt "$(grep -n '^if \[ "\$rc" != 0 \]; then$' quecdeck/www/cgi-bin/manage_security | cut -d: -f1)" ] && grep -q '^        8) json_result false' quecdeck/www/cgi-bin/manage_security && echo yes || echo no)"
t "SSH key status distinguishes incompatible root home permissions" "yes" \
  "$(grep -q 'safe_root_home || exit 9' quecdeck/script/ssh_access.sh && grep -q 'root_home_ready' quecdeck/www/cgi-bin/get_security quecdeck/www/js/security.js && grep -q '^        9) json_result false' quecdeck/www/cgi-bin/manage_security && echo yes || echo no)"
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
  "$( _load=$(extract_fn quecdeck/script/ssh_access.sh load_store); ! printf '%s\n' "$_load" | grep -q 'valid_key_syntax.*return 1' && printf '%s\n' "$_load" | grep -q 'fingerprint_line.*|| fp=' && echo yes || echo no)"
t "SSH key listing fingerprints each nonblank source line" "yes" \
  "$( _load=$(extract_fn quecdeck/script/ssh_access.sh load_store); printf '%s\n' "$_load" | grep -q 'fingerprint_line "\$line".*|| fp=' && ! printf '%s\n' "$_load" | grep -q 'batch_' && echo yes || echo no)"
t "SSH fingerprinting uses volatile runtime storage" "yes" \
  "$( _fingerprint=$(extract_fn quecdeck/script/ssh_access.sh fingerprint_line); printf '%s\n' "$_fingerprint" | grep -q 'mktemp "\$RUNTIME_DIR/ssh-key\.XXXXXX"' && ! printf '%s\n' "$_fingerprint" | grep -q '\$ROOT_HOME' && echo yes || echo no)"
t "adding a key activates SSH only through the firewall path" "yes" \
  "$( _add=$(sed -n '/^    add)/,/^        ;;/p' quecdeck/script/ssh_access.sh); printf '%s\n' "$_add" | grep -q 'enabled_marker_safe' && printf '%s\n' "$_add" | grep -q 'apply_network_policy 1' && ! printf '%s\n' "$_add" | grep -q 'systemctl start sshd' && echo yes || echo no)"
t "a stored key has one fail-closed activation warning" "yes" \
  "$( _add=$(sed -n '/^    add)/,/^        ;;/p' quecdeck/script/ssh_access.sh); [ "$(printf '%s\n' "$_add" | grep -c 'exit 14')" = 2 ] && [ "$(printf '%s\n' "$_add" | grep -c 'systemctl stop sshd')" = 2 ] && ! printf '%s\n' "$_add" | grep -q 'exit 15\|exit 16' && grep -q '14) action_warning=ssh_key_activation' quecdeck/www/cgi-bin/manage_security && ! grep -q 'action_warning=ssh_key_\(firewall\|start\|state\)' quecdeck/www/cgi-bin/manage_security && grep -q "data.warning === 'ssh_key_activation'" quecdeck/www/js/security.js && echo yes || echo no)"
t "SSH settings stay inside the existing privileged helper" "yes" \
  "$(grep -q '^    settings)' quecdeck/script/ssh_access.sh && grep -q 'ssh_access.sh settings' quecdeck/www/cgi-bin/manage_security && ! grep -qE 'sudo .*systemctl.*sshd|sudo .*firewall' quecdeck/www/cgi-bin/manage_security && echo yes || echo no)"
# Enable/disable and port need the ADMINISTRATOR password: a forged www-data
# session carries no credential, so this is what stops one switching an existing
# key back on. Not the developer password, which gates granting root (add and
# remove), and which this change does not do.
# Keys live in root's home, not /opt/etc/ssh, so they outlive the packages an
# uninstall removes. Left behind they are unreachable (every ssh_access.sh arm
# needs sshd installed) and go live again on reinstall, which takes no credential.
# Matched against the rm arguments one at a time, not as a substring of the
# line: a prefix match would accept a mistyped suffix as a hit.
t "uninstall removes the authorized keys" "yes" \
  "$( sed -n '/^uninstall_sshd() {/,/^}/p' quecdeck/script/install_sshd.sh | grep '^ *rm -f ' | tr ' ' '\n' | grep -qx '/usrdata/root/.ssh/authorized_keys' && echo yes || echo no)"
# It must clear the same path the daemon reads, or it clears nothing.
t "uninstall clears the path sshd_config declares" "yes" \
  "$( _p=$(grep -oE '^AuthorizedKeysFile [^ ]+' quecdeck/script/install_sshd.sh | awk '{print $2}'); [ -n "$_p" ] && sed -n '/^uninstall_sshd() {/,/^}/p' quecdeck/script/install_sshd.sh | grep '^ *rm -f ' | tr ' ' '\n' | grep -qx "$_p" && echo yes || echo no)"
unset _p
# bf_clear fires on any success. With one shared counter, an administrator
# password holder could alternate a failed add_key guess with a successful
# ssh_settings save and retry the developer password without limit.
t "credential failures are counted per class" "yes" \
  "$(grep -q 'auth_class=admin' quecdeck/www/cgi-bin/manage_security && grep -q 'auth_class=dev' quecdeck/www/cgi-bin/manage_security && grep -q 'auth_class=keys' quecdeck/www/cgi-bin/manage_security && grep -q 'security-auth-failures/\$auth_class' quecdeck/www/cgi-bin/manage_security && echo yes || echo no)"
t "key operations do not share a counter with administrator-only actions" "yes" \
  "$(_c=$(sed -n '/^case "\$action" in$/,/^esac$/p' quecdeck/www/cgi-bin/manage_security | head -8); printf '%s\n' "$_c" | grep -q 'change_password|ssh_settings) auth_class=admin' && printf '%s\n' "$_c" | grep -q 'add_key|remove_key)           auth_class=keys' && echo yes || echo no)"
# An absent listenaddress means every interface, so the gate must require a
# positive result rather than only rejecting explicit wildcards.
t "the SSH bind gate requires a listener, not just a non-wildcard one" "yes" \
  "$(_k=$(extract_fn quecdeck/script/ssh_access.sh keys_ready); printf '%s\n' "$_k" | grep -q 'listen=\$(printf' && printf '%s\n' "$_k" | grep -qF '[ -n "$listen" ] || return 1' && echo yes || echo no)"
# Policy lines are literals: the dots in the key path are regex wildcards without -F.
t "SSH policy lines are compared literally" "yes" \
  "$(grep -q 'grep -Fqx' quecdeck/script/sshd-policy-lib.sh && ! grep -qE 'grep -qx ' quecdeck/script/sshd-policy-lib.sh && echo yes || echo no)"
t "the credential helper header matches what it reads" "yes" \
  "$(! grep -q 'Both modes read the current administrator password' quecdeck/script/change_password.sh && grep -q 'Reads only the current value of the credential being changed' quecdeck/script/change_password.sh && echo yes || echo no)"
unset _c _k
t "SSH settings require the administrator password" "yes" \
  "$( _settings=$(sed -n '/^    settings)/,/^        ;;/p' quecdeck/script/ssh_access.sh); printf '%s\n' "$_settings" | grep -q 'verify_admin_credential' && printf '%s\n' "$_settings" | grep -q 'ADMIN_PASSWORD' && echo yes || echo no)"
t "SSH settings do not ask for the developer password" "yes" \
  "$( _settings=$(sed -n '/^    settings)/,/^        ;;/p' quecdeck/script/ssh_access.sh); ! printf '%s\n' "$_settings" | grep -q 'verify_credentials' && ! sed -n '/^    ssh_settings)/,/;;/p' quecdeck/www/cgi-bin/manage_security | grep -q 'developer_password' && grep -q 'developerRequired: false' quecdeck/www/js/security.js && echo yes || echo no)"
# Anchored on the privileged call, not on a case statement: the classification
# block above the dispatch is also a "case $action in".
t "every security action requires a current password" "yes" \
  "$(! grep -q 'ssh_settings) ;;' quecdeck/www/cgi-bin/manage_security && [ "$(grep -n 'Current password is required' quecdeck/www/cgi-bin/manage_security | cut -d: -f1)" -lt "$(grep -n '/opt/bin/sudo' quecdeck/www/cgi-bin/manage_security | head -1 | cut -d: -f1)" ] && echo yes || echo no)"
# The unused password field must leave the DOM, not just hide: that is what the
# browser otherwise pairs with unrelated inputs and offers to save.
t "the credential dialog removes the unused developer field" "yes" \
  "$(grep -q 'x-if="credentialDeveloperRequired"' quecdeck/www/ssh.html && echo yes || echo no)"
t "the key gate still requires both credentials" "2" \
  "$( _n=0; for _a in add remove; do sed -n "/^    $_a)/,/^        ;;/p" quecdeck/script/ssh_access.sh | grep -q verify_credentials && _n=$((_n + 1)); done; echo "$_n")"
t "SSH settings accept only a Boolean and the reviewed port range" "yes" \
  "$( _settings=$(sed -n '/^    settings)/,/^        ;;/p' quecdeck/script/ssh_access.sh); _ports=$(extract_fn quecdeck/script/sshd-policy-lib.sh valid_ssh_port); printf '%s\n' "$_settings" | grep -q 'case "\$SSH_ENABLED" in 0|1)' && printf '%s\n' "$_settings" | grep -q 'valid_ssh_port "\$SSH_PORT"' && printf '%s\n' "$_ports" | grep -q '\$1.*= 22' && printf '%s\n' "$_ports" | grep -q '\$1.*-ge 1024' && echo yes || echo no)"
# The settings functions can run against temporary files with their privileged
# dependencies replaced by recording stubs. These cases assert outcomes rather
# than the spelling or internal layout of the implementation.
_ssh_settings_fixture() { # _ssh_settings_fixture <same|invalid|changed>
    (
        eval "$(extract_fn quecdeck/script/sshd-policy-lib.sh valid_ssh_port)"
        eval "$(extract_fn quecdeck/script/ssh_access.sh configured_port)"
        eval "$(extract_fn quecdeck/script/ssh_access.sh apply_settings)"
        _dir=$(mktemp -d)
        SSHD_CONFIG=$_dir/sshd_config
        ENABLED_MARKER=$_dir/enabled
        _calls=$_dir/calls
        printf 'Port 22\nPasswordAuthentication no\n' > "$SSHD_CONFIG"
        chown() {
            return 0
        }
        chmod() {
            return 0
        }
        enabled_marker_safe() {
            [ -f "$ENABLED_MARKER" ] && grep -qx enabled "$ENABLED_MARKER"
        }
        systemctl() {
            printf 'systemctl %s\n' "$*" >> "$_calls"
            return 0
        }
        apply_network_policy() {
            printf 'policy %s\n' "$1" >> "$_calls"
            return 0
        }
        case "$1" in
            same)
                _before=$(sha256sum "$SSHD_CONFIG" | awk '{print $1}')
                apply_settings 0 22
                _rc=$?
                _after=$(sha256sum "$SSHD_CONFIG" | awk '{print $1}')
                printf '%s:%s:%s' "$_rc" "$([ "$_before" = "$_after" ] && echo unchanged || echo changed)" "$(tr '\n' ',' < "$_calls")"
                ;;
            invalid)
                validate_sshd_config() {
                    return 1
                }
                _before=$(sha256sum "$SSHD_CONFIG" | awk '{print $1}')
                apply_settings 1 2222
                _rc=$?
                _after=$(sha256sum "$SSHD_CONFIG" | awk '{print $1}')
                _temps=$(find "$_dir" -name 'sshd_config.tmp.*' | wc -l | tr -d ' ')
                printf '%s:%s:%s:%s' "$_rc" "$([ "$_before" = "$_after" ] && echo preserved || echo replaced)" "$_temps" "$([ -s "$_calls" ] && echo called || echo quiet)"
                ;;
            changed)
                validate_sshd_config() {
                    grep -qx 'Port 2222' "$1"
                }
                apply_settings 1 2222
                _rc=$?
                printf '%s:%s:%s:%s' "$_rc" "$(sed -n 's/^Port //p' "$SSHD_CONFIG")" "$(cat "$ENABLED_MARKER")" "$(tr '\n' ',' < "$_calls")"
                ;;
        esac
        rm -rf "$_dir"
    )
}
t "unchanged SSH settings preserve persistent files and reconcile policy" \
  "0:unchanged:policy 0," "$(_ssh_settings_fixture same)"
t "invalid SSH configuration leaves persistent state untouched" \
  "1:preserved:0:quiet" "$(_ssh_settings_fixture invalid)"
t "valid SSH settings commit the port and enabled state before policy" \
  "0:2222:enabled:systemctl stop sshd,policy 1," "$(_ssh_settings_fixture changed)"

# The firewall command is an absolute device path and cannot be executed by the
# host fixture. Keep one narrow ordering pin for this fail-closed boundary.
t "SSH starts only after the firewall accepts the new port" "yes" \
  "$( _act=$(extract_fn quecdeck/script/ssh_access.sh apply_network_policy); _sync=$(extract_fn quecdeck/script/ssh_access.sh sync_daemon); _fw=$(printf '%s\n' "$_act" | grep -n 'firewall.sh' | head -1 | cut -d: -f1); _next=$(printf '%s\n' "$_act" | grep -n 'sync_daemon' | head -1 | cut -d: -f1); [ -n "$_fw" ] && [ -n "$_next" ] && [ "$_fw" -lt "$_next" ] && printf '%s\n' "$_sync" | grep -q 'systemctl start sshd' && ! printf '%s\n' "$_act" | grep -q 'systemctl restart firewall' && echo yes || echo no)"
_ssh_sync_fixture() { # _ssh_sync_fixture <enabled> <ready> <active>
    (
        eval "$(extract_fn quecdeck/script/ssh_access.sh sync_daemon)"
        _calls=$(mktemp)
        _ready=$2
        _active=$3
        keys_ready() {
            [ "$_ready" = 1 ]
        }
        systemctl() {
            if [ "$1 $2 ${3:-}" = "is-active --quiet sshd" ]; then
                [ "$_active" = 1 ]
                return
            fi
            printf '%s\n' "$*" >> "$_calls"
            return 0
        }
        sync_daemon "$1"
        _rc=$?
        printf '%s:%s' "$_rc" "$(tr '\n' ',' < "$_calls")"
        rm -f "$_calls"
    )
}
t "disabled SSH is stopped" "0:stop sshd," "$(_ssh_sync_fixture 0 1 1)"
t "SSH readiness failure stops the daemon" "0:stop sshd," "$(_ssh_sync_fixture 1 0 1)"
t "ready inactive SSH is reset and started" \
  "0:reset-failed sshd,start sshd," "$(_ssh_sync_fixture 1 1 0)"
unset -f _ssh_settings_fixture _ssh_sync_fixture
t "SSH enable marker is fixed, root-only, and shared with the unit" "yes" \
  "$(grep -q '^ENABLED_MARKER=/opt/etc/ssh/quecdeck_enabled$' quecdeck/script/ssh_access.sh && grep -q 'chmod 600 "\$ENABLED_MARKER"' quecdeck/script/ssh_access.sh && grep -q '^ConditionPathExists=/opt/etc/ssh/quecdeck_enabled$' quecdeck/optional/sshd/sshd.service && echo yes || echo no)"
t "SSH settings API and UI expose enabled state and port" "yes" \
  "$(grep -q 'ssh_enabled' quecdeck/www/cgi-bin/get_security quecdeck/www/js/security.js && grep -q 'ssh_port' quecdeck/www/cgi-bin/get_security quecdeck/www/cgi-bin/manage_security quecdeck/www/js/security.js && grep -q 'form-check form-switch' quecdeck/www/ssh.html && echo yes || echo no)"
t "SSH page reports the installed server version" "yes" \
  "$(grep -q '/opt/sbin/sshd -V' quecdeck/www/cgi-bin/get_security && grep -q 'ssh_version' quecdeck/www/cgi-bin/get_security quecdeck/www/js/security.js && grep -q 'sshVersion' quecdeck/www/ssh.html && echo yes || echo no)"
# The server settings and the key store are separate panels with separate
# credential inputs. ssh_access.sh consults neither the port nor the enable marker
# when adding a key, so an unsaved edit in one panel must not disable the other.
# sshSettingsChanged now only gates its own Save button.
t "SSH panels do not gate each other" "yes" \
  "$(! grep -q 'Save the SSH settings before managing public keys' quecdeck/www/js/security.js && ! grep -q 'sshSettingsChanged' <(sed -n '/Authorized Keys/,$p' quecdeck/www/ssh.html) && grep -q 'sshSettingsChanged' quecdeck/www/js/security.js && echo yes || echo no)"
# Credentials are collected by one conditional dialog rather than fields parked
# on either card.
t "the SSH cards park no credentials" "yes" \
  "$(! grep -q 'settingsPassword\|keyPassword\|keyDeveloperPassword' quecdeck/www/ssh.html quecdeck/www/js/security.js && grep -q '<template x-if="credentialOpen">' quecdeck/www/ssh.html && echo yes || echo no)"
t "both key actions prompt for both credentials" "2" \
  "$( _n=0; for _m in addKey confirmRemove; do sed -n "/^    $_m(/,/^    },/p" quecdeck/www/js/security.js | grep -q 'promptCredentials' && _n=$((_n + 1)); done; echo "$_n")"
# The dialog owns the attempt: a wrong password must not close it and stack an
# error modal, and a lockout must stop offering a retry that cannot succeed.
t "credential dialog survives a failed attempt" "yes" \
  "$( _s=$(sed -n '/^    submitCredentials() {/,/^    },/p' quecdeck/www/js/security.js); printf '%s\n' "$_s" | grep -q 'credentialError = err.message' && printf '%s\n' "$_s" | grep -q 'credentialLocked = err.locked === true' && printf '%s\n' "$_s" | grep -q 'credentialBusy || this.credentialLocked' && echo yes || echo no)"
t "credential dialog zeroes both fields when it closes" "yes" \
  "$( _c=$(sed -n '/^    closeCredentials() {/,/^    },/p' quecdeck/www/js/security.js); printf '%s\n' "$_c" | grep -q "credentialAdmin = ''" && printf '%s\n' "$_c" | grep -q "credentialDeveloper = ''" && echo yes || echo no)"
t "SSH page presents server and keys as separate panels" "2" \
  "$(grep -c 'class="panel-section"' quecdeck/www/ssh.html)"
t "password-change reports success with an invalidation warning" "yes" \
  "$(grep -q 'session_invalidation_failed=1' quecdeck/www/cgi-bin/manage_security && grep -q '"ok":true,"warning":"session_invalidation"' quecdeck/www/cgi-bin/manage_security && grep -q 'session_warning=1' quecdeck/www/js/security.js quecdeck/www/js/login.js && echo yes || echo no)"
t "hidden unsupported SSH entries do not consume the UI key limit" "yes" \
  "$(grep -q '\[ "\$KEY_USABLE_COUNT" -lt "\$MAX_KEYS" \]' quecdeck/script/ssh_access.sh && echo yes || echo no)"
t "SSH readiness enforces effective key-only policy" "yes" \
  "$(grep -q 'sshd -T' quecdeck/script/ssh_access.sh && grep -q "authenticationmethods publickey" quecdeck/script/sshd-policy-lib.sh && grep -q "passwordauthentication no" quecdeck/script/sshd-policy-lib.sh && ! grep -q 'usepam' quecdeck/script/ssh_access.sh quecdeck/script/sshd-policy-lib.sh && echo yes || echo no)"
t "SSH stops when the final key is removed" "yes" \
  "$(grep -q 'KEY_COUNT.*= 0' quecdeck/script/ssh_access.sh && grep -q 'systemctl stop sshd' quecdeck/script/ssh_access.sh && echo yes || echo no)"
t "explicit SSH stops terminate sessions" "yes" \
  "$(grep -q '^KillMode=control-group$' quecdeck/optional/sshd/sshd.service && grep -q '^TimeoutStopSec=10$' quecdeck/optional/sshd/sshd.service && grep -q 'systemctl restart sshd' quecdeck/script/ssh_access.sh && echo yes || echo no)"
t "full uninstall removes SSH before firewall" "yes" \
  "$(_uninstall=$(sed -n '/^uninstall_quecdeck_components() {/,/^}/p' quecdeck.sh); _ssh_stop=$(printf '%s\n' "$_uninstall" | grep -n 'systemctl stop sshd' | head -1 | cut -d: -f1); _fw_remove=$(printf '%s\n' "$_uninstall" | grep -n '# Uninstall firewall' | cut -d: -f1); [ -n "$_ssh_stop" ] && [ -n "$_fw_remove" ] && [ "$_ssh_stop" -lt "$_fw_remove" ] && echo yes || echo no)"
_security_lock=$(grep -n 'bf_lock "\$FAILURE_DIR"' quecdeck/www/cgi-bin/manage_security | cut -d: -f1)
_security_sudo=$(grep -n '/opt/bin/sudo' quecdeck/www/cgi-bin/manage_security | head -1 | cut -d: -f1)
t "security mutations lock authentication before sudo" "yes" \
  "$([ -n "$_security_lock" ] && [ -n "$_security_sudo" ] && [ "$_security_lock" -lt "$_security_sudo" ] && echo yes || echo no)"
# Exit 13 confirms the replacement equals the other stored credential, which is
# a guess about that secret. Counting only exit 2 left it testable for free.
t "a matching-credential rejection counts toward the lockout" "yes" \
  "$(grep -q '\[ "\$rc" = 2 \] || \[ "\$rc" = 13 \]' quecdeck/www/cgi-bin/manage_security && echo yes || echo no)"
t "exit 13 is not also answered without counting" "yes" \
  "$(! sed -n '/^if \[ "\$rc" != 0 \]; then/,/^fi$/p' quecdeck/www/cgi-bin/manage_security | grep -qE '^ *13\)' && echo yes || echo no)"
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
_sweep_classify() { # _sweep_classify <libdir> <shippeddir> <optionaldir> -> "keep|orphan|foreign <name>" per line
    for _f in "$1"/*.service; do
        [ -f "$_f" ] || continue
        _n=$(basename "$_f")
        if ! grep -qE '^Exec(Start|StartPre|StartPost|Reload|Stop|StopPost)=.*/usrdata/quecdeck(/|[[:space:]]|$)' "$_f" 2>/dev/null; then
            echo "foreign $_n"
        elif [ -f "$2/$_n" ] || [ -f "$3/$_n" ]; then
            echo "keep $_n"
        else
            echo "orphan $_n"
        fi
    done
}
_swp=$(mktemp -d); mkdir -p "$_swp/lib" "$_swp/shipped" "$_swp/optional"
printf '[Service]\nExecStart=/usrdata/quecdeck/script/firewall.sh\n' > "$_swp/lib/firewall.service"
: > "$_swp/shipped/firewall.service"
printf '[Service]\nExecStart=/usrdata/quecdeck/script/gone.sh\n'     > "$_swp/lib/dropped.service"
printf '[Service]\nExecStart=/usr/sbin/sshd\n'                       > "$_swp/lib/sshd.service"
printf '[Service]\nExecStart=/usrdata/quecdeck/script/ssh_access.sh ready\n' > "$_swp/lib/optional.service"
: > "$_swp/optional/optional.service"
printf '[Service]\nExecStart=/vendor/bin/pcie\n'                     > "$_swp/lib/pcie.service"
printf '# old path in a comment only: /usrdata/quecdeck/gone\n[Service]\nExecStart=/vendor/bin/commented\n' > "$_swp/lib/commented.service"
_cls=$(_sweep_classify "$_swp/lib" "$_swp/shipped" "$_swp/optional")
t "sweep keeps a shipped unit"        "keep firewall.service"  "$(printf '%s\n' "$_cls" | grep ' firewall.service$')"
t "sweep keeps an optional shipped unit" "keep optional.service" "$(printf '%s\n' "$_cls" | grep ' optional.service$')"
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
for _h in check_password.sh write_htpasswd.sh change_password.sh ssh_access.sh; do
    t "$_h takes its lock through flock_wait" "yes" \
      "$(grep -q '^\. /usrdata/quecdeck/script/lock-lib.sh ||' "quecdeck/script/$_h" && grep -q 'flock_wait 9 5 || exit 75' "quecdeck/script/$_h" && echo yes || echo no)"
done
t "lock library is installed root-only" "yes" \
  "$(sed -n '/for _s in lighttpd_prestart.sh/,/done/p' update_quecdeck.sh | grep -q 'lock-lib.sh' && grep -q '  quecdeck/script/lock-lib.sh$' .githooks/pre-commit && echo yes || echo no)"
unset _lock_lib

# The SSH posture is asserted in two places: at install and on every daemon
# start. A three-site edit to the permitrootlogin spelling once passed the whole
# suite, so pin the list to one definition and require the installer to cover it.
_policy=$(sed -n '/^SSHD_POLICY="/,/"$/p' quecdeck/script/sshd-policy-lib.sh | sed '1s/^SSHD_POLICY="//; $s/"$//')
t "runtime SSH policy list is populated" "yes" \
  "$([ "$(printf '%s\n' "$_policy" | grep -c .)" -ge 10 ] && echo yes || echo no)"
t "both runtime checkers share one policy list" "yes" \
  "$( _k=$(extract_fn quecdeck/script/ssh_access.sh keys_ready); _v=$(extract_fn quecdeck/script/ssh_access.sh validate_sshd_config); printf '%s\n' "$_k" | grep -q 'sshd_policy_ok' && printf '%s\n' "$_v" | grep -q 'sshd_policy_ok' && ! printf '%s\n' "$_k$_v" | grep -q "grep -qx 'passwordauthentication" && echo yes || echo no)"
# The installer and the runtime check now share one definition rather than
# keeping two lists in step, so assert neither restates it locally.
t "installer and runtime share one policy definition" "yes" \
  "$(grep -q '^\. \$QUECDECK_DIR/script/sshd-policy-lib\.sh' quecdeck/script/install_sshd.sh && grep -q 'sshd_policy_ok "\$effective"' quecdeck/script/install_sshd.sh && ! grep -q "grep -qx 'passwordauthentication" quecdeck/script/install_sshd.sh && ! grep -q '^SSHD_POLICY=' quecdeck/script/ssh_access.sh quecdeck/script/install_sshd.sh && echo yes || echo no)"
# keys_ready needs only "is any key usable", and ssh-keygen skips lines it
# cannot parse while still exiting 0 (device-verified). Going through load_store
# would make one malformed imported line cost 23ms per key on every sshd start.
t "SSH readiness avoids the per-key fingerprint fallback" "yes" \
  "$( _k=$(extract_fn quecdeck/script/ssh_access.sh keys_ready); printf '%s\n' "$_k" | grep -q 'has_usable_key' && ! printf '%s\n' "$_k" | grep -q 'load_store' && grep -q 'ssh-keygen -lf "\$KEYS"' quecdeck/script/sshd-policy-lib.sh quecdeck/script/ssh_access.sh && echo yes || echo no)"
# The publisher runs from the checksummed release tree, not an unverified copy.
t "bind publisher runs from the verified release tree" "yes" \
  "$(grep -qx 'ExecStartPre=/bin/sh /usrdata/quecdeck/optional/sshd/update_sshd_ip.sh' quecdeck/optional/sshd/sshd.service && ! grep -q 'cp -f "\$ASSET_DIR/update_sshd_ip.sh"' quecdeck/script/install_sshd.sh && echo yes || echo no)"
t "SSH unit is a boot-safe regular copy" "yes" \
  "$( _u=$(extract_fn quecdeck/script/install_sshd.sh install_sshd_unit); printf '%s\n' "$_u" | grep -q 'cp -f "\$ASSET_DIR/sshd.service" /lib/systemd/system/sshd.service' && printf '%s\n' "$_u" | grep -q 'chmod 644' && ! printf '%s\n' "$_u" | grep -q 'ln -sf "\$ASSET_DIR/sshd.service"' && echo yes || echo no)"
t "updater refreshes and rolls back the managed SSH unit" "yes" \
  "$( _u=$(extract_fn update_quecdeck.sh refresh_managed_sshd_unit); printf '%s\n' "$_u" | grep -q 'Include /run/quecdeck/sshd-listen.conf' && printf '%s\n' "$_u" | grep -q 'optional/sshd/sshd.service' && printf '%s\n' "$_u" | grep -q 'chmod 644' && [ "$(grep -c 'refresh_managed_sshd_unit "\$QUECDECK_DIR"' update_quecdeck.sh)" -eq 2 ] && echo yes || echo no)"
for _d in 'AllowTcpForwarding no' 'AllowAgentForwarding no' 'AllowStreamLocalForwarding no' \
          'GatewayPorts no' 'PermitTunnel no' 'X11Forwarding no'; do
    t "shipped sshd_config sets $_d" "yes" \
      "$(grep -qx "$_d" quecdeck/script/install_sshd.sh && echo yes || echo no)"
done
t "developer generation token is not world readable" "yes" \
  "$(! grep -rn 'chmod 644.*generation\|generation.*chmod 644' quecdeck/ >/dev/null 2>&1 && grep -q 'chmod 640 "\$GENERATION_TMP"' quecdeck/script/change_password.sh && grep -q 'chmod 640 "\$tmp"' quecdeck/script/write_htpasswd.sh && grep -q 'chmod 640 "\$generation_tmp"' quecdeck/quecdeckdevpasswd && echo yes || echo no)"
unset _policy _policy_missing _line _d _k _v

# The bind address is the one thing that used to be edited into sshd_config on
# every boot. It now lives in a tmpfs Include, so the configuration file stays
# byte-identical to what the installer verified and no boot write reaches flash.
t "sshd_config includes the bind fragment by literal path" "yes" \
  "$(grep -qx 'Include /run/quecdeck/sshd-listen.conf' quecdeck/script/install_sshd.sh && ! grep -q 'Include .*\*' quecdeck/script/install_sshd.sh && ! grep -q '^ListenAddress' quecdeck/script/install_sshd.sh && echo yes || echo no)"
t "bind publisher writes only to the runtime tree" "yes" \
  "$(grep -q 'LISTEN_CONF="\$RUNTIME_DIR/sshd-listen.conf"' quecdeck/optional/sshd/update_sshd_ip.sh && grep -q 'mv -f "\$_tmp" "\$LISTEN_CONF"' quecdeck/optional/sshd/update_sshd_ip.sh && ! grep -q '^SSHD_CONF=' quecdeck/optional/sshd/update_sshd_ip.sh && ! grep -qE '^[[:space:]]*sed -i' quecdeck/optional/sshd/update_sshd_ip.sh && echo yes || echo no)"
t "bind publisher rejects a symlinked runtime target" "yes" \
  "$(grep -q '\[ ! -L "\$RUNTIME_DIR" \]' quecdeck/optional/sshd/update_sshd_ip.sh && grep -q '\[ ! -L "\$LISTEN_CONF" \]' quecdeck/optional/sshd/update_sshd_ip.sh && echo yes || echo no)"
t "installer publishes the bind fragment before validating" "yes" \
  "$( _i=$(sed -n '/^install_sshd() {/,/^}/p' quecdeck/script/install_sshd.sh); _pub=$(printf '%s\n' "$_i" | grep -n 'update_sshd_ip.sh' | head -1 | cut -d: -f1); _cfg=$(printf '%s\n' "$_i" | grep -n 'configure_key_only_ssh ' | cut -d: -f1); [ -n "$_pub" ] && [ -n "$_cfg" ] && [ "$_pub" -lt "$_cfg" ] && echo yes || echo no)"
t "unit publishes the bind fragment before every config read" "yes" \
  "$( _u=quecdeck/optional/sshd/sshd.service; _pub=$(grep -n '^ExecStartPre=.*update_sshd_ip.sh' "$_u" | cut -d: -f1); _ready=$(grep -n 'ssh_access.sh ready' "$_u" | cut -d: -f1); _t=$(grep -n 'sshd -t$' "$_u" | cut -d: -f1); [ "$_pub" -lt "$_ready" ] && [ "$_ready" -lt "$_t" ] && echo yes || echo no)"
unset _i _pub _cfg _u _ready _t

# lighttpd.conf is checksummed, so the old in-place sed moved the installed copy
# away from its manifest hash on the first boot after every install. The bind
# address now comes from a tmpfs fragment and the file is never rewritten.
t "lighttpd binds through the published fragment" "yes" \
  "$(grep -qx 'include "/run/quecdeck/lighttpd-listen.conf"' quecdeck/lighttpd.conf && grep -qx 'server.bind = var.lan_ip' quecdeck/lighttpd.conf && grep -q 'var.lan_ip + ":443"' quecdeck/lighttpd.conf && echo yes || echo no)"
# lighttpd variables are write-once: assigning a default here and letting the
# fragment override it is a "Duplicate config variable" parse error. The
# fragment must be the only definition. Device-verified that this fails closed:
# with the fragment absent the parse aborts with "include file not found"
# (rc=255), so the server can never fall back to binding every interface.
t "lighttpd declares no bind default of its own" "yes" \
  "$(! grep -qE '^var\.lan_ip *=' quecdeck/lighttpd.conf && ! grep -qE '^(server\.bind = "[0-9.]+"|\$SERVER\["socket"\] == "[0-9.]+:443")' quecdeck/lighttpd.conf && echo yes || echo no)"
t "lighttpd prestart publishes instead of editing its config" "yes" \
  "$( _p=quecdeck/script/lighttpd_prestart.sh; grep -q 'mv -f "\$_tmp" "\$LISTEN_CONF"' "$_p" && ! grep -q 'sed -i "s/server' "$_p" && echo yes || echo no)"
# One parser for the address every publisher binds or protects.
t "boot publishers share one LAN address parser" "3" \
  "$(grep -lc '^\. /usrdata/quecdeck/script/lan-ip-lib.sh' quecdeck/script/lighttpd_prestart.sh quecdeck/script/firewall.sh quecdeck/optional/sshd/update_sshd_ip.sh 2>/dev/null | wc -l | tr -d ' ')"
t "only the shared library and cgi-lib parse the modem config" "yes" \
  "$([ "$(grep -rl 'APIPAddr' quecdeck/script/*.sh quecdeck/optional/sshd/*.sh | sort | tr '\n' ' ')" = "quecdeck/script/cgi-lib.sh quecdeck/script/lan-ip-lib.sh " ] && echo yes || echo no)"
t "shared parser always yields an address" "yes" \
  "$( _r=$(extract_fn quecdeck/script/lan-ip-lib.sh resolve_lan_ip); printf '%s\n' "$_r" | grep -q 'LAN_IP=\$QUECDECK_DEFAULT_LAN_IP' && printf '%s\n' "$_r" | grep -q 'grep -qE' && echo yes || echo no)"

# Run the real parser against crafted configs. 0.0.0.0 passes a naive range
# check and binds every interface, so the rejections are asserted by outcome
# rather than by pattern. The addresses that must SURVIVE matter just as much:
# substituting the default for a live LAN address binds one the modem lacks.
_ip_case() { # _ip_case <APIPAddr value>
    local _dir _out
    _dir=$(mktemp -d) || return 1
    printf '<cfg><APIPAddr>%s</APIPAddr></cfg>\n' "$1" > "$_dir/mobileap_cfg.xml"
    _out=$(
        . quecdeck/script/lan-ip-lib.sh
        QUECDECK_MOBILEAP_CFG="$_dir/mobileap_cfg.xml"
        resolve_lan_ip
        printf '%s' "$LAN_IP"
    )
    rm -rf "$_dir"
    printf '%s' "$_out"
}
t "wildcard LAN address is refused" "192.168.225.1" "$(_ip_case 0.0.0.0)"
t "loopback LAN address is refused" "192.168.225.1" "$(_ip_case 127.0.0.1)"
t "multicast LAN address is refused" "192.168.225.1" "$(_ip_case 239.1.1.1)"
t "reserved LAN address is refused" "192.168.225.1" "$(_ip_case 255.255.255.255)"
t "out-of-range octet is refused" "192.168.225.1" "$(_ip_case 192.168.999.1)"
t "the configured default survives" "192.168.225.1" "$(_ip_case 192.168.225.1)"
t "an alternate private range survives" "10.20.30.1" "$(_ip_case 10.20.30.1)"
t "the upper private range survives" "172.31.5.1" "$(_ip_case 172.31.5.1)"
unset _p _r
unset -f _ip_case

# The key limit is stated in the helper, the CGI's message, the page and the
# controller. Changing it once meant touching all four, so assert they agree.
_max=$(sed -n 's/^MAX_KEYS=\([0-9]*\)$/\1/p' quecdeck/script/ssh_access.sh)
t "key limit is defined" "yes" "$([ -n "$_max" ] && echo yes || echo no)"
t "every stated key limit matches the helper" "yes" \
  "$(grep -q "The maximum of $_max SSH keys" quecdeck/www/cgi-bin/manage_security &&
     grep -q "keys.length >= $_max" quecdeck/www/ssh.html &&
     grep -q "this.keys.length >= $_max" quecdeck/www/js/security.js &&
     grep -q "maximum of $_max SSH keys" quecdeck/www/js/security.js &&
     grep -q "up to $_max root public keys" README.md &&
     echo yes || echo no)"
unset _max

# A tmpfs Include fragment is what keeps sshd on the LAN. sshd accepts a missing
# Include and then reports NO ListenAddress, which binds every interface, and
# sshd -t accepts that too. Device-verified: a missing fragment yields
# "listenaddress 0.0.0.0:<port>" and "[::]:<port>".
t "sshd start gate rejects a wildcard bind" "yes" \
  "$(extract_fn quecdeck/script/ssh_access.sh keys_ready | grep -qiE 'listenaddress \(0\\.0\\.0\\.0' && echo yes || echo no)"
# ExecReload does not run ExecStartPre, so a reload with the fragment gone would
# re-exec sshd onto every interface. Republish before signalling.
t "sshd reload republishes the bind fragment first" "yes" \
  "$(_r=$(grep -n '^ExecReload=' quecdeck/optional/sshd/sshd.service | head -1); _k=$(grep -n '^ExecReload=/bin/kill' quecdeck/optional/sshd/sshd.service); printf '%s' "$_r" | grep -q 'update_sshd_ip.sh' && [ "${_r%%:*}" -lt "${_k%%:*}" ] && echo yes || echo no)"
# If the two sides of this path ever disagree, sshd finds no Include, reports no
# ListenAddress, and binds every interface. Nothing else would fail first.
t "sshd Include path matches what the publisher writes" "yes" \
  "$(_d=$(sed -n 's/^RUNTIME_DIR=//p' quecdeck/optional/sshd/update_sshd_ip.sh); _b=$(sed -n 's#^LISTEN_CONF="\$RUNTIME_DIR/\(.*\)"$#\1#p' quecdeck/optional/sshd/update_sshd_ip.sh); [ -n "$_d" ] && [ -n "$_b" ] && grep -qxF "Include $_d/$_b" quecdeck/script/install_sshd.sh && echo yes || echo no)"
unset _d _b
