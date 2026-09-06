# Exercise bootstrap lifecycle and its embedded downloader without device writes.
_eb_dir=$(mktemp -d)
{
    extract_fn installentware.sh secure_opkg_metadata
    extract_fn installentware.sh require_https_opkg_feeds
    extract_fn installentware.sh bootstrap_tls_packages
} | sed -e "s|/run/quecdeck-entware.XXXXXX|$_eb_dir/wrapper.XXXXXX|g" \
        -e "s|/opt/var/opkg-lists|$_eb_dir/lists|g" \
        -e "s|/opt/etc/opkg.conf|$_eb_dir/opkg.conf|g" \
        -e "s|/opt/etc|$_eb_dir|g" \
        -e 's|chown root:root|chown_mock|g' \
        -e 's|/opt/bin/opkg|bootstrap_opkg|g' > "$_eb_dir/functions.sh"
chown_mock() { return 0; }
_eb_mode_events="$_eb_dir/mode-events"
chmod() {
    printf '%s\n' "$*" >> "$_eb_mode_events"
    command chmod "$@"
}
stat() {
    if [ "$1" = -c ] && [ "$2" = %u ]; then
        printf '0\n'
    elif [ "$1" = -c ] && [ "$2" = %a ] &&
         [ "$3" = "$_eb_dir/opkg.conf" ] && [ -n "${_eb_config_mode:-}" ]; then
        printf '%s\n' "$_eb_config_mode"
    else
        command stat "$@"
    fi
}
. "$_eb_dir/functions.sh"

printf '%s\n' 'src/gz entware https://bin.entware.net/armv7sf-k3.2' \
    'src/gz custom https://example.test/packages' > "$_eb_dir/opkg.conf"
require_https_opkg_feeds
t_rc 'Entware accepts HTTPS-only feed configuration' 0 "$?"
printf '%s\n' 'src/gz entware https://bin.entware.net/armv7sf-k3.2' \
    'src/gz custom http://example.test/packages' > "$_eb_dir/opkg.conf"
require_https_opkg_feeds >/dev/null 2>&1
t_rc 'Entware rejects a plaintext custom feed' 1 "$?"
: > "$_eb_dir/opkg.conf"
require_https_opkg_feeds >/dev/null 2>&1
t_rc 'Entware rejects a configuration without a feed' 1 "$?"

sed -n '/^# Secure the index/,/^# Fix for multiuser environment/p' installentware.sh |
    sed -e 's|/opt/bin/opkg|bootstrap_opkg|g' \
        -e "s|/opt/etc/opkg.conf|$_eb_dir/opkg.conf|g" > "$_eb_dir/batch.sh"
bootstrap_opkg() {
    local downloader=entware
    case "$PATH" in "$_eb_dir"/wrapper.*:*) downloader=curl; [ -x "${PATH%%:*}/wget" ] || return 91 ;; esac
    grep -q '^src/gz entware https://' "$_eb_dir/opkg.conf" || return 92
    printf '%s:%s\n' "$downloader" "$*" >> "$_eb_dir/events"
    if [ "$1" = update ]; then
        mkdir -p "$_eb_dir/lists"
        printf 'index\n' > "$_eb_dir/lists/entware"
        chmod 700 "$_eb_dir/lists"
        chmod 600 "$_eb_dir/lists/entware"
    fi
    [ "${_eb_failure:-}" != "$downloader:$1" ]
}
for _eb_failure in '' curl:update curl:install entware:update; do
    printf '%s\n' 'src/gz entware http://bin.entware.net/armv7sf-k3.2' 'src/gz custom https://example.test/packages' > "$_eb_dir/opkg.conf"
    chmod 600 "$_eb_dir/opkg.conf"
    : > "$_eb_dir/events"
    ( . "$_eb_dir/batch.sh"; echo completed >> "$_eb_dir/events" ) >/dev/null 2>&1
    _eb_rc=$?
    t "Entware removes wrapper after ${_eb_failure:-success}" 0 "$(find "$_eb_dir" -maxdepth 1 -name 'wrapper.*' | wc -l | tr -d ' ')"
    case "$_eb_failure" in
        '')
            t 'Entware hands downloads from curl to wget after TLS packages' $'curl:update\ncurl:install wget-ssl ca-certificates entware-opt\nentware:update\ncompleted' "$(cat "$_eb_dir/events")"
            t_rc 'Entware bootstrap succeeds' 0 "$_eb_rc"
            t 'Entware preserves custom feeds' 'src/gz custom https://example.test/packages' "$(tail -1 "$_eb_dir/opkg.conf")"
            t 'Entware secures opkg.conf' yes "$(grep -qx "644 $_eb_dir/opkg.conf" "$_eb_mode_events" && echo yes || echo no)"
            t 'Entware secures the package-list directory' yes "$(grep -qx "755 $_eb_dir/lists" "$_eb_mode_events" && echo yes || echo no)"
            t 'Entware secures refreshed package indexes' yes "$(grep -qx "644 $_eb_dir/lists/entware" "$_eb_mode_events" && echo yes || echo no)" ;;
        *)
            t_rc "Entware aborts on $_eb_failure" 1 "$_eb_rc"
            t "Entware stops at $_eb_failure without fallback" "$_eb_failure" "$(tail -1 "$_eb_dir/events" | cut -d' ' -f1)" ;;
    esac
done
_eb_config_mode=666
secure_opkg_metadata >/dev/null 2>&1
t_rc 'Entware rejects a previously writable opkg.conf' 1 "$?"
unset _eb_config_mode
rm -f "$_eb_dir/lists/entware"
mkdir "$_eb_dir/lists/entware"
secure_opkg_metadata >/dev/null 2>&1
t_rc 'Entware rejects a non-file package index' 1 "$?"
rmdir "$_eb_dir/lists/entware"
# Execute the embedded wrapper, replacing only curl's executable.
sed -n '/^#!\/bin\/sh$/,/^CURL_WGET$/p' "$_eb_dir/functions.sh" | sed '$d' | sed "s|/usr/bin/curl|$_eb_dir/curl|g" > "$_eb_dir/wget"
cat > "$_eb_dir/curl" <<'MOCK_CURL'
#!/bin/sh
printf '%s\n' "$@" > "$EB_ARGS"
exit "${EB_CURL_RC:-0}"
MOCK_CURL
chmod +x "$_eb_dir/curl"
export EB_ARGS="$_eb_dir/args"
bash "$_eb_dir/wget" -q --timeout 25 -Y on -O '/path with spaces/package' 'https://example.test/p?a=1&b=2'
t_rc 'curl wrapper accepts opkg arguments' 0 "$?"
t 'curl wrapper preserves arguments and enforces HTTPS' $'-q\n--proto\n=https\n--proto-redir\n=https\n--cacert\n/etc/ssl/certs/ca-certificates.crt\n-fsSL\n--connect-timeout\n15\n--max-time\n25\n--retry\n1\n-o\n/path with spaces/package\n--\nhttps://example.test/p?a=1&b=2' "$(cat "$EB_ARGS")"
for _eb_bad in http://example.test/p --no-check-certificate --unknown; do
    rm -f "$EB_ARGS"
    bash "$_eb_dir/wget" -q -O output "$_eb_bad" >/dev/null 2>&1
    t_rc "wrapper rejects $_eb_bad" 2 "$?"
    t 'rejected arguments never invoke curl' no "$([ -e "$EB_ARGS" ] && echo yes || echo no)"
done
bash "$_eb_dir/wget" -O >/dev/null 2>&1
t_rc 'wrapper rejects missing output argument' 2 "$?"
EB_CURL_RC=60 bash "$_eb_dir/wget" -q -O output https://example.test/p
t_rc 'wrapper propagates TLS verification failure' 60 "$?"
rm -rf "$_eb_dir"
unset -f bootstrap_opkg bootstrap_tls_packages secure_opkg_metadata require_https_opkg_feeds chown_mock chmod stat
unset _eb_dir _eb_failure _eb_rc _eb_bad _eb_mode_events EB_ARGS
