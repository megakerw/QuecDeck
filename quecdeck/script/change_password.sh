#!/bin/bash
# Root-only sudo helper for changing the web administrator password.
# The current and new passwords arrive as two lines on stdin. No file path,
# username, or hash is accepted from the web tier.

PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin
umask 077

HTPASSWD=/opt/etc/.htpasswd
LOCK=/opt/etc/.quecdeck-credentials.lock

[ "$#" -eq 0 ] || exit 1
PAYLOAD=$(
    head -c 1025
    printf .
)
PAYLOAD=${PAYLOAD%.}
[ "${#PAYLOAD}" -le 1024 ] || exit 1
PAYLOAD=${PAYLOAD%$'\n'}
{
    IFS= read -r CURRENT || exit 1
    IFS= read -r NEW || exit 1
    IFS= read -r EXTRA && exit 1
} <<< "$PAYLOAD"
[ -n "$CURRENT" ] && [ "${#CURRENT}" -le 256 ] || exit 1
[ "${#NEW}" -ge 12 ] && [ "${#NEW}" -le 256 ] || exit 1
[ -f "$HTPASSWD" ] && [ ! -L "$HTPASSWD" ] || exit 1

exec 9>>"$LOCK" || exit 1
chown root:root "$LOCK" && chmod 600 "$LOCK" || exit 1
flock -w 5 -x 9 || exit 75

printf '%s\n' "$CURRENT" |
    /usrdata/quecdeck/script/check_password.sh admin admin
password_rc=${PIPESTATUS[1]}
[ "$password_rc" != 75 ] || exit 75
if [ "$password_rc" != 0 ]; then
    exit 2
fi

HASH=$(printf '%s' "$NEW" | openssl passwd -6 -stdin 2>/dev/null)
[ -n "$HASH" ] || exit 1
TMP=$(mktemp "${HTPASSWD}.tmp.XXXXXX") || exit 1
if ! printf 'admin:%s\n' "$HASH" > "$TMP" ||
   ! chown root:root "$TMP" || ! chmod 600 "$TMP" ||
   ! mv -f "$TMP" "$HTPASSWD"; then
    rm -f "$TMP"
    exit 1
fi
