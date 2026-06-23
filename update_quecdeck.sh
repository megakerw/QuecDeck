#!/bin/bash

# Define constants
GITUSER="megakerw"
REPONAME="QuecDeck"
GITTREE="${1:-main}"
GITROOT="https://raw.githubusercontent.com/$GITUSER/$REPONAME/$GITTREE"

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

UPDATE_LOCK_FILE=/tmp/quecdeck_update.lock
if ! command -v flock >/dev/null 2>&1; then
    echo "FATAL: flock command not found. Cannot safely check for a running update."
    exit 1
fi
if ! ( umask 0; exec 9>"$UPDATE_LOCK_FILE"; flock -n 9 ); then
    echo "An update is already in progress."
    exit 1
fi

# Installation prep
remount_rw
trap 'remount_ro' EXIT  # ensures RO is restored on any exit path
rm -f $SERVICE_FILE

# Create the systemd service file
cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=Update $DIR_NAME temporary service

[Service]
Type=oneshot
TimeoutStartSec=0
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
GITROOT="https://raw.githubusercontent.com/$GITUSER/$REPONAME/$GITTREE"

QUECDECK_DIR="/usrdata/quecdeck"
STAGE_DIR="\${QUECDECK_DIR}.new"
OLD_DIR="\${QUECDECK_DIR}.old"
STATUS_FILE=/tmp/quecdeck_update.status
export HOME=/usrdata/root
export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/opt/bin:/opt/sbin:/usrdata/root/bin

remount_rw() {
    mount -o remount,rw /
}

remount_ro() {
    mount -o remount,ro /
}

UPDATE_LOCK_FILE=/tmp/quecdeck_update.lock
if ! command -v flock >/dev/null 2>&1; then
    echo "FATAL: flock command not found. Cannot safely check for a running update."
    exit 1
fi
_orig_umask=\$(umask)
umask 0
exec 9>"\$UPDATE_LOCK_FILE"
umask "\$_orig_umask"
if ! flock -n 9; then
    echo "Another update is already running. Aborting."
    exit 1
fi

echo "running" > "\${STATUS_FILE}.tmp" && mv "\${STATUS_FILE}.tmp" "\$STATUS_FILE"

remount_rw

_update_status="failed"

_update_cleanup() {
    echo "\$_update_status" > "\${STATUS_FILE}.tmp" && mv "\${STATUS_FILE}.tmp" "\$STATUS_FILE" || rm -f "\${STATUS_FILE}.tmp"
    remount_ro
}
trap '_update_cleanup' EXIT

# Preserve lean mode, watchcat, and scheduled restart state across updates
lean_mode_was_installed=0
[ -L /lib/systemd/system/multi-user.target.wants/lean-mode.service ] && lean_mode_was_installed=1
watchcat_was_installed=0
[ -L /lib/systemd/system/multi-user.target.wants/watchcat.service ] && watchcat_was_installed=1
scheduled_restart_was_installed=0
[ -L /lib/systemd/system/multi-user.target.wants/scheduled_restart.service ] && scheduled_restart_was_installed=1

preflight_check() {
    echo "Running pre-flight checks..."
    _pf_checksums=/tmp/quecdeck_preflight.sha256

    /opt/bin/wget --timeout=30 --tries=2 -q -O "\$_pf_checksums" "$GITROOT/quecdeck/checksums.sha256" || {
        echo "FATAL: Could not download release files. Check network connectivity and that the release tag exists."
        rm -f "\$_pf_checksums"
        return 1
    }
    if [ ! -s "\$_pf_checksums" ]; then
        echo "FATAL: Release checksums file is empty. The release tag may not exist."
        rm -f "\$_pf_checksums"
        return 1
    fi
    rm -f "\$_pf_checksums"

    # The new release is staged alongside the live install before swapping in,
    # so /usrdata briefly holds both copies at once. Require headroom for
    # roughly 2.2x the current install size (live + staged + a small margin
    # for the old copy that lingers until cleanup completes).
    _pf_needed=\$(du -sk "$QUECDECK_DIR" 2>/dev/null | awk '{print int(\$1*2.2)}')
    _pf_needed=\${_pf_needed:-4000}
    _pf_free=\$(df -k /usrdata 2>/dev/null | awk 'NR==2 {print \$4}')
    if [ -n "\$_pf_free" ] && [ "\$_pf_free" -lt "\$_pf_needed" ]; then
        echo "FATAL: Not enough free space on /usrdata (need ~\${_pf_needed}KB, have \${_pf_free}KB). Aborting update."
        return 1
    fi

    echo "Pre-flight checks passed."
    return 0
}

stage_release() {
    echo -e "\e[1;32mDownloading new release...\e[0m"

    rm -rf "\$STAGE_DIR"
    mkdir -p \$STAGE_DIR
    mkdir -p \$STAGE_DIR/systemd
    mkdir -p \$STAGE_DIR/script
    mkdir -p \$STAGE_DIR/console
    mkdir -p \$STAGE_DIR/console/menu
    mkdir -p \$STAGE_DIR/www
    mkdir -p \$STAGE_DIR/www/cgi-bin
    mkdir -p \$STAGE_DIR/www/css
    mkdir -p \$STAGE_DIR/www/js
    mkdir -p \$STAGE_DIR/www/fonts

    echo "Downloading files..."

    cd \$STAGE_DIR/systemd
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/systemd/lighttpd.service &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/systemd/watchcat.service &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/systemd/scheduled_restart.service &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/systemd/atcmd-daemon.service &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/systemd/lean-mode.service &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/systemd/connection-logger.service &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/systemd/firewall.service &
    wait

    cd \$STAGE_DIR/script
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/script/remove_watchcat.sh &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/script/create_watchcat.sh &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/script/lighttpd_prestart.sh &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/script/lean_mode.sh &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/script/create_scheduled_restart.sh &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/script/remove_scheduled_restart.sh &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/script/atcmd_queue_daemon.sh &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/script/connection_logger.sh &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/script/watchcat.sh &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/script/scheduled_restart.sh &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/script/json-lib.sh &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/script/cgi-lib.sh &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/script/write_htpasswd.sh &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/script/firewall.sh &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/script/run_update.sh &
    wait

    cd \$STAGE_DIR/console
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/console/.profile

    cd \$STAGE_DIR/console/menu
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/console/menu/start_menu.sh

    /opt/bin/wget --timeout=30 --tries=2 -q -O "\$STAGE_DIR/auth.lua" $GITROOT/quecdeck/auth.lua
    printf '%s\n' "${GITTREE#v}" > "\$STAGE_DIR/version"
    /opt/bin/wget --timeout=30 --tries=2 -q -O "\$STAGE_DIR/lighttpd.conf" $GITROOT/quecdeck/lighttpd.conf || { echo -e "\e[1;31mFailed to download lighttpd.conf.\e[0m"; return 1; }

    cd \$STAGE_DIR/www
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/deviceinfo.html &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/login.html &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/setup.html &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/developer.html &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/favicon.ico &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/index.html &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/network.html &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/settings.html &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/sms.html &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/scanner.html &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/monitoring.html &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/logs.html &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/update.html &
    wait

    cd \$STAGE_DIR/www/js
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/js/alpinejs.min.js &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/js/bootstrap.bundle.min.js &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/js/dark-mode.js &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/js/nav.js &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/js/utils.js &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/js/parse-settings.js &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/js/populate-bands.js &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/js/login.js &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/js/home.js &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/js/settings.js &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/js/scanner.js &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/js/deviceinfo.js &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/js/developer.js &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/js/sms.js &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/js/watchcat.js &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/js/network.js &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/js/logs.js &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/js/setup.js &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/js/update.js &
    wait

    cd \$STAGE_DIR/www/css
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/css/bootstrap.min.css &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/css/styles.css &
    wait

    # Fonts are large binary files that never change between updates. Copy
    # forward from the live install if present instead of re-downloading ~500 KB.
    cd \$STAGE_DIR/www/fonts
    if [ -f "\$QUECDECK_DIR/www/fonts/poppins-v23-latin-regular.woff2" ]; then
        cp -f \$QUECDECK_DIR/www/fonts/*.woff2 . 2>/dev/null
        echo "Fonts copied from existing install."
    else
        echo "Downloading fonts..."
        /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/fonts/poppins-v23-latin-300italic.woff2 &
        /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/fonts/poppins-v23-latin-300.woff2 &
        /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/fonts/poppins-v23-latin-500italic.woff2 &
        /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/fonts/poppins-v23-latin-500.woff2 &
        /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/fonts/poppins-v23-latin-600italic.woff2 &
        /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/fonts/poppins-v23-latin-600.woff2 &
        /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/fonts/poppins-v23-latin-700italic.woff2 &
        /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/fonts/poppins-v23-latin-700.woff2 &
        /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/fonts/poppins-v23-latin-italic.woff2 &
        /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/fonts/poppins-v23-latin-regular.woff2 &
        wait
    fi

    cd \$STAGE_DIR/www/cgi-bin
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/cgi-bin/auth_login &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/cgi-bin/auth_logout &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/cgi-bin/auth_dev &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/cgi-bin/get_deviceinfo &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/cgi-bin/get_settings &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/cgi-bin/set_setting &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/cgi-bin/get_network_info &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/cgi-bin/set_bands &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/cgi-bin/save_apn &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/cgi-bin/save_network_pref &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/cgi-bin/set_cell_lock &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/cgi-bin/get_neighbour_cells &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/cgi-bin/get_sms &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/cgi-bin/delete_sms &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/cgi-bin/user_atcommand &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/cgi-bin/get_ping &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/cgi-bin/get_dashboard &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/cgi-bin/get_watchcat_status &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/cgi-bin/get_watchcat_stats &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/cgi-bin/watchcat_maker &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/cgi-bin/toggle_ttyd &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/cgi-bin/get_scheduled_restart &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/cgi-bin/scheduled_restart_maker &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/cgi-bin/get_set_lanip &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/cgi-bin/get_ippt_status &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/cgi-bin/get_upnp_status &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/cgi-bin/run_cell_scan &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/cgi-bin/get_service_status &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/cgi-bin/get_scan_status &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/cgi-bin/get_logs &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/cgi-bin/get_restart_log &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/cgi-bin/clear_restart_log &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/cgi-bin/check_update &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/cgi-bin/trigger_update &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/cgi-bin/get_update_log &
    /opt/bin/wget --timeout=30 --tries=2 -q $GITROOT/quecdeck/www/cgi-bin/init_setup &
    wait

    # atcli is a compiled binary (~350 KB). Copy forward from the live install
    # when the repo checksum matches it, instead of re-downloading.
    _atcli_expected=\$(/opt/bin/wget --timeout=30 --tries=2 -qO- "$GITROOT/quecdeck/checksums.sha256" 2>/dev/null | \
        awk '/[*]quecdeck\/bin\/atcli/{print \$1}')
    _atcli_current=""
    [ -f "\$QUECDECK_DIR/atcli" ] && _atcli_current=\$(sha256sum "\$QUECDECK_DIR/atcli" 2>/dev/null | awk '{print \$1}')
    if [ -n "\$_atcli_expected" ] && [ "\$_atcli_expected" = "\$_atcli_current" ]; then
        echo "atcli up to date, copying from existing install."
        cp -f "\$QUECDECK_DIR/atcli" "\$STAGE_DIR/atcli"
    else
        echo "Downloading atcli..."
        /opt/bin/wget --timeout=30 --tries=2 -q -O "\$STAGE_DIR/atcli" "$GITROOT/quecdeck/bin/atcli" || {
            echo -e "\e[1;31mFailed to download atcli.\e[0m"
            return 1
        }
        if [ -n "\$_atcli_expected" ]; then
            _atcli_downloaded=\$(sha256sum "\$STAGE_DIR/atcli" 2>/dev/null | awk '{print \$1}')
            if [ "\$_atcli_downloaded" != "\$_atcli_expected" ]; then
                echo -e "\e[1;31mFATAL: atcli checksum mismatch after download.\e[0m"
                return 1
            fi
        fi
    fi
    chown root:www-data "\$STAGE_DIR/atcli"
    chmod 4750 "\$STAGE_DIR/atcli"

    echo "All files downloaded."

    cd /

    # cgi.assign executes ANY file under cgi-bin, so keep it root-owned and not
    # www-data-writable (755): a web-tier compromise can't drop/overwrite a CGI.
    chown -R root:www-data \$STAGE_DIR/www/cgi-bin
    chmod 755 \$STAGE_DIR/www/cgi-bin \$STAGE_DIR/www/cgi-bin/*
    chmod +x \$STAGE_DIR/script/*
    chmod +x \$STAGE_DIR/console/menu/*
    chmod +x \$STAGE_DIR/console/.profile
    # Ensure sudo-accessible scripts are root-owned (prevents www-data from replacing them)
    chown root:root \$STAGE_DIR/script/create_watchcat.sh
    chown root:root \$STAGE_DIR/script/remove_watchcat.sh
    chown root:root \$STAGE_DIR/script/create_scheduled_restart.sh
    chown root:root \$STAGE_DIR/script/remove_scheduled_restart.sh
    chown root:root \$STAGE_DIR/script/lighttpd_prestart.sh
    chmod 700 \$STAGE_DIR/script/lighttpd_prestart.sh
    chown root:root \$STAGE_DIR/script/write_htpasswd.sh
    chown root:root \$STAGE_DIR/script/run_update.sh
    chmod 700 \$STAGE_DIR/script/run_update.sh

    # Detect empty files from failed downloads before checksum verification
    _empty=\$(find "\$STAGE_DIR" -type f -empty 2>/dev/null)
    if [ -n "\$_empty" ]; then
        echo "FATAL: One or more downloads produced empty files (possible network failure):"
        printf '%s\n' "\$_empty" | while IFS= read -r _f; do echo "  \$_f"; done
        return 1
    fi

    # Verify integrity of all downloaded files against published checksums
    echo "Verifying file integrity..."
    CHECKSUMS_FILE="/tmp/quecdeck/checksums.sha256"
    mkdir -p /tmp/quecdeck
    /opt/bin/wget --timeout=30 --tries=2 -q -O "\$CHECKSUMS_FILE" "$GITROOT/quecdeck/checksums.sha256" || {
        echo "FATAL: Could not download checksums file. Aborting."
        return 1
    }
    if [ ! -s "\$CHECKSUMS_FILE" ]; then
        echo "FATAL: Checksums file is empty after download. Aborting."
        return 1
    fi
    verify_ok=1
    while IFS= read -r line; do
        # Skip comments and blank lines
        case "\$line" in '#'*|'') continue ;; esac
        expected=\$(echo "\$line" | awk '{print \$1}')
        key=\$(echo "\$line" | awk '{print \$2}')
        # Map repo-relative path to staged path; skip entries not under quecdeck/
        rel=\${key#*quecdeck/}
        [ "\$rel" = "\$key" ] && continue
        file="\$STAGE_DIR/\$rel"
        if [ -f "\$file" ]; then
            actual=\$(sha256sum "\$file" | awk '{print \$1}')
            if [ "\$actual" != "\$expected" ]; then
                echo "ERROR: Checksum mismatch: \$file"
                echo "  Expected: \$expected"
                echo "  Got:      \$actual"
                verify_ok=0
            fi
        else
            case "\$rel" in
                bin/atcli|systemd/ttyd.service|console/ttyd.bash|quecdeckdevpasswd) ;;
                *)
                    echo "ERROR: File missing from staged release: \$file"
                    verify_ok=0
                    ;;
            esac
        fi
    done < "\$CHECKSUMS_FILE"
    rm -f "\$CHECKSUMS_FILE"
    if [ "\$verify_ok" != "1" ]; then
        echo "FATAL: One or more files failed checksum verification. Staged release may be compromised."
        return 1
    fi
    echo "All checksums verified OK."

    # Carry forward state that lives outside the downloaded release: watchcat/
    # scheduled-restart config, lan_ip, and the TLS certificate (so HTTPS clients
    # don't have to re-trust a brand-new cert on every update).
    mkdir -p "\$STAGE_DIR/var"
    if [ -d "\$QUECDECK_DIR/var" ]; then
        cp -rf "\$QUECDECK_DIR/var/." "\$STAGE_DIR/var/" 2>/dev/null || true
    fi
    chown -R www-data "\$STAGE_DIR/var"
    chmod 700 "\$STAGE_DIR/var"
    [ -f "\$QUECDECK_DIR/server.crt" ] && cp -f "\$QUECDECK_DIR/server.crt" "\$STAGE_DIR/server.crt"
    [ -f "\$QUECDECK_DIR/server.key" ] && cp -f "\$QUECDECK_DIR/server.key" "\$STAGE_DIR/server.key"

    # Generate a TLS certificate if one wasn't carried forward from a previous install
    if [ ! -f "\$STAGE_DIR/server.crt" ] || [ ! -f "\$STAGE_DIR/server.key" ]; then
        _cert_ip="192.168.225.1"
        if [ -f "/etc/data/mobileap_cfg.xml" ]; then
            _extracted=\$(grep -o '<APIPAddr>[^<]*</APIPAddr>' "/etc/data/mobileap_cfg.xml" | sed 's/<APIPAddr>//;s/<\/APIPAddr>//')
            if printf '%s' "\$_extracted" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' && \
               printf '%s' "\$_extracted" | awk -F. '\$1<=255&&\$2<=255&&\$3<=255&&\$4<=255{exit 0} {exit 1}'; then
                _cert_ip="\$_extracted"
            fi
        fi
        _tmpconf=\$(mktemp)
        printf '[req]\ndistinguished_name=dn\n[dn]\n[san]\nsubjectAltName=IP:%s\n' "\$_cert_ip" > "\$_tmpconf"
        openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
            -subj "/O=QuecDeck/CN=QuecDeck" \
            -config "\$_tmpconf" -extensions san \
            -keyout "\$STAGE_DIR/server.key" -out "\$STAGE_DIR/server.crt" || {
            rm -f "\$_tmpconf"
            echo -e "\e[1;31mFATAL: Failed to generate TLS certificate.\e[0m"
            return 1
        }
        rm -f "\$_tmpconf"
    fi
    chmod 600 "\$STAGE_DIR/server.key"

    # lighttpd is reinstalled only when actually necessary. Determining
    # that (presence AND staleness) requires a fresh opkg index, so do all of
    # this here in staging where it overlaps with the old site still serving.
    # Reading the installed-package database and comparing against the index
    # never touches the live lighttpd process; only the eventual opkg install
    # (deferred to the swap, since its postinst scripts may restart the
    # service) needs that controlled window.
    echo "Checking lighttpd package status..."
    _lighttpd_pkgs="sudo lighttpd lighttpd-mod-cgi lighttpd-mod-magnet lighttpd-mod-openssl lighttpd-mod-proxy"
    _lighttpd_needs_install=0
    _lighttpd_index_fresh=1
    timeout 120 /opt/bin/opkg update >/dev/null 2>&1 || {
        echo -e "\e[1;33mWARNING: Could not refresh the opkg package index. Proceeding with a presence-only check (version-staleness can't be verified this run).\e[0m"
        _lighttpd_index_fresh=0
    }
    _lighttpd_installed=\$(/opt/bin/opkg list-installed 2>/dev/null)
    [ "\$_lighttpd_index_fresh" = "1" ] && _lighttpd_upgradable=\$(/opt/bin/opkg list-upgradable 2>/dev/null)
    for _pkg in \$_lighttpd_pkgs; do
        if ! printf '%s\n' "\$_lighttpd_installed" | grep -q "^\$_pkg "; then
            echo "  \$_pkg: not installed"
            _lighttpd_needs_install=1
        elif [ "\$_lighttpd_index_fresh" = "1" ] && printf '%s\n' "\$_lighttpd_upgradable" | grep -q "^\$_pkg "; then
            echo "  \$_pkg: update available"
            _lighttpd_needs_install=1
        fi
    done
    if [ "\$_lighttpd_needs_install" = "1" ]; then
        echo "Lighttpd packages will be (re)installed during the switch."
        result_lighttpd="PENDING"
    elif [ "\$_lighttpd_index_fresh" = "1" ]; then
        echo "Lighttpd packages are present and up to date."
        result_lighttpd="SKIPPED"
    else
        echo "Lighttpd packages are present (staleness not verified this run)."
        result_lighttpd="SKIPPED"
    fi

    echo -e "\e[1;32mNew release staged.\e[0m"
    return 0
}

swap_in_release() {
    _had_previous=0
    [ -d "\$QUECDECK_DIR/www" ] && _had_previous=1

    # Snapshot the live release's systemd unit filenames before the swap. Unlike
    # everything else inside \$QUECDECK_DIR (which the rename-based rollback
    # restores wholesale), unit files are copied out into /lib/systemd/system/
    # by name, so a brand-new unit introduced by this release would be left
    # behind as an orphan if we have to roll back, since the restored old
    # release's systemd/ directory never contained it. Diff the staged set
    # against this snapshot below so _revert_swap knows what to remove.
    _old_systemd_units=""
    [ "\$_had_previous" = "1" ] && _old_systemd_units=\$(ls "\$QUECDECK_DIR/systemd/" 2>/dev/null)

    # Tracks whether we've actually started rearranging the live install. Only
    # then is there anything for _revert_swap to undo. A failure before this
    # point means the old site is still sitting at \$QUECDECK_DIR untouched, so
    # reporting a "rollback" (let alone a failed one) would be actively misleading.
    _swap_committed=0

    # Only stop/start lighttpd if config, the unit file, or packages changed.
    # Pure content updates (HTML/JS/CSS/CGI/auth.lua) go live without a restart:
    # the mv is atomic so lighttpd serves new content immediately, and mod_magnet
    # reloads auth.lua on the next request when it detects the mtime change.
    _need_lighttpd_restart=0
    if [ "\$_lighttpd_needs_install" = "1" ] || [ "\$_had_previous" = "0" ]; then
        _need_lighttpd_restart=1
    else
        # lighttpd_prestart.sh patches server.bind and the socket line in the
        # live lighttpd.conf to the LAN IP, while the staged file (from the
        # repo) always has 0.0.0.0. Normalize both to 0.0.0.0 before diffing
        # so a mere IP patch doesn't force an unnecessary restart.
        _conf_norm='s/server\.bind = "[0-9.]*"/server.bind = "0.0.0.0"/;s/== "[0-9.]*:443"/== "0.0.0.0:443"/'
        diff -q <(sed "\$_conf_norm" "\$STAGE_DIR/lighttpd.conf") \
                <(sed "\$_conf_norm" "\$QUECDECK_DIR/lighttpd.conf") >/dev/null 2>&1 \
            || _need_lighttpd_restart=1
        diff -q "\$STAGE_DIR/systemd/lighttpd.service" "/lib/systemd/system/lighttpd.service" >/dev/null 2>&1 \
            || _need_lighttpd_restart=1
    fi

    if [ "\$_need_lighttpd_restart" = "1" ]; then
        echo -e "\e[1;32mSwitching to new release (web UI will be briefly unavailable)...\e[0m"
    else
        echo -e "\e[1;32mSwitching to new release (web UI stays up)...\e[0m"
    fi

    echo "Preparing for swap..."
    [ "\$_need_lighttpd_restart" = "1" ] && systemctl stop lighttpd 2>/dev/null
    systemctl stop watchcat 2>/dev/null
    systemctl stop scheduled_restart 2>/dev/null
    systemctl stop atcmd-daemon 2>/dev/null
    systemctl stop connection-logger 2>/dev/null
    systemctl stop ttyd 2>/dev/null
    systemctl stop lean-mode 2>/dev/null

    rm -rf "\$OLD_DIR"
    if [ "\$_had_previous" = "1" ]; then
        mv "\$QUECDECK_DIR" "\$OLD_DIR" || { echo -e "\e[1;31mFailed to move aside the current installation. Aborting swap; the existing site was not touched.\e[0m"; return 1; }
        _swap_committed=1
    elif [ -e "\$QUECDECK_DIR" ]; then
        # Stale/partial directory from a previous failed run (no /www, so
        # nothing worth preserving). Clear it so the rename below replaces
        # rather than nests inside it.
        rm -rf "\$QUECDECK_DIR"
    fi
    mv "\$STAGE_DIR" "\$QUECDECK_DIR" || { echo -e "\e[1;31mFailed to move the new release into place.\e[0m"; return 1; }
    _swap_committed=1

    # Diff the new release's unit filenames against the old snapshot. Anything
    # present now but absent before is new to this release and won't exist in
    # \$OLD_DIR/systemd/ for _revert_swap to restore, so it'd be left orphaned
    # in /lib/systemd/system/ on a rollback unless we explicitly clean it up.
    _newly_introduced_units=""
    for _u in \$(ls "\$QUECDECK_DIR/systemd/" 2>/dev/null); do
        printf '%s\n' "\$_old_systemd_units" | grep -qxF "\$_u" || _newly_introduced_units="\$_newly_introduced_units \$_u"
    done

    rm -f /usrdata/root/bin/atcli
    ln -sf "\$QUECDECK_DIR/atcli" /usrdata/root/bin/atcli
    rm -f /usrdata/root/bin/menu
    ln -sf "\$QUECDECK_DIR/console/menu/start_menu.sh" /usrdata/root/bin/menu
    cp -f "\$QUECDECK_DIR/console/.profile" /usrdata/root/.profile
    chmod +x /usrdata/root/.profile

    _sudoers_rule="www-data ALL = (root) NOPASSWD: /usrdata/quecdeck/script/create_watchcat.sh, /usrdata/quecdeck/script/remove_watchcat.sh, /usrdata/quecdeck/script/create_scheduled_restart.sh, /usrdata/quecdeck/script/remove_scheduled_restart.sh, /bin/systemctl start ttyd, /bin/systemctl stop ttyd, /bin/systemctl start watchcat, /bin/systemctl stop watchcat, /bin/systemctl is-active watchcat, /usrdata/quecdeck/script/write_htpasswd.sh, /usrdata/quecdeck/script/run_update.sh"
    _sudoers_mode=\$(stat -c '%a' /opt/etc/sudoers.d/www-data 2>/dev/null)
    if [ "\$(cat /opt/etc/sudoers.d/www-data 2>/dev/null)" != "\$_sudoers_rule" ] || [ "\$_sudoers_mode" != "440" ]; then
        # On a from-scratch install, the sudo package (which would normally
        # create this directory) isn't installed until later in this
        # function, so it may not exist yet here.
        mkdir -p /opt/etc/sudoers.d
        _sudoers_tmp=\$(mktemp /opt/etc/sudoers.d/.www-data.XXXXXX) || { echo -e "\e[1;31mFATAL: Could not create temp sudoers file.\e[0m"; return 1; }
        printf '%s\n' "\$_sudoers_rule" > "\$_sudoers_tmp"
        chmod 440 "\$_sudoers_tmp"
        mv "\$_sudoers_tmp" /opt/etc/sudoers.d/www-data
    fi

    rm -f /lib/systemd/system/lighttpd.service /lib/systemd/system/multi-user.target.wants/lighttpd.service
    rm -f /lib/systemd/system/atcmd-daemon.service /lib/systemd/system/multi-user.target.wants/atcmd-daemon.service
    rm -f /lib/systemd/system/connection-logger.service /lib/systemd/system/multi-user.target.wants/connection-logger.service
    rm -f /lib/systemd/system/ttyd.service /lib/systemd/system/multi-user.target.wants/ttyd.service
    rm -f /lib/systemd/system/lean-mode.service /lib/systemd/system/multi-user.target.wants/lean-mode.service
    rm -f /lib/systemd/system/multi-user.target.wants/watchcat.service
    rm -f /lib/systemd/system/multi-user.target.wants/scheduled_restart.service
    cp -rf "\$QUECDECK_DIR/systemd/"* /lib/systemd/system/

    ln -sf /lib/systemd/system/lighttpd.service /lib/systemd/system/multi-user.target.wants/lighttpd.service
    ln -sf /lib/systemd/system/firewall.service /lib/systemd/system/multi-user.target.wants/firewall.service
    ln -sf /lib/systemd/system/atcmd-daemon.service /lib/systemd/system/multi-user.target.wants/atcmd-daemon.service
    ln -sf /lib/systemd/system/connection-logger.service /lib/systemd/system/multi-user.target.wants/connection-logger.service
    ln -sf /usrdata/quecdeck/console/ttyd /bin

    if [ "\$lean_mode_was_installed" = "1" ]; then
        ln -sf /lib/systemd/system/lean-mode.service /lib/systemd/system/multi-user.target.wants/lean-mode.service
    fi
    if [ "\$watchcat_was_installed" = "1" ] && [ -s "\$QUECDECK_DIR/var/watchcat.json" ]; then
        ln -sf /lib/systemd/system/watchcat.service /lib/systemd/system/multi-user.target.wants/watchcat.service
    fi
    if [ "\$scheduled_restart_was_installed" = "1" ] && [ -s "\$QUECDECK_DIR/var/scheduled_restart.json" ]; then
        ln -sf /lib/systemd/system/scheduled_restart.service /lib/systemd/system/multi-user.target.wants/scheduled_restart.service
    fi

    # Ensure rc.unslung doesn't try to start its own copy of lighttpd
    for script in /opt/etc/init.d/*lighttpd*; do
        if [ -f "\$script" ]; then
            echo "Removing existing Lighttpd init script: \$script"
            rm "\$script"
        fi
    done

    # Whether lighttpd packages need installing was already determined (and
    # the opkg index already refreshed if so) back in stage_release, while
    # the old site was still serving. So this is just the actual install,
    # which only needs to happen here because opkg's postinst scripts may
    # restart the service (a restart is happening in this window anyway).
    if [ "\$_lighttpd_needs_install" = "1" ]; then
        echo "Installing lighttpd packages..."
        timeout 300 /opt/bin/opkg install \$_lighttpd_pkgs || { echo -e "\e[1;31mFailed to install lighttpd packages (or it timed out).\e[0m"; result_lighttpd="FAILED"; return 1; }
        result_lighttpd="UPDATED"
    fi

    systemctl daemon-reload
    if [ "\$_need_lighttpd_restart" = "1" ]; then
        systemctl start lighttpd || { echo -e "\e[1;31mWARNING: lighttpd failed to start. Check 'systemctl status lighttpd' for details.\e[0m"; return 1; }
    fi
    _need_firewall_restart=0
    if [ "\$_had_previous" = "0" ]; then
        _need_firewall_restart=1
    else
        diff -q "\$QUECDECK_DIR/script/firewall.sh" "\$OLD_DIR/script/firewall.sh" >/dev/null 2>&1 \
            || _need_firewall_restart=1
        diff -q "\$QUECDECK_DIR/systemd/firewall.service" "\$OLD_DIR/systemd/firewall.service" >/dev/null 2>&1 \
            || _need_firewall_restart=1
    fi
    [ "\$_need_firewall_restart" = "1" ] && { systemctl restart firewall || echo "WARNING: Firewall failed to restart."; }
    systemctl restart atcmd-daemon
    systemctl restart connection-logger

    if [ "\$lean_mode_was_installed" = "1" ]; then
        systemctl start --no-block lean-mode
        echo "Lean Mode preserved."
    fi
    if [ "\$watchcat_was_installed" = "1" ] && [ -s "\$QUECDECK_DIR/var/watchcat.json" ]; then
        systemctl restart watchcat
        echo "Watchcat preserved and restarted."
    fi
    if [ "\$scheduled_restart_was_installed" = "1" ] && [ -s "\$QUECDECK_DIR/var/scheduled_restart.json" ]; then
        systemctl restart scheduled_restart
        echo "Scheduled restart preserved and restarted."
    fi

    # Verify the new site is serving. If lighttpd was restarted, poll for up to
    # ~20s to allow for slow startup. If it stayed up, just confirm it is still
    # active (the mv is atomic so content is already live).
    _health_ip=\$(grep -o '<APIPAddr>[^<]*</APIPAddr>' /etc/data/mobileap_cfg.xml 2>/dev/null | sed 's/<APIPAddr>//;s/<\/APIPAddr>//')
    printf '%s' "\$_health_ip" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}\$' || _health_ip="192.168.225.1"
    _health_ok=0
    if [ "\$_need_lighttpd_restart" = "1" ]; then
        echo "Verifying the new site responds on \$_health_ip..."
        for _i in 1 2 3 4 5 6 7 8 9 10; do
            sleep 2
            if systemctl is-active lighttpd >/dev/null 2>&1 && \
               /opt/bin/wget --timeout=10 --tries=1 -q -O /dev/null --no-check-certificate "https://\$_health_ip/login.html"; then
                _health_ok=1
                break
            fi
        done
    else
        systemctl is-active lighttpd >/dev/null 2>&1 && _health_ok=1
        [ "\$_health_ok" = "1" ] && echo "lighttpd stayed up through the swap."
    fi
    if [ "\$_health_ok" != "1" ]; then
        echo -e "\e[1;31mPost-swap health check failed. The new site is not responding on \$_health_ip.\e[0m"
        return 1
    fi

    rm -rf "\$OLD_DIR"
    echo -e "\e[1;32mSwitch complete.\e[0m"
    return 0
}

_revert_swap() {
    echo ""
    echo -e "\e[1;31mRolling back to previous installation...\e[0m"
    if [ ! -d "\$OLD_DIR" ]; then
        echo "No previous installation found. Cannot roll back automatically."
        echo "Re-run the installer via ADB or SSH to recover."
        return 1
    fi
    rm -rf "\$QUECDECK_DIR"
    mv "\$OLD_DIR" "\$QUECDECK_DIR"
    cp -f "\$QUECDECK_DIR/console/.profile" /usrdata/root/.profile 2>/dev/null || true
    cp -rf "\$QUECDECK_DIR/systemd/"* /lib/systemd/system/ 2>/dev/null || true
    # Remove unit files this (failed) release introduced that the restored
    # release knows nothing about, otherwise they'd linger as orphans.
    for _u in \$_newly_introduced_units; do
        [ -n "\$_u" ] || continue
        echo "Removing orphaned unit from failed release: \$_u"
        systemctl stop "\$_u" 2>/dev/null
        rm -f "/lib/systemd/system/\$_u" "/lib/systemd/system/multi-user.target.wants/\$_u"
    done
    ln -sf /lib/systemd/system/lighttpd.service /lib/systemd/system/multi-user.target.wants/lighttpd.service
    ln -sf /lib/systemd/system/firewall.service /lib/systemd/system/multi-user.target.wants/firewall.service
    ln -sf /lib/systemd/system/atcmd-daemon.service /lib/systemd/system/multi-user.target.wants/atcmd-daemon.service
    ln -sf /lib/systemd/system/connection-logger.service /lib/systemd/system/multi-user.target.wants/connection-logger.service
    systemctl daemon-reload
    # lighttpd may be missing if the swap failed mid-reinstall, so the start below may fail
    systemctl start lighttpd 2>/dev/null || echo "WARNING: Could not restart lighttpd. Opkg packages may need reinstalling via ADB or SSH."
    systemctl restart firewall 2>/dev/null
    systemctl restart atcmd-daemon 2>/dev/null
    systemctl restart connection-logger 2>/dev/null
    if [ "\$lean_mode_was_installed" = "1" ]; then
        ln -sf /lib/systemd/system/lean-mode.service /lib/systemd/system/multi-user.target.wants/lean-mode.service
        systemctl start --no-block lean-mode 2>/dev/null
    fi
    if [ "\$watchcat_was_installed" = "1" ] && [ -s "\$QUECDECK_DIR/var/watchcat.json" ]; then
        ln -sf /lib/systemd/system/watchcat.service /lib/systemd/system/multi-user.target.wants/watchcat.service
        systemctl start watchcat 2>/dev/null || true
    fi
    if [ "\$scheduled_restart_was_installed" = "1" ] && [ -s "\$QUECDECK_DIR/var/scheduled_restart.json" ]; then
        ln -sf /lib/systemd/system/scheduled_restart.service /lib/systemd/system/multi-user.target.wants/scheduled_restart.service
        systemctl start scheduled_restart 2>/dev/null || true
    fi
    echo -e "\e[1;32mRollback complete. Previous version restored.\e[0m"
    return 0
}

install_ttyd() {
    # ttyd does not publish checksums, so pin the hash of the known-good binary here.
    # To update: download the new release, sha256sum it, and update TTYD_HASH + the URL below.
    TTYD_VERSION="1.7.7"
    TTYD_HASH="8240c8438b68d3b10b0e1a4e7c914d70fca6a7606b516f40bf40adfa1044d801"

    echo -e "\e[1;32mInstalling ttyd...\e[0m"
    cd $QUECDECK_DIR/console || return 1
    /opt/bin/wget --timeout=60 --tries=2 -q -O ttyd https://github.com/tsl0922/ttyd/releases/download/\${TTYD_VERSION}/ttyd.armhf || { echo -e "\e[1;31mFailed to download ttyd.\e[0m"; return 1; }
    echo "\${TTYD_HASH}  ttyd" | sha256sum -c >/dev/null || { echo -e "\e[1;31mIntegrity check failed for ttyd.\e[0m"; rm -f ttyd; return 1; }
    chmod +x ttyd
    /opt/bin/wget --timeout=30 --tries=2 -q "$GITROOT/quecdeck/console/ttyd.bash" || { echo -e "\e[1;31mFailed to download ttyd.bash.\e[0m"; return 1; }
    chmod +x ttyd.bash
    cd $QUECDECK_DIR/systemd/ || return 1
    /opt/bin/wget --timeout=30 --tries=2 -q "$GITROOT/quecdeck/systemd/ttyd.service" || { echo -e "\e[1;31mFailed to download ttyd.service.\e[0m"; return 1; }
    cp -f $QUECDECK_DIR/systemd/ttyd.service /lib/systemd/system/
    ln -sf /usrdata/quecdeck/console/ttyd /bin

    # Install the service but don't enable/start it; ttyd is launched
    # on demand from the Developer page.
    systemctl daemon-reload
    rm -f /lib/systemd/system/multi-user.target.wants/ttyd.service

    echo -e "\e[1;32mttyd installed.\e[0m"
}

result_stage="FAILED"
result_swap="FAILED"
result_quecdeck="FAILED"
result_ttyd="FAILED"
result_firewall="N/A"
result_rollback="N/A"
result_lighttpd="N/A"
_lighttpd_needs_install=0

preflight_check || exit 1

stage_release && result_stage="OK" || rm -rf "\$STAGE_DIR"

if [ "\$result_stage" = "OK" ]; then
    swap_in_release && { result_swap="OK"; result_quecdeck="OK"; } || {
        rm -rf "\$STAGE_DIR"
        if [ "\$_swap_committed" = "1" ]; then
            _revert_swap && result_rollback="OK" || result_rollback="FAILED"
        elif [ "\$_had_previous" = "1" ]; then
            echo -e "\e[1;33mThe switch never started. The previous installation is untouched and still serving.\e[0m"
        else
            echo -e "\e[1;33mThe switch never started. Nothing was installed.\e[0m"
        fi
    }
fi

if [ "\$result_quecdeck" = "OK" ]; then
    install_ttyd && result_ttyd="OK" || result_ttyd="WARNING"
fi

systemctl is-active firewall >/dev/null 2>&1 && result_firewall="OK" || result_firewall="WARNING"

_show_result() {
    local label="\$1" val="\$2"
    case "\$val" in
        OK|UPDATED) echo -e "  \$(printf '%-22s' "\$label") \e[1;32m\$val\e[0m" ;;
        WARNING)    echo -e "  \$(printf '%-22s' "\$label") \e[1;33m\$val\e[0m" ;;
        SKIPPED|PENDING) echo -e "  \$(printf '%-22s' "\$label") \$val" ;;
        *)          echo -e "  \$(printf '%-22s' "\$label") \e[1;31m\$val\e[0m" ;;
    esac
}

echo ""
echo -e "\e[1;32mInstall Summary\e[0m"
echo "============================================"
_show_result "Stage release"      "\$result_stage"
_show_result "Switch to release"  "\$result_swap"
_show_result "QuecDeck"           "\$result_quecdeck"
_show_result "Firewall"           "\$result_firewall"
_show_result "ttyd"               "\$result_ttyd"
[ "\$result_lighttpd" != "N/A" ] && _show_result "Lighttpd"          "\$result_lighttpd"
[ "\$result_rollback" != "N/A" ] && _show_result "Rollback"          "\$result_rollback"
echo "============================================"

if [ "\$result_quecdeck" = "OK" ]; then
    _update_status="done"
elif [ "\$result_rollback" = "OK" ]; then
    _update_status="failed:rollback_ok"
elif [ "\$result_rollback" = "FAILED" ]; then
    _update_status="failed:rollback_failed"
fi

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
rm -f "$LOG_FILE"
touch "$LOG_FILE"

# If stdout is an actual terminal (ADB/SSH/console), stream the log live while
# we wait, since the unit's own output goes straight to $LOG_FILE, not to us.
# The web path redirects our stdout to a file already, so this stays off there.
_tail_pid=""
if [ -t 1 ]; then
    tail -n +1 -f "$LOG_FILE" &
    _tail_pid=$!
fi
systemctl start $SERVICE_NAME
_start_rc=$?
[ -n "$_tail_pid" ] && { kill "$_tail_pid" 2>/dev/null; wait "$_tail_pid" 2>/dev/null; }
[ "$_start_rc" -ne 0 ] && { echo -e "\e[1;31mFailed to start install service. Check 'systemctl status $SERVICE_NAME' for details.\e[0m"; exit 1; }
if [ -f "$LOG_FILE" ]; then
    if grep -q "Install Summary" "$LOG_FILE"; then
        if [ -t 1 ]; then
            # Already streamed live via tail above; no need to reprint it.
            echo -e "\e[1;32mQuecDeck installed.\e[0m"
        else
            echo -e "\e[1;32mQuecDeck installed.\e[0m"
            echo ""
            sed -n '/Install Summary/,$p' "$LOG_FILE"
            echo ""
        fi
    else
        echo -e "\e[1;31mInstall did not complete. Check $LOG_FILE for details.\e[0m"
        remount_ro
        rm -f "$0"
        exit 1
    fi
fi
remount_ro
rm -f "$0"
