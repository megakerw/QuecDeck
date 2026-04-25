#!/bin/bash
# Called via sudo by the init_setup CGI to create htpasswd files with correct
# ownership. stdin must contain exactly one "user:$6$hash" line.
# Usage: printf 'user:%s\n' "$hash" | sudo write_htpasswd.sh [admin|dev]

TYPE="$1"
case "$TYPE" in
    admin) FILE="/opt/etc/.htpasswd" ;;
    dev)   FILE="/opt/etc/.htpasswd_dev" ;;
    *)     exit 1 ;;
esac

LINE=$(head -1)

# Validate: must be "word:$6$..." (SHA-512 crypt)
if ! printf '%s' "$LINE" | grep -qE '^[a-zA-Z0-9_-]+:\$6\$'; then
    exit 1
fi

mkdir -p /opt/etc
printf '%s\n' "$LINE" > "$FILE"
chown root:dialout "$FILE"
chmod 640 "$FILE"
