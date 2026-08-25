# Updater host tests.
# Sourced by tests/host/run-tests.sh.

# --------------------------------------------- updater pure helpers --------
# The updater's install phase is now plain committed code (no generated
# heredoc), so its pure helpers can be extracted and tested directly.
eval "$(extract_fn update_quecdeck.sh _tag_to_version)"
# v-strip for the version file. Regression guard for the bug the de-heredoc
# equivalence diff caught (would have written "v1.0.15" instead of "1.0.15").
t "tag_to_version strips v"   "1.0.15" "$(_tag_to_version v1.0.15)"
t "tag_to_version idempotent" "1.0.15" "$(_tag_to_version 1.0.15)"
t "tag_to_version branch"     "main"   "$(_tag_to_version main)"

eval "$(extract_fn update_quecdeck.sh _version_lt)"
# Downgrade guard compare, numeric per field rather than lexical (1.0.9 < 1.0.10).
_version_lt 1.0.9  1.0.10; t_rc "version_lt numeric not lexical" "0" "$?"
_version_lt 1.0.10 1.0.9;  t_rc "version_lt greater patch"      "1" "$?"
_version_lt 1.0.5  1.0.5;  t_rc "version_lt equal"              "1" "$?"
_version_lt 1.9.9  2.0.0;  t_rc "version_lt major"              "0" "$?"
_version_lt 2.0.0  1.9.9;  t_rc "version_lt greater major"      "1" "$?"
_version_lt 1.2.3  1.10.0; t_rc "version_lt minor numeric"      "0" "$?"

eval "$(extract_fn update_quecdeck.sh _normalize_bind)"
# Both the live-IP-patched and repo (0.0.0.0) conf must normalize identically,
# or a mere IP patch forces an unnecessary lighttpd restart during updates.
t "normalize_bind LAN ip"    'server.bind = "0.0.0.0"'              "$(printf 'server.bind = "192.168.225.1"\n' | _normalize_bind)"
t "normalize_bind 443 sock"  '$SERVER["socket"] == "0.0.0.0:443" {' "$(printf '$SERVER["socket"] == "192.168.8.1:443" {\n' | _normalize_bind)"

# Persistent state is copied before the live tree moves. Exercise every
# mandatory boundary with real fixture data and injected command failures.
eval "$(extract_fn update_quecdeck.sh _stage_persistent_state)"
_state_fixture=$(mktemp -d)
_state_case() { # _state_case <ok|mkdir|cp|rm|chown|chmod|incompatible>
    (
        mode=$1
        QUECDECK_DIR="$_state_fixture/source.$mode"
        STAGE_DIR="$_state_fixture/stage.$mode"
        command mkdir -p "$QUECDECK_DIR/var" "$STAGE_DIR"
        printf '%s\n' static-services-v1 > "$QUECDECK_DIR/monitoring-generation"
        if [ "$mode" = incompatible ] || [ "$mode" = rm ]; then
            printf '%s\n' static-services-v2 > "$STAGE_DIR/monitoring-generation"
        else
            printf '%s\n' static-services-v1 > "$STAGE_DIR/monitoring-generation"
        fi
        printf '%s\n' '{"enabled":true,"sentinel":"preserved bytes"}' > "$QUECDECK_DIR/var/watchcat.json"

        mkdir() { [ "$mode" = mkdir ] && return 1; command mkdir "$@"; }
        cp() { [ "$mode" = cp ] && return 1; command cp "$@"; }
        rm() { [ "$mode" = rm ] && return 1; command rm "$@"; }
        chown() { [ "$mode" = chown ] && return 1; return 0; }
        chmod() { [ "$mode" = chmod ] && return 1; return 0; }

        _monitoring_rollback_supported=0
        _stage_persistent_state >/dev/null 2>&1
        rc=$?
        body=$(command cat "$STAGE_DIR/var/watchcat.json" 2>/dev/null)
        [ -e "$STAGE_DIR/var/watchcat.json" ] && exists=yes || exists=no
        printf '%s|%s|%s|%s\n' "$rc" "$body" "$_monitoring_rollback_supported" "$exists"
    )
}
t "state staging preserves compatible bytes" \
  '0|{"enabled":true,"sentinel":"preserved bytes"}|1|yes' "$(_state_case ok)"
for _boundary in mkdir cp chown chmod; do
    t "state staging fails when $_boundary fails" "1" "$(_state_case "$_boundary" | cut -d'|' -f1)"
done
t "incompatible monitoring state is removed" "0||0|no" "$(_state_case incompatible)"
t "failure to remove incompatible monitoring state aborts staging" "1" "$(_state_case rm | cut -d'|' -f1)"
rm -rf "$_state_fixture"
unset -f _stage_persistent_state _state_case

# The root-owned status file is the one outcome source for both CLI and web.
# systemctl's rc appears only in diagnostics when no valid terminal status was
# committed. It never overrides a committed result.
LOG_FILE=/run/quecdeck/install.log
eval "$(extract_fn update_quecdeck.sh report_install_outcome)"
for _status in failed failed:rollback_ok failed:rollback_failed running '' unexpected; do
    report_install_outcome "$_status" 0 >/dev/null
    t_rc "update outcome rejects '${_status:-missing}'" "1" "$?"
done
report_install_outcome done 1 >/dev/null
t_rc "done status overrides systemctl failure" "0" "$?"
t "bootstrap replaces stale status before systemctl" "yes" \
  "$(_status_line=$(grep -n 'Replace any terminal status from an earlier run' update_quecdeck.sh | cut -d: -f1); _start_line=$(grep -n '^systemctl start \$SERVICE_NAME$' update_quecdeck.sh | cut -d: -f1); [ -n "$_status_line" ] && [ "$_status_line" -lt "$_start_line" ] && echo yes || echo no)"
t "install phase returns computed outcome" "yes" \
  "$(grep -q '^exit "\$_install_rc"$' update_quecdeck.sh && echo yes || echo no)"
t "invalid bootstrap status is committed as failed" "yes" \
  "$(sed -n '/^_final_status=/,$p' update_quecdeck.sh | grep -q 'echo "failed" > "${STATUS_FILE}.tmp"' && echo yes || echo no)"
t "web fetch rejection uses terminal abort" "yes" \
  "$(grep -q 'systemctl start --no-block install_quecdeck_fetch.*|| abort' quecdeck/script/run_update.sh && echo yes || echo no)"
t "installer refuses failed rw remount" "yes" \
  "$(grep -q '^if ! remount_rw; then$' update_quecdeck.sh && echo yes || echo no)"
t "forward unit copy is rollback-gated" "yes" \
  "$(grep -q '^    if ! cp -rf "\$QUECDECK_DIR/systemd/"\* /lib/systemd/system/; then$' update_quecdeck.sh && echo yes || echo no)"
t "rollback requires old-tree move" "yes" \
  "$(sed -n '/^_revert_swap() {/,/^}/p' update_quecdeck.sh | grep -q 'mv "\$OLD_DIR" "\$QUECDECK_DIR" ||' && echo yes || echo no)"
t "rollback requires firewall recovery" "yes" \
  "$(sed -n '/^_revert_swap() {/,/^}/p' update_quecdeck.sh | grep -q 'systemctl restart firewall.*||' && echo yes || echo no)"

# Exercise the real rollback function with command failures injected at each
# mandatory recovery boundary. Optional service failures must remain warnings.
eval "$(extract_fn update_quecdeck.sh _revert_swap)"
_rollback_fixture=$(mktemp -d)
mkdir -p "$_rollback_fixture/old"
_rollback_case() { # _rollback_case <failure-point> [monitoring-compatible] -> rc:completion-marker
    (
        _fail=$1
        _monitoring_rollback_supported=${2:-0}
        OLD_DIR="$_rollback_fixture/old"
        QUECDECK_DIR="$_rollback_fixture/current"
        _sudoers_prev=""
        _newly_introduced_units=""
        rm() { return 0; }
        mv() { [ "$_fail" = move ] && return 1; return 0; }
        cp() {
            case "$*" in
                *systemd*) [ "$_fail" = unit-copy ] && return 1 ;;
            esac
            return 0
        }
        chmod() { return 0; }
        ln() { [ "$_fail" = unit-link ] && return 1; return 0; }
        systemctl() {
            printf '%s\n' "$*" >> "$_rollback_fixture/calls"
            case "$*" in
                "daemon-reload")       [ "$_fail" = daemon-reload ] && return 1 ;;
                "restart firewall")    [ "$_fail" = firewall ] && return 1 ;;
                "start lighttpd")      [ "$_fail" = lighttpd ] && return 1 ;;
                "restart atcmd-daemon"|"restart connection-logger")
                    [ "$_fail" = optional ] && return 1 ;;
                "restart watchcat"|"restart scheduled_restart")
                    [ "$_fail" = monitoring ] && return 1 ;;
            esac
            return 0
        }
        _out=$(_revert_swap 2>&1); _rc=$?
        _marker=$(printf '%s\n' "$_out" | grep -c 'Rollback complete')
        printf '%s:%s\n' "$_rc" "$_marker"
    )
}

# _revert_swap stops both workers before moving the tree and leaves them stopped
# on every path. Compatible monitoring is restarted by the install phase only
# after rollback status and filesystem bookkeeping are complete.
_rollback_restarted_workers() { # _rollback_restarted_workers <failure-point> [compatible]
    rm -f "$_rollback_fixture/calls"
    _rollback_case "$1" "${2:-0}" >/dev/null
    # Not `grep -c ... || echo 0`: grep prints 0 AND exits 1 on no match, so the
    # fallback fires too and the count comes back as two lines.
    _n=$(grep -c '^restart watchcat$' "$_rollback_fixture/calls" 2>/dev/null)
    echo "${_n:-0}"
}
for _failure in move unit-copy unit-link daemon-reload firewall lighttpd; do
    t "a rollback failing at $_failure starts no watchdog" "0" \
      "$(_rollback_restarted_workers "$_failure" 1)"
done
t "a completed legacy rollback leaves the watchdog stopped" "0" \
  "$(_rollback_restarted_workers optional 0)"
t "a completed compatible rollback keeps the watchdog stopped for bookkeeping" "0" \
  "$(_rollback_restarted_workers optional 1)"
unset -f _rollback_restarted_workers
for _failure in move unit-copy unit-link daemon-reload firewall lighttpd; do
    t "rollback fails closed on $_failure" "1:0" "$(_rollback_case "$_failure")"
done
t "rollback tolerates optional-service failure" "0:1" "$(_rollback_case optional)"
t "compatible rollback completes with monitoring deferred" "0:1" \
  "$(_rollback_case none 1)"
rm -rf "$_rollback_fixture"
t "web updater requires initial status write" "yes" \
  "$(grep -q '^if ! write_status running; then$' quecdeck/script/run_update.sh && echo yes || echo no)"
t "web updater requires log preparation" "yes" \
  "$(grep -q '^if ! : > "\$LOG" || ! chmod 644 "\$LOG"; then$' quecdeck/script/run_update.sh && echo yes || echo no)"
t "web updater requires fetch-unit reload" "yes" \
  "$(grep -q '^systemctl daemon-reload || abort ' quecdeck/script/run_update.sh && echo yes || echo no)"
t "bootstrap requires install-unit reload" "yes" \
  "$(grep -q '^systemctl daemon-reload || _bootstrap_abort ' update_quecdeck.sh && echo yes || echo no)"
t "preflight rejects unreadable run capacity" "yes" \
  "$(sed -n '/_pf_run_free=/,/Not enough free space on \/run/p' update_quecdeck.sh | grep -q "''|\*\[!0-9\]\*)" && echo yes || echo no)"
t "preflight rejects unreadable usrdata capacity" "yes" \
  "$(sed -n '/_pf_free=/,/Not enough free space on \/usrdata/p' update_quecdeck.sh | grep -q "''|\*\[!0-9\]\*)" && echo yes || echo no)"
t "preflight reserves runtime headroom" "yes" \
  "$(grep -q '_pf_run_needed=\$((_pf_run_needed + 1024))' update_quecdeck.sh && echo yes || echo no)"
t "all updater status renames normalize mode" "0" \
  "$(grep 'mv .*STATUS_FILE' update_quecdeck.sh | grep -vc 'chmod 644')"
t "successful install requires read-only remount" "yes" \
  "$(sed -n '/rm -f "\$SERVICE_FILE" \/lib\/systemd\/system\/install_quecdeck.service/,/exit "\$_install_rc"/p' update_quecdeck.sh | grep -q '^if ! remount_ro; then$' && echo yes || echo no)"
t "atcli uses its installed path in the release tree" "yes" \
  "$([ -f quecdeck/atcli ] && [ ! -e quecdeck/bin/atcli ] && echo yes || echo no)"
t "release manifest uses the installed atcli path once" "1:0" \
  "$(printf '%s:%s\n' "$(grep -cE '^[a-f0-9]{64} \*quecdeck/atcli$' quecdeck/checksums.sha256)" "$(grep -cE '^[a-f0-9]{64} \*quecdeck/bin/atcli$' quecdeck/checksums.sha256)")"
t "updater does not relocate or remap atcli" "yes" \
  "$(! grep -qE 'STAGE_DIR/bin/atcli|bin/atcli\).*STAGE_DIR/atcli' update_quecdeck.sh && echo yes || echo no)"
t "updater rejects files absent from manifest" "yes" \
  "$(grep -q 'find "\$STAGE_DIR".*-type f.*-type l' update_quecdeck.sh && grep -q 'diff -u "\$_manifest_inventory" "\$_stage_inventory"' update_quecdeck.sh && echo yes || echo no)"
t "CI enforces release manifest inventory" "yes" \
  "$(grep -q 'git ls-files quecdeck' tests/host/ci-checks.sh && grep -q 'manifest inventory does not cover exactly' tests/host/ci-checks.sh && echo yes || echo no)"
t "pre-commit enforces staged release inventory" "yes" \
  "$(grep -q 'git ls-files --cached quecdeck' .githooks/pre-commit && grep -q 'CHECKSUMMED_FILES must cover every tracked' .githooks/pre-commit && echo yes || echo no)"
t "updater health probe avoids blocked loopback HTTP" "yes" \
  "$(! sed -n '/^    _probe_site() {/,/^    }/p' update_quecdeck.sh | grep -q 'wget' && echo yes || echo no)"
t "updater health probe exercises auth CGI as web uid" "yes" \
  "$( _probe_src=$(sed -n '/^    _probe_site() {/,/^    }/p' update_quecdeck.sh); printf '%s\n' "$_probe_src" | grep -q 'su www-data' && printf '%s\n' "$_probe_src" | grep -q 'auth_login' && echo yes || echo no)"
_at_probe=$(sed -n '/systemctl restart atcmd-daemon/,/systemctl restart connection-logger/p' update_quecdeck.sh)
t "AT daemon health probe tolerates one systemd restart" "yes" \
  "$(printf '%s\n' "$_at_probe" | grep -q '_at_probe_attempt.*-lt 10' && printf '%s\n' "$_at_probe" | grep -q "atcmd_run 'AT' 1000" && ! printf '%s\n' "$_at_probe" | grep -q 'sleep 2' && echo yes || echo no)"
unset _at_probe
t "updater health probe requires lighttpd-owned LAN HTTPS socket" "yes" \
  "$( _probe_src=$(sed -n '/^    _probe_site() {/,/^    }/p' update_quecdeck.sh); printf '%s\n' "$_probe_src" | grep -q 'systemctl show -p MainPID' && printf '%s\n' "$_probe_src" | grep -q '_health_hex:01BB' && printf '%s\n' "$_probe_src" | grep -q 'socket:\[\$_https_inode\]' && echo yes || echo no)"
t "pre-swap failures restore previously active services" "yes" \
  "$([ "$(grep -c '^[[:space:]]*_restore_pre_swap_services$' update_quecdeck.sh)" -ge 4 ] && grep -q '^_restore_pre_swap_services()' update_quecdeck.sh && echo yes || echo no)"
t "stage_release requires persistent-state staging" "yes" \
  "$(sed -n '/^stage_release() {/,/^}/p' update_quecdeck.sh | grep -q '^    _stage_persistent_state || return 1$' && echo yes || echo no)"
t "monitoring restarts only after update bookkeeping" "yes" \
  "$(_restart=$(grep -n '^    _restart_monitoring_workers$' update_quecdeck.sh | tail -1 | cut -d: -f1); _remount=$(grep -n '^if ! remount_ro; then$' update_quecdeck.sh | tail -1 | cut -d: -f1); _swap=$(sed -n '/^swap_in_release() {/,/^}/p' update_quecdeck.sh); [ -n "$_restart" ] && [ "$_restart" -gt "$_remount" ] && ! printf '%s\n' "$_swap" | grep -q '_restart_monitoring_workers' && echo yes || echo no)"
t "interrupted compatible rollback restarts monitoring after remount" "yes" \
  "$(_cleanup=$(sed -n '/^_update_cleanup() {/,/^}/p' update_quecdeck.sh); _remount=$(printf '%s\n' "$_cleanup" | grep -n 'if remount_ro' | cut -d: -f1); _restart=$(printf '%s\n' "$_cleanup" | grep -n '_restart_monitoring_workers' | cut -d: -f1); printf '%s\n' "$_cleanup" | grep -q '_monitoring_rollback_supported' && [ -n "$_remount" ] && [ "$_restart" -gt "$_remount" ] && echo yes || echo no)"
t "monitoring boot-link failure aborts the forward swap" "yes" \
  "$(sed -n '/for _m in watchcat scheduled_restart/,/done/p' update_quecdeck.sh | head -20 | grep -q 'FATAL: Could not enable' && echo yes || echo no)"
t "pre-commit loads runtime guard from staged index" "yes" \
  "$(sed -n '/tmpguard_defs=$(mktemp)/,/rm -f "\$tmpguard_defs"/p' .githooks/pre-commit | grep -q 'git show :tests/host/guards/runtime-path.sh' && echo yes || echo no)"
t "uninstall requires writable remount first" "yes" \
  "$(sed -n '/^uninstall_quecdeck_components() {/,/# Remove any transient update unit/p' quecdeck.sh | grep -q '^    if ! remount_rw; then$' && echo yes || echo no)"
t "uninstall refuses to race active update units" "2" \
  "$(sed -n '/^uninstall_quecdeck_components() {/,/echo.*Uninstalling QuecDeck/p' quecdeck.sh | grep -o 'install_quecdeck\(_fetch\)\?' | sort -u | wc -l | tr -d ' ')"
t "normalize_bind untouched" 'server.port = 80'                     "$(printf 'server.port = 80\n' | _normalize_bind)"
