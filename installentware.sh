#!/bin/sh
# Modified by iamromulan to set up a proper entware environment for Quectel RM5xx series m.2 modems
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

# Verified on stock firmware: curl and its CA store do not depend on Entware.
# Refuse unsupported firmware before changing mounts or the package manager.
[ -x /usr/bin/curl ] && [ -s /etc/ssl/certs/ca-certificates.crt ] || {
    echo "Stock curl and CA certificates are required for HTTPS bootstrap." >&2
    exit 1
}

# Remount filesystem as read-write
mount -o remount,rw /
trap 'mount -o remount,ro /' EXIT  # ensures RO is restored on any exit path

create_opt_mount() {
    # Bind /usrdata/opt to /opt
    echo -e '\033[32mInfo: Setting up /opt mount to /usrdata/opt...\033[0m'
    cat <<EOF > /lib/systemd/system/opt.mount
[Unit]
Description=Bind /usrdata/opt to /opt

[Mount]
What=/usrdata/opt
Where=/opt
Type=none
Options=bind

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl start opt.mount
    
    # Additional systemd service to ensure opt.mount starts at boot
    echo -e '\033[32mInfo: Creating service to start opt.mount at boot...\033[0m'
    cat <<EOF > /lib/systemd/system/start-opt-mount.service
[Unit]
Description=Ensure opt.mount is started at boot
After=network.target

[Service]
Type=oneshot
ExecStart=/bin/systemctl start opt.mount

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    ln -sf /lib/systemd/system/start-opt-mount.service /lib/systemd/system/multi-user.target.wants/start-opt-mount.service
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
create_opt_mount
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
/usr/bin/curl -q --proto '=https' --proto-redir '=https' --cacert /etc/ssl/certs/ca-certificates.crt -fsSL --connect-timeout 15 --max-time 60 --retry 1 -o /opt/bin/opkg "$URL/opkg" || { echo -e "\e[1;31mFailed to download opkg binary.\e[0m"; exit 1; }
chmod 755 /opt/bin/opkg
/usr/bin/curl -q --proto '=https' --proto-redir '=https' --cacert /etc/ssl/certs/ca-certificates.crt -fsSL --connect-timeout 15 --max-time 30 --retry 1 -o /opt/etc/opkg.conf "$URL/opkg.conf" || { echo -e "\e[1;31mFailed to download opkg.conf.\e[0m"; exit 1; }

bootstrap_tls_packages() {
    # Scope PATH and cleanup to a subshell, preserving the outer remount trap.
    (
        umask 077
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
        /opt/bin/opkg install wget-ssl ca-certificates entware-opt || exit 1
    )
}

echo -e '\033[32mInfo: Basic packages installation...\033[0m'
# Secure the index and every dependency from the first package batch onwards.
sed -i 's|http://bin\.entware\.net/|https://bin.entware.net/|g' /opt/etc/opkg.conf || exit 1
bootstrap_tls_packages || exit 1
# opkg chooses its downloader from PATH. The firmware wget cannot verify TLS.
PATH=/opt/bin:/opt/sbin:$PATH /opt/bin/opkg update || {
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
cat <<EOF > /lib/systemd/system/rc.unslung.service
[Unit]
Description=Start Entware services

[Service]
Type=oneshot
# Add a delay to give /opt time to mount
ExecStartPre=/bin/sleep 5
ExecStart=/opt/etc/init.d/rc.unslung start
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
ln -sf /lib/systemd/system/rc.unslung.service /lib/systemd/system/multi-user.target.wants/rc.unslung.service
systemctl start rc.unslung.service
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
