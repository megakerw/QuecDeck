#!/bin/sh
# Shared JSON field extraction for watchcat.sh / scheduled_restart.sh.
#
# NOT a general JSON parser. Intentionally limited to the flat (no nested
# objects), single-level shape used by this project's *.json config and
# state files: scalar strings/numbers/booleans, and at most one array of
# scalars. The "key" is matched as a quoted, exact string, so it can't
# collide with a different key that happens to contain it as a substring
# (e.g. "day" vs "dayofweek", "ips" vs "track_ips").

# Extract the raw value of a top-level key from flat JSON text.
# Strips surrounding quotes from string values; arrays are returned with
# their brackets/quotes intact for the caller to extract elements from.
# Prints nothing and returns failure if the key isn't found.
# Usage: json_get <json_text> <key>
json_get() {
    local json="$1" key="$2" raw
    raw=$(printf '%s' "$json" | grep -oE "\"$key\"[[:space:]]*:[[:space:]]*\[[^]]*\]")
    if [ -z "$raw" ]; then
        raw=$(printf '%s' "$json" | grep -oE "\"$key\"[[:space:]]*:[[:space:]]*\"[^\"]*\"")
    fi
    if [ -z "$raw" ]; then
        raw=$(printf '%s' "$json" | grep -oE "\"$key\"[[:space:]]*:[[:space:]]*[^,}[:space:]]*")
    fi
    [ -z "$raw" ] && return 1
    raw="${raw#*:}"
    while [ "${raw# }" != "$raw" ]; do raw="${raw# }"; done
    case "$raw" in
        \"*\") raw="${raw#\"}"; raw="${raw%\"}" ;;
    esac
    printf '%s' "$raw"
}
