#!/bin/bash
# Called via sudo by authentication CGIs and fixed-operation security helpers
# to verify a web password.
# The htpasswd files are root:root 600 so the web tier can never read the
# stored hashes. This helper is the only credential-check path. It serializes
# and paces checks at the root boundary. CGIs retain per-client lockouts for
# user feedback and network-level abuse control.
# Usage: printf '%s\n' "$password" | sudo check_password.sh <admin|dev> <username>
# Exit 0 if the password matches, 1 otherwise, or 75 when verification is
# temporarily unavailable.

# sudo's secure_path varies by build. Pin one that has openssl.
PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin
umask 077
[ "$#" -eq 2 ] || exit 1

case "${1:-}" in
    admin) FILE="/opt/etc/.htpasswd"; LIMIT_NAME=admin; USERNAME=admin ;;
    dev)   FILE="/opt/etc/.htpasswd_dev"; LIMIT_NAME=dev; USERNAME=devadmin ;;
    *) exit 1 ;;
esac

# Password arrives on stdin, never argv (argv is world-readable in /proc).
# Stored hashes are made with `openssl passwd -stdin`, which hashes only the
# first line, so reading one line here matches how passwords are set.
IFS= read -r password
[ -n "$password" ] || exit 1
[ "${#password}" -le 256 ] || exit 1

# A compromised web process can invoke this sudo helper without passing
# through CGI lockouts. A fixed root-owned lock limits each credential to one
# failed verification per second. This deliberately creates a bounded global
# availability tradeoff for each credential. A 5-second wait prevents sustained
# failures from leaving CGI processes queued indefinitely.
LIMIT_DIR=/run/quecdeck/auth-limit
[ ! -L /run/quecdeck ] || exit 1
mkdir -p /run/quecdeck || exit 1
chown root:root /run/quecdeck && chmod 755 /run/quecdeck || exit 1
mkdir -p "$LIMIT_DIR" || exit 1
[ -d "$LIMIT_DIR" ] && [ ! -L "$LIMIT_DIR" ] || exit 1
chown root:root "$LIMIT_DIR" && chmod 700 "$LIMIT_DIR" || exit 1
exec 9>>"$LIMIT_DIR/$LIMIT_NAME.lock" || exit 1
chown root:root "$LIMIT_DIR/$LIMIT_NAME.lock" && chmod 600 "$LIMIT_DIR/$LIMIT_NAME.lock" || exit 1
command -v flock >/dev/null 2>&1 || exit 75
. /usrdata/quecdeck/script/lock-lib.sh || exit 75
flock_wait 9 5 || exit 75

# Pace a syntactically valid unknown username like a wrong password. The web
# username is fixed and public, but keeping failure timing uniform is cheap.
if [ "${2:-}" != "$USERNAME" ]; then
    sleep 1
    exit 1
fi

# Verify a password against an htpasswd file (SHA-512 crypt format).
# Usage: validate_htpasswd <htpasswd_file> <username> <password>
validate_htpasswd() {
    local htpasswd_file="$1" username="$2" password="$3"
    [ -f "$htpasswd_file" ] || return 1
    # Literal prefix match, never a grep pattern. The caller pins the username.
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

if validate_htpasswd "$FILE" "$USERNAME" "$password"; then
    exit 0
fi

# Keep the credential lock while pacing a failed check. Successful checks do
# not need the delay.
sleep 1
exit 1
