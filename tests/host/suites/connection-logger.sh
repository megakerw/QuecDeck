#!/bin/bash
# Connection logger parser, transition, persistence, and writer contracts.

_conn_fixture=$(mktemp -d)
QUECDECK_SCRIPT_DIR=quecdeck/script
CONNECTION_LOGGER_LIB_ONLY=1
CONNECTION_LOG_FILE=$_conn_fixture/events.jsonl
STATE_FILE=$_conn_fixture/state
BOOT_ID_FILE=$_conn_fixture/boot_id
UPTIME_FILE=$_conn_fixture/uptime
SCAN_ACTIVE_FILE=$_conn_fixture/scan.active
SCAN_SETTLE_FILE=$_conn_fixture/scan.settle
printf 'test-boot\n' > "$BOOT_ID_FILE"
printf '100.00 0.00\n' > "$UPTIME_FILE"
_conn_stub_flock=0
if ! command -v flock >/dev/null 2>&1; then
  _conn_stub_flock=1
  flock() { return 0; }
fi
. quecdeck/script/connection_logger.sh
unregistered_samples=0
pending_mode=""
pending_mode_samples=0
scan_rebaseline=0

_qeng_modern=$'+QENG: "servingcell","CONNECT","LTE","FDD",240,01,ABC123,42,1300,3,-95\nOK'
qeng_sample "$_qeng_modern"
t_rc "modern QENG sample is accepted" 0 "$?"
t "modern QENG fields are parsed" "CONNECT|LTE|240|01|ABC123|42|1300|3" \
  "$(printf '%s|%s|%s|%s|%s|%s|%s|%s' "$sc_state" "$sc_mode" "$sc_mcc" "$sc_mnc" "$sc_cell_id" "$sc_pci" "$sc_earfcn" "$sc_band")"

_qeng_split=$'+QENG: "servingcell","NOCONN"\n+QENG: "LTE","FDD",240,01,DEF456,7,1650,3,-100\n+QENG: "NR5G-NSA",240,01,123,-95,20,-11,640000,78,8,1\nOK'
qeng_sample "$_qeng_split"
t_rc "split NSA QENG sample is accepted" 0 "$?"
t "split NSA QENG fields are parsed" "NOCONN|NR5G-NSA|DEF456|7|1650|3" \
  "$(printf '%s|%s|%s|%s|%s|%s' "$sc_state" "$sc_mode" "$sc_cell_id" "$sc_pci" "$sc_earfcn" "$sc_band")"
qeng_sample $'+QENG: "servingcell","NOCONN"\n+QENG: "LTE","FDD",240,01,DEF456,7,1650,3,-100\n+QENG: "NR5G-NSA",240,01,123,-,-,-,-,-\nOK'
t_rc "NSA line with invalid radio fields falls back to LTE" 0 "$?"
t "invalid NSA allocation is reported as LTE" "LTE" "$sc_mode"
qeng_sample $'+QENG: "servingcell","NOCONN"\n+QENG: "LTE","FDD",240,01,DEF456,7,1650,3,-100\n+QENG: "NR5G-NSA",240,01,123,-95,20,-11,-,78,8,1\nOK'
t "missing NSA channel cannot be hidden by a valid band" "LTE" "$sc_mode"
qeng_sample $'+QENG: "servingcell","NOCONN"\n+QENG: "LTE","FDD",240,01,DEF456,7,1650,3,-100\n+QENG: "NR5G-NSA",240,01,123,-95,20,-11,640000,-,8,1\nOK'
t "missing NSA band cannot be hidden by a valid channel" "LTE" "$sc_mode"

qeng_sample $'+QENG: "servingcell","CONNECT","LTE","FDD",240,01\nOK'
t_rc "registered sample with missing fields is rejected" 1 "$?"
t "rejected sample does not retain an earlier cell" "" "$sc_cell_id"
qeng_sample "${_qeng_modern%$'\nOK'}"
t_rc "unterminated QENG sample is rejected" 1 "$?"
qeng_sample $'+QENG: "servingcell","BOGUS"\nOK'
t_rc "unknown QENG state is rejected" 1 "$?"
qeng_sample $'+QENG: "servingcell","CONNECT","WCDMA","FDD",240,01,ABC123,42,1300,3\nOK'
t_rc "unimplemented radio layout is rejected" 1 "$?"
t "NSA band label identifies the LTE anchor" "LTE anchor B3" \
  "$(band_label NR5G-NSA 3)"
t "SA channel label uses NR terminology" "NR-ARFCN" \
  "$(channel_label NR5G-SA)"

printf '200\n' > "$SCAN_ACTIVE_FILE"
scan_suppresses_logging
t_rc "active scan suppresses logger polling" 0 "$?"
t "active scan requests a later silent baseline" "1" "$scan_rebaseline"
rm -f "$SCAN_ACTIVE_FILE"
printf '160\n' > "$SCAN_SETTLE_FILE"
scan_suppresses_logging
t_rc "post-scan settling window suppresses logger polling" 0 "$?"
printf '100\n' > "$SCAN_SETTLE_FILE"
scan_suppresses_logging
t_rc "expired settling window releases logger polling" 1 "$?"
t "expired settling marker is removed" "0" \
  "$([ -e "$SCAN_SETTLE_FILE" ] && echo 1 || echo 0)"
t "logger rechecks scan suppression after an AT response" "yes" \
  "$(grep -A3 'response=.*atcmd_run.*QENG' quecdeck/script/connection_logger.sh | grep -q 'scan_suppresses_logging && continue' && echo yes || echo no)"
t "post-scan outage uses normal disconnect handling" "yes" \
  "$(grep -A16 'if \[ "\$scan_rebaseline" = "1" \]' quecdeck/script/connection_logger.sh | grep -q 'process_sample' && echo yes || echo no)"

# Operator changes remain separate, while a mode change summarizes subordinate
# cell and band changes from the same radio transition.
prev_state=CONNECT
prev_mode=LTE
prev_mcc=240
prev_mnc=01
prev_cell_id=AAAA
prev_pci=1
prev_band=1
qeng_sample $'+QENG: "servingcell","CONNECT","NR5G-SA","TDD",242,02,BBBB,2,ABCD,640000,78,-90\nOK'
t "SA parser skips TAC before channel and band" "640000|78" \
  "$(printf '%s|%s' "$sc_earfcn" "$sc_band")"
_events=""
connection_log_append() { _events="$_events$1\n"; }
unregistered_samples=0
process_sample
t "mode transition avoids redundant cell and band events" "2" \
  "$(printf '%b' "$_events" | grep -Ec 'operator_change|mode_change|cell_change|band_change')"
t "mode transition contains operator and mode events" "2" \
  "$(printf '%b' "$_events" | grep -Ec 'operator_change|mode_change')"

# The LTE anchor can stay unchanged while the NSA secondary carrier comes and
# goes. Require the same mode-only transition in two accepted samples.
prev_state=CONNECT
prev_mode=LTE
prev_mcc=240
prev_mnc=01
prev_cell_id=AAAA
prev_pci=1
prev_band=3
qeng_sample $'+QENG: "servingcell","NOCONN"\n+QENG: "LTE","FDD",240,01,AAAA,1,1300,3,-95\n+QENG: "NR5G-NSA",240,01,123,-95,20,-11,640000,78,8,1\nOK'
_events=""
pending_mode=""
pending_mode_samples=0
process_sample
t_rc "first mode-only change is debounced" 1 "$?"
t "first mode-only change emits no event" "" "$_events"
t "first mode-only change keeps the old baseline" "LTE" "$prev_mode"
process_sample
t_rc "second mode-only change is confirmed" 0 "$?"
t "confirmed mode-only change emits once" "1" \
  "$(printf '%b' "$_events" | grep -c 'mode_change')"

# A cell handover already carries its new band, so a separate band event would
# describe the same transition twice.
prev_state=CONNECT
prev_mode=LTE
prev_mcc=240
prev_mnc=01
prev_cell_id=AAAA
prev_pci=1
prev_band=1
qeng_sample $'+QENG: "servingcell","CONNECT","LTE","FDD",240,01,BBBB,2,1650,3,-90\nOK'
_events=""
process_sample
t "cell handover suppresses a redundant band event" "1" \
  "$(printf '%b' "$_events" | grep -Ec 'cell_change|band_change')"

# A delayed reconnect poll that has already lost service must not emit a
# connected event or replace the previous disconnected baseline.
prev_state=NOSERVICE
prev_mode=""
sc_state=CONNECT
sc_mode=LTE
sc_mcc=240
sc_mnc=01
sc_cell_id=AAAA
sc_pci=1
sc_earfcn=1300
sc_band=3
_events=""
unregistered_samples=0
sleep() { return 0; }
atcmd_run() { printf '%s\n' '+QENG: "servingcell","NOSERVICE"' OK; }
process_sample
t_rc "lost delayed reconnect is postponed" 1 "$?"
t "lost delayed reconnect emits no event" "" "$_events"
t "lost delayed reconnect keeps prior state" "NOSERVICE" "$prev_state"
unset -f sleep atcmd_run connection_log_append

# Two valid unregistered samples confirm a disconnect. A one-sample dip is
# ignored and leaves the registered baseline intact.
connection_log_append() { _events="$_events$1\n"; }
prev_state=CONNECT
prev_mode=LTE
prev_mcc=240
prev_mnc=01
prev_cell_id=AAAA
prev_pci=1
prev_band=3
sc_state=NOSERVICE
sc_mode=""
sc_mcc=""
sc_mnc=""
sc_cell_id=""
sc_pci=""
sc_earfcn=""
sc_band=""
_events=""
unregistered_samples=0
process_sample
t_rc "first unregistered sample is debounced" 1 "$?"
t "first unregistered sample emits no event" "" "$_events"
t "first unregistered sample keeps registered baseline" "CONNECT" "$prev_state"
process_sample
t_rc "second unregistered sample confirms disconnect" 0 "$?"
t "confirmed disconnect emits one event" "1" \
  "$(printf '%b' "$_events" | grep -c 'disconnected')"
unset -f connection_log_append

# Exercise the real writer after restoring the function replaced by the event
# capture above. Git Bash uses a successful flock stub when the command is not
# installed, while devices exercise the real lock in the scan and logger.
. quecdeck/script/connection-log.sh
CONNECTION_LOG_FILE=$_conn_fixture/retained.jsonl
CONNECTION_LOG_LIMIT=3
for _event_id in 1 2 3 4; do
  connection_log_append "{\"id\":$_event_id}"
done
t "shared writer retains the newest bounded window" \
  "$(printf '{\"id\":2}\n{\"id\":3}\n{\"id\":4}')" \
  "$(cat "$CONNECTION_LOG_FILE")"
t "shared writer leaves no rotation temporary file" "0" \
  "$(find "$_conn_fixture" -name 'retained.jsonl.tmp.*' | wc -l | tr -d ' ')"

# Persisted same-boot state is the restart baseline, preventing a duplicate
# startup connected event. A different boot must reject that baseline.
sc_state=NOSERVICE
sc_mode=""
sc_mcc=""
sc_mnc=""
sc_cell_id=""
sc_pci=""
sc_earfcn=""
sc_band=""
save_state
qeng_reset
load_state
t_rc "unregistered state with empty radio fields reloads" 0 "$?"
t "unregistered restart baseline is preserved" "NOSERVICE" "$prev_state"
qeng_sample "$_qeng_modern"
save_state
qeng_reset
load_state
t_rc "same-boot logger state reloads" 0 "$?"
t "same-boot state restores the prior cell" "ABC123" "$prev_cell_id"
printf 'next-boot\n' > "$BOOT_ID_FILE"
load_state
t_rc "state from an earlier boot is rejected" 1 "$?"

t "scan and daemon use the shared connection-log writer" "2" \
  "$(grep -l 'connection_log_append' quecdeck/script/connection_logger.sh quecdeck/www/cgi-bin/run_cell_scan | wc -l | tr -d ' ')"
t "shared writer serializes append and rotation" "yes" \
  "$(grep -q 'flock -x 8' quecdeck/script/connection-log.sh && grep -q '\.tmp\.\$\$' quecdeck/script/connection-log.sh && echo yes || echo no)"

rm -rf "$_conn_fixture"
if [ "$_conn_stub_flock" = "1" ]; then unset -f flock; fi
unset _conn_fixture _qeng_modern _qeng_split _events
unset _event_id CONNECTION_LOG_LIMIT
unset _conn_stub_flock
unset QUECDECK_SCRIPT_DIR CONNECTION_LOGGER_LIB_ONLY CONNECTION_LOG_FILE
unset STATE_FILE BOOT_ID_FILE INTERVAL
unset UPTIME_FILE SCAN_ACTIVE_FILE SCAN_SETTLE_FILE
