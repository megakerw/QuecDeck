#!/bin/bash
# QuecDeck connection event logger.
# Polls AT+QENG="servingcell" every 30 seconds and records validated radio
# state changes in the volatile web runtime tree.

: "${QUECDECK_SCRIPT_DIR:=/usrdata/quecdeck/script}"
. "$QUECDECK_SCRIPT_DIR/at-lib.sh" || exit 1
. "$QUECDECK_SCRIPT_DIR/connection-log.sh" || exit 1

: "${STATE_FILE:=/run/quecdeck-web/logs/connection_logger.state}"
: "${BOOT_ID_FILE:=/proc/sys/kernel/random/boot_id}"
: "${UPTIME_FILE:=/proc/uptime}"
: "${SCAN_ACTIVE_FILE:=/run/quecdeck-web/scan/active}"
: "${SCAN_SETTLE_FILE:=/run/quecdeck-web/scan/settle}"
: "${INTERVAL:=30}"

command -v flock >/dev/null 2>&1 || exit 1
(umask 077; mkdir -p "$(dirname "$STATE_FILE")") || exit 1

qeng_reset() {
    sc_state=""
    sc_mode=""
    sc_mcc=""
    sc_mnc=""
    sc_cell_id=""
    sc_pci=""
    sc_earfcn=""
    sc_band=""
}

qeng_digits() {
    printf '%s' "$1" | awk -F',' -v field="$2" \
        '{gsub(/[^0-9]/,"",$field); print $field}'
}

qeng_hex() {
    printf '%s' "$1" | awk -F',' -v field="$2" \
        '{gsub(/[^0-9A-Fa-f]/,"",$field); print $field}'
}

parse_lte_fields() {
    sc_mcc=$(qeng_digits "$1" 3)
    sc_mnc=$(qeng_digits "$1" 4)
    sc_cell_id=$(qeng_hex "$1" 5)
    sc_pci=$(qeng_digits "$1" 6)
    sc_earfcn=$(qeng_digits "$1" 7)
    sc_band=$(qeng_digits "$1" 8)
}

nsa_line_valid() {
    local arfcn band
    arfcn=$(qeng_digits "$1" 8)
    band=$(qeng_digits "$1" 9)
    case "$arfcn" in ""|*[!0-9]*) return 1 ;; esac
    case "$band" in ""|*[!0-9]*) return 1 ;; esac
}

is_registered() {
    case "$1" in CONNECT|NOCONN) return 0 ;; *) return 1 ;; esac
}

qeng_fields_valid() {
    case "$sc_state" in
        CONNECT|NOCONN|NOSERVICE|SEARCH|LIMSRV) ;;
        *) return 1 ;;
    esac

    case "$sc_mode" in
        LTE|NR5G-SA|NR5G-NSA) ;;
        "") is_registered "$sc_state" && return 1 ;;
        *) return 1 ;;
    esac

    is_registered "$sc_state" || return 0
    [ "${#sc_mcc}" = "3" ] || return 1
    case "${#sc_mnc}" in 2|3) ;; *) return 1 ;; esac
    case "$sc_cell_id" in ""|*[!0-9A-Fa-f]*) return 1 ;; esac
    [ "${#sc_cell_id}" -le 16 ] || return 1
    case "$sc_pci" in ""|*[!0-9]*) return 1 ;; esac
    case "$sc_earfcn" in ""|*[!0-9]*) return 1 ;; esac
    case "$sc_band" in ""|*[!0-9]*) return 1 ;; esac
    [ "${#sc_pci}" -le 5 ] || return 1
    [ "${#sc_earfcn}" -le 8 ] || return 1
    [ "${#sc_band}" -le 4 ] || return 1

    sc_pci=$((10#$sc_pci))
    sc_earfcn=$((10#$sc_earfcn))
    sc_band=$((10#$sc_band))
}

# Parses a complete QENG response into the sc_* globals. A registered sample is
# accepted only when all fields used by the event stream are present.
parse_qeng() {
    local response="$1" sc_line lte_line nsa_line
    qeng_reset

    sc_line=$(printf '%s' "$response" | grep '+QENG: "servingcell"' | head -1)
    if [ -n "$sc_line" ]; then
        sc_state=$(printf '%s' "$sc_line" | awk -F',' '{gsub(/"/,"",$2); print $2}')
        sc_mode=$(printf '%s' "$sc_line" | awk -F',' '{gsub(/"/,"",$3); print $3}')
        sc_mcc=$(qeng_digits "$sc_line" 5)
        sc_mnc=$(qeng_digits "$sc_line" 6)
        sc_cell_id=$(qeng_hex "$sc_line" 7)
        sc_pci=$(qeng_digits "$sc_line" 8)
        if [ "$sc_mode" = "NR5G-SA" ]; then
            # SA inserts TAC before NR-ARFCN and band.
            sc_earfcn=$(qeng_digits "$sc_line" 10)
            sc_band=$(qeng_digits "$sc_line" 11)
        else
            sc_earfcn=$(qeng_digits "$sc_line" 9)
            sc_band=$(qeng_digits "$sc_line" 10)
        fi

        # Some firmware reports only the state on the servingcell line and
        # carries LTE details on a separate line.
        if [ -z "$sc_mode" ]; then
            lte_line=$(printf '%s' "$response" | grep '+QENG: "LTE"' | head -1)
            if [ -n "$lte_line" ]; then
                nsa_line=$(printf '%s' "$response" | grep '+QENG: "NR5G-NSA"' | head -1)
                if [ -n "$nsa_line" ] && nsa_line_valid "$nsa_line"; then
                    sc_mode=NR5G-NSA
                else
                    sc_mode=LTE
                fi
                parse_lte_fields "$lte_line"
            fi
        fi
    else
        # Older firmware can omit the servingcell wrapper.
        lte_line=$(printf '%s' "$response" | grep '+QENG: "LTE"' | head -1)
        [ -n "$lte_line" ] || return 1
        sc_state=CONNECT
        sc_mode=LTE
        parse_lte_fields "$lte_line"
    fi

    qeng_fields_valid
}

qeng_sample() {
    local response="$1"
    [ "${response##*$'\n'}" = "OK" ] || return 1
    parse_qeng "$response"
}

band_label() {
    case "$1" in
        NR5G-SA) printf 'N%s' "$2" ;;
        NR5G-NSA) printf 'LTE anchor B%s' "$2" ;;
        *) printf 'B%s' "$2" ;;
    esac
}

channel_label() {
    case "$1" in NR5G-SA) printf 'NR-ARFCN' ;; *) printf 'EARFCN' ;; esac
}

runtime_uptime() {
    local value
    read -r value _ < "$UPTIME_FILE" || return 1
    value=${value%.*}
    case "$value" in ""|*[!0-9]*) return 1 ;; esac
    printf '%s\n' "$value"
}

runtime_marker_live() {
    local marker="$1" max_future="$2" expiry now
    [ -f "$marker" ] || return 1
    scan_rebaseline=1
    read -r expiry < "$marker" 2>/dev/null || expiry=""
    case "$expiry" in ""|*[!0-9]*) rm -f "$marker"; return 1 ;; esac
    now=$(runtime_uptime) || return 0
    if [ "$expiry" -gt "$now" ] && [ "$expiry" -le "$((now + max_future))" ]; then
        return 0
    fi
    rm -f "$marker"
    return 1
}

scan_suppresses_logging() {
    runtime_marker_live "$SCAN_ACTIVE_FILE" 300 && return 0
    runtime_marker_live "$SCAN_SETTLE_FILE" 120 && return 0
    return 1
}

emit_event() {
    connection_log_append "$1" || exit 1
}

queue_event() {
    if [ -n "$event_batch" ]; then
        event_batch="$event_batch
$1"
    else
        event_batch=$1
    fi
}

save_state() {
    local boot_id tmp
    boot_id=$(cat "$BOOT_ID_FILE" 2>/dev/null) || return 1
    tmp="${STATE_FILE}.tmp.$$"
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
        "$boot_id" "$sc_state" "$sc_mode" "$sc_mcc" "$sc_mnc" \
        "$sc_cell_id" "$sc_pci" "$sc_earfcn" "$sc_band" > "$tmp" \
        && mv -f "$tmp" "$STATE_FILE"
}

load_state() {
    local current_boot saved_boot
    [ -s "$STATE_FILE" ] || return 1
    current_boot=$(cat "$BOOT_ID_FILE" 2>/dev/null) || return 1
    IFS='|' read -r saved_boot sc_state sc_mode sc_mcc sc_mnc sc_cell_id \
        sc_pci sc_earfcn sc_band < "$STATE_FILE" || return 1
    [ "$saved_boot" = "$current_boot" ] || return 1
    qeng_fields_valid || return 1
    prev_state=$sc_state
    prev_mode=$sc_mode
    prev_mcc=$sc_mcc
    prev_mnc=$sc_mnc
    prev_cell_id=$sc_cell_id
    prev_pci=$sc_pci
    prev_band=$sc_band
}

remember_sample() {
    prev_state=$sc_state
    prev_mode=$sc_mode
    prev_mcc=$sc_mcc
    prev_mnc=$sc_mnc
    prev_cell_id=$sc_cell_id
    prev_pci=$sc_pci
    prev_band=$sc_band
    save_state || exit 1
}

process_sample() {
    local ts was_registered=0 now_registered=0 response event_batch=""
    ts=$(date +%s)
    is_registered "$prev_state" && was_registered=1
    is_registered "$sc_state" && now_registered=1
    [ "$now_registered" = "1" ] && unregistered_samples=0

    if [ "$now_registered" = "0" ] && [ "$was_registered" = "1" ]; then
        pending_mode=""
        pending_mode_samples=0
        unregistered_samples=$((unregistered_samples + 1))
        # Ignore one isolated unregistered sample. The previous accepted radio
        # state remains the baseline so a second sample can confirm the outage.
        [ "$unregistered_samples" -ge 2 ] || return 1
        queue_event "{\"ts\":$ts,\"type\":\"disconnected\",\"prev_mode\":\"$prev_mode\"}"
    elif [ "$now_registered" = "1" ] && [ "$was_registered" = "0" ]; then
        pending_mode=""
        pending_mode_samples=0
        # Registration details often settle after the state first changes.
        sleep 5
        response=$(atcmd_run 'AT+QENG="servingcell"' 10000)
        qeng_sample "$response" || return 1
        is_registered "$sc_state" || return 1
        ts=$(date +%s)
        queue_event "{\"ts\":$ts,\"type\":\"connected\",\"mode\":\"$sc_mode\",\"cell_id\":\"$sc_cell_id\",\"pci\":$sc_pci,\"earfcn\":$sc_earfcn,\"channel_label\":\"$(channel_label "$sc_mode")\",\"band\":\"$(band_label "$sc_mode" "$sc_band")\"}"
    elif [ "$now_registered" = "1" ]; then
        # A mode-only change commonly reflects the NSA secondary carrier being
        # released and reacquired. Require the same new mode twice unless an
        # operator or cell change independently confirms a larger transition.
        if [ "$sc_mode" != "$prev_mode" ] \
            && [ "$sc_mcc$sc_mnc" = "$prev_mcc$prev_mnc" ] \
            && [ "$sc_cell_id" = "$prev_cell_id" ] \
            && [ "$sc_pci" = "$prev_pci" ]; then
            if [ "$pending_mode" = "$sc_mode" ]; then
                pending_mode_samples=$((pending_mode_samples + 1))
            else
                pending_mode=$sc_mode
                pending_mode_samples=1
            fi
            [ "$pending_mode_samples" -ge 2 ] || return 1
        else
            pending_mode=""
            pending_mode_samples=0
        fi
        if [ "$sc_mcc$sc_mnc" != "$prev_mcc$prev_mnc" ]; then
            queue_event "{\"ts\":$ts,\"type\":\"operator_change\",\"from\":\"$prev_mcc$prev_mnc\",\"to\":\"$sc_mcc$sc_mnc\",\"mode\":\"$sc_mode\",\"cell_id\":\"$sc_cell_id\",\"pci\":$sc_pci}"
        fi
        if [ "$sc_mode" != "$prev_mode" ]; then
            queue_event "{\"ts\":$ts,\"type\":\"mode_change\",\"from\":\"$prev_mode\",\"to\":\"$sc_mode\",\"cell_id\":\"$sc_cell_id\",\"pci\":$sc_pci}"
        elif [ "$sc_cell_id" != "$prev_cell_id" ] || [ "$sc_pci" != "$prev_pci" ]; then
            queue_event "{\"ts\":$ts,\"type\":\"cell_change\",\"mode\":\"$sc_mode\",\"from\":{\"cell_id\":\"$prev_cell_id\",\"pci\":$prev_pci},\"to\":{\"cell_id\":\"$sc_cell_id\",\"pci\":$sc_pci,\"earfcn\":$sc_earfcn,\"channel_label\":\"$(channel_label "$sc_mode")\",\"band\":\"$(band_label "$sc_mode" "$sc_band")\"}}"
        elif [ "$sc_band" != "$prev_band" ]; then
            queue_event "{\"ts\":$ts,\"type\":\"band_change\",\"mode\":\"$sc_mode\",\"cell_id\":\"$sc_cell_id\",\"pci\":$sc_pci,\"from\":\"$(band_label "$prev_mode" "$prev_band")\",\"to\":\"$(band_label "$sc_mode" "$sc_band")\"}"
        fi
    fi

    unregistered_samples=0
    pending_mode=""
    pending_mode_samples=0
    [ -z "$event_batch" ] || connection_log_append "$event_batch" || exit 1
    remember_sample
}

connection_logger_main() {
    local have_previous=0 response ts
    # Give the AT daemon time to settle before the first poll. A same-boot state
    # file prevents a service restart from creating a duplicate connected event.
    sleep 15
    unregistered_samples=0
    pending_mode=""
    pending_mode_samples=0
    scan_rebaseline=0
    load_state && have_previous=1

    while true; do
        if scan_suppresses_logging; then
            sleep "$INTERVAL"
            continue
        fi
        if [ -S "$_ATCLI_SOCK" ]; then
            response=$(atcmd_run 'AT+QENG="servingcell"' 10000)
            # A scan can begin after the pre-poll check while this request is
            # queued. Discard that in-flight result if a marker appeared.
            scan_suppresses_logging && continue
            if qeng_sample "$response"; then
                if [ "$scan_rebaseline" = "1" ]; then
                    unregistered_samples=0
                    pending_mode=""
                    pending_mode_samples=0
                    scan_rebaseline=0
                    if [ "$have_previous" = "0" ] || is_registered "$sc_state"; then
                        # Normal scan recovery is adopted silently. If the
                        # worker started during the scan, this also establishes
                        # its first trustworthy baseline.
                        remember_sample
                        have_previous=1
                    else
                        # A modem still unregistered after the settling window
                        # may have a real outage. Keep the pre-scan baseline and
                        # apply the normal two-sample disconnect policy.
                        process_sample
                    fi
                elif [ "$have_previous" = "1" ]; then
                    process_sample
                else
                    if is_registered "$sc_state"; then
                        ts=$(date +%s)
                        emit_event "{\"ts\":$ts,\"type\":\"connected\",\"mode\":\"$sc_mode\",\"cell_id\":\"$sc_cell_id\",\"pci\":$sc_pci,\"earfcn\":$sc_earfcn,\"channel_label\":\"$(channel_label "$sc_mode")\",\"band\":\"$(band_label "$sc_mode" "$sc_band")\"}"
                    fi
                    remember_sample
                    have_previous=1
                fi
            fi
        fi
        sleep "$INTERVAL"
    done
}

[ "${CONNECTION_LOGGER_LIB_ONLY:-0}" = "1" ] || connection_logger_main
