#!/bin/bash
# QuecDeck connection event logger.
# Polls AT+QENG="servingcell" every 30 seconds via the AT command queue and
# appends state-change events to /tmp/quecdeck/connection_events.jsonl.
#
# Events logged: connected, disconnected, cell_change, band_change, mode_change.

. /usrdata/quecdeck/www/cgi-bin/cgi-lib.sh

LOG_FILE="/tmp/quecdeck/logs/connection_events.jsonl"
MAX_EVENTS=500
INTERVAL=30

mkdir -p "$(dirname "$LOG_FILE")" && chmod 700 "$(dirname "$LOG_FILE")"

# ---------------------------------------------------------------------------

log_event() {
    printf '%s\n' "$1" >> "$LOG_FILE"
    local count
    count=$(wc -l < "$LOG_FILE" 2>/dev/null || echo 0)
    if [ "$count" -gt "$MAX_EVENTS" ]; then
        tail -"$MAX_EVENTS" "$LOG_FILE" > "${LOG_FILE}.tmp" && mv "${LOG_FILE}.tmp" "$LOG_FILE"
    fi
}

# Parses response from AT+QENG="servingcell" and sets:
#   sc_state    — CONNECT | NOCONN | NOSERVICE | SEARCH | LIMSRV
#   sc_mode     — LTE | NR5G-SA | NR5G-NSA | WCDMA | (empty when not registered)
#   sc_cell_id  — hex cell identifier
#   sc_pci      — physical cell ID (integer)
#   sc_earfcn   — frequency (integer)
#   sc_band     — primary band number (integer)
parse_qeng() {
    local response="$1"
    local sc_line lte_line

    # Primary format (newer firmware):
    # +QENG: "servingcell","<state>","<mode>","<duplex>",<mcc>,<mnc>,<cellhex>,<pci>,<earfcn>,<band>,...
    sc_line=$(printf '%s' "$response" | grep '+QENG: "servingcell"' | head -1)

    if [ -n "$sc_line" ]; then
        sc_state=$(  printf '%s' "$sc_line" | awk -F',' '{gsub(/"/,"",$2); print $2}')
        sc_mode=$(   printf '%s' "$sc_line" | awk -F',' '{gsub(/"/,"",$3); print $3}')
        sc_cell_id=$(printf '%s' "$sc_line" | awk -F',' '{gsub(/[^0-9A-Fa-f]/,"",$7); print $7}')
        sc_pci=$(    printf '%s' "$sc_line" | awk -F',' '{gsub(/[^0-9]/,"",$8); print $8+0}')
        sc_earfcn=$( printf '%s' "$sc_line" | awk -F',' '{gsub(/[^0-9]/,"",$9); print $9+0}')
        sc_band=$(   printf '%s' "$sc_line" | awk -F',' '{gsub(/[^0-9]/,"",$10); print $10+0}')

        # In RGMII/PCIe mode the servingcell line is truncated to just the state
        # ("NOCONN") with no mode or cell fields. Fall through to the sub-lines.
        if [ -z "$sc_mode" ]; then
            lte_line=$(printf '%s' "$response" | grep '+QENG: "LTE"' | head -1)
            if [ -n "$lte_line" ]; then
                if printf '%s' "$response" | grep -q '+QENG: "NR5G-NSA"'; then
                    sc_mode="NR5G-NSA"
                else
                    sc_mode="LTE"
                fi
                sc_cell_id=$(printf '%s' "$lte_line" | awk -F',' '{gsub(/[^0-9A-Fa-f]/,"",$5); print $5}')
                sc_pci=$(    printf '%s' "$lte_line" | awk -F',' '{gsub(/[^0-9]/,"",$6); print $6+0}')
                sc_earfcn=$( printf '%s' "$lte_line" | awk -F',' '{gsub(/[^0-9]/,"",$7); print $7+0}')
                sc_band=$(   printf '%s' "$lte_line" | awk -F',' '{gsub(/[^0-9]/,"",$8); print $8+0}')
            fi
        fi
    else
        # Fallback format (older firmware):
        # +QENG: "LTE","<duplex>",<mcc>,<mnc>,<cellhex>,<pci>,<earfcn>,<band>,...
        lte_line=$(printf '%s' "$response" | grep '+QENG: "LTE"' | head -1)
        if [ -n "$lte_line" ]; then
            sc_state="CONNECT"
            sc_mode="LTE"
            sc_cell_id=$(printf '%s' "$lte_line" | awk -F',' '{gsub(/[^0-9A-Fa-f]/,"",$5); print $5}')
            sc_pci=$(    printf '%s' "$lte_line" | awk -F',' '{gsub(/[^0-9]/,"",$6); print $6+0}')
            sc_earfcn=$( printf '%s' "$lte_line" | awk -F',' '{gsub(/[^0-9]/,"",$7); print $7+0}')
            sc_band=$(   printf '%s' "$lte_line" | awk -F',' '{gsub(/[^0-9]/,"",$8); print $8+0}')
        else
            sc_state="NOSERVICE"
            sc_mode=""
            sc_cell_id=""
            sc_pci=0
            sc_earfcn=0
            sc_band=0
        fi
    fi

    # Whitelist sc_mode against known values to prevent JSON injection from crafted AT responses.
    case "$sc_mode" in
        LTE|NR5G-SA|NR5G-NSA|WCDMA|CDMA|TDSCDMA) ;;
        *) sc_mode="" ;;
    esac
}

is_registered() {
    case "$1" in
        CONNECT|NOCONN) return 0 ;;
        *) return 1 ;;
    esac
}

band_label() {
    local mode="$1" band="$2"
    case "$mode" in
        NR5G-SA) printf 'N%s' "$band" ;;
        *)        printf 'B%s' "$band" ;;
    esac
}

# ---------------------------------------------------------------------------
# Wait for the AT command daemon to settle before first poll.
sleep 15

# Initial poll — log startup event.
ts=$(date +%s)
if [ -p "$_ATCMD_NOTIFY" ]; then
    response=$(atcmd_run 'AT+QENG="servingcell"' 10000)
    parse_qeng "$response"
else
    sc_state="NOSERVICE"; sc_mode=""; sc_cell_id=""; sc_pci=0; sc_earfcn=0; sc_band=0
fi

prev_state="$sc_state"
prev_mode="$sc_mode"
prev_cell_id="$sc_cell_id"
prev_pci="$sc_pci"
prev_band="$sc_band"

if is_registered "$sc_state"; then
    log_event "{\"ts\":$ts,\"type\":\"connected\",\"mode\":\"$sc_mode\",\"cell_id\":\"$sc_cell_id\",\"pci\":$sc_pci,\"earfcn\":$sc_earfcn,\"band\":\"$(band_label "$sc_mode" "$sc_band")\"}"
fi

# ---------------------------------------------------------------------------
# Main poll loop.
while true; do
    sleep "$INTERVAL"

    [ ! -p "$_ATCMD_NOTIFY" ] && continue

    ts=$(date +%s)
    response=$(atcmd_run 'AT+QENG="servingcell"' 10000)
    parse_qeng "$response"

    was_registered=0; is_registered "$prev_state" && was_registered=1
    now_registered=0; is_registered "$sc_state"   && now_registered=1

    if [ "$now_registered" = "0" ] && [ "$was_registered" = "1" ]; then
        log_event "{\"ts\":$ts,\"type\":\"disconnected\",\"prev_mode\":\"$prev_mode\"}"

    elif [ "$now_registered" = "1" ] && [ "$was_registered" = "0" ]; then
        # Re-poll after a short delay so cell info is populated before logging.
        sleep 5
        ts=$(date +%s)
        response=$(atcmd_run 'AT+QENG="servingcell"' 10000)
        parse_qeng "$response"
        log_event "{\"ts\":$ts,\"type\":\"connected\",\"mode\":\"$sc_mode\",\"cell_id\":\"$sc_cell_id\",\"pci\":$sc_pci,\"earfcn\":$sc_earfcn,\"band\":\"$(band_label "$sc_mode" "$sc_band")\"}"

    elif [ "$now_registered" = "1" ]; then
        if [ "$sc_mode" != "$prev_mode" ] && [ -n "$sc_mode" ] && [ -n "$prev_mode" ]; then
            log_event "{\"ts\":$ts,\"type\":\"mode_change\",\"from\":\"$prev_mode\",\"to\":\"$sc_mode\",\"cell_id\":\"$sc_cell_id\",\"pci\":$sc_pci}"
        elif [ "$sc_cell_id" != "$prev_cell_id" ] || [ "$sc_pci" != "$prev_pci" ]; then
            log_event "{\"ts\":$ts,\"type\":\"cell_change\",\"mode\":\"$sc_mode\",\"from\":{\"cell_id\":\"$prev_cell_id\",\"pci\":$prev_pci},\"to\":{\"cell_id\":\"$sc_cell_id\",\"pci\":$sc_pci,\"earfcn\":$sc_earfcn,\"band\":\"$(band_label "$sc_mode" "$sc_band")\"}}"
        elif [ "$sc_band" != "$prev_band" ]; then
            log_event "{\"ts\":$ts,\"type\":\"band_change\",\"mode\":\"$sc_mode\",\"cell_id\":\"$sc_cell_id\",\"pci\":$sc_pci,\"from\":\"$(band_label "$prev_mode" "$prev_band")\",\"to\":\"$(band_label "$sc_mode" "$sc_band")\"}"
        fi
    fi

    prev_state="$sc_state"
    prev_mode="$sc_mode"
    prev_cell_id="$sc_cell_id"
    prev_pci="$sc_pci"
    prev_band="$sc_band"
done
