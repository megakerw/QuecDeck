#!/bin/bash
# Triggered by the QuecDeck web UI to perform an update.
# Called via sudo by the trigger_update CGI.
# Usage: run_update.sh <tag>  e.g. run_update.sh v1.2.3

TAG="${1:-}"
LOG=/tmp/install_quecdeck.log
STATUS_FILE=/tmp/quecdeck_update.status
UPDATE_TMP=/tmp/.quecdeck-update
CHECKSUMS="$UPDATE_TMP/quecdeck_update_checksums.sha256"
UPDATE_SCRIPT="$UPDATE_TMP/quecdeck_update.sh"
GITROOT="https://raw.githubusercontent.com/megakerw/QuecDeck/$TAG"

# Writes a message to the log, records failure in the status file,
# then exits the calling (sub)shell.
abort() {
    echo "$1" | tee -a "$LOG"
    echo "failed" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
    exit 1
}

if [ -z "$TAG" ]; then
    echo "Usage: run_update.sh <tag>"
    exit 1
fi

if ! echo "$TAG" | grep -qE '^v[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "Invalid tag format: $TAG"
    exit 1
fi

# Update lock, handled only in the root domain. A lock left by another SELinux
# (SEAndroid) domain, e.g. an older www-data CGI, can't be opened by root but can
# be unlinked, and can only be stale, so clear it first. Then fail fast (exit 2,
# which the CGI maps to "already in progress") if an update is genuinely running.
# flock auto-releases when the holder dies, so a killed update never wedges this.
UPDATE_LOCK_FILE=/tmp/quecdeck_update.lock
if [ -e "$UPDATE_LOCK_FILE" ] && ! ( : >>"$UPDATE_LOCK_FILE" ) 2>/dev/null; then
    rm -f "$UPDATE_LOCK_FILE"
fi
if command -v flock >/dev/null 2>&1 && ! ( exec 9>"$UPDATE_LOCK_FILE"; flock -n 9 ); then
    echo "An update is already in progress; not starting another." >> "$LOG" 2>/dev/null
    exit 2
fi

rm -rf "$UPDATE_TMP"
mkdir -m 700 "$UPDATE_TMP" || { echo "Security: failed to create $UPDATE_TMP."; exit 1; }
chown root:root "$UPDATE_TMP"

mkdir -p /tmp/quecdeck
echo "running" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"
> "$LOG"
chmod 644 "$LOG"

# Run all downloads and the installer itself in a background subshell so this
# script returns immediately, keeping the trigger_update CGI response fast.
(
    if ! /opt/bin/opkg list-installed 2>/dev/null | grep -q '^wget-ssl '; then
        /opt/bin/opkg update >> "$LOG" 2>&1
        /opt/bin/opkg install wget-ssl ca-certificates >> "$LOG" 2>&1 || abort "Failed to install wget-ssl."
    fi

    /opt/bin/wget --timeout=30 --tries=2 -q -O "$CHECKSUMS" "$GITROOT/quecdeck/checksums.sha256" || abort "Failed to download checksums."

    expected_hash=$(grep -E '^[a-f0-9]{64} \*update_quecdeck\.sh$' "$CHECKSUMS" | awk '{print $1}')
    rm -f "$CHECKSUMS"
    [ -z "$expected_hash" ] && abort "Could not find hash for update_quecdeck.sh in checksums."

    /opt/bin/wget --timeout=30 --tries=2 -q -O "$UPDATE_SCRIPT" "$GITROOT/update_quecdeck.sh" || abort "Failed to download update_quecdeck.sh."

    actual_hash=$(sha256sum "$UPDATE_SCRIPT" | awk '{print $1}')
    if [ "$actual_hash" != "$expected_hash" ]; then
        rm -f "$UPDATE_SCRIPT"
        abort "FATAL: Hash mismatch for update_quecdeck.sh."
    fi
    echo "update_quecdeck.sh integrity verified." | tee -a "$LOG"

    chmod +x "$UPDATE_SCRIPT"

    nohup "$UPDATE_SCRIPT" "$TAG" >> "$LOG" 2>&1 &
    disown "$!"
    echo "Update started (tag: $TAG)." | tee -a "$LOG"
) &
disown "$!"
echo "Downloading installer..." | tee -a "$LOG"
