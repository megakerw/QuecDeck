# Monitoring host tests. These assert the product contract and a few small pure
# helpers, rather than mirroring each worker's internal control flow.

WATCHCAT=quecdeck/script/watchcat.sh
SCHEDULED=quecdeck/script/scheduled_restart.sh
COORD=quecdeck/script/watchcat-coord.sh
WATCHCAT_MAKER=quecdeck/www/cgi-bin/watchcat_maker
SCHEDULED_MAKER=quecdeck/www/cgi-bin/scheduled_restart_maker

# --------------------------------------------------------- service lifecycle
t "monitoring units are static and boot enabled" "yes" \
  "$(_swap=$(sed -n '/^swap_in_release() {/,/^}/p' update_quecdeck.sh); printf '%s\n' "$_swap" | grep -q 'for _m in watchcat scheduled_restart' && printf '%s\n' "$_swap" | grep -q 'multi-user.target.wants/${_m}.service' && echo yes || echo no)"
t "monitoring workers exit cleanly when inactive" "2" \
  "$(grep -l 'exit 0' "$WATCHCAT" "$SCHEDULED" | wc -l | tr -d ' ')"
t "monitoring workers fail when a required library is missing" "2" \
  "$(_n=0; for _worker in "$WATCHCAT" "$SCHEDULED"; do sed -n '/^for _lib in/,/^done$/p' "$_worker" | grep -q '|| exit 1' && _n=$((_n + 1)); done; echo "$_n")"
t "workers do not contain inactive keepalive loops" "yes" \
  "$(! grep -qE 'wait_inactive|sleep 86400' "$WATCHCAT" "$SCHEDULED" && echo yes || echo no)"

for _unit in watchcat scheduled_restart; do
    t "$_unit restarts only on failure" "on-failure" \
      "$(sed -n 's/^Restart=//p' "quecdeck/systemd/${_unit}.service")"
    t "$_unit has a bounded stop" "5" \
      "$(sed -n 's/^TimeoutStopSec=//p' "quecdeck/systemd/${_unit}.service")"
done

t "monitoring makers use fixed installed services" "yes" \
  "$(grep -q 'systemctl restart watchcat' "$WATCHCAT_MAKER" && grep -q 'systemctl restart scheduled_restart' "$SCHEDULED_MAKER" && ! grep -qE 'create_|remove_' "$WATCHCAT_MAKER" "$SCHEDULED_MAKER" && echo yes || echo no)"
t "every explicit monitoring save reloads its worker" "yes" \
  "$(! grep -q '^needs_restart=' "$WATCHCAT_MAKER" "$SCHEDULED_MAKER" && [ "$(grep -l 'Every explicit save' "$WATCHCAT_MAKER" "$SCHEDULED_MAKER" | wc -l | tr -d ' ')" = "2" ] && echo yes || echo no)"
t "makers clear failed state before restart" "yes" \
  "$(for _maker in "$WATCHCAT_MAKER" "$SCHEDULED_MAKER"; do _reset=$(grep -n 'systemctl reset-failed' "$_maker" | cut -d: -f1); _restart=$(grep -n 'systemctl restart' "$_maker" | cut -d: -f1); [ -n "$_reset" ] && [ "$_reset" -lt "$_restart" ] || exit 1; done && echo yes || echo no)"
t "Watchcat commits config before clearing its old backoff" "yes" \
  "$(_write=$(grep -n 'write_json_config.*new_config' "$WATCHCAT_MAKER" | cut -d: -f1); _clear=$(grep -n 'rm -f .*watchcat_reboot_state' "$WATCHCAT_MAKER" | cut -d: -f1); [ -n "$_write" ] && [ "$_write" -lt "$_clear" ] && echo yes || echo no)"
t "monitoring status endpoints report actual unit state" "2" \
  "$(grep -l 'systemctl is-active.*service_active=true' quecdeck/www/cgi-bin/get_watchcat_status quecdeck/www/cgi-bin/get_scheduled_restart | wc -l | tr -d ' ')"
t "sudo permits every monitoring systemctl command used by CGIs" "" \
  "$(_rule=$(grep '_sudoers_rule=' update_quecdeck.sh); grep -rhoE '/opt/bin/sudo /bin/systemctl [a-z-]+ (watchcat|scheduled_restart)' quecdeck/www/cgi-bin/ | sed 's|/opt/bin/sudo ||' | sort -u | while read -r _cmd; do printf '%s\n' "$_rule" | grep -qF "$_cmd" || printf '%s\n' "$_cmd"; done)"
t "cell scans fail closed when flock is unavailable" "yes" \
  "$(grep -q '^if ! cgi_flock_available; then$' quecdeck/www/cgi-bin/run_cell_scan && grep -q 'Cell scanning requires flock' quecdeck/www/cgi-bin/run_cell_scan && echo yes || echo no)"
t "watchcat maker normalizes decimal numbers" "yes" \
  "$(grep -q 'PING_INTERVAL=.*10#' quecdeck/www/cgi-bin/watchcat_maker \
      && grep -q 'PING_FAILURE_COUNT=.*10#' quecdeck/www/cgi-bin/watchcat_maker && echo yes || echo no)"
t "scheduled restart maker normalizes decimal numbers" "yes" \
  "$(grep -q 'HOUR=.*10#' quecdeck/www/cgi-bin/scheduled_restart_maker \
      && grep -q 'MINUTE=.*10#' quecdeck/www/cgi-bin/scheduled_restart_maker && echo yes || echo no)"

# ------------------------------------------------------------- update/remove
eval "$(extract_fn update_quecdeck.sh stop_monitoring_for_swap)"
_stop_fixture=$(mktemp -d)
_stop_case() {
    (
        mode=$1 MONITORING_UNIT_DIR="$_stop_fixture"
        rm -f "$MONITORING_UNIT_DIR/watchcat.service" "$MONITORING_UNIT_DIR/scheduled_restart.service"
        if [ "$mode" != missing ]; then
            : > "$MONITORING_UNIT_DIR/watchcat.service"
            : > "$MONITORING_UNIT_DIR/scheduled_restart.service"
        fi
        systemctl() {
            case "$1:$2" in
                stop:watchcat) [ "$mode" != stop-fails ] ;;
                stop:scheduled_restart) return 0 ;;
                is-active:watchcat)
                    [ "$mode" = survives ] && { echo active; return 0; }
                    [ "$mode" = missing ] && return 1
                    echo inactive; return 3
                    ;;
                is-active:scheduled_restart)
                    [ "$mode" = missing ] && return 1
                    echo inactive; return 3
                    ;;
                *) return 1 ;;
            esac
        }
        stop_monitoring_for_swap >/dev/null 2>&1
    )
}
_stop_case missing; t_rc "first install has no monitoring to stop" 0 "$?"
_stop_case stopped; t_rc "stopped monitoring permits update" 0 "$?"
_stop_case stop-fails; t_rc "stop failure aborts update" 1 "$?"
_stop_case survives; t_rc "surviving worker aborts update" 1 "$?"
rm -rf "$_stop_fixture"
unset -f stop_monitoring_for_swap _stop_case

eval "$(extract_fn update_quecdeck.sh _restart_monitoring_workers)"
_restart_calls=$(mktemp)
systemctl() {
    printf '%s\n' "$*" >> "$_restart_calls"
    [ "$*" = "restart watchcat" ] && return 1
    return 0
}
_restart_monitoring_workers >/dev/null 2>&1
t_rc "one monitoring restart failure remains a warning" 0 "$?"
t "monitoring recovery attempts both workers after one fails" \
  "$(printf 'reset-failed watchcat\nrestart watchcat\nreset-failed scheduled_restart\nrestart scheduled_restart')" \
  "$(cat "$_restart_calls")"
rm -f "$_restart_calls"
unset -f systemctl _restart_monitoring_workers
unset _restart_calls

_revert=$(sed -n '/^_revert_swap() {/,/^}/p' update_quecdeck.sh)
t "rollback stops both monitoring workers" "2" \
  "$(printf '%s\n' "$_revert" | grep -c 'systemctl stop \(watchcat\|scheduled_restart\)')"
t "a release marker defines the future monitoring contract" "static-services-v1" \
  "$(cat quecdeck/monitoring-generation)"
t "compatible rollback restores monitoring boot enablement" "yes" \
  "$(printf '%s\n' "$_revert" | grep -q 'ln -sf "/lib/systemd/system/${_m}.service" "/lib/systemd/system/multi-user.target.wants/${_m}.service"' && echo yes || echo no)"
t "compatible rollback defers monitoring until update bookkeeping finishes" "yes" \
  "$(! printf '%s\n' "$_revert" | grep -q 'systemctl restart.*\$_m' && printf '%s\n' "$_revert" | grep -q 'restarted only after the updater' && echo yes || echo no)"
t "legacy rollback removes monitoring enablement" "yes" \
  "$(printf '%s\n' "$_revert" | grep -q 'Legacy monitoring was left disabled after rollback' && printf '%s\n' "$_revert" | grep -q 'rm -f "/lib/systemd/system/multi-user.target.wants/${_m}.service"' && echo yes || echo no)"
unset _revert

_stage=$(sed -n '/^_stage_persistent_state() {/,/^}/p' update_quecdeck.sh)
t "legacy monitoring state is discarded during staging" "4" \
  "$(printf '%s\n' "$_stage" | grep -c 'staged_var/\(watchcat.json\|watchcat_reboot_state.json\|scheduled_restart.json\|restart_log.jsonl\)')"
t "compatible monitoring state is identified by the explicit marker" "yes" \
  "$(printf '%s\n' "$_stage" | grep -q 'cmp -s.*monitoring-generation' && echo yes || echo no)"
unset _stage

_uninstall=$(sed -n '/^uninstall_quecdeck_components() {/,/^}/p' quecdeck.sh)
t "uninstaller always removes both monitoring services" "2" \
  "$(printf '%s\n' "$_uninstall" | grep -c '^    remove_monitoring_unit \(watchcat\|scheduled_restart\)$')"
t "uninstaller removes the release tree after monitoring" "yes" \
  "$(_monitor=$(printf '%s\n' "$_uninstall" | grep -n 'remove_monitoring_unit watchcat' | cut -d: -f1); _tree=$(printf '%s\n' "$_uninstall" | grep -n 'rm -rf "\$QUECDECK_DIR"' | cut -d: -f1); [ -n "$_monitor" ] && [ "$_monitor" -lt "$_tree" ] && echo yes || echo no)"
unset _uninstall

# ---------------------------------------------------------- pause coordination
eval "$(extract_fn "$COORD" watchcat_uptime)"
eval "$(extract_fn "$COORD" watchcat_atomic_write)"
eval "$(extract_fn "$COORD" watchcat_pause)"
eval "$(extract_fn "$COORD" watchcat_pause_for_disruption)"
eval "$(extract_fn "$COORD" watchcat_resume)"
eval "$(extract_fn "$COORD" watchcat_is_paused)"
_pause_fixture=$(mktemp -d)
WATCHCAT_PAUSE_DIR="$_pause_fixture/markers"
WATCHCAT_MAX_PAUSE=300
_real_uptime=$(watchcat_uptime)
watchcat_pause scan 60; t_rc "pause marker publishes" 0 "$?"
watchcat_is_paused; t_rc "published marker pauses Watchcat" 0 "$?"
watchcat_resume scan; watchcat_is_paused; t_rc "resume removes the pause" 1 "$?"
watchcat_pause '../escape' 60; t_rc "pause names cannot escape the marker directory" 1 "$?"
watchcat_pause oversized 301; t_rc "pause requests cannot exceed five minutes" 1 "$?"
systemctl() { printf '%s\n' "${WATCHCAT_TEST_STATE:-unknown}"; }
WATCHCAT_TEST_STATE=inactive
watchcat_pause_for_disruption inactive 60
t_rc "inactive Watchcat accepts a disruption marker" 0 "$?"
t "inactive Watchcat is not reported paused" false "$WATCHCAT_WAS_ACTIVE"
t "inactive Watchcat is protected from a concurrent start" yes "$([ -e "$WATCHCAT_PAUSE_DIR/inactive" ] && echo yes || echo no)"
watchcat_resume inactive
WATCHCAT_TEST_STATE=active
watchcat_pause_for_disruption active 60
t_rc "active Watchcat requires a pause marker" 0 "$?"
t "active Watchcat is reported paused" true "$WATCHCAT_WAS_ACTIVE"
t "active Watchcat publishes a marker" yes "$([ -e "$WATCHCAT_PAUSE_DIR/active" ] && echo yes || echo no)"
watchcat_resume active
WATCHCAT_TEST_STATE=unknown
watchcat_pause_for_disruption unknown 60
t_rc "unknown Watchcat state fails safe with a marker" 0 "$?"
t "unknown Watchcat state publishes a marker" yes "$([ -e "$WATCHCAT_PAUSE_DIR/unknown" ] && echo yes || echo no)"
watchcat_resume unknown
unset -f systemctl
mkdir -p "$WATCHCAT_PAUSE_DIR"
printf '%s\n' "$((_real_uptime - 1))" > "$WATCHCAT_PAUSE_DIR/expired"
watchcat_is_paused; t_rc "expired marker does not pause Watchcat" 1 "$?"
t "expired marker is removed" "no" "$([ -e "$WATCHCAT_PAUSE_DIR/expired" ] && echo yes || echo no)"
printf '%s\n' "$((_real_uptime + 600))" > "$WATCHCAT_PAUSE_DIR/oversized"
watchcat_is_paused; t_rc "oversized marker does not pause Watchcat" 1 "$?"
t "oversized marker is removed" "no" "$([ -e "$WATCHCAT_PAUSE_DIR/oversized" ] && echo yes || echo no)"
rm -rf "$_pause_fixture"
unset -f watchcat_uptime watchcat_atomic_write watchcat_pause watchcat_pause_for_disruption watchcat_resume watchcat_is_paused

t "modem disruptions use pause markers" "yes" \
  "$(grep -q 'watchcat_pause_for_disruption scan' quecdeck/www/cgi-bin/run_cell_scan && grep -q 'watchcat_resume scan' quecdeck/www/cgi-bin/run_cell_scan && grep -q 'watchcat_pause_for_disruption "$_pause_id"' quecdeck/www/cgi-bin/save_apn && echo yes || echo no)"
t "scan fails closed if its pause cannot be published" "yes" \
  "$(sed -n '/^watchcat_pause_for_disruption scan/,/^fi$/p' quecdeck/www/cgi-bin/run_cell_scan | grep -q '500 Internal Server Error' && echo yes || echo no)"
t "APN reconnect fails closed if its pause cannot be published" "yes" \
  "$(_apn=quecdeck/www/cgi-bin/save_apn; _pause=$(grep -n 'watchcat_pause_for_disruption' "$_apn" | cut -d: -f1); _spawn=$(grep -n '^    ($' "$_apn" | cut -d: -f1); [ -n "$_pause" ] && [ "$_pause" -lt "$_spawn" ] && grep -q 'WARNING: Settings saved' "$_apn" && grep -q 'text.includes("WARNING:")' quecdeck/www/js/network.js && echo yes || echo no)"
_apn_fixture=$(mktemp -d)
_apn_mock="$_apn_fixture/cgi-lib.sh"
_apn_runner="$_apn_fixture/save_apn"
_apn_calls="$_apn_fixture/at.calls"
cp quecdeck/www/cgi-bin/save_apn "$_apn_runner"
sed -i "s|^\. /usrdata/quecdeck/script/cgi-lib.sh$|. $_apn_mock|" "$_apn_runner"
cat > "$_apn_mock" <<'EOF'
cgi_require_post() { :; }
cgi_read_post() { read -r POST_DATA || true; }
get_post_param() {
    case "$1" in
        apn) printf test.apn ;;
        ip_type) printf IP ;;
        action) printf reconnect ;;
    esac
}
cgi_output_text() { printf 'Content-Type: text/plain\r\n\r\n'; }
cgi_error() { printf '%s\n' "$1"; exit 1; }
atcmd_run() { printf '%s\n' "$1" >> "$APN_TEST_CALLS"; printf 'OK\n'; }
atcmd_fire() { printf '%s\n' "$1" >> "$APN_TEST_CALLS"; }
at_result() { printf '%s\n' "$1"; }
at_response_ok() { printf '%s\n' "$1" | grep -qx OK; }
cache_invalidate() { :; }
watchcat_pause_for_disruption() { return 1; }
_CACHE_MODEM_ALL=all
_CACHE_NETWORK=network
_CACHE_MODEM_CONN=modem
EOF
_apn_output=$(printf 'ignored=1\n' | APN_TEST_CALLS="$_apn_calls" bash "$_apn_runner")
t "failed APN pause returns a partial-success warning" yes \
  "$(printf '%s\n' "$_apn_output" | grep -q 'WARNING: Settings saved' && echo yes || echo no)"
t "failed APN pause applies settings without disrupting the modem" \
  'AT+CGDCONT=1,"IP","test.apn"' "$(cat "$_apn_calls")"
rm -rf "$_apn_fixture"
unset _apn_fixture _apn_mock _apn_runner _apn_calls _apn_output
t "reboot lease protocol has been removed" "yes" \
  "$(! grep -qE 'REBOOT_LEASE|claim_reboot|release_reboot|reboot_in_progress' "$COORD" "$WATCHCAT" quecdeck/www/cgi-bin/run_cell_scan quecdeck/www/cgi-bin/save_apn && echo yes || echo no)"

# ---------------------------------------------------------- Watchcat behavior
t "Watchcat accepts the UI ranges" "yes" \
  "$(grep -q 'PING_INTERVAL.*-ge 10.*-le 600' "$WATCHCAT" && grep -q 'PING_FAILURE_COUNT.*-ge 3.*-le 10' "$WATCHCAT" && echo yes || echo no)"
t "Watchcat caps targets at six" "yes" \
  "$(grep -q 'head -6' "$WATCHCAT" && echo yes || echo no)"
t "Watchcat rotates the first target and stops on success" "yes" \
  "$(_ping=$(extract_fn "$WATCHCAT" ping_round); printf '%s\n' "$_ping" | grep -q 'round_start + offset' && printf '%s\n' "$_ping" | grep -q 'round_start=.*round_start + 1' && printf '%s\n' "$_ping" | grep -q 'return 0' && echo yes || echo no)"
eval "$(extract_fn "$WATCHCAT" ping_round)"
TRACK_IPS_ARRAY=(a b c); target_count=3; round_start=0; misses=(-1 -1 -1); PING_TIMEOUT=3
_ping_log=$(mktemp)
ping() { printf '%s\n' "${@: -1}" >> "$_ping_log"; return 0; }
ping_round; ping_round; ping_round; ping_round
t "successful rounds cycle through every target" "$(printf 'a\nb\nc\na')" "$(cat "$_ping_log")"
rm -f "$_ping_log"
unset -f ping ping_round
unset TRACK_IPS_ARRAY target_count round_start misses _ping_log overall_success
t "Watchcat stats retain the UI contract" "yes" \
  "$(_stats=$(extract_fn "$WATCHCAT" write_stats); for _field in stats consecutive_failures reboot_count failure_threshold retry_after paused; do printf '%s\n' "$_stats" | grep -qF "\\\"${_field}\\\"" || exit 1; done && echo yes || echo no)"
t "Watchcat checks pauses at round and reboot boundaries" "yes" \
  "$([ "$(grep -c 'watchcat_is_paused' "$WATCHCAT")" -ge 3 ] && echo yes || echo no)"
t "Watchcat backoff uses uptime rather than wall time" "yes" \
  "$(_attempt=$(extract_fn "$WATCHCAT" attempt_reboot); printf '%s\n' "$_attempt" | grep -q 'get_uptime' && ! printf '%s\n' "$_attempt" | grep -q 'date ' && echo yes || echo no)"
t "backoff persistence is mandatory only when enabled" "yes" \
  "$(_attempt=$(extract_fn "$WATCHCAT" attempt_reboot); printf '%s\n' "$_attempt" | grep -q '\[ "$REBOOT_BACKOFF" = "1" \] && ! save_reboot_state' && echo yes || echo no)"
t "Watchcat appends normally and resets history past 100 entries" "yes" \
  "$(_log=$(extract_fn "$WATCHCAT" log_restart); printf '%s\n' "$_log" | grep -q 'wc -l' && printf '%s\n' "$_log" | grep -q '\[ "$count" -le 100 \] || watchcat_atomic_write' && ! printf '%s\n' "$_log" | grep -q 'tail -n' && echo yes || echo no)"
eval "$(extract_fn "$COORD" watchcat_atomic_write)"
eval "$(extract_fn "$WATCHCAT" log_restart)"
_log_fixture=$(mktemp -d)
RESTART_LOG="$_log_fixture/restart.jsonl" LOG_RESTARTS=1 BOOT_ID=test-boot
get_uptime() { echo 42; }
for _i in $(seq 1 99); do printf '{"old":%s}\n' "$_i"; done > "$RESTART_LOG"
log_restart hundred
t "the hundredth log entry is appended without rewriting history" "100" \
  "$(wc -l < "$RESTART_LOG" | tr -d ' ')"
log_restart newest
t "the hundred-and-first log entry clears old history" "1" \
  "$(wc -l < "$RESTART_LOG" | tr -d ' ')"
t "history reset retains the newest event" "yes" \
  "$(grep -q '"detail":"newest"' "$RESTART_LOG" && echo yes || echo no)"
rm -rf "$_log_fixture"
unset -f watchcat_atomic_write log_restart get_uptime
unset RESTART_LOG LOG_RESTARTS BOOT_ID
t "SIM absence suppresses reboot but unknown SIM state does not" "yes" \
  "$(_attempt=$(extract_fn "$WATCHCAT" attempt_reboot); printf '%s\n' "$_attempt" | grep -q '\[ "$sim_state" = "1" \]' && printf '%s\n' "$_attempt" | grep -q '\[ "$sim_state" = "2" \].*Continuing' && echo yes || echo no)"
t "modem reboot has one fire-and-forget path per worker" "2" \
  "$(grep -h -c "atcmd_fire 'AT+CFUN=1,1'" "$WATCHCAT" "$SCHEDULED" | awk '{n+=$1} END {print n}')"

eval "$(extract_fn "$WATCHCAT" calc_backoff_delay)"
REBOOT_BACKOFF=1 PING_FAILURE_COUNT=3 PING_INTERVAL=10 MAX_REBOOT_INTERVAL=7200
reboot_count=1; calc_backoff_delay; t "first backoff doubles the evidence window" 60 "$backoff_delay"
reboot_count=20; calc_backoff_delay; t "backoff is capped" 7200 "$backoff_delay"
REBOOT_BACKOFF=0; calc_backoff_delay; t "disabled backoff adds no delay" 0 "$backoff_delay"
unset -f calc_backoff_delay

# --------------------------------------------------- Scheduled Restart behavior
t "scheduled restart rejects invalid day and time ranges" "yes" \
  "$(grep -q 'RESTART_DAY.*-ge 1.*-le 7' "$SCHEDULED" && grep -q 'RESTART_HOUR.*-ge 0.*-le 23' "$SCHEDULED" && grep -q 'RESTART_MINUTE.*-ge 0.*-le 59' "$SCHEDULED" && echo yes || echo no)"
t "scheduled restart waits for a plausible wall clock" "yes" \
  "$(grep -q '^CLOCK_FLOOR=' "$SCHEDULED" && grep -q 'now_epoch.*-lt.*CLOCK_FLOOR' "$SCHEDULED" && echo yes || echo no)"
t "scheduled restart dispatches once per occurrence" "yes" \
  "$(grep -q '^last_occurrence=$' "$SCHEDULED" && grep -q 'occurrence.*!=.*last_occurrence' "$SCHEDULED" && grep -q 'last_occurrence=$occurrence' "$SCHEDULED" && echo yes || echo no)"
t "failed scheduled dispatch moves beyond the matching minute" "yes" \
  "$(grep -A5 "atcmd_fire 'AT+CFUN=1,1'" "$SCHEDULED" | grep -q 'sleep 90' && echo yes || echo no)"
t "scheduled restart skips a matching startup minute" "yes" \
  "$(grep -q '^startup_check=1$' "$SCHEDULED" && grep -q 'matching startup minute skipped' "$SCHEDULED" && grep -q '^    startup_check=0$' "$SCHEDULED" && echo yes || echo no)"
t "system status verifies the scheduled worker is running" "yes" \
  "$(grep '^SERVICE_UNITS=' quecdeck/www/cgi-bin/get_system_status | grep -q 'scheduled_restart' && grep -q 'state_scheduled_restart.*active' quecdeck/www/cgi-bin/get_system_status && grep -q 'scheduled_restart.running' quecdeck/www/deviceinfo.html && echo yes || echo no)"

unset WATCHCAT SCHEDULED COORD WATCHCAT_MAKER SCHEDULED_MAKER
