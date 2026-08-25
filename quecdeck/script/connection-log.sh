#!/bin/bash
# Shared writer for connection events. Every producer uses the same lock so an
# append cannot be lost while another process rotates the log.

: "${CONNECTION_LOG_FILE:=/run/quecdeck-web/logs/connection_events.jsonl}"
: "${CONNECTION_LOG_LIMIT:=500}"

connection_log_append() {
    local event="$1" log_dir lock_file tmp count rc=0
    log_dir=$(dirname "$CONNECTION_LOG_FILE") || return 1
    (umask 077; mkdir -p "$log_dir") || return 1
    lock_file="$log_dir/connection_events.lock"

    command -v flock >/dev/null 2>&1 || return 1
    exec 8>>"$lock_file" || return 1
    if ! flock -x 8; then
        exec 8>&-
        return 1
    fi

    printf '%s\n' "$event" >> "$CONNECTION_LOG_FILE" || rc=1
    if [ "$rc" = "0" ]; then
        count=$(wc -l < "$CONNECTION_LOG_FILE" 2>/dev/null) || count=0
        if [ "$count" -gt "$CONNECTION_LOG_LIMIT" ]; then
            tmp="${CONNECTION_LOG_FILE}.tmp.$$"
            if ! tail -"$CONNECTION_LOG_LIMIT" "$CONNECTION_LOG_FILE" > "$tmp" \
                || ! mv -f "$tmp" "$CONNECTION_LOG_FILE"; then
                rm -f "$tmp"
                rc=1
            fi
        fi
    fi

    flock -u 8 || rc=1
    exec 8>&-
    return "$rc"
}
