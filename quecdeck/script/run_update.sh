#!/bin/bash
# Triggered by the QuecDeck web UI to perform an update.
# Called via sudo by the trigger_update CGI.
# Usage: run_update.sh <tag>  e.g. run_update.sh v1.2.3

TAG="${1:-}"
LOG=/tmp/install_quecdeck.log
PID_FILE=/tmp/quecdeck_update.pid
CHECKSUMS=/tmp/quecdeck_update_checksums.sha256
UPDATE_SCRIPT=/tmp/quecdeck_update.sh
GITROOT="https://raw.githubusercontent.com/megakerw/QuecDeck/$TAG"

# Writes a message to the log, marks the run as failed with a sentinel that
# get_update_log can detect, then exits the calling (sub)shell.
abort() {
    echo "$1" | tee -a "$LOG"
    echo "===UPDATE_FAILED===" >> "$LOG"
    rm -f "$PID_FILE"
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

[ -L "$CHECKSUMS" ] && { echo "Security: $CHECKSUMS is a symlink."; exit 1; }
[ -L "$UPDATE_SCRIPT" ] && { echo "Security: $UPDATE_SCRIPT is a symlink."; exit 1; }

mkdir -p /tmp/quecdeck
> "$LOG"
chmod 644 "$LOG"
echo $$ > "$PID_FILE"

# Run all downloads and the installer itself in a background subshell so this
# script returns immediately, keeping the trigger_update CGI response fast.
# The subshell's PID is written to the PID file so get_update_log sees a live
# process while downloads are in progress, then the file is overwritten with
# the installer's PID once it's launched.
(
    if [ ! -x "/opt/bin/wget" ]; then
        opkg install wget-ssl ca-certificates >> "$LOG" 2>&1 || abort "Failed to install wget-ssl."
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
    _update_pid=$!
    echo "$_update_pid" > "$PID_FILE"
    disown "$_update_pid"
    echo "Update started (tag: $TAG)." | tee -a "$LOG"
) &
_bg_pid=$!
echo "$_bg_pid" > "$PID_FILE"
echo "Downloading installer..." | tee -a "$LOG"
