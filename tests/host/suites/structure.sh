# Repository structure host tests.
# Sourced by tests/host/run-tests.sh.

# ---------------------------------------------------- monitoring page split --
t "Watchcat and Scheduled Restart have separate pages" "yes" \
  "$([ -f quecdeck/www/watchcat.html ] && [ -f quecdeck/www/scheduled-restart.html ] && [ ! -e quecdeck/www/monitoring.html ] && echo yes || echo no)"
t "monitoring pages load only their own controllers" "yes" \
  "$(grep -q 'x-data="quecdeckWatchCat()"' quecdeck/www/watchcat.html && grep -q 'js/watchcat.js' quecdeck/www/watchcat.html && ! grep -q 'Scheduled Restart\|scheduled-restart' quecdeck/www/watchcat.html && grep -q 'x-data="quecdeckScheduledRestart()"' quecdeck/www/scheduled-restart.html && grep -q 'js/scheduled-restart.js' quecdeck/www/scheduled-restart.html && ! grep -q 'Watchcat\|watchcat' quecdeck/www/scheduled-restart.html && echo yes || echo no)"
t "monitoring controllers call only their own endpoints" "yes" \
  "$(! grep -q 'scheduled_restart' quecdeck/www/js/watchcat.js && ! grep -q 'watchcat' quecdeck/www/js/scheduled-restart.js && grep -q 'get_watchcat_status' quecdeck/www/js/watchcat.js && grep -q 'get_scheduled_restart' quecdeck/www/js/scheduled-restart.js && echo yes || echo no)"
t "navigation exposes both monitoring pages" "yes" \
  "$(grep -q "href: '/watchcat.html', label: 'Watchcat'" quecdeck/www/js/nav.js && grep -q "href: '/scheduled-restart.html', label: 'Scheduled Restart'" quecdeck/www/js/nav.js && grep -q 'href="/watchcat.html"' quecdeck/www/deviceinfo.html && grep -q 'href="/scheduled-restart.html"' quecdeck/www/deviceinfo.html && ! grep -q '/monitoring.html' quecdeck/www/js/nav.js quecdeck/www/deviceinfo.html && echo yes || echo no)"

t "Security and SSH pages are wired to their controller and navigation" "yes" \
  "$(grep -q 'x-data="securitySettings()"' quecdeck/www/security.html && grep -q 'x-data="securitySettings(true)"' quecdeck/www/ssh.html && grep -q 'js/security.js' quecdeck/www/security.html quecdeck/www/ssh.html && grep -q "href: '/security.html', label: 'Security'" quecdeck/www/js/nav.js && grep -q "href: '/ssh.html', label: 'SSH'" quecdeck/www/js/nav.js && grep -q 'href="/ssh.html"' quecdeck/www/deviceinfo.html && echo yes || echo no)"
t "SSH page supports public-key upload and multiple key rows" "yes" \
  "$(grep -q 'type="file".*accept=".pub,text/plain"' quecdeck/www/ssh.html && grep -q 'x-for="key in keys"' quecdeck/www/ssh.html && grep -q 'keys.length >= 5' quecdeck/www/ssh.html && echo yes || echo no)"
t "Password change returns to a clear login state" "yes" \
  "$(grep -q 'password_changed=1' quecdeck/www/js/security.js && grep -q 'passwordChanged' quecdeck/www/js/login.js quecdeck/www/login.html && echo yes || echo no)"

# ------------------------------------------ root-home migration lifecycle ---
# The legacy root bin was world-writable. These ordering assertions prevent a
# future cleanup from putting it back in the updater's command search path or
# running the destructive migration before a verified release and rollback
# snapshot exist.
t "installer PATH excludes legacy root bin" "yes" \
  "$(grep '^export PATH=' quecdeck.sh | grep -qv '/usrdata/root/bin' && echo yes || echo no)"
t "updater PATH excludes legacy root bin" "yes" \
  "$(grep '^export PATH=' update_quecdeck.sh | grep -qv '/usrdata/root/bin' && echo yes || echo no)"
_harden_line=$(grep -n '^[[:space:]]*harden_root_home ||' update_quecdeck.sh | cut -d: -f1)
_commit_line=$(grep -n '^[[:space:]]*_swap_committed=1$' update_quecdeck.sh | tail -1 | cut -d: -f1)
_helper_line=$(grep -n 'ln -sf "\$QUECDECK_DIR/atcli" /usrdata/root/bin/atcli' update_quecdeck.sh | head -1 | cut -d: -f1)
t "root home hardens after rollback becomes possible" "yes" \
  "$([ -n "$_harden_line" ] && [ "$_harden_line" -gt "$_commit_line" ] && echo yes || echo no)"
t "root home hardens before helper writes" "yes" \
  "$([ -n "$_harden_line" ] && [ "$_harden_line" -lt "$_helper_line" ] && echo yes || echo no)"
t "installed console menu is retired" "yes" \
  "$([ ! -e quecdeck/console/menu/start_menu.sh ] && ! grep -q '/usrdata/quecdeck/console' quecdeck/console/.profile && ! grep -q 'root/bin/menu.*ln -s\|ln -s.*root/bin/menu' update_quecdeck.sh quecdeck.sh && grep -q 'rm -f /usrdata/root/bin/menu' update_quecdeck.sh quecdeck.sh && echo yes || echo no)"
t "developer password helper and web form remain available" "yes" \
  "$([ -x quecdeck/quecdeckdevpasswd ] && grep -q 'changeDeveloperPassword' quecdeck/www/security.html quecdeck/www/js/security.js && grep -q 'cp -f.*quecdeckdevpasswd.*usrdata/root/bin/quecdeckdevpasswd' update_quecdeck.sh && echo yes || echo no)"
t "rollback restores password helper copies" "2" \
  "$(sed -n '/^_revert_swap() {/,/^}/p' update_quecdeck.sh | grep -c 'cp -f.*quecdeck.*passwd.*usrdata/root/bin')"
t "uninstall clears root-home migration marker" "yes" \
  "$(sed -n '/^uninstall_quecdeck_components() {/,/^}/p' quecdeck.sh | grep -q 'rm -f.*ROOT_HOME_HARDENED' && echo yes || echo no)"

# Base installation and key-only SSH must not replace firmware authentication
# commands or request a system password.
t "Entware bootstrap does not install a root login stack" "yes" \
  "$(! grep -qE 'shadow-(login|passwd|useradd)|/opt/bin/passwd|Patching Quectel Login' installentware.sh && echo yes || echo no)"
_entware_base=$(sed -n '/^ensure_entware_installed() {/,/^}/p' quecdeck.sh)
t "base installer does not prepare root authentication" "yes" \
  "$(! printf '%s\n' "$_entware_base" | grep -qE 'shadow-(login|passwd|useradd)|/opt/bin/passwd|/bin/login\.shadow' && echo yes || echo no)"
_ssh_installer=quecdeck/script/install_sshd.sh
_ssh_accounts=$(sed -n '/^prepare_ssh_accounts() {/,/^}/p' "$_ssh_installer")
t "SSH prepares only a private Entware service account" "yes" \
  "$(printf '%s\n' "$_ssh_accounts" | grep -q 'cp /etc/passwd /opt/etc/passwd' && printf '%s\n' "$_ssh_accounts" | grep -q 'sshd:x:106:' && ! printf '%s\n' "$_ssh_accounts" | grep -qE 'shadow|/bin/login|/usr/bin/passwd|useradd' && echo yes || echo no)"
t "SSH account preparation copies the firmware root line literally" "yes" \
  "$(printf '%s\n' "$_ssh_accounts" | grep -q 'printf.*firmware_root' && printf '%s\n' "$_ssh_accounts" | grep -q "grep -v '\^root:'" && ! printf '%s\n' "$_ssh_accounts" | grep -q 'sed -i.*firmware_root' && echo yes || echo no)"
t "QuecDeck uninstall does not rewrite Entware passwd links" "yes" \
  "$(! sed -n '/^uninstall_quecdeck_components() {/,/^}/p' quecdeck.sh | grep -q 'sed -i.*opt/etc/passwd' && echo yes || echo no)"
t "SSH install uses the non-PAM server with key-only authentication" "yes" \
  "$(grep -q 'openssh-server openssh-keygen' "$_ssh_installer" && grep -q '^AuthenticationMethods publickey$' "$_ssh_installer" && ! grep -q 'UsePAM' "$_ssh_installer" && echo yes || echo no)"
_sshd_menu=$(sed -n '/^sshd_service() {/,/^}/p' quecdeck.sh)
t "SSH menu dispatches only to the installed root helper" "yes" \
  "$(printf '%s\n' "$_sshd_menu" | grep -q 'script/install_sshd.sh' && ! printf '%s\n' "$_sshd_menu" | grep -q 'wget\|GITROOT\|opkg install' && echo yes || echo no)"
t "SSH installation has no PAM migration path" "yes" \
  "$(! grep -qE 'opkg (download|install).*openssh-server-pam|opkg remove openssh-server-pam.*Failed to remove' "$_ssh_installer" && echo yes || echo no)"
t "SSH bundled assets verify before package installation" "yes" \
  "$([ "$(grep -n 'verify_asset sshd.service' "$_ssh_installer" | cut -d: -f1)" -lt "$(grep -n 'opkg install --force-maintainer openssh-server' "$_ssh_installer" | cut -d: -f1)" ] && ! grep -q 'wget\|GITROOT' "$_ssh_installer" && echo yes || echo no)"
t "SSH configuration scopes its restrictive umask" "yes" \
  "$(grep -q '^configure_key_only_ssh() ($' "$_ssh_installer" && echo yes || echo no)"
_ssh_config=$(sed -n '/^configure_key_only_ssh() (/,/^)/p' "$_ssh_installer")
t "SSH validates the temporary configuration before replacement" "yes" \
  "$( _validate=$(printf '%s\n' "$_ssh_config" | grep -n 'sshd -t -f.*config_tmp' | cut -d: -f1); _replace=$(printf '%s\n' "$_ssh_config" | grep -n 'mv -f.*config_tmp.*sshd_config' | cut -d: -f1); [ -n "$_validate" ] && [ -n "$_replace" ] && [ "$_validate" -lt "$_replace" ] && printf '%s\n' "$_ssh_config" | grep -q 'sshd -T -f.*config_tmp' && echo yes || echo no)"
_ssh_prepare_line=$(grep -n 'prepare_ssh_accounts ||' "$_ssh_installer" | cut -d: -f1)
_ssh_install_line=$(grep -n 'opkg install --force-maintainer openssh-server openssh-keygen' "$_ssh_installer" | cut -d: -f1)
_ssh_start_line=$(grep -n 'systemctl start sshd ||' "$_ssh_installer" | cut -d: -f1)
t "SSH service account is ready before daemon installation and start" "yes" \
  "$([ -n "$_ssh_prepare_line" ] && [ "$_ssh_prepare_line" -lt "$_ssh_install_line" ] && [ "$_ssh_install_line" -lt "$_ssh_start_line" ] && echo yes || echo no)"
unset _entware_base _ssh_installer _ssh_accounts _sshd_menu _ssh_config _ssh_prepare_line _ssh_install_line _ssh_start_line

# Branch installs must pin one ref for the manifest, the installer, and the
# archive. Leaving the tag empty falls back to the updater's own default, which
# silently pairs a branch installer with a main-branch release.
_install_fn=$(sed -n '/^install_quecdeck() {/,/^}/p' quecdeck.sh)
t "branch install passes its ref to the updater" "yes" \
  "$(printf '%s\n' "$_install_fn" | grep -q 'fetch_and_run_installer "\$GITROOT" "\$GITTREE"' && echo yes || echo no)"
# Every pinned fetch reads the global GITROOT, and the pins live in this same
# script. Repointing GITROOT before the first fetch is what keeps them matched.
t "branch install repoints GITROOT before any pinned fetch" "yes" \
  "$( _set=$(printf '%s\n' "$_install_fn" | grep -n 'GITROOT="https://raw.githubusercontent.com/\$GITUSER/\$REPONAME/\$GITTREE"' | cut -d: -f1); _ent=$(printf '%s\n' "$_install_fn" | grep -n 'ensure_entware_installed' | cut -d: -f1); _pw=$(printf '%s\n' "$_install_fn" | grep -n 'set_quecdeck_passwd' | cut -d: -f1); [ -n "$_set" ] && [ "$_set" -lt "$_ent" ] && [ "$_set" -lt "$_pw" ] && echo yes || echo no)"
t "menu install options name their ref explicitly" "yes" \
  "$(grep -q '^            install_quecdeck main$' quecdeck.sh && grep -q '^            install_quecdeck_dev$' quecdeck.sh && echo yes || echo no)"
t "development branch install is offered and confirmed" "yes" \
  "$( _dev=$(sed -n '/^install_quecdeck_dev() {/,/^}/p' quecdeck.sh); grep -q '3) Install/Update QuecDeck (development branch)' quecdeck.sh && printf '%s\n' "$_dev" | grep -q 'valid_git_ref' && printf '%s\n' "$_dev" | grep -q 'DEVTREE' && printf '%s\n' "$_dev" | grep -q 'y|Y)' && echo yes || echo no)"
eval "$(extract_fn quecdeck.sh valid_git_ref)"
t "ref validator accepts a plain branch" "0" "$(valid_git_ref dev; echo $?)"
t "ref validator accepts a namespaced branch" "0" "$(valid_git_ref feature/ssh-keys; echo $?)"
t "ref validator rejects traversal" "1" "$(valid_git_ref ../../etc; echo $?)"
t "ref validator rejects shell metacharacters" "1" "$(valid_git_ref 'a;id'; echo $?)"
t "ref validator rejects percent encoding" "1" "$(valid_git_ref 'a%2e'; echo $?)"
t "ref validator rejects an empty ref" "1" "$(valid_git_ref ''; echo $?)"
t "ref validator rejects a leading dash" "1" "$(valid_git_ref -x; echo $?)"
unset _install_fn

# This generation requires a clean QuecDeck and Entware installation. The
# boundary is checked before either installer mutates the device.
t "release declares its installation generation" "2" \
  "$(tr -d '[:space:]' < quecdeck/install-generation)"
t "installation generation is checksummed automatically" "yes" \
  "$(grep -q '^  quecdeck/install-generation$' .githooks/pre-commit && echo yes || echo no)"
t "extensionless generation markers stay LF-only" "yes" \
  "$(grep -q '^quecdeck/install-generation text eol=lf$' .gitattributes && grep -q '^quecdeck/monitoring-generation text eol=lf$' .gitattributes && echo yes || echo no)"
t "installer checks generation before Entware setup" "yes" \
  "$(_guard=$(grep -n 'require_supported_install_state ||' quecdeck.sh | head -1 | cut -d: -f1); _entware=$(grep -n '^[[:space:]]*ensure_entware_installed$' quecdeck.sh | tail -1 | cut -d: -f1); [ -n "$_guard" ] && [ -n "$_entware" ] && [ "$_guard" -lt "$_entware" ] && echo yes || echo no)"
t "interrupted first install retries only with its Entware marker" "yes" \
  "$( _ensure=$(sed -n '/^ensure_entware_installed() {/,/^}/p' quecdeck.sh); grep -q '^ENTWARE_BOOTSTRAP_MARKER=' quecdeck.sh && printf '%s\n' "$_ensure" | grep -q '^    require_supported_install_state || return 1$' && printf '%s\n' "$_ensure" | grep -q 'ENTWARE_BOOTSTRAP_MARKER' && sed -n '/^supported_install_state() {/,/^}/p' quecdeck.sh | grep -q 'grep -qx.*ENTWARE_BOOTSTRAP_MARKER' && echo yes || echo no)"
t "non-PAM SSH configuration omits UsePAM handling" "yes" \
  "$(! grep -qE 'UsePAM|usepam' quecdeck.sh quecdeck/script/ssh_keys.sh && echo yes || echo no)"
t "updater rejects releases before this installation generation" "yes" \
  "$(grep -q '_install_generation_supported' update_quecdeck.sh && grep -q 'requires a clean installation' update_quecdeck.sh quecdeck.sh && echo yes || echo no)"
t "updater has no legacy SSH or authentication migration" "yes" \
  "$(! grep -qE '_withdraw_legacy_ssh|_ssh_is_key_only|_restore_legacy_auth' update_quecdeck.sh && echo yes || echo no)"

# ttyd was removed as a feature. The full uninstaller still removes files left
# by an older release so it can prepare a device for the clean installation.
t "ttyd release files are removed" "yes" \
  "$([ ! -e quecdeck/systemd/ttyd.service ] && [ ! -e quecdeck/console/ttyd.bash ] && [ ! -e quecdeck/www/cgi-bin/toggle_ttyd ] && echo yes || echo no)"
t "ttyd is absent from UI, auth, server config, and sudoers" "yes" \
  "$(! grep -qi ttyd quecdeck/www/developer.html quecdeck/www/js/developer.js quecdeck/www/deviceinfo.html quecdeck/auth.lua quecdeck/lighttpd.conf quecdeck/www/cgi-bin/get_system_status && ! grep '_sudoers_rule=' update_quecdeck.sh | grep -q ttyd && echo yes || echo no)"
t "updater removes legacy ttyd activation" "yes" \
  "$(grep -q 'systemctl stop ttyd' update_quecdeck.sh && grep -q 'rm -f /lib/systemd/system/ttyd.service' update_quecdeck.sh && grep -q 'readlink /bin/ttyd.*opt/bin/ttyd.*rm -f /bin/ttyd' update_quecdeck.sh && echo yes || echo no)"
t "full uninstall removes legacy ttyd files" "yes" \
  "$(grep -q 'rm -f /lib/systemd/system/ttyd.service' quecdeck.sh && grep -q 'rm -f /bin/ttyd' quecdeck.sh && echo yes || echo no)"
t "firmware authentication restoration has its own uninstall result" "yes" \
  "$(grep -q '_show_uninstall_result "Firmware login".*result_auth_restore' quecdeck.sh && ! grep -q 'restore_legacy_auth_commands || result_sshd=' quecdeck.sh && echo yes || echo no)"
t "firmware authentication no-op remains skipped" "yes" \
  "$(grep -q 'RESTORE_LEGACY_AUTH_CHANGED=0' quecdeck.sh && grep -q 'RESTORE_LEGACY_AUTH_CHANGED.*result_auth_restore="RESTORED"' quecdeck.sh && echo yes || echo no)"
t "removed web console has no auth integration assertions" "yes" \
  "$(! grep -q '/console/' tests/host/integration/auth-lua.test.lua && echo yes || echo no)"

# Every shipped unit must carry the marker or both sweeps go blind to it and it
# stays installed and enabled forever. The ci-checks.sh script also checks this. It is repeated
# here because run-tests.sh is what the pre-commit hook runs, so a marker-less
# unit is blocked at commit time rather than discovered in CI.
for _u in quecdeck/systemd/*.service; do
    [ -f "$_u" ] || continue
    t "unit self-identifies: $(basename "$_u")" "yes" \
      "$(grep -qE '^Exec(Start|StartPre|StartPost|Reload|Stop|StopPost)=.*/usrdata/quecdeck(/|[[:space:]]|$)' "$_u" && echo yes || echo no)"
done

# ---------------------------------------------------------- JS structure ----
t "Alpine controllers rely on one automatic init call" "yes" \
  "$(! grep -q 'x-init="init()"' quecdeck/www/setup.html quecdeck/www/security.html && echo yes || echo no)"
t "setup blocks when recovery-state loading fails" "yes" \
  "$(grep -q 'if (!response.ok)' quecdeck/www/js/setup.js && grep -q 'if (!this.setupReady)' quecdeck/www/js/setup.js && echo yes || echo no)"
t "SSH validates the final generated config" "yes" \
  "$([ "$(grep -n 'update_sshd_ip.sh' quecdeck/optional/sshd/sshd.service | cut -d: -f1)" -lt "$(grep -n 'ssh_keys.sh ready' quecdeck/optional/sshd/sshd.service | cut -d: -f1)" ] && echo yes || echo no)"
t "SSH installation creates the root-only enable marker" "yes" \
  "$( _configure=$(sed -n '/^configure_key_only_ssh() (/,/^)/p' quecdeck/script/install_sshd.sh); printf '%s\n' "$_configure" | grep -q 'quecdeck_enabled' && printf '%s\n' "$_configure" | grep -q 'chmod 600' && echo yes || echo no)"
t "strict CSP has no blocked literal style attributes" "yes" \
  "$(! grep -R -E '(^|[[:space:]])style=' quecdeck/www --include='*.html' --include='*.js' && ! grep -q "style-src.*unsafe-inline" quecdeck/lighttpd.conf && echo yes || echo no)"
js_fail=0
for f in quecdeck/www/js/*.js; do
    case "$f" in *.min.js) continue ;; esac
    out=$(perl tests/host/support/jscheck.pl "$f")
    if [[ "$out" == *": OK" ]]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1)); js_fail=1
        echo "FAIL: jscheck $out"
    fi
done
