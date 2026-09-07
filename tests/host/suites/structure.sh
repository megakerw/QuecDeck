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
  "$(grep -q 'x-data="securityController()"' quecdeck/www/security.html && grep -q 'x-data="securityController(true)"' quecdeck/www/ssh.html && grep_all 'js/security.js' quecdeck/www/security.html quecdeck/www/ssh.html && grep -q "href: '/security.html', label: 'Security'" quecdeck/www/js/nav.js && grep -q "href: '/ssh.html', label: 'SSH'" quecdeck/www/js/nav.js && grep -q 'href="/ssh.html"' quecdeck/www/deviceinfo.html && echo yes || echo no)"
t "SSH page supports public-key upload and multiple key rows" "yes" \
  "$(grep -q 'id="public-key-file"' quecdeck/www/ssh.html && grep -q 'accept=".pub,text/plain"' quecdeck/www/ssh.html && grep -q 'x-for="(key, index) in keys"' quecdeck/www/ssh.html && grep -q 'keys.length >= 5' quecdeck/www/ssh.html && echo yes || echo no)"
t "Password change returns to a clear login state" "yes" \
  "$(grep -q 'password_changed=1' quecdeck/www/js/security.js && grep_all 'passwordChanged' quecdeck/www/js/login.js quecdeck/www/login.html && echo yes || echo no)"

# ------------------------------------------ root-home migration lifecycle ---
# harden_root_home is a destructive migration that still runs on every update.
# These ordering assertions keep it behind a committed swap (so a rollback
# snapshot exists) and ahead of the helper writes that depend on it.
_harden_line=$(grep -n '^[[:space:]]*harden_root_home ||' update_quecdeck.sh | cut -d: -f1)
_commit_line=$(grep -n '^[[:space:]]*_swap_committed=1$' update_quecdeck.sh | tail -1 | cut -d: -f1)
_helper_line=$(grep -n 'ln -sf "\$QUECDECK_DIR/atcli" /usrdata/root/bin/atcli' update_quecdeck.sh | head -1 | cut -d: -f1)
t "root home hardens after rollback becomes possible" "yes" \
  "$([ -n "$_harden_line" ] && [ "$_harden_line" -gt "$_commit_line" ] && echo yes || echo no)"
t "root home hardens before helper writes" "yes" \
  "$([ -n "$_harden_line" ] && [ "$_harden_line" -lt "$_helper_line" ] && echo yes || echo no)"
# The uninstaller reaps the console menu symlink an earlier release may have
# left behind, so it can prepare a device for the clean installation this
# generation requires.
t "uninstall removes the retired console menu symlink" "yes" \
  "$(grep -q 'rm -f /usrdata/root/bin/menu' quecdeck.sh && echo yes || echo no)"
t "developer password helper and web form remain available" "yes" \
  "$([ -x quecdeck/quecdeckdevpasswd ] && grep_all 'changeDeveloperPassword' quecdeck/www/security.html quecdeck/www/js/security.js && grep -q 'cp -f.*quecdeckdevpasswd.*usrdata/root/bin/quecdeckdevpasswd' update_quecdeck.sh && echo yes || echo no)"
t "rollback restores password helper copies" "2" \
  "$(sed -n '/^_revert_swap() {/,/^}/p' update_quecdeck.sh | grep -c 'cp -f.*quecdeck.*passwd.*usrdata/root/bin')"
t "uninstall clears root-home migration marker" "yes" \
  "$(sed -n '/^uninstall_quecdeck_components() {/,/^}/p' quecdeck.sh | grep -q 'rm -f.*ROOT_HOME_HARDENED' && echo yes || echo no)"

# Key-only SSH must not replace firmware authentication commands or request a
# system password.
_ssh_installer=quecdeck/script/install_sshd.sh
_ssh_accounts=$(sed -n '/^prepare_ssh_accounts() {/,/^}/p' "$_ssh_installer")
t "SSH prepares only a private Entware service account" "yes" \
  "$(printf '%s\n' "$_ssh_accounts" | grep -q 'passwd_source=/etc/passwd' && printf '%s\n' "$_ssh_accounts" | grep -q 'sshd:x:106:' && ! printf '%s\n' "$_ssh_accounts" | grep -qE 'shadow|/bin/login|/usr/bin/passwd|useradd' && echo yes || echo no)"
t "SSH account preparation copies the firmware root line literally" "yes" \
  "$(printf '%s\n' "$_ssh_accounts" | grep -q 'printf.*firmware_root' && printf '%s\n' "$_ssh_accounts" | grep -q "grep -vE '\^(root|sshd):'" && ! printf '%s\n' "$_ssh_accounts" | grep -q 'sed -i.*firmware_root' && echo yes || echo no)"
t "SSH account preparation rejects conflicting usernames before replacement" "yes" \
  "$( _check=$(printf '%s\n' "$_ssh_accounts" | grep -n 'incompatible sshd account' | head -1 | cut -d: -f1); _replace=$(printf '%s\n' "$_ssh_accounts" | grep -n 'mv -f.*passwd' | head -1 | cut -d: -f1); [ -n "$_check" ] && [ -n "$_replace" ] && [ "$_check" -lt "$_replace" ] && echo yes || echo no)"

# QuecDeck creates the Entware mount and init units, so their boot ordering and
# filesystem permissions are part of our installer contract.
_entware_writer=$(extract_fn installentware.sh write_system_unit)
_entware_mount=$(extract_fn installentware.sh create_opt_mount)
_entware_rc=$(sed -n '/^write_system_unit \/lib\/systemd\/system\/rc\.unslung\.service/,/^EOF$/p' installentware.sh)
t "Entware units are prepared securely before atomic replacement" "yes" \
  "$(printf '%s\n' "$_entware_writer" | grep -q 'mktemp.*_unit_target' && printf '%s\n' "$_entware_writer" | grep -q 'chown root:root' && printf '%s\n' "$_entware_writer" | grep -q 'chmod 644' && printf '%s\n' "$_entware_writer" | grep -q 'mv -f.*_unit_target' && echo yes || echo no)"
t "Entware enables opt.mount directly without a wrapper service" "yes" \
  "$(printf '%s\n' "$_entware_mount" | grep -q 'multi-user.target.wants/opt.mount' && ! printf '%s\n' "$_entware_mount" | grep -q 'cat.*start-opt-mount.service\|write_system_unit.*start-opt-mount.service' && echo yes || echo no)"
t "Entware mount waits for firmware data initialization" "yes" \
  "$( _mount_unit=$(sed -n '/^    write_system_unit \/lib\/systemd\/system\/opt\.mount/,/^EOF$/p' installentware.sh); printf '%s\n' "$_mount_unit" | grep -qx 'DefaultDependencies=no' && printf '%s\n' "$_mount_unit" | grep -qx 'Requires=usrdata.mount' && printf '%s\n' "$_mount_unit" | grep -qx 'After=usrdata.mount data-init.service' && echo yes || echo no)"
t "Entware init waits for the actual opt mount" "yes" \
  "$(printf '%s\n' "$_entware_rc" | grep -qx 'Requires=opt.mount' && printf '%s\n' "$_entware_rc" | grep -qx 'After=opt.mount' && ! printf '%s\n' "$_entware_rc" | grep -q 'sleep' && echo yes || echo no)"
t "Entware uninstall removes direct and legacy mount enablement" "yes" \
  "$( _uninstall=$(extract_fn quecdeck.sh uninstall_entware); printf '%s\n' "$_uninstall" | grep -q 'multi-user.target.wants/opt.mount' && printf '%s\n' "$_uninstall" | grep -q 'multi-user.target.wants/start-opt-mount.service' && echo yes || echo no)"
_opkg_hardened=0
for _opkg_script in installentware.sh quecdeck.sh update_quecdeck.sh quecdeck/script/install_sshd.sh; do
    _opkg_guard=$(extract_fn "$_opkg_script" secure_opkg_metadata)
    _opkg_local_guard=$(extract_fn "$_opkg_script" secure_opkg_installed_metadata)
    _opkg_https=$(extract_fn "$_opkg_script" require_https_opkg_feeds)
    if grep -q '^umask 022$' "$_opkg_script" &&
       printf '%s\n' "$_opkg_guard" | grep -q '\[ ! -L' &&
       printf '%s\n' "$_opkg_guard" | grep -q 'chown root:root' &&
       printf '%s\n' "$_opkg_guard" | grep -q 'chmod 644' &&
       printf '%s\n' "$_opkg_guard" | grep -q 'chmod 755' &&
       printf '%s\n' "$_opkg_guard" | grep -q 'secure_opkg_installed_metadata' &&
       printf '%s\n' "$_opkg_local_guard" | grep -q '/opt/lib/opkg/status' &&
       printf '%s\n' "$_opkg_local_guard" | grep -q '/opt/lib/opkg/info' &&
       printf '%s\n' "$_opkg_https" | grep -q 'src|src/gz' &&
       printf '%s\n' "$_opkg_https" | grep -q 'https://\*' &&
       [ "$(grep -c 'require_https_opkg_feeds' "$_opkg_script")" -ge 2 ] &&
       [ "$(grep -c 'secure_opkg_metadata' "$_opkg_script")" -ge 2 ]; then
        _opkg_hardened=$((_opkg_hardened + 1))
    fi
done
t "every privileged opkg entry point seals its trust metadata" 4 "$_opkg_hardened"
t "Entware installs opkg.conf atomically with an explicit mode" "yes" \
  "$(grep -q 'mktemp /opt/etc/.opkg.conf' installentware.sh && grep -q 'chmod 644.*_opkg_conf_tmp' installentware.sh && grep -q 'mv -f.*opkg.conf' installentware.sh && echo yes || echo no)"
t "Entware installs the initial opkg binary atomically" "yes" \
  "$(grep -q 'mktemp /opt/bin/.opkg' installentware.sh && grep -q '\[ ! -s.*_opkg_bin_tmp' installentware.sh && grep -q 'chmod 755.*_opkg_bin_tmp' installentware.sh && grep -q '_opkg_bin_tmp.*--version' installentware.sh && grep -q 'mv -f.*_opkg_bin_tmp.* /opt/bin/opkg' installentware.sh && echo yes || echo no)"
t "Entware initializes and protects the installed-package database" "yes" \
  "$(grep -q '! -L /opt/lib/opkg/info.*! -L /opt/lib/opkg/status' installentware.sh && grep -q 'chmod 600 /opt/lib/opkg/status' installentware.sh && _bootstrap=$(extract_fn installentware.sh bootstrap_tls_packages); [ "$(printf '%s\n' "$_bootstrap" | grep -c 'secure_opkg_metadata')" -eq 2 ] && echo yes || echo no)"
_tls_recovery=$(extract_fn quecdeck.sh install_entware_tls_packages)
t "missing Entware TLS packages recover through stock curl" "yes" \
  "$(printf '%s\n' "$_tls_recovery" | grep -q '/usr/bin/curl' && printf '%s\n' "$_tls_recovery" | grep -q -- "--proto '=https'" && printf '%s\n' "$_tls_recovery" | grep -q '/opt/bin/opkg update' && printf '%s\n' "$_tls_recovery" | grep -q '/opt/bin/opkg install wget-ssl ca-certificates' && [ "$(printf '%s\n' "$_tls_recovery" | grep -c 'secure_opkg_metadata')" -eq 2 ] && echo yes || echo no)"
_ensure_entware=$(extract_fn quecdeck.sh ensure_entware_installed)
t "Entware migration validates HTTPS before TLS recovery" "yes" \
  "$( _migrate=$(printf '%s\n' "$_ensure_entware" | grep -n "sed -i.*http://bin" | cut -d: -f1); _validate=$(printf '%s\n' "$_ensure_entware" | grep -n 'require_https_opkg_feeds' | head -1 | cut -d: -f1); _recover=$(printf '%s\n' "$_ensure_entware" | grep -n '^[[:space:]]*install_entware_tls_packages' | cut -d: -f1); [ -n "$_migrate" ] && [ "$_migrate" -lt "$_validate" ] && [ "$_validate" -lt "$_recover" ] && echo yes || echo no)"
unset _opkg_hardened _opkg_script _opkg_guard _opkg_local_guard _opkg_https _tls_recovery _ensure_entware _migrate _validate _recover
unset _entware_writer _entware_mount _entware_rc

t "SSH install uses the non-PAM server with key-only authentication" "yes" \
  "$(grep -q 'openssh-server openssh-keygen' "$_ssh_installer" && grep -q '^AuthenticationMethods publickey$' "$_ssh_installer" && ! grep -q 'UsePAM' "$_ssh_installer" && echo yes || echo no)"
_sshd_menu=$(sed -n '/^sshd_service() {/,/^}/p' quecdeck.sh)
t "SSH menu dispatches only to the installed root helper" "yes" \
  "$(printf '%s\n' "$_sshd_menu" | grep -q 'script/install_sshd.sh' && ! printf '%s\n' "$_sshd_menu" | grep -q 'wget\|GITROOT\|opkg install' && echo yes || echo no)"
_sshd_server_view=$(sed -n '/get serverView() {/,/^    },$/p' quecdeck/www/js/security.js)
# A finished removal must be tested before sshInstalled, which stays true until
# the get_security refresh lands. Reversing them re-exposes the management panel
# for a server that was just removed.
t "SSH removal has one result view before installation returns" "yes" \
  "$( _removed=$(printf '%s\n' "$_sshd_server_view" | grep -n "'removed'" | head -1 | cut -d: -f1); _installed=$(printf '%s\n' "$_sshd_server_view" | grep -n 'sshInstalled' | head -1 | cut -d: -f1); [ -n "$_removed" ] && [ -n "$_installed" ] && [ "$_removed" -lt "$_installed" ] && grep -q "x-if=\"serverView === 'removed'\"" quecdeck/www/ssh.html && grep -q '>Dismiss</button>' quecdeck/www/ssh.html && echo yes || echo no)"
# Layout and contents both derive from serverView, so they cannot disagree.
t "SSH server card branches on one exhaustive predicate" "yes" \
  "$( _views=0; for _v in loading removing removed install manage; do grep -q "x-if=\"serverView === '$_v'\"" quecdeck/www/ssh.html && _views=$((_views + 1)); done; [ "$_views" = 5 ] && grep -q "serverView === 'removing' || this.serverView === 'removed'" quecdeck/www/js/security.js && ! grep -q 'x-if="loaded' quecdeck/www/ssh.html && echo yes || echo no)"
t "enabled SSH distinguishes waiting for a key from a failed start" "yes" \
  "$(grep -q 'keys.length === 0' quecdeck/www/js/security.js && grep -q 'waiting for an authorized key' quecdeck/www/js/security.js && grep -q 'Enabled with a key, but the server is not running' quecdeck/www/js/security.js && echo yes || echo no)"
# The card paints a real body in every state, so no state collapses it to a bare
# header. It must not depend on x-show: the CSP has no style-src-attr allowance.
t "SSH panels render a body before initial status loads" "yes" \
  "$(grep -q "if (!this.loaded) return 'loading';" quecdeck/www/js/security.js && grep -q 'Reading the SSH server status' quecdeck/www/ssh.html && grep -q 'panel-loading' quecdeck/www/ssh.html && ! grep -q 'ssh-panel-layout.*x-show' quecdeck/www/ssh.html && ! grep -q 'ssh-keys-column.*x-show' quecdeck/www/ssh.html && echo yes || echo no)"
t "SSH panel order uses the same nested columns at every width" "yes" \
  "$(! grep -qE 'ssh-(primary-column|server-slot|keys-column|software-slot).*(display: contents|order:)' quecdeck/www/css/styles.css && echo yes || echo no)"
# The pending toggle is reported before any running-state wording, so an unsaved
# change never reads as the server's current condition.
t "unsaved SSH toggle describes its pending state" "yes" \
  "$( _hint=$(sed -n '/get enableHint() {/,/^    },$/p' quecdeck/www/js/security.js); _pending=$(printf '%s\n' "$_hint" | grep -n 'sshEnabled !== this.savedSshEnabled' | head -1 | cut -d: -f1); _active=$(printf '%s\n' "$_hint" | grep -n 'this.sshActive' | head -1 | cut -d: -f1); [ -n "$_pending" ] && [ -n "$_active" ] && [ "$_pending" -lt "$_active" ] && printf '%s\n' "$_hint" | grep -q 'SSH will be enabled after you save settings' && printf '%s\n' "$_hint" | grep -q 'SSH will be disabled after you save settings' && echo yes || echo no)"
t "SSH lifecycle actions wait for their completion poll before refreshing status" "yes" \
  "$(grep -q 'refreshOnSuccess = true' quecdeck/www/js/security.js && [ "$(grep -c 'refreshOnSuccess: false' quecdeck/www/js/security.js)" -eq 3 ] && echo yes || echo no)"
t "SSH progress polls immediately and keeps fast actions readable" "yes" \
  "$(grep -q '^      poll();$' quecdeck/www/js/security.js && grep -q 'setInterval(poll, 1000)' quecdeck/www/js/security.js && grep -q 'setTimeout(finish, 750)' quecdeck/www/js/security.js && ! grep -q 'sshdProgressSince' quecdeck/www/js/security.js && echo yes || echo no)"
t "SSH progress requires the exact action and recovers missing shared status" "yes" \
  "$( _poll=$(sed -n '/^    startSshdPolling() {/,/^    },/p' quecdeck/www/js/security.js); printf '%s\n' "$_poll" | grep -q "expectedKind = 'sshd:' + expectedAction" && printf '%s\n' "$_poll" | grep -q 'data.kind !== expectedKind' && printf '%s\n' "$_poll" | grep -q 'resetSshdView' && echo yes || echo no)"
_sshd_dispatch=$(sed -n '/systemctl start --no-block install_quecdeck_sshd/,/echo "Started\."/p' quecdeck/script/run_update.sh)
t "SSH credential dialog is released as soon as systemd accepts the action" "yes" \
  "$(printf '%s\n' "$_sshd_dispatch" | grep -q 'systemctl start --no-block' && ! printf '%s\n' "$_sshd_dispatch" | grep -q 'sleep\|is-active' && echo yes || echo no)"
unset _sshd_dispatch
unset _sshd_removal_view
t "SSH bundled assets verify before package installation" "yes" \
  "$([ "$(grep -n 'verify_asset sshd.service' "$_ssh_installer" | cut -d: -f1)" -lt "$(grep -n 'opkg install --force-maintainer openssh-server' "$_ssh_installer" | cut -d: -f1)" ] && ! grep -q 'wget\|GITROOT' "$_ssh_installer" && echo yes || echo no)"
t "SSH configuration scopes its restrictive umask" "yes" \
  "$(grep -q '^configure_key_only_ssh() ($' "$_ssh_installer" && echo yes || echo no)"
_ssh_config=$(sed -n '/^configure_key_only_ssh() (/,/^)/p' "$_ssh_installer")
t "SSH configuration expands only the validated port" "yes" \
  "$(printf '%s\n' "$_ssh_config" | grep -q "printf 'Port %s" && printf '%s\n' "$_ssh_config" | grep -q "cat <<'EOF'" && ! printf '%s\n' "$_ssh_config" | grep -q 'cat .*<<EOF' && echo yes || echo no)"
t "SSH validates the temporary configuration before replacement" "yes" \
  "$( _validate=$(printf '%s\n' "$_ssh_config" | grep -n 'sshd -t -f.*config_tmp' | cut -d: -f1); _replace=$(printf '%s\n' "$_ssh_config" | grep -n 'mv -f.*config_tmp.*sshd_config' | cut -d: -f1); [ -n "$_validate" ] && [ -n "$_replace" ] && [ "$_validate" -lt "$_replace" ] && printf '%s\n' "$_ssh_config" | grep -q 'sshd -T -f.*config_tmp' && echo yes || echo no)"
t "SSH installation preserves the configured port and enabled state" "yes" \
  "$( _resolve=$(extract_fn "$_ssh_installer" resolve_saved_settings); _update=$(extract_fn "$_ssh_installer" update_sshd); _install=$(extract_fn "$_ssh_installer" install_sshd); printf '%s\n' "$_resolve" | grep -q 'ssh_access.sh" saved-state' && printf '%s\n' "$_update" | grep -q 'install_sshd "\$saved_ssh_port" "\$saved_ssh_enabled"' && printf '%s\n' "$_install" | grep -q 'configure_key_only_ssh "\$ssh_port" "\$ssh_enabled"' && printf '%s\n' "$_ssh_config" | grep -q "printf 'Port %s.*\"\$ssh_port\"" && printf '%s\n' "$_ssh_config" | grep -q '\[ "\$ssh_enabled" = 1 \]' && echo yes || echo no)"
t "SSH installation refuses unreadable existing settings" "yes" \
  "$( _resolve=$(extract_fn "$_ssh_installer" resolve_saved_settings); _update=$(extract_fn "$_ssh_installer" update_sshd); _install=$(extract_fn "$_ssh_installer" install_sshd); _read=$(printf '%s\n' "$_resolve" | grep -n 'saved-state' | head -1 | cut -d: -f1); _abort=$(printf '%s\n' "$_resolve" | grep -n 'Existing SSH settings could not be read' | head -1 | cut -d: -f1); _first=$(printf '%s\n' "$_update" | grep -n 'resolve_saved_settings || return' | head -1 | cut -d: -f1); _apply=$(printf '%s\n' "$_update" | grep -n 'install_sshd "' | head -1 | cut -d: -f1); _managed=$(extract_fn quecdeck/script/ssh_access.sh managed_state_exists); [ -n "$_read" ] && [ -n "$_abort" ] && [ "$_read" -lt "$_abort" ] && [ -n "$_first" ] && [ -n "$_apply" ] && [ "$_first" -lt "$_apply" ] && ! printf '%s\n' "$_install" | grep -q 'saved-state' && printf '%s\n' "$_managed" | grep -q 'sshd-listen.conf' && printf '%s\n' "$_managed" | grep -q 'ExecStartPre=.*update_sshd_ip.sh' && ! printf '%s\n' "$_install" | grep -q 'sshd-listen.conf' && echo yes || echo no)"
t "SSH installation identifies a missing bundled helper before reading state" "yes" \
  "$( _resolve=$(extract_fn "$_ssh_installer" resolve_saved_settings); _missing=$(printf '%s\n' "$_resolve" | grep -n 'bundled SSH access helper is missing' | head -1 | cut -d: -f1); _read=$(printf '%s\n' "$_resolve" | grep -n 'saved-state' | head -1 | cut -d: -f1); [ -n "$_missing" ] && [ -n "$_read" ] && [ "$_missing" -lt "$_read" ] && echo yes || echo no)"
t "SSH installation reconciles a running daemon and fails closed with the firewall" "yes" \
  "$( _install=$(extract_fn "$_ssh_installer" install_sshd); printf '%s\n' "$_install" | grep -q 'systemctl restart sshd ||' && _failure=$(printf '%s\n' "$_install" | sed -n '/if ! apply_firewall; then/,/RC_FIREWALL/p'); printf '%s\n' "$_failure" | grep -q 'stop_sshd_safely' && printf '%s\n' "$_failure" | grep -q 'Sshd was not started' && echo yes || echo no)"
t "SSH update stops first and restores its hardened config after opkg" "yes" \
  "$( _install=$(extract_fn "$_ssh_installer" install_sshd); _stop=$(printf '%s\n' "$_install" | grep -n 'stop_sshd_safely' | head -1 | cut -d: -f1); _opkg=$(printf '%s\n' "$_install" | grep -n 'opkg install' | head -1 | cut -d: -f1); _restore=$(printf '%s\n' "$_install" | grep -n 'previous_config.*sshd_config' | tail -1 | cut -d: -f1); [ -n "$_stop" ] && [ "$_stop" -lt "$_opkg" ] && [ -n "$_restore" ] && [ "$_opkg" -lt "$_restore" ] && echo yes || echo no)"
t "SSH install and removal recheck local opkg metadata" "yes" \
  "$( _install=$(extract_fn "$_ssh_installer" install_sshd); _remove=$(extract_fn "$_ssh_installer" uninstall_sshd); [ "$(printf '%s\n' "$_install" | grep -c 'secure_opkg_metadata')" -ge 1 ] && [ "$(printf '%s\n' "$_remove" | grep -c 'secure_opkg_installed_metadata')" -eq 2 ] && ! printf '%s\n' "$_remove" | grep -q 'require_https_opkg_feeds' && echo yes || echo no)"
t "SSH unit replacement is atomic" "yes" \
  "$( _unit=$(extract_fn "$_ssh_installer" install_sshd_unit); printf '%s\n' "$_unit" | grep -q 'unit_tmp=' && printf '%s\n' "$_unit" | grep -q 'mv -f.*sshd.service' && ! printf '%s\n' "$_unit" | grep -q 'cp -f.* /lib/systemd/system/sshd.service' && echo yes || echo no)"
# A unit restart takes lighttpd with it (PartOf=), so the rules are rebuilt by
# running firewall.sh directly whenever the unit is already up.
t "SSH applies firewall rules without cycling the web server" "yes" \
  "$( _fw=$(extract_fn "$_ssh_installer" apply_firewall); printf '%s\n' "$_fw" | grep -q 'systemctl is-active --quiet firewall' && printf '%s\n' "$_fw" | grep -q 'script/firewall.sh' && printf '%s\n' "$_fw" | grep -q 'systemctl restart firewall' && [ "$(grep -c 'systemctl restart firewall' "$_ssh_installer")" -eq 1 ] && echo yes || echo no)"
t "SSH reconciles firewall rules on every install or update" "yes" \
  "$( _install=$(extract_fn "$_ssh_installer" install_sshd); _uninstall=$(extract_fn "$_ssh_installer" uninstall_sshd); [ "$(printf '%s\n' "$_install" | grep -c '^    if ! apply_firewall; then$')" -eq 1 ] && ! printf '%s\n' "$_install" | grep -q 'need_firewall\|live_port\|live_enabled' && printf '%s\n' "$_uninstall" | grep -q 'apply_firewall' && echo yes || echo no)"
t "SSH removal reports reaching its commit point distinctly" "yes" \
  "$( _uninstall=$(extract_fn "$_ssh_installer" uninstall_sshd); _install=$(extract_fn "$_ssh_installer" install_sshd); printf '%s\n' "$_uninstall" | grep -q 'return "\$RC_PARTIAL_REMOVAL"' && ! printf '%s\n' "$_install" | grep -q 'RC_PARTIAL_REMOVAL' && [ "$(grep -c '^RC_[A-Z_]*=' "$_ssh_installer")" -ge 12 ] && [ "$(grep -oE '^RC_[A-Z_]*=[0-9]+' "$_ssh_installer" | cut -d= -f2 | sort | uniq -d | grep -c .)" -eq 0 ] && echo yes || echo no)"
t "SSH index refresh is separate from every mutating action" "yes" \
  "$( _check=$(extract_fn "$_ssh_installer" check_packages); _install=$(extract_fn "$_ssh_installer" install_sshd); printf '%s\n' "$_check" | grep -q 'opkg update' && ! printf '%s\n' "$_check" | grep -qE 'opkg (install|remove)' && ! printf '%s\n' "$_install" | grep -q 'opkg update' && echo yes || echo no)"
t "SSH console menu refuses a stdin that is not a terminal" "yes" \
  "$( _tty=$(grep -n '\[ -t 0 \] || exit' "$_ssh_installer" | head -1 | cut -d: -f1); _read=$(grep -n 'read -r -p' "$_ssh_installer" | head -1 | cut -d: -f1); [ -n "$_tty" ] && [ -n "$_read" ] && [ "$_tty" -lt "$_read" ] && echo yes || echo no)"
_ssh_prepare_line=$(grep -n 'prepare_ssh_accounts ||' "$_ssh_installer" | cut -d: -f1)
_ssh_install_line=$(grep -n 'opkg install --force-maintainer openssh-server openssh-keygen' "$_ssh_installer" | cut -d: -f1)
_ssh_start_line=$(grep -n 'systemctl restart sshd ||' "$_ssh_installer" | cut -d: -f1)
t "SSH service account is ready before daemon installation and start" "yes" \
  "$([ -n "$_ssh_prepare_line" ] && [ "$_ssh_prepare_line" -lt "$_ssh_install_line" ] && [ "$_ssh_install_line" -lt "$_ssh_start_line" ] && echo yes || echo no)"
unset _ssh_installer _ssh_accounts _sshd_menu _ssh_config _ssh_prepare_line _ssh_install_line _ssh_start_line _install _failure _read _abort _packages _managed _missing

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
t "updater rejects releases before this installation generation" "yes" \
  "$(grep -q '_install_generation_supported' update_quecdeck.sh && grep_all 'requires a clean installation' update_quecdeck.sh quecdeck.sh && echo yes || echo no)"

# The full uninstaller reaps ttyd files left by an older release, so it can
# prepare a device for the clean installation this generation requires.
t "full uninstall removes legacy ttyd files" "yes" \
  "$(grep -q 'rm -f /lib/systemd/system/ttyd.service' quecdeck.sh && grep -q 'rm -f /bin/ttyd' quecdeck.sh && echo yes || echo no)"
t "firmware authentication restoration has its own uninstall result" "yes" \
  "$(grep -q '_show_uninstall_result "Firmware login".*result_auth_restore' quecdeck.sh && ! grep -q 'restore_legacy_auth_commands || result_sshd=' quecdeck.sh && echo yes || echo no)"
t "firmware authentication no-op remains skipped" "yes" \
  "$(grep -q 'RESTORE_LEGACY_AUTH_CHANGED=0' quecdeck.sh && grep -q 'RESTORE_LEGACY_AUTH_CHANGED.*result_auth_restore="RESTORED"' quecdeck.sh && echo yes || echo no)"
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
  "$([ "$(grep -n 'update_sshd_ip.sh' quecdeck/optional/sshd/sshd.service | head -1 | cut -d: -f1)" -lt "$(grep -n 'ssh_access.sh ready' quecdeck/optional/sshd/sshd.service | cut -d: -f1)" ] && echo yes || echo no)"
t "SSH installation creates the root-only enable marker" "yes" \
  "$( _configure=$(sed -n '/^configure_key_only_ssh() (/,/^)/p' quecdeck/script/install_sshd.sh); printf '%s\n' "$_configure" | grep -q 'quecdeck_enabled' && printf '%s\n' "$_configure" | grep -q 'chmod 600' && echo yes || echo no)"

# Entware's rc.unslung runs every S* script in /opt/etc/init.d/ at boot, and each
# opkg postinst RECREATES its own. Left in place, a second daemon starts from
# stock config: lighttpd on 0.0.0.0:80 stealing the port from our LAN-bound
# unit, or an sshd with password auth, no bind fragment and none of the unit's
# gates. Removing before the install is a no-op, so assert the order too. The
# failure only shows up after a reboot, which is how it reached the field once.
t "lighttpd init script is removed after its opkg install" "yes" \
  "$( _b=$(sed -n '/^swap_in_release() {/,/^}/p' update_quecdeck.sh); _o=$(printf '%s\n' "$_b" | grep -n 'opkg install .*_lighttpd_pkgs' | head -1 | cut -d: -f1); _r=$(printf '%s\n' "$_b" | grep -n 'init\.d/\*lighttpd\*' | head -1 | cut -d: -f1); [ -n "$_o" ] && [ -n "$_r" ] && [ "$_o" -lt "$_r" ] && echo yes || echo no)"
t "sshd init script is removed after its opkg install" "yes" \
  "$( _b=$(sed -n '/^install_sshd() {/,/^}/p' quecdeck/script/install_sshd.sh); _o=$(printf '%s\n' "$_b" | grep -n 'opkg install' | head -1 | cut -d: -f1); _r=$(printf '%s\n' "$_b" | grep -n 'remove_entware_sshd_init_scripts' | head -1 | cut -d: -f1); [ -n "$_o" ] && [ -n "$_r" ] && [ "$_o" -lt "$_r" ] && echo yes || echo no)"
t "failed sshd package install still reaps its init script" "yes" \
  "$( _b=$(sed -n '/^install_sshd() {/,/^}/p' quecdeck/script/install_sshd.sh); printf '%s\n' "$_b" | grep -q '^    package_rc=\$?' && ! printf '%s\n' "$_b" | grep -q 'opkg install.*||' && echo yes || echo no)"
t "sshd uninstall reports incomplete package removal" "yes" \
  "$( _b=$(sed -n '/^uninstall_sshd() {/,/^}/p' quecdeck/script/install_sshd.sh); printf '%s\n' "$_b" | grep -q 'opkg remove.*|| package_failed=1' && printf '%s\n' "$_b" | grep -q 'remove_entware_sshd_init_scripts || package_failed=1' && printf '%s\n' "$_b" | grep -q 'if \[ "\$package_failed" -ne 0 \]' && echo yes || echo no)"
# One install site each is what makes one removal site sufficient. A second
# opkg call elsewhere would reintroduce the init script with nothing to reap it.
# Defence in depth for an opkg upgrade done by hand after install: the boot-time
# publishers reap the script too. Must never abort the start, so the removal is
# explicitly non-fatal in scripts where every other failure exits non-zero.
t "lighttpd publisher reaps the Entware init script" "yes" \
  "$(grep -q 'rm -f /opt/etc/init\.d/\*lighttpd\*' quecdeck/script/lighttpd_prestart.sh && grep -q 'rm -f /opt/etc/init\.d/\*lighttpd\*.*||[[:space:]]*:' quecdeck/script/lighttpd_prestart.sh && echo yes || echo no)"
t "sshd publisher reaps the Entware init script" "yes" \
  "$(grep -q 'rm -f /opt/etc/init\.d/\*sshd\*' quecdeck/optional/sshd/update_sshd_ip.sh && grep -q 'rm -f /opt/etc/init\.d/\*sshd\*.*||[[:space:]]*:' quecdeck/optional/sshd/update_sshd_ip.sh && echo yes || echo no)"
t "rc.unslung reaps unmanaged sshd and lighttpd before dispatch" "yes" \
  "$( _pre=$(grep -nF "ExecStartPre=/bin/sh -c 'rm -f /opt/etc/init.d/*sshd* /opt/etc/init.d/*lighttpd*'" installentware.sh | cut -d: -f1); _start=$(grep -nF 'ExecStart=/opt/etc/init.d/rc.unslung start' installentware.sh | cut -d: -f1); [ -n "$_pre" ] && [ -n "$_start" ] && [ "$_pre" -lt "$_start" ] && echo yes || echo no)"
t "Entware removal deletes rc.unslung unit and boot link" "yes" \
  "$( _uninstall=$(extract_fn quecdeck.sh uninstall_entware); printf '%s\n' "$_uninstall" | grep -q 'rm -f /lib/systemd/system/rc.unslung.service' && printf '%s\n' "$_uninstall" | grep -q 'rm -f /lib/systemd/system/multi-user.target.wants/rc.unslung.service' && echo yes || echo no)"
t "lighttpd has exactly one opkg install site" "1" \
  "$(grep -rn 'opkg install' --include=*.sh . | grep -v '^\./tests/' | grep -v ':[[:space:]]*#' | grep -c lighttpd | tr -d ' ')"
t "sshd has exactly one opkg install site" "1" \
  "$(grep -rn 'opkg install' --include=*.sh . | grep -v '^\./tests/' | grep -v ':[[:space:]]*#' | grep -c openssh | tr -d ' ')"
unset _b _o _r
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

# Service status badges go through one helper. Rebuilding the ternary inline is
# how four pages end up with four spellings of the same two states.
t "service badges share one helper" "yes" \
  "$(grep -q '^function serviceBadge' quecdeck/www/js/utils.js && ! grep -q "text-bg-success' : 'text-bg-secondary'" quecdeck/www/*.html && ! grep -q "'Not Installed'" quecdeck/www/*.html quecdeck/www/js/*.js && echo yes || echo no)"
t "deviceinfo routes every service row through the helper" "6" \
  "$(grep -c "serviceState('" quecdeck/www/deviceinfo.html)"
t "panel action rows use one class" "yes" \
  "$(grep -q '^\.panel-actions' quecdeck/www/css/styles.css && ! grep -q 'mt-auto pt-3' quecdeck/www/*.html && echo yes || echo no)"

# Add key is inert until there is something to add. readKeyFile writes the file
# contents into the same publicKey model, so one check covers paste and upload.
t "add key is gated on a usable key" "yes" \
  "$(grep -q 'keys.length >= 5 || !keyReady"' quecdeck/www/ssh.html && grep -q '@input="validateKey()"' quecdeck/www/ssh.html && grep -q 'this.publicKey = text.trim()' quecdeck/www/js/security.js && echo yes || echo no)"
# The browser catches only cheap mistakes. Public-key parsing and duplicate
# detection stay at the root helper, so there is one authoritative rule set.
t "client key check stays preliminary" "yes" \
  "$( _v=$(sed -n '/^    validateKey() {/,/^    },/p' quecdeck/www/js/security.js); printf '%s\n' "$_v" | grep -q '8192' && printf '%s\n' "$_v" | grep -q 'PRIVATE KEY' && ! printf '%s\n' "$_v" | grep -q 'ssh-ed25519\|crypto.subtle' && echo yes || echo no)"
t "root helper owns duplicate-key detection" "yes" \
  "$(grep -q 'exit 6' quecdeck/script/ssh_access.sh && grep -q '6) json_result false \"This SSH key has already been added\"' quecdeck/www/cgi-bin/manage_security && ! grep -q 'crypto.subtle\|fingerprintOf' quecdeck/www/js/security.js && echo yes || echo no)"

t "credential inputs are local and conditional" "yes" \
  "$(grep -q '<template x-if="credentialOpen">' quecdeck/www/ssh.html && [ "$(grep -c 'type="password"' quecdeck/www/ssh.html)" = 2 ] && ! grep -q 'credentialModal\|cred-admin\|cred-dev' quecdeck/www/js/utils.js && echo yes || echo no)"

# A real form submission makes Chromium classify the disappearing password
# fields as a successful credential update. Keep the inputs masked, but submit
# through explicit keyboard/click handlers and clear them before removal.
t "credential dialog does not submit a login-like form" "yes" \
  "$( _c=$(sed -n '/^    closeCredentials() {/,/^    },/p' quecdeck/www/js/security.js); ! grep -q '<form\|type="submit"' quecdeck/www/ssh.html && grep -q '@keydown.enter.prevent="submitCredentials()"' quecdeck/www/ssh.html && grep -q '@click="submitCredentials()"' quecdeck/www/ssh.html && printf '%s\n' "$_c" | grep -q "el.value = ''" && [ "$(printf '%s\n' "$_c" | grep -n "el.value = ''" | cut -d: -f1)" -lt "$(printf '%s\n' "$_c" | grep -n 'credentialOpen = false' | cut -d: -f1)" ] && echo yes || echo no)"

# The file picker fills the textarea and then clears itself, so a key lives in
# exactly one place. Without the reset, editing or emptying the textarea leaves a
# filename on display that does not match what would be submitted.
t "the key file picker resets after loading" "yes" \
  "$( _r=$(sed -n '/^    readKeyFile(event) {/,/^    },/p' quecdeck/www/js/security.js); printf '%s\n' "$_r" | grep -q 'finally' && printf '%s\n' "$_r" | grep -q "input.value = ''" && printf '%s\n' "$_r" | grep -q 'this.validateKey()' && echo yes || echo no)"

# Assert every plain click handler resolves to a controller method.
_handler_missing=0
for _page in quecdeck/www/ssh.html quecdeck/www/security.html; do
    for _fn in $(grep -o '@click="[a-zA-Z_][a-zA-Z0-9_]*(' "$_page" | sed 's/@click="//; s/($//' | sort -u); do
        grep -q "^    $_fn(" quecdeck/www/js/security.js || _handler_missing=1
    done
done
t "every SSH and Security click handler is defined" "0" "$_handler_missing"
unset _handler_missing _page _fn
