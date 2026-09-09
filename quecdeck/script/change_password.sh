#!/bin/bash
# Root-only sudo helper for changing administrator or developer credentials.
# Reads only the current value of the credential being changed and its
# replacement. The other credential is never asked for, so it is never handled
# by this process. No file path, username, or hash is accepted from the web tier.

PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin
umask 077
. /usrdata/quecdeck/script/lock-lib.sh || exit 1

HTPASSWD=/opt/etc/.htpasswd
DEV_GENERATION=/opt/etc/.htpasswd_dev.generation
LOCK=/opt/etc/.quecdeck-credentials.lock

[ "$#" -le 1 ] || exit 1
case "${1:-admin}" in admin|dev) MODE="${1:-admin}" ;; *) exit 1 ;; esac
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

# Only the credential being replaced is required. The other one is never asked
# for, so it is also never handled by this process.
if [ "$MODE" = dev ]; then
    HTPASSWD=/opt/etc/.htpasswd_dev
    USERNAME=devadmin
    SELF_KIND=dev;    SELF_USER=devadmin
    OTHER_KIND=admin; OTHER_USER=admin
else
    USERNAME=admin
    SELF_KIND=admin;  SELF_USER=admin
    OTHER_KIND=dev;   OTHER_USER=devadmin
fi
[ -f "$HTPASSWD" ] && [ ! -L "$HTPASSWD" ] || exit 1

exec 9>>"$LOCK" || exit 1
chown root:root "$LOCK" && chmod 600 "$LOCK" || exit 1
flock_wait 9 5 || exit 75

printf '%s\n' "$CURRENT" |
    /usrdata/quecdeck/script/check_password.sh "$SELF_KIND" "$SELF_USER"
password_rc=${PIPESTATUS[1]}
[ "$password_rc" != 75 ] || exit 75
[ "$password_rc" = 0 ] || exit 2

# The two credentials must stay distinct: if they were equal, knowing the
# administrator password would also clear the developer gate. Test the
# replacement against the OTHER stored hash instead of asking the caller to
# supply that password, which keeps the guard without widening what this
# operation needs to know.
printf '%s\n' "$NEW" |
    /usrdata/quecdeck/script/check_password.sh "$OTHER_KIND" "$OTHER_USER"
other_rc=${PIPESTATUS[1]}
[ "$other_rc" != 75 ] || exit 75
[ "$other_rc" != 0 ] || exit 13

HASH=$(printf '%s' "$NEW" | openssl passwd -6 -stdin 2>/dev/null)
[ -n "$HASH" ] || exit 1
TMP=$(mktemp "${HTPASSWD}.tmp.XXXXXX") || exit 1
if ! printf '%s:%s\n' "$USERNAME" "$HASH" > "$TMP" ||
   ! chown root:root "$TMP" || ! chmod 600 "$TMP"; then
    rm -f "$TMP"
    exit 1
fi

if [ "$MODE" = dev ]; then
    GENERATION=$(openssl rand -hex 16 2>/dev/null)
    printf '%s' "$GENERATION" | grep -qE '^[a-f0-9]{32}$' || { rm -f "$TMP"; exit 1; }
    GENERATION_TMP=$(mktemp "${DEV_GENERATION}.tmp.XXXXXX") || { rm -f "$TMP"; exit 1; }
    if ! printf '%s\n' "$GENERATION" > "$GENERATION_TMP" ||
       ! chown root:www-data "$GENERATION_TMP" || ! chmod 640 "$GENERATION_TMP"; then
        rm -f "$TMP" "$GENERATION_TMP"
        exit 1
    fi
    # Removing the old generation invalidates every existing unlock before
    # the credential changes. An interrupted rotation therefore fails closed.
    rm -f "$DEV_GENERATION" || { rm -f "$TMP" "$GENERATION_TMP"; exit 1; }
    if ! mv -f "$TMP" "$HTPASSWD" || ! mv -f "$GENERATION_TMP" "$DEV_GENERATION"; then
        rm -f "$TMP" "$GENERATION_TMP"
        exit 1
    fi
elif ! mv -f "$TMP" "$HTPASSWD"; then
    rm -f "$TMP"
    exit 1
fi
