#!/bin/bash
# Called via sudo by the auth_login/auth_dev CGIs to verify a web password.
# The htpasswd files are root:root 600 so the web tier can never read the
# stored hashes; this helper is the only credential-check path. It answers
# yes/no only: lockout and rate limiting stay in the CGIs (bf_* in cgi-lib).
# Usage: printf '%s\n' "$password" | sudo check_password.sh <admin|dev> <username>
# Exit 0 if the password matches, 1 otherwise.

# sudo's secure_path varies by build; pin one that has openssl.
PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin

case "$1" in
    admin) FILE="/opt/etc/.htpasswd" ;;
    dev)   FILE="/opt/etc/.htpasswd_dev" ;;
    *)     exit 1 ;;
esac

USERNAME="$2"
printf '%s' "$USERNAME" | grep -qE '^[a-zA-Z0-9_-]{1,64}$' || exit 1

# Password arrives on stdin, never argv (argv is world-readable in /proc).
# Stored hashes are made with `openssl passwd -stdin`, which hashes only the
# first line, so reading one line here matches how passwords are set.
IFS= read -r password
[ -n "$password" ] || exit 1
[ "${#password}" -le 256 ] || exit 1

# Verify a password against an htpasswd file (SHA-512 crypt format).
# Usage: validate_htpasswd <htpasswd_file> <username> <password>
validate_htpasswd() {
    local htpasswd_file="$1" username="$2" password="$3"
    [ -f "$htpasswd_file" ] || return 1
    # Literal prefix match, never a grep pattern: the username may be
    # unvalidated.
    local line="" l
    while IFS= read -r l || [ -n "$l" ]; do
        case "$l" in "${username}:"*) line="$l"; break ;; esac
    done < "$htpasswd_file"
    [ -n "$line" ] || return 1
    local stored_hash="${line#*:}"
    local salt computed
    salt=$(printf '%s' "$stored_hash" | awk -F'[$]' '{print $3}')
    computed=$(printf '%s' "$password" | openssl passwd -6 -salt "$salt" -stdin 2>/dev/null)
    [ "$computed" = "$stored_hash" ]
}

validate_htpasswd "$FILE" "$USERNAME" "$password"
