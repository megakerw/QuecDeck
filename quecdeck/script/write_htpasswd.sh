#!/bin/bash
# Called via sudo by the init_setup CGI to create htpasswd files with correct
# ownership. stdin must contain exactly one "user:$6$hash" line.
# Usage: printf 'user:%s\n' "$hash" | sudo write_htpasswd.sh [admin|dev]
#
# This script is for ONE-TIME initial setup only and refuses to overwrite an
# already-configured (non-empty) file. Password CHANGES are done from the
# console via quecdeckpasswd/quecdeckdevpasswd, which run as root and write the
# htpasswd files directly without going through this sudo entry point. The
# guard ensures that a www-data compromise cannot reset admin/dev credentials
# by invoking this script directly (it is in www-data's NOPASSWD sudoers list).

TYPE="$1"
case "$TYPE" in
    admin) FILE="/opt/etc/.htpasswd" ;;
    dev)   FILE="/opt/etc/.htpasswd_dev" ;;
    *)     exit 1 ;;
esac

# Refuse if credentials already exist; setup is one-time only.
if [ -s "$FILE" ]; then
    exit 1
fi

LINE=$(head -1)

# Validate: must be "word:$6$..." (SHA-512 crypt)
if ! printf '%s' "$LINE" | grep -qE '^[a-zA-Z0-9_-]+:\$6\$'; then
    exit 1
fi

mkdir -p /opt/etc
# 077: the file must never exist with looser perms than the chmod below sets.
umask 077
printf '%s\n' "$LINE" > "$FILE"
# root:root 600: the web tier must never read stored hashes. Login checks go
# through the check_password.sh sudo helper instead.
chown root:root "$FILE"
chmod 600 "$FILE"
