#!/bin/bash
# Short-lived pause markers shared by Watchcat and operations that deliberately
# disrupt connectivity. All callers run as www-data.

WATCHCAT_PAUSE_DIR=/tmp/quecdeck/watchcat.pause.d
WATCHCAT_MAX_PAUSE=300

watchcat_uptime() {
    local value
    read -r value _ < /proc/uptime || return 1
    value=${value%.*}
    case "$value" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s\n' "$value"
}

# Publish a complete file in one rename, so readers never observe a partial
# marker or state file.
watchcat_atomic_write() {
    local path="$1" body="$2" tmp="${1}.tmp.$$"
    if printf '%s\n' "$body" > "$tmp" && mv -f "$tmp" "$path"; then
        return 0
    fi
    rm -f "$tmp"
    return 1
}

# Usage: watchcat_pause <simple-name> <seconds>
watchcat_pause() {
    local name="$1" seconds="$2" now
    case "$name" in ''|*[!A-Za-z0-9_.-]*) return 1 ;; esac
    case "$seconds" in ''|*[!0-9]*) return 1 ;; esac
    [ "$seconds" -le "$WATCHCAT_MAX_PAUSE" ] || return 1
    now=$(watchcat_uptime) || return 1
    mkdir -p "$WATCHCAT_PAUSE_DIR" || return 1
    chmod 700 "$WATCHCAT_PAUSE_DIR" 2>/dev/null
    watchcat_atomic_write "$WATCHCAT_PAUSE_DIR/$name" "$((now + seconds))"
}

# Protect a modem disruption from the current worker and from one started by a
# concurrent settings save. The marker is required even when the unit is
# inactive at this instant. Sets WATCHCAT_WAS_ACTIVE for event reporting.
watchcat_pause_for_disruption() {
    local state
    WATCHCAT_WAS_ACTIVE=false
    state=$(systemctl is-active watchcat 2>/dev/null)
    case "$state" in
        active|activating|deactivating|reloading) WATCHCAT_WAS_ACTIVE=true ;;
    esac
    watchcat_pause "$1" "$2"
}

watchcat_resume() {
    case "$1" in ''|*[!A-Za-z0-9_.-]*) return 1 ;; esac
    rm -f "$WATCHCAT_PAUSE_DIR/$1"
}

# True if any unexpired marker exists. If uptime cannot be read, fail safe and
# leave Watchcat paused for this round.
watchcat_is_paused() {
    [ -d "$WATCHCAT_PAUSE_DIR" ] || return 1
    local marker expiry now latest active=1
    now=$(watchcat_uptime) || return 0
    latest=$((now + WATCHCAT_MAX_PAUSE))
    for marker in "$WATCHCAT_PAUSE_DIR"/*; do
        [ -e "$marker" ] || continue
        if read -r expiry < "$marker" 2>/dev/null \
            && case "$expiry" in ''|*[!0-9]*) false ;; *) true ;; esac \
            && [ "$expiry" -gt "$now" ] \
            && [ "$expiry" -le "$latest" ]; then
            active=0
        else
            rm -f "$marker"
        fi
    done
    return "$active"
}
