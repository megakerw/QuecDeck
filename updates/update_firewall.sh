#!/bin/bash

# Define constants
# Define GitHub repo info
GITUSER="megakerw"
REPONAME="QuecDeck"
GITTREE="main"
GITMAINTREE="main"
GITDEVTREE="main"
GITROOT="https://raw.githubusercontent.com/$GITUSER/$REPONAME/$GITTREE"
GITROOTMAIN="https://raw.githubusercontent.com/$GITUSER/$REPONAME/$GITMAINTREE"
GITROOTDEV="https://raw.githubusercontent.com/$GITUSER/$REPONAME/$GITDEVTREE"

# Define filesystem path
DIR_NAME="firewall"
SERVICE_FILE="/lib/systemd/system/install_firewall.service"
SERVICE_NAME="install_firewall"
TMP_SCRIPT="/tmp/install_firewall.sh"
LOG_FILE="/tmp/install_firewall.log"

# Tmp Script dependent constants
FIREWALL_DIR="/usrdata/firewall"
FIREWALL_SCRIPT="$FIREWALL_DIR/firewall.sh"
FIREWALL_SYSTEMD_DIR="$FIREWALL_DIR/systemd"

# Function to remount file system as read-write
remount_rw() {
    mount -o remount,rw /
}

# Function to remount file system as read-only
remount_ro() {
    mount -o remount,ro /
}
remount_rw
# Create the systemd service file
cat <<EOF > "$SERVICE_FILE"
[Unit]
Description=Update $DIR_NAME temporary service

[Service]
Type=oneshot
ExecStart=/bin/bash $TMP_SCRIPT > $LOG_FILE 2>&1

[Install]
WantedBy=multi-user.target
EOF

# Create and populate the temporary shell script for installation
cat <<EOF > "$TMP_SCRIPT"
#!/bin/bash

# Define GitHub repo info
GITUSER="megakerw"
REPONAME="QuecDeck"
GITTREE="main"
GITMAINTREE="main"
GITDEVTREE="main"
GITROOT="https://raw.githubusercontent.com/$GITUSER/$REPONAME/$GITTREE"
GITROOTMAIN="https://raw.githubusercontent.com/$GITUSER/$REPONAME/$GITMAINTREE"
GITROOTDEV="https://raw.githubusercontent.com/$GITUSER/$REPONAME/$GITDEVTREE"

# Define filesystem path
FIREWALL_DIR="/usrdata/firewall"
FIREWALL_SCRIPT="$FIREWALL_DIR/firewall.sh"
FIREWALL_SYSTEMD_DIR="$FIREWALL_DIR/systemd"

# Function to remount file system as read-write
remount_rw() {
    mount -o remount,rw /
}

# Function to remount file system as read-only
remount_ro() {
    mount -o remount,ro /
}
remount_rw
# Function to remove Firewall
uninstall_firewall() {
	echo "Uninstalling Firewall..."
    systemctl stop firewall
    # TTL override service was removed — clean up any remnants from older installs
    systemctl stop ttl-override 2>/dev/null
    rm -f /lib/systemd/system/ttl-override.service
    rm -f /lib/systemd/system/multi-user.target.wants/ttl-override.service
    rm -f /lib/systemd/system/firewall.service
    systemctl daemon-reload
    rm -rf "$FIREWALL_DIR"
    echo "Firewall uninstalled."
}
# Function to install Firewall
install_firewall() {
    systemctl stop firewall
    # TTL override service was removed — clean up any remnants from older installs
    systemctl stop ttl-override 2>/dev/null
    rm -f /lib/systemd/system/ttl-override.service
    rm -f /lib/systemd/system/multi-user.target.wants/ttl-override.service
    rm -f "$FIREWALL_DIR/ttl-override"
    rm -f "$FIREWALL_DIR/ttlvalue"
    echo -e "\033[0;32mInstalling/Updating Firewall...\033[0m"
    mount -o remount,rw /
    mkdir -p "$FIREWALL_DIR"
    mkdir -p "$FIREWALL_SYSTEMD_DIR"
    wget -O "$FIREWALL_DIR/firewall.sh" $GITROOT/components/firewall/firewall.sh
    chmod +x "$FIREWALL_DIR/firewall.sh"
    wget -O "$FIREWALL_SYSTEMD_DIR/firewall.service" $GITROOT/components/firewall/systemd/firewall.service
    cp -f $FIREWALL_SYSTEMD_DIR/firewall.service /lib/systemd/system
    ln -sf "/lib/systemd/system/firewall.service" "/lib/systemd/system/multi-user.target.wants/"
    systemctl daemon-reload
    systemctl start firewall
    echo -e "\033[0;32mFirewall installation/update complete.\033[0m"
	}
uninstall_firewall
install_firewall
remount_ro
exit 0
EOF

# Make the temporary script executable
chmod +x "$TMP_SCRIPT"

# Reload systemd to recognize the new service and start the update
systemctl daemon-reload
systemctl start $SERVICE_NAME
