#!/bin/sh
# Modified by iamromulan to set up a proper entware environment for Quectel RM5xx series m.2 modems
# The stock ADB root shell uses umask 0000.  Entware creates its feed config and
# package indexes using the caller's mask, so pin both the command search path
# and mask before the first privileged download.
PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH
umask 022
TYPE='generic'
#|---------|-----------------|
#| TARGET  | Quectel Modem   |
#| ARCH    | armv7sf-k3.2    | 
#| LOADER  | ld-linux.so.3   | 
#| GLIBC   | 2.27            | 
#|---------|-----------------|
unset LD_LIBRARY_PATH
unset LD_PRELOAD
ARCH=armv7sf-k3.2
LOADER=ld-linux.so.3
GLIBC=2.27
PRE_OPKG_PATH=$(which opkg)

# opkg trusts both its configuration and every cached package index while it is
# running as root.  Keep that trust state root-owned even when an outer caller
# supplied a permissive umask.  Reject special files rather than following a
# symlink planted during an interrupted or damaged installation.
secure_opkg_metadata() {
    _opkg_config=/opt/etc/opkg.conf
    _opkg_lists=/opt/var/opkg-lists

    [ -d /opt/etc ] && [ ! -L /opt/etc ] || return 1
    [ -f "$_opkg_config" ] && [ ! -L "$_opkg_config" ] || return 1
    _opkg_mode=$(stat -c %a /opt/etc 2>/dev/null) || return 1
    [ "$(stat -c %u /opt/etc 2>/dev/null)" = 0 ] &&
        [ $((0$_opkg_mode & 022)) -eq 0 ] || return 1
    _opkg_mode=$(stat -c %a "$_opkg_config" 2>/dev/null) || return 1
    [ "$(stat -c %u "$_opkg_config" 2>/dev/null)" = 0 ] &&
        [ $((0$_opkg_mode & 022)) -eq 0 ] || return 1
    chown root:root /opt/etc "$_opkg_config" || return 1
    chmod 755 /opt/etc && chmod 644 "$_opkg_config" || return 1

    [ -d "$_opkg_lists" ] && [ ! -L "$_opkg_lists" ] || return 1
    _opkg_mode=$(stat -c %a "$_opkg_lists" 2>/dev/null) || return 1
    [ "$(stat -c %u "$_opkg_lists" 2>/dev/null)" = 0 ] &&
        [ $((0$_opkg_mode & 022)) -eq 0 ] || return 1
    chown root:root "$_opkg_lists" && chmod 755 "$_opkg_lists" || return 1
    for _opkg_entry in "$_opkg_lists"/* "$_opkg_lists"/.[!.]* "$_opkg_lists"/..?*; do
        [ -e "$_opkg_entry" ] || [ -L "$_opkg_entry" ] || continue
        [ -f "$_opkg_entry" ] && [ ! -L "$_opkg_entry" ] || return 1
        _opkg_mode=$(stat -c %a "$_opkg_entry" 2>/dev/null) || return 1
        [ "$(stat -c %u "$_opkg_entry" 2>/dev/null)" = 0 ] &&
            [ $((0$_opkg_mode & 022)) -eq 0 ] || return 1
        chown root:root "$_opkg_entry" && chmod 644 "$_opkg_entry" || return 1
    done
}

# Package indexes are the trust root for every archive and maintainer script
# opkg executes.  HTTPS is therefore mandatory for every enabled feed, including
# third-party feeds an administrator may have added deliberately.
require_https_opkg_feeds() {
    _opkg_source_count=0
    while IFS= read -r _opkg_line || [ -n "$_opkg_line" ]; do
        IFS=' 	' read -r _opkg_kind _opkg_name _opkg_url _opkg_rest <<EOF
$_opkg_line
EOF
        case "$_opkg_kind" in
            src|src/gz)
                [ -n "$_opkg_name" ] && [ -n "$_opkg_url" ] || return 1
                case "$_opkg_url" in
                    https://*) _opkg_source_count=$((_opkg_source_count + 1)) ;;
                    *) return 1 ;;
                esac
                ;;
        esac
    done < /opt/etc/opkg.conf || return 1
    [ "$_opkg_source_count" -gt 0 ]
}

# Verified on stock firmware: curl and its CA store do not depend on Entware.
# Refuse unsupported firmware before changing mounts or the package manager.
[ -x /usr/bin/curl ] && [ -s /etc/ssl/certs/ca-certificates.crt ] || {
    echo "Stock curl and CA certificates are required for HTTPS bootstrap." >&2
    exit 1
}

# Remount filesystem as read-write
mount -o remount,rw /
trap 'mount -o remount,ro /' EXIT  # ensures RO is restored on any exit path

# Write systemd units with their final ownership and mode before replacing the
# live path. This avoids inheriting a permissive caller umask or retaining the
# mode of an older unit while the root filesystem is writable.
write_system_unit() { # write_system_unit <absolute path>; content on stdin
    _unit_target=$1
    _unit_tmp=$(mktemp "${_unit_target}.XXXXXX") || return 1
    if ! cat > "$_unit_tmp" ||
       ! chown root:root "$_unit_tmp" ||
       ! chmod 644 "$_unit_tmp" ||
       ! mv -f "$_unit_tmp" "$_unit_target"; then
        rm -f "$_unit_tmp"
        return 1
    fi
}

create_opt_mount() {
    # Bind /usrdata/opt to /opt
    echo -e '\033[32mInfo: Setting up /opt mount to /usrdata/opt...\033[0m'
    write_system_unit /lib/systemd/system/opt.mount <<'EOF' || return 1
[Unit]
Description=Bind /usrdata/opt to /opt
# Mount units normally run before local-fs.target. On this firmware that is
# several seconds before the vendor data initialization has finished, even
# though usrdata.mount already reports active. Place this bind mount in the
# normal multi-user transaction after the vendor's data initialization.
DefaultDependencies=no
Requires=usrdata.mount
After=usrdata.mount data-init.service
Before=umount.target
Conflicts=umount.target

[Mount]
What=/usrdata/opt
Where=/opt
Type=none
Options=bind

[Install]
WantedBy=multi-user.target
EOF

    # opt.mount already has normal systemd enablement metadata. Enable it
    # directly so dependent units can order against the real mount operation.
    rm -f /lib/systemd/system/multi-user.target.wants/start-opt-mount.service \
        /lib/systemd/system/start-opt-mount.service
    ln -sf /lib/systemd/system/opt.mount /lib/systemd/system/multi-user.target.wants/opt.mount || return 1
    systemctl daemon-reload || return 1
    systemctl start opt.mount
}

if [ -n "$PRE_OPKG_PATH" ]; then
    # Automatically rename the existing opkg binary
    mv "$PRE_OPKG_PATH" "${PRE_OPKG_PATH}_old"
    echo -e "\033[32mFactory/Already existing opkg has been renamed to opkg_old.\033[0m"
else
    echo "Info: no existing opkg binary detected, proceeding with installation"
fi

echo -e '\033[32mInfo: Creating /opt mount pointed to /usrdata/opt ...\033[0m'
mkdir -p /usrdata/opt
mkdir -p /opt
create_opt_mount || exit 1
echo -e '\033[32mInfo: Proceeding with main installation ...\033[0m'
# no need to create many folders. The entware-opt package creates most
for folder in bin etc lib/opkg tmp var/lock
do
  if [ -d "/opt/$folder" ]; then
    echo -e "\033[31mWarning: Folder /opt/$folder exists!\033[0m"
    echo -e "\033[31mWarning: If something goes wrong please clean /opt folder and try again.\033[0m"
  else
    mkdir -p /opt/$folder
  fi
done

echo -e '\033[32mInfo: opkg package manager deployment...\033[0m'
URL=https://bin.entware.net/${ARCH}/installer
_opkg_bin_tmp=$(mktemp /opt/bin/.opkg.XXXXXX) || exit 1
if ! /usr/bin/curl -q --proto '=https' --proto-redir '=https' --cacert /etc/ssl/certs/ca-certificates.crt -fsSL --connect-timeout 15 --max-time 60 --retry 1 -o "$_opkg_bin_tmp" "$URL/opkg" ||
   [ ! -s "$_opkg_bin_tmp" ] || ! chown root:root "$_opkg_bin_tmp" ||
   ! chmod 755 "$_opkg_bin_tmp" || ! "$_opkg_bin_tmp" --version >/dev/null 2>&1 ||
   ! mv -f "$_opkg_bin_tmp" /opt/bin/opkg; then
    rm -f "$_opkg_bin_tmp"
    echo -e "\e[1;31mFailed to install opkg binary securely.\e[0m"
    exit 1
fi
_opkg_conf_tmp=$(mktemp /opt/etc/.opkg.conf.XXXXXX) || exit 1
if ! /usr/bin/curl -q --proto '=https' --proto-redir '=https' --cacert /etc/ssl/certs/ca-certificates.crt -fsSL --connect-timeout 15 --max-time 30 --retry 1 -o "$_opkg_conf_tmp" "$URL/opkg.conf" ||
   ! chown root:root "$_opkg_conf_tmp" || ! chmod 644 "$_opkg_conf_tmp" ||
   ! mv -f "$_opkg_conf_tmp" /opt/etc/opkg.conf; then
    rm -f "$_opkg_conf_tmp"
    echo -e "\e[1;31mFailed to install opkg.conf securely.\e[0m"
    exit 1
fi

bootstrap_tls_packages() {
    # Scope PATH and cleanup to a subshell, preserving the outer remount trap.
    (
        umask 077
        require_https_opkg_feeds || exit 1
        _bootstrap_dir=$(mktemp -d /run/quecdeck-entware.XXXXXX) || exit 1
        trap 'rm -rf "$_bootstrap_dir"' EXIT
        trap 'exit 1' HUP INT TERM
        cat > "$_bootstrap_dir/wget" <<'CURL_WGET'
#!/bin/sh
# Only the wget arguments emitted by opkg_download.c are supported.
output= url= timeout=60
while [ "$#" -gt 0 ]; do
    case "$1" in
        -q) shift ;;
        -O)
            [ "$#" -ge 2 ] && [ -z "$output" ] || exit 2
            output=$2; shift 2 ;;
        --timeout)
            [ "$#" -ge 2 ] || exit 2
            case "$2" in ''|*[!0-9]*|0) exit 2 ;; esac
            timeout=$2; shift 2 ;;
        -Y)
            [ "$#" -ge 2 ] && [ "$2" = on ] || exit 2
            shift 2 ;; # curl honours opkg's exported proxy variables.
        https://*)
            [ -z "$url" ] || exit 2
            url=$1; shift ;;
        *) echo "Unsupported bootstrap wget argument: $1" >&2; exit 2 ;;
    esac
done
[ -n "$output" ] && [ -n "$url" ] || exit 2
unset LD_LIBRARY_PATH LD_PRELOAD
exec /usr/bin/curl -q --proto '=https' --proto-redir '=https' \
    --cacert /etc/ssl/certs/ca-certificates.crt -fsSL \
    --connect-timeout 15 --max-time "$timeout" --retry 1 -o "$output" -- "$url"
CURL_WGET
        chmod 700 "$_bootstrap_dir/wget" || exit 1
        export PATH="$_bootstrap_dir:/opt/bin:/opt/sbin:$PATH"
        /opt/bin/opkg update || exit 1
        secure_opkg_metadata || exit 1
        /opt/bin/opkg install wget-ssl ca-certificates entware-opt || exit 1
    )
}

echo -e '\033[32mInfo: Basic packages installation...\033[0m'
# Secure the index and every dependency from the first package batch onwards.
sed -i 's|http://bin\.entware\.net/|https://bin.entware.net/|g' /opt/etc/opkg.conf || exit 1
require_https_opkg_feeds || {
    echo "Every enabled Entware feed must use HTTPS." >&2
    exit 1
}
bootstrap_tls_packages || exit 1
# opkg chooses its downloader from PATH. The firmware wget cannot verify TLS.
PATH=/opt/bin:/opt/sbin:$PATH /opt/bin/opkg update
_opkg_update_rc=$?
secure_opkg_metadata || {
    echo "Entware metadata permissions could not be secured." >&2
    exit 1
}
[ "$_opkg_update_rc" -eq 0 ] || {
    echo "Entware HTTPS verification failed. Check certificates and the device clock." >&2
    exit 1
}

# Fix for multiuser environment
chmod 1777 /opt/tmp

for file in passwd group shells shadow gshadow; do
  if [ $TYPE = 'generic' ]; then
    if [ -f /etc/$file ]; then
      ln -sf /etc/$file /opt/etc/$file
    else
      [ -f /opt/etc/$file.1 ] && cp /opt/etc/$file.1 /opt/etc/$file
    fi
  else
    if [ -f /opt/etc/$file.1 ]; then
      cp /opt/etc/$file.1 /opt/etc/$file
    fi
  fi
done

[ -f /etc/localtime ] && ln -sf /etc/localtime /opt/etc/localtime

# Create and enable rc.unslung service
echo -e '\033[32mInfo: Creating rc.unslung (Entware init.d service)...\033[0m'
write_system_unit /lib/systemd/system/rc.unslung.service <<'EOF' || exit 1
[Unit]
Description=Start Entware services
Requires=opt.mount
After=opt.mount

[Service]
Type=oneshot
ExecStart=/opt/etc/init.d/rc.unslung start
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

ln -sf /lib/systemd/system/rc.unslung.service /lib/systemd/system/multi-user.target.wants/rc.unslung.service || exit 1
systemctl daemon-reload || exit 1
systemctl start rc.unslung.service || exit 1
echo -e '\033[32mInfo: Congratulations!\033[0m'
echo -e '\033[32mInfo: If there are no errors above then Entware was successfully initialized.\033[0m'
echo -e '\033[32mInfo: Add /opt/bin & /opt/sbin to $PATH variable\033[0m'
ln -sf /opt/bin/opkg /bin
ROOT_HOME_HARDENED=/usrdata/root/.quecdeck-home-hardened
mkdir -p /usrdata/root || exit 1
chown root:root /usrdata/root && chmod 700 /usrdata/root || exit 1
_hardened=0
if [ ! -L "$ROOT_HOME_HARDENED" ] && [ -f "$ROOT_HOME_HARDENED" ] && \
   [ "$(stat -c '%U %a' "$ROOT_HOME_HARDENED" 2>/dev/null)" = "root 600" ] && \
   grep -qx '1' "$ROOT_HOME_HARDENED" 2>/dev/null; then
    _hardened=1
fi
if [ "$_hardened" = "0" ]; then
    if [ -e /usrdata/root/bin ] || [ -L /usrdata/root/bin ]; then
        _quarantine="/usrdata/root/bin.pre-quecdeck-hardening.$(date +%s).$$"
        while [ -e "$_quarantine" ] || [ -L "$_quarantine" ]; do _quarantine="${_quarantine}.x"; done
        mv /usrdata/root/bin "$_quarantine" || exit 1
        echo "Previous root bin quarantined at $_quarantine"
    fi
    mkdir -m 755 /usrdata/root/bin || exit 1
    chown root:root /usrdata/root/bin || exit 1
    rm -f /usrdata/root/.profile "$ROOT_HOME_HARDENED"
    printf '1\n' > "$ROOT_HOME_HARDENED" || exit 1
    chown root:root "$ROOT_HOME_HARDENED" && chmod 600 "$ROOT_HOME_HARDENED" || exit 1
elif [ -L /usrdata/root/bin ] || [ ! -d /usrdata/root/bin ]; then
    echo -e "\e[1;31mRefusing unsafe /usrdata/root/bin after hardening.\e[0m"
    exit 1
else
    chown root:root /usrdata/root/bin && chmod 755 /usrdata/root/bin || exit 1
fi
rm -f /usrdata/root/.profile
printf '%s\n' '# Set PATH for all shells' \
    'export PATH=/bin:/usr/sbin:/usr/bin:/sbin:/opt/sbin:/opt/bin:/usrdata/root/bin' \
    > /usrdata/root/.profile
chown root:root /usrdata/root/.profile
chmod 644 /usrdata/root/.profile
