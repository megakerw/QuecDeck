#!/bin/bash

# Define constants
GITUSER="megakerw"
REPONAME="QuecDeck"
GITTREE="main"
GITMAINTREE="main"
GITDEVTREE="main"
GITROOT="https://raw.githubusercontent.com/$GITUSER/$REPONAME/$GITTREE"
GITROOTMAIN="https://raw.githubusercontent.com/$GITUSER/$REPONAME/$GITMAINTREE"
GITROOTDEV="https://raw.githubusercontent.com/$GITUSER/$REPONAME/$GITDEVTREE"

DIR_NAME="quecdeck"
SERVICE_FILE="/lib/systemd/system/install_quecdeck.service"
SERVICE_NAME="install_quecdeck"
TMP_SCRIPT="/tmp/install_quecdeck.sh"
LOG_FILE="/tmp/install_quecdeck.log"
QUECDECK_DIR="/usrdata/quecdeck"
export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/opt/bin:/opt/sbin:/usrdata/root/bin

remount_rw() {
    mount -o remount,rw /
}

remount_ro() {
    mount -o remount,ro /
}

# Installation prep
remount_rw
trap 'remount_ro' EXIT
rm -f $SERVICE_FILE

# Create the systemd service file
cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=Update $DIR_NAME temporary service

[Service]
Type=oneshot
ExecStart=/bin/bash $TMP_SCRIPT
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE

[Install]
WantedBy=multi-user.target
EOF

# Create and populate the temporary shell script for installation
cat <<EOF > "$TMP_SCRIPT"
#!/bin/bash

GITUSER="megakerw"
REPONAME="QuecDeck"
GITTREE="main"
GITMAINTREE="main"
GITDEVTREE="main"
GITROOT="https://raw.githubusercontent.com/$GITUSER/$REPONAME/$GITTREE"
GITROOTMAIN="https://raw.githubusercontent.com/$GITUSER/$REPONAME/$GITMAINTREE"
GITROOTDEV="https://raw.githubusercontent.com/$GITUSER/$REPONAME/$GITDEVTREE"

QUECDECK_DIR="/usrdata/quecdeck"
export HOME=/usrdata/root
export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/opt/bin:/opt/sbin:/usrdata/root/bin

remount_rw() {
    mount -o remount,rw /
}

remount_ro() {
    mount -o remount,ro /
}

remount_rw
trap 'remount_ro' EXIT

# Preserve lean mode, watchcat, and scheduled restart state across updates
lean_mode_was_installed=0
[ -L /lib/systemd/system/multi-user.target.wants/lean-mode.service ] && lean_mode_was_installed=1
watchcat_was_installed=0
[ -L /lib/systemd/system/multi-user.target.wants/watchcat.service ] && watchcat_was_installed=1
scheduled_restart_was_installed=0
[ -L /lib/systemd/system/multi-user.target.wants/scheduled_restart.service ] && scheduled_restart_was_installed=1

uninstall_quecdeck() {
    echo "Uninstalling QuecDeck..."

    # Check if Lighttpd service is installed and remove it if present
    if [ -f "/lib/systemd/system/lighttpd.service" ]; then
        echo "Lighttpd detected, uninstalling Lighttpd webserver and its modules..."
        systemctl stop lighttpd
        rm -f /lib/systemd/system/lighttpd.service
        opkg --force-remove --force-removal-of-dependent-packages remove lighttpd-mod-authn_file lighttpd-mod-auth lighttpd-mod-magnet lighttpd-mod-cgi lighttpd-mod-openssl lighttpd-mod-proxy lighttpd
    fi

    echo -e "\e[1;34mUninstalling quecdeck content...\e[0m"
    systemctl stop watchcat 2>/dev/null
    systemctl stop scheduled_restart 2>/dev/null
    systemctl stop atcmd-daemon 2>/dev/null
    rm -f /lib/systemd/system/atcmd-daemon.service
    rm -f /lib/systemd/system/multi-user.target.wants/atcmd-daemon.service
    systemctl stop connection-logger 2>/dev/null
    rm -f /lib/systemd/system/connection-logger.service
    rm -f /lib/systemd/system/multi-user.target.wants/connection-logger.service
    systemctl daemon-reload

    echo -e "\e[1;34mUninstalling ttyd...\e[0m"
    systemctl stop ttyd
    rm -rf /usrdata/ttyd
    # Preserve var/ (watchcat config, lan_ip) and SSL certs across updates
    rm -f "$QUECDECK_DIR/atcli"
    rm -f /usrdata/root/bin/atcli
    rm -rf "$QUECDECK_DIR/www"
    rm -rf "$QUECDECK_DIR/systemd"
    rm -rf "$QUECDECK_DIR/script"
    rm -rf "$QUECDECK_DIR/console"
    rm -f /lib/systemd/system/ttyd.service
    rm -f /lib/systemd/system/multi-user.target.wants/ttyd.service
    rm -f /lib/systemd/system/lean-mode.service
    rm -f /lib/systemd/system/multi-user.target.wants/lean-mode.service
    rm -f /bin/ttyd
    rm -f /opt/etc/sudoers.d/www-data
    echo -e "\e[1;32mttyd has been uninstalled.\e[0m"

    echo "Uninstallation process completed."
}

install_lighttpd() {
    /opt/bin/opkg update || { echo -e "\e[1;31mFailed to update opkg package list.\e[0m"; return 1; }
    /opt/bin/opkg install sudo lighttpd lighttpd-mod-cgi lighttpd-mod-magnet lighttpd-mod-openssl lighttpd-mod-proxy || { echo -e "\e[1;31mFailed to install lighttpd packages.\e[0m"; return 1; }

    # Ensure rc.unslung doesn't try to start it
    for script in /opt/etc/init.d/*lighttpd*; do
        if [ -f "\$script" ]; then
            echo "Removing existing Lighttpd init script: \$script"
            rm "\$script"
        fi
    done

    systemctl stop lighttpd
    echo -e "\033[0;32mInstalling/Updating Lighttpd...\033[0m"
    mkdir -p "$QUECDECK_DIR/script"
    wget -O "$QUECDECK_DIR/lighttpd.conf" $GITROOT/quecdeck/lighttpd.conf || { echo -e "\e[1;31mFailed to download lighttpd.conf.\e[0m"; return 1; }
    wget -O "$QUECDECK_DIR/script/update_lan_ip.sh" $GITROOT/quecdeck/script/update_lan_ip.sh || { echo -e "\e[1;31mFailed to download update_lan_ip.sh.\e[0m"; return 1; }
    chmod +x "$QUECDECK_DIR/script/update_lan_ip.sh"
    wget -O "/lib/systemd/system/lighttpd.service" $GITROOT/quecdeck/systemd/lighttpd.service || { echo -e "\e[1;31mFailed to download lighttpd.service.\e[0m"; return 1; }
    ln -sf "/lib/systemd/system/lighttpd.service" "/lib/systemd/system/multi-user.target.wants/"
    echo "www-data ALL = (root) NOPASSWD: /usrdata/quecdeck/script/create_watchcat.sh, /usrdata/quecdeck/script/remove_watchcat.sh, /usrdata/quecdeck/script/create_scheduled_restart.sh, /usrdata/quecdeck/script/remove_scheduled_restart.sh, /bin/systemctl start ttyd, /bin/systemctl stop ttyd, /bin/systemctl start watchcat, /bin/systemctl stop watchcat, /bin/systemctl is-active watchcat, /usrdata/quecdeck/script/write_htpasswd.sh" > /opt/etc/sudoers.d/www-data

    if [ ! -f "$QUECDECK_DIR/server.crt" ] || [ ! -f "$QUECDECK_DIR/server.key" ]; then
        _cert_ip="192.168.225.1"
        if [ -f "/etc/data/mobileap_cfg.xml" ]; then
            _extracted=$(grep -o '<APIPAddr>[^<]*</APIPAddr>' "/etc/data/mobileap_cfg.xml" | sed 's/<APIPAddr>//;s/<\/APIPAddr>//')
            if printf '%s' "$_extracted" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' && \
               printf '%s' "$_extracted" | awk -F. '$1<=255&&$2<=255&&$3<=255&&$4<=255{exit 0} {exit 1}'; then
                _cert_ip="$_extracted"
            fi
        fi
        _tmpconf=$(mktemp)
        printf '[req]\ndistinguished_name=dn\n[dn]\n[san]\nsubjectAltName=IP:%s\n' "$_cert_ip" > "$_tmpconf"
        openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
            -subj "/O=QuecDeck/CN=QuecDeck" \
            -config "$_tmpconf" -extensions san \
            -keyout "$QUECDECK_DIR/server.key" -out "$QUECDECK_DIR/server.crt"
        rm -f "$_tmpconf"
    fi
    chmod 600 "$QUECDECK_DIR/server.key"
    systemctl daemon-reload
    systemctl start lighttpd

    echo -e "\033[0;32mLighttpd installation/update complete.\033[0m"
}

install_quecdeck() {
    echo -e "\e[1;31m2) Installing quecdeck from the $GITTREE branch\e[0m"

    mkdir -p $QUECDECK_DIR
    mkdir -p $QUECDECK_DIR/systemd
    mkdir -p $QUECDECK_DIR/script
    mkdir -p $QUECDECK_DIR/var
    chown www-data "$QUECDECK_DIR/var"
    chmod 700 "$QUECDECK_DIR/var"
    mkdir -p $QUECDECK_DIR/console
    mkdir -p $QUECDECK_DIR/console/menu
    mkdir -p $QUECDECK_DIR/www
    mkdir -p $QUECDECK_DIR/www/cgi-bin
    mkdir -p $QUECDECK_DIR/www/css
    mkdir -p $QUECDECK_DIR/www/js
    mkdir -p $QUECDECK_DIR/www/fonts

    echo "Downloading files..."

    cd $QUECDECK_DIR/systemd
    wget -q $GITROOT/quecdeck/systemd/lighttpd.service &
    wget -q $GITROOT/quecdeck/systemd/watchcat.service &
    wget -q $GITROOT/quecdeck/systemd/scheduled_restart.service &
    wget -q $GITROOT/quecdeck/systemd/atcmd-daemon.service &
    wget -q $GITROOT/quecdeck/systemd/lean-mode.service &
    wget -q $GITROOT/quecdeck/systemd/connection-logger.service &
    wget -q $GITROOT/quecdeck/systemd/firewall.service &
    wait

    cd $QUECDECK_DIR/script
    wget -q $GITROOT/quecdeck/script/remove_watchcat.sh &
    wget -q $GITROOT/quecdeck/script/create_watchcat.sh &
    wget -q $GITROOT/quecdeck/script/update_lan_ip.sh &
    wget -q $GITROOT/quecdeck/script/lean_mode.sh &
    wget -q $GITROOT/quecdeck/script/create_scheduled_restart.sh &
    wget -q $GITROOT/quecdeck/script/remove_scheduled_restart.sh &
    wget -q $GITROOT/quecdeck/script/atcmd_queue_daemon.sh &
    wget -q $GITROOT/quecdeck/script/connection_logger.sh &
    wget -q $GITROOT/quecdeck/script/watchcat.sh &
    wget -q $GITROOT/quecdeck/script/scheduled_restart.sh &
    wget -q $GITROOT/quecdeck/script/write_htpasswd.sh &
    wget -q $GITROOT/quecdeck/script/firewall.sh &
    wait

    cd $QUECDECK_DIR/console
    wget -q $GITROOT/quecdeck/console/.profile

    cd $QUECDECK_DIR/console/menu
    wget -q $GITROOT/quecdeck/console/menu/start_menu.sh
    ln -f $QUECDECK_DIR/console/menu/start_menu.sh /usrdata/root/bin/menu

    wget -q -O "$QUECDECK_DIR/auth.lua" $GITROOT/quecdeck/auth.lua

    cd $QUECDECK_DIR/www
    wget -q $GITROOT/quecdeck/www/deviceinfo.html &
    wget -q $GITROOT/quecdeck/www/login.html &
    wget -q $GITROOT/quecdeck/www/setup.html &
    wget -q $GITROOT/quecdeck/www/developer.html &
    wget -q $GITROOT/quecdeck/www/favicon.ico &
    wget -q $GITROOT/quecdeck/www/index.html &
    wget -q $GITROOT/quecdeck/www/network.html &
    wget -q $GITROOT/quecdeck/www/settings.html &
    wget -q $GITROOT/quecdeck/www/sms.html &
    wget -q $GITROOT/quecdeck/www/scanner.html &
    wget -q $GITROOT/quecdeck/www/monitoring.html &
    wget -q $GITROOT/quecdeck/www/logs.html &
    wait

    cd $QUECDECK_DIR/www/js
    wget -q $GITROOT/quecdeck/www/js/alpinejs.min.js &
    wget -q $GITROOT/quecdeck/www/js/bootstrap.bundle.min.js &
    wget -q $GITROOT/quecdeck/www/js/dark-mode.js &
    wget -q $GITROOT/quecdeck/www/js/nav.js &
    wget -q $GITROOT/quecdeck/www/js/utils.js &
    wget -q $GITROOT/quecdeck/www/js/parse-settings.js &
    wget -q $GITROOT/quecdeck/www/js/populate-bands.js &
    wget -q $GITROOT/quecdeck/www/js/login.js &
    wget -q $GITROOT/quecdeck/www/js/home.js &
    wget -q $GITROOT/quecdeck/www/js/settings.js &
    wget -q $GITROOT/quecdeck/www/js/scanner.js &
    wget -q $GITROOT/quecdeck/www/js/deviceinfo.js &
    wget -q $GITROOT/quecdeck/www/js/developer.js &
    wget -q $GITROOT/quecdeck/www/js/sms.js &
    wget -q $GITROOT/quecdeck/www/js/watchcat.js &
    wget -q $GITROOT/quecdeck/www/js/network.js &
    wget -q $GITROOT/quecdeck/www/js/logs.js &
    wget -q $GITROOT/quecdeck/www/js/setup.js &
    wait

    cd $QUECDECK_DIR/www/css
    wget -q $GITROOT/quecdeck/www/css/bootstrap.min.css &
    wget -q $GITROOT/quecdeck/www/css/styles.css &
    wait

    # Fonts are large binary files that never change between updates — skip if
    # already present to avoid re-downloading ~500 KB of woff2 files each time.
    cd $QUECDECK_DIR/www/fonts
    if [ ! -f "poppins-v23-latin-regular.woff2" ]; then
        echo "Downloading fonts..."
        wget -q $GITROOT/quecdeck/www/fonts/poppins-v23-latin-300italic.woff2 &
        wget -q $GITROOT/quecdeck/www/fonts/poppins-v23-latin-300.woff2 &
        wget -q $GITROOT/quecdeck/www/fonts/poppins-v23-latin-500italic.woff2 &
        wget -q $GITROOT/quecdeck/www/fonts/poppins-v23-latin-500.woff2 &
        wget -q $GITROOT/quecdeck/www/fonts/poppins-v23-latin-600italic.woff2 &
        wget -q $GITROOT/quecdeck/www/fonts/poppins-v23-latin-600.woff2 &
        wget -q $GITROOT/quecdeck/www/fonts/poppins-v23-latin-700italic.woff2 &
        wget -q $GITROOT/quecdeck/www/fonts/poppins-v23-latin-700.woff2 &
        wget -q $GITROOT/quecdeck/www/fonts/poppins-v23-latin-italic.woff2 &
        wget -q $GITROOT/quecdeck/www/fonts/poppins-v23-latin-regular.woff2 &
        wait
    else
        echo "Fonts already present, skipping."
    fi

    cd $QUECDECK_DIR/www/cgi-bin
    wget -q $GITROOT/quecdeck/www/cgi-bin/auth_login &
    wget -q $GITROOT/quecdeck/www/cgi-bin/auth_logout &
    wget -q $GITROOT/quecdeck/www/cgi-bin/auth_dev &
    wget -q $GITROOT/quecdeck/www/cgi-bin/get_atcommand &
    wget -q $GITROOT/quecdeck/www/cgi-bin/get_modem_stats &
    wget -q $GITROOT/quecdeck/www/cgi-bin/get_device_info &
    wget -q $GITROOT/quecdeck/www/cgi-bin/get_settings &
    wget -q $GITROOT/quecdeck/www/cgi-bin/set_setting &
    wget -q $GITROOT/quecdeck/www/cgi-bin/get_network_info &
    wget -q $GITROOT/quecdeck/www/cgi-bin/set_bands &
    wget -q $GITROOT/quecdeck/www/cgi-bin/save_apn &
    wget -q $GITROOT/quecdeck/www/cgi-bin/save_network_pref &
    wget -q $GITROOT/quecdeck/www/cgi-bin/set_cell_lock &
    wget -q $GITROOT/quecdeck/www/cgi-bin/get_neighbour_cells &
    wget -q $GITROOT/quecdeck/www/cgi-bin/get_sms &
    wget -q $GITROOT/quecdeck/www/cgi-bin/delete_sms &
    wget -q $GITROOT/quecdeck/www/cgi-bin/user_atcommand &
    wget -q $GITROOT/quecdeck/www/cgi-bin/get_ping &
    wget -q $GITROOT/quecdeck/www/cgi-bin/get_uptime &
    wget -q $GITROOT/quecdeck/www/cgi-bin/get_system_stats &
    wget -q $GITROOT/quecdeck/www/cgi-bin/get_watchcat_status &
    wget -q $GITROOT/quecdeck/www/cgi-bin/get_watchcat_stats &
    wget -q $GITROOT/quecdeck/www/cgi-bin/watchcat_maker &
    wget -q $GITROOT/quecdeck/www/cgi-bin/toggle_ttyd &
    wget -q $GITROOT/quecdeck/www/cgi-bin/get_scheduled_restart &
    wget -q $GITROOT/quecdeck/www/cgi-bin/scheduled_restart_maker &
    wget -q $GITROOT/quecdeck/www/cgi-bin/get_set_lanip &
    wget -q $GITROOT/quecdeck/www/cgi-bin/get_ippt_status &
    wget -q $GITROOT/quecdeck/www/cgi-bin/get_upnp_status &
    wget -q $GITROOT/quecdeck/www/cgi-bin/run_cell_scan &
    wget -q $GITROOT/quecdeck/www/cgi-bin/cgi-lib.sh &
    wget -q $GITROOT/quecdeck/www/cgi-bin/get_service_status &
    wget -q $GITROOT/quecdeck/www/cgi-bin/get_scan_status &
    wget -q $GITROOT/quecdeck/www/cgi-bin/get_logs &
    wget -q $GITROOT/quecdeck/www/cgi-bin/init_setup &
    wait

    # atcli is a compiled binary (~350 KB) — download only when the repo
    # checksum differs from the local file (or the file is missing).
    # Always reapply root:www-data 4750 so only the www-data daemon can invoke it.
    _atcli_expected=$(wget -qO- "$GITROOT/quecdeck/checksums.sha256" 2>/dev/null | \
        awk '/[*]quecdeck\/bin\/atcli/{print $1}')
    _atcli_current=""
    [ -f "$QUECDECK_DIR/atcli" ] && _atcli_current=$(sha256sum "$QUECDECK_DIR/atcli" 2>/dev/null | awk '{print $1}')
    if [ -n "$_atcli_expected" ] && [ "$_atcli_expected" = "$_atcli_current" ]; then
        echo "atcli up to date, skipping download."
    else
        echo "Downloading atcli..."
        wget -q -O "$QUECDECK_DIR/atcli" "$GITROOT/quecdeck/bin/atcli"
        ln -sf "$QUECDECK_DIR/atcli" /usrdata/root/bin/atcli
    fi
    chown root:www-data "$QUECDECK_DIR/atcli"
    chmod 4750 "$QUECDECK_DIR/atcli"

    echo "All files downloaded."

    cd /

    chmod +x $QUECDECK_DIR/www/cgi-bin/*
    chmod +x $QUECDECK_DIR/script/*
    chmod +x $QUECDECK_DIR/console/menu/*
    chmod +x $QUECDECK_DIR/console/.profile
    # Ensure sudo-accessible scripts are root-owned (prevents www-data from replacing them)
    chown root:root $QUECDECK_DIR/script/create_watchcat.sh
    chown root:root $QUECDECK_DIR/script/remove_watchcat.sh
    chown root:root $QUECDECK_DIR/script/create_scheduled_restart.sh
    chown root:root $QUECDECK_DIR/script/remove_scheduled_restart.sh
    chown root:root $QUECDECK_DIR/script/update_lan_ip.sh
    chown root:root $QUECDECK_DIR/script/write_htpasswd.sh
    cp -f $QUECDECK_DIR/console/.profile /usrdata/root/.profile
    chmod +x /usrdata/root/.profile
    cp -rf $QUECDECK_DIR/systemd/* /lib/systemd/system

    # Restore lean mode symlink if it was enabled before the update
    if [ "\$lean_mode_was_installed" = "1" ]; then
        ln -sf /lib/systemd/system/lean-mode.service /lib/systemd/system/multi-user.target.wants/lean-mode.service
        echo "Lean Mode preserved."
    fi

    # Verify integrity of all downloaded files against published checksums
    echo "Verifying file integrity..."
    CHECKSUMS_FILE="/tmp/quecdeck/checksums.sha256"
    mkdir -p /tmp/quecdeck
    wget -q -O "\$CHECKSUMS_FILE" "$GITROOT/quecdeck/checksums.sha256"
    if [ ! -f "\$CHECKSUMS_FILE" ]; then
        echo "WARNING: Could not download checksums file, skipping verification."
    else
        verify_ok=1
        while IFS= read -r line; do
            # Skip comments and blank lines
            case "\$line" in '#'*|'') continue ;; esac
            expected=\$(echo "\$line" | awk '{print \$1}')
            key=\$(echo "\$line" | awk '{print \$2}')
            # Map repo-relative path to installed path
            rel=\${key#*quecdeck/}
            file="\$QUECDECK_DIR/\$rel"
            if [ -f "\$file" ]; then
                actual=\$(sha256sum "\$file" | awk '{print \$1}')
                if [ "\$actual" != "\$expected" ]; then
                    echo "ERROR: Checksum mismatch: \$file"
                    echo "  Expected: \$expected"
                    echo "  Got:      \$actual"
                    verify_ok=0
                fi
            fi
        done < "\$CHECKSUMS_FILE"
        rm -f "\$CHECKSUMS_FILE"
        if [ "\$verify_ok" = "1" ]; then
            echo "All checksums verified OK."
        else
            echo "FATAL: One or more files failed checksum verification. Installation may be compromised."
            return 1
        fi
    fi

    systemctl daemon-reload
    ln -sf /lib/systemd/system/firewall.service /lib/systemd/system/multi-user.target.wants/firewall.service
    systemctl restart firewall
    ln -sf /lib/systemd/system/atcmd-daemon.service /lib/systemd/system/multi-user.target.wants/atcmd-daemon.service
    systemctl restart atcmd-daemon
    ln -sf /lib/systemd/system/connection-logger.service /lib/systemd/system/multi-user.target.wants/connection-logger.service
    systemctl restart connection-logger
    rm -f /lib/systemd/system/multi-user.target.wants/watchcat.service

    # Re-engage lean mode immediately if it was active before the update.
    # --no-block prevents the update from waiting up to 90s for the polling loop.
    if [ "\$lean_mode_was_installed" = "1" ]; then
        systemctl start --no-block lean-mode
    fi

    # Restore watchcat if it was running before the update
    if [ "\$watchcat_was_installed" = "1" ] && \
       [ -f /usrdata/quecdeck/var/watchcat.json ]; then
        ln -sf /lib/systemd/system/watchcat.service /lib/systemd/system/multi-user.target.wants/watchcat.service
        systemctl restart watchcat
        echo "Watchcat preserved and restarted."
    fi

    # Restore scheduled restart if it was running before the update
    if [ "\$scheduled_restart_was_installed" = "1" ] && \
       [ -f /usrdata/quecdeck/var/scheduled_restart.json ]; then
        ln -sf /lib/systemd/system/scheduled_restart.service /lib/systemd/system/multi-user.target.wants/scheduled_restart.service
        systemctl restart scheduled_restart
        echo "Scheduled restart preserved and restarted."
    fi
}

install_ttyd() {
    # ttyd project does not publish official checksums — pin the hash of the known-good binary here.
    # To update: download the new release, run sha256sum on it, and update TTYD_HASH + the URL below.
    TTYD_VERSION="1.7.7"
    TTYD_HASH="8240c8438b68d3b10b0e1a4e7c914d70fca6a7606b516f40bf40adfa1044d801"

    echo -e "\e[1;34mStarting ttyd installation process...\e[0m"
    cd $QUECDECK_DIR/console
    curl -L -o ttyd https://github.com/tsl0922/ttyd/releases/download/\${TTYD_VERSION}/ttyd.armhf || { echo -e "\e[1;31mFailed to download ttyd.\e[0m"; return 1; }
    echo "\${TTYD_HASH}  ttyd" | sha256sum -c >/dev/null || { echo -e "\e[1;31mIntegrity check failed for ttyd.\e[0m"; rm -f ttyd; return 1; }
    chmod +x ttyd
    wget -q "$GITROOT/quecdeck/console/ttyd.bash" || { echo -e "\e[1;31mFailed to download ttyd.bash.\e[0m"; return 1; }
    chmod +x ttyd.bash
    cd $QUECDECK_DIR/systemd/
    wget -q "$GITROOT/quecdeck/systemd/ttyd.service" || { echo -e "\e[1;31mFailed to download ttyd.service.\e[0m"; return 1; }
    cp -f $QUECDECK_DIR/systemd/ttyd.service /lib/systemd/system/
    ln -sf /usrdata/quecdeck/console/ttyd /bin

    # Install service file but do NOT enable or start — user starts ttyd on demand via Developer page
    systemctl daemon-reload
    rm -f /lib/systemd/system/multi-user.target.wants/ttyd.service

    echo -e "\e[1;32mInstallation Complete! Start ttyd from the Developer page when needed.\e[0m"
}

result_uninstall="FAILED"
result_lighttpd="FAILED"
result_quecdeck="FAILED"
result_ttyd="FAILED"
result_firewall="FAILED"

if [ -d "\$QUECDECK_DIR/www" ]; then
    uninstall_quecdeck && result_uninstall="OK"
else
    result_uninstall="SKIPPED"
fi
install_lighttpd && result_lighttpd="OK"
if [ "\$result_lighttpd" = "OK" ]; then
    install_quecdeck && result_quecdeck="OK"
fi
install_ttyd        && result_ttyd="OK" || result_ttyd="WARNING"
systemctl is-active firewall >/dev/null 2>&1 && result_firewall="OK" || result_firewall="FAILED"

_show_result() {
    local label="\$1" val="\$2"
    case "\$val" in
        OK)      echo -e "  \$(printf '%-22s' "\$label") \e[1;32m\$val\e[0m" ;;
        WARNING) echo -e "  \$(printf '%-22s' "\$label") \e[1;33m\$val\e[0m" ;;
        SKIPPED) echo -e "  \$(printf '%-22s' "\$label") \$val" ;;
        *)       echo -e "  \$(printf '%-22s' "\$label") \e[1;31m\$val\e[0m" ;;
    esac
}

echo ""
echo "Install Summary"
echo "============================================"
_show_result "Uninstall previous" "\$result_uninstall"
_show_result "Lighttpd"           "\$result_lighttpd"
_show_result "QuecDeck"           "\$result_quecdeck"
_show_result "Firewall"           "\$result_firewall"
_show_result "ttyd"               "\$result_ttyd"
echo "============================================"

rm -f /tmp/install_quecdeck.sh
rm -f /lib/systemd/system/install_quecdeck.service
rm -f /lib/systemd/system/multi-user.target.wants/install_quecdeck.service
systemctl daemon-reload
remount_ro
exit 0
EOF

# Make the temporary script executable
chmod +x "$TMP_SCRIPT"

# Run the rest of the installation via the systemd service
systemctl daemon-reload
systemctl start $SERVICE_NAME
echo ""
if [ -f "$LOG_FILE" ]; then
    if grep -q "Install Summary" "$LOG_FILE"; then
        echo -e "\e[1;32mQuecDeck installed.\e[0m"
        echo ""
        sed -n '/Install Summary/,$p' "$LOG_FILE"
        echo ""
    else
        echo -e "\e[1;31mInstall did not complete. Check $LOG_FILE for details.\e[0m"
    fi
fi
remount_ro
