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
# KNOWN LIMITATION: opkg and opkg.conf are fetched over plain HTTP with no
# integrity check (Entware ships no signed installer, and the modem's wget can't
# validate TLS). This is used once during the first install. The exposure is a
# WAN-path MITM during
# bootstrap. To close: pin their sha256 here, or vendor opkg in the repo and pull
# it over the GitHub channel with a hash check, like atcli.
URL=http://bin.entware.net/${ARCH}/installer
wget $URL/opkg -O /opt/bin/opkg || { echo -e "\e[1;31mFailed to download opkg binary.\e[0m"; exit 1; }
chmod 755 /opt/bin/opkg
wget $URL/opkg.conf -O /opt/etc/opkg.conf || { echo -e "\e[1;31mFailed to download opkg.conf.\e[0m"; exit 1; }

echo -e '\033[32mInfo: Basic packages installation...\033[0m'
/opt/bin/opkg update
/opt/bin/opkg install entware-opt

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
