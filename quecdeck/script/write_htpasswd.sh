#!/bin/bash
# Called via sudo by the init_setup CGI to create htpasswd files with correct
# ownership. The setup mode accepts the administrator line followed by an
# developer line when needed and commits them as one transaction.
# Usage: printf 'admin:%s\n' "$hash" | sudo write_htpasswd.sh setup
#
# This script is for ONE-TIME initial setup only and refuses to overwrite an
# already-configured (non-empty) file. Later administrator changes use the
# separate fixed-operation change_password.sh helper. Standalone password tools
# write the files directly as root. This guard prevents a www-data compromise
# from resetting credentials through the one-time setup entry point.

# sudo's command path varies by build. Setup needs Entware's flock and mktemp.
PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin
umask 077
if [ ! -e /opt/etc ]; then
    (umask 022 && mkdir -p /opt/etc) || exit 1
fi
[ -d /opt/etc ] && [ ! -L /opt/etc ] &&
    [ "$(stat -c %u /opt/etc 2>/dev/null)" = 0 ] || exit 1
chmod 755 /opt/etc || exit 1

# Serialize the existence check and installation. Without this lock, two first
# setup requests can both observe an absent file and the later write replaces
# the credentials chosen by the first request.
LOCK=/opt/etc/.quecdeck-setup.lock
exec 9>>"$LOCK" || exit 1
chown root:root "$LOCK" && chmod 600 "$LOCK" || exit 1
command -v flock >/dev/null 2>&1 || exit 75
flock -w 5 -x 9 || exit 75

valid_line() { # valid_line <expected username> <line>
    [ "${#2}" -le 256 ] &&
        printf '%s' "$2" | grep -qE "^${1}:\\\$6\\\$[^[:space:]]+\$"
}

install_line() { # install_line <path> <line>
    local path="$1" line="$2" tmp
    tmp=$(mktemp "${path}.tmp.XXXXXX") || return 1
    if ! printf '%s\n' "$line" > "$tmp" ||
       ! chown root:root "$tmp" || ! chmod 600 "$tmp" ||
       ! mv -f "$tmp" "$path"; then
        rm -f "$tmp"
        return 1
    fi
}

TYPE="${1:-}"
[ "$#" -eq 1 ] || exit 1
case "$TYPE" in
    setup)
        PAYLOAD=$(
            head -c 1025
            printf .
        )
        PAYLOAD=${PAYLOAD%.}
        [ "${#PAYLOAD}" -le 1024 ] || exit 1
        PAYLOAD=${PAYLOAD%$'\n'}
        {
            IFS= read -r ADMIN_LINE || exit 1
            IFS= read -r DEV_LINE || DEV_LINE=""
            IFS= read -r EXTRA && exit 1
        } <<< "$PAYLOAD"
        valid_line admin "$ADMIN_LINE" || exit 1
        [ -z "$DEV_LINE" ] || valid_line devadmin "$DEV_LINE" || exit 1
        [ ! -s /opt/etc/.htpasswd ] || exit 1
        [ -z "$DEV_LINE" ] || [ ! -s /opt/etc/.htpasswd_dev ] || exit 1
        # Mandatory developer credential: refuse a setup that would leave the
        # device without one. Blank is only allowed when it already exists.
        [ -n "$DEV_LINE" ] || [ -s /opt/etc/.htpasswd_dev ] || exit 1

        # Install the developer file first and the administrator file last.
        # auth.lua treats the administrator file as the setup commit point.
        dev_created=0
        if [ -n "$DEV_LINE" ]; then
            install_line /opt/etc/.htpasswd_dev "$DEV_LINE" || exit 1
            dev_created=1
        fi
        if ! install_line /opt/etc/.htpasswd "$ADMIN_LINE"; then
            [ "$dev_created" = "0" ] || rm -f /opt/etc/.htpasswd_dev
            exit 1
        fi
        ;;
    *) exit 1 ;;
esac
