# QuecDeck

QuecDeck is a web-based management interface for the Quectel RM520N-GL. It runs directly on the modem and provides a modern UI for monitoring, configuration, and troubleshooting.

## ⚠️ Warning

This software modifies system files and settings on your modem. It is provided as-is, with no guarantees of any kind. Use it at your own risk. The authors take no responsibility for any damage, data loss, or other issues that may result from its use, including but not limited to bricking your device or disrupting connectivity.

## Compatibility

**QuecDeck has only been tested on the Quectel RM520N-GL. Running it on any other device is unsupported and may not work or could cause unintended behavior.**

## Installation

### Pre-Setup

Before installing QuecDeck, the modem needs to be configured for RGMII Ethernet and ADB access.

**1. Install drivers**

Install the NDIS and ECM drivers from Quectel. Uninstall all other Quectel drivers before proceeding. Do **not** use the RNDIS driver. The latest drivers are available from the [Quectel Download Zone](https://www.quectel.com/download-zone).

**2. Configure the modem**

Use Qnavigator to send the following AT commands:

```
AT+QCFG="data_interface",0,0
AT+QETH="eth_driver","r8125",1
AT+QCFG="pcie/mode",1
AT+QCFG="usbnet",1
```

Then reboot the modem:

```
AT+CFUN=1,1
```

**3. Enable ADB**

Follow [iamromulan's guide](https://github.com/iamromulan/cellular-modem-wiki/blob/main/quectel/sdxlemur/sdxlemur_m.2_to_eth.md#unlocking-adb) to unlock ADB access on the modem.
### Installing QuecDeck

Run the following command on your modem (via ADB shell, SSH, or the web console):

```sh
cd /tmp && wget -O quecdeck.sh https://raw.githubusercontent.com/megakerw/QuecDeck/main/quecdeck.sh && chmod +x quecdeck.sh && ./quecdeck.sh && cd /
```

Select **Install/Update QuecDeck** from the menu. On first access, a setup wizard will guide you through setting your passwords.

To update, run the same command and select **Install/Update QuecDeck** again. Your settings and service state are preserved across updates.

## Features

Features are organised by page.

### Home
Real-time overview of the modem's current status: signal strength, temperature, SIM status, internet connectivity, active band aggregation, and more.

### Cellular Network
- Band locking for LTE, NR5G-NSA, and NR5G-SA
- APN configuration, PDP type, and roaming preferences
- Automatic APN/MBN selection
- SIM slot selection
- Network mode and RAT acquisition order
- NR5G mode control (NSA/SA)

### Cell Scan
Scan for nearby cells and display network, provider, band, frequency, PCI, and RSRP in real time. While a scan is in progress, a banner is shown across the UI and all modem data is served from cache to avoid interfering with the scan. Watchcat is temporarily disabled during the scan to prevent false reboots, and completed scans are logged in the Logs page.

### Settings
- LAN IP and DHCP range configuration
- One-click utilities: reboot, onboard DNS IPv4/IPv6 proxy, IP Passthrough (IPPT), auto-connect (QMAPWAC), and GNSS toggle

### Monitoring
- **Watchcat:** ping-based watchdog that reboots the modem if connectivity is lost, with ping statistics and consecutive failure tracking
- **Scheduled Restart:** schedule daily or weekly reboots at a specified time

### SMS
View, read, and delete SMS messages directly from the modem's inbox.

### Device Information
- **Device & SIM:** manufacturer, model, firmware version, build time, IMEI, phone number, IMSI, and ICCID
- **Network:** LAN IP, WWAN IPv4/IPv6, primary/secondary DNS (IPv4 and IPv6 shown separately), and UPnP status
- **Services:** live status overview of all QuecDeck services (AT Daemon, Firewall, Connection Logger, Watchcat, Scheduled Restart, SSH, Lean Mode, and ttyd)

### Logs
- **Connection Events:** timestamped log of connection changes and failures
- **Access Events:** timestamped log of UI access activity

Both logs keep the last 500 entries and are cleared on reboot.

### Developer
Requires a separate developer password to unlock. Provides access to:
- **AT Terminal:** send AT commands directly to the modem, with support for multiple commands separated by a semicolon
- **Cell Locking:** lock the primary cell for LTE or NR5G-SA by EARFCN and PCI (not persistent across reboots)
- **Web Console (ttyd):** start/stop the browser-based terminal and open it directly from the UI
- **Console Menu:** an interactive shell menu (`menu` command) available over ADB, SSH, or ttyd. Provides access to modem apps (file browser, disk usage, task manager), password management (admin, developer, and root passwords), and a shortcut to re-run the installer.

## Implementation

QuecDeck started as a fork of [Simple Admin](https://github.com/iamromulan/quectel-rgmii-toolkit) but most of the code has since been rewritten or redesigned from scratch.

### Approach

- **Fewer features, done well.** QuecDeck covers the basics: signal monitoring, band locking, network config, a handful of utilities. New functionality is only added when it fits that scope and can be implemented cleanly.
- **Minimize attack surface.** The web server and SSH bind only to the LAN IP, the firewall blocks WAN access, and the only component with elevated privileges is the `atcli` binary that needs it. Everything else runs with the minimum access required.
- **Destructive features behind a separate auth wall.** Things that can cause real damage (like the AT terminal and the web console) require a separate developer password on top of the standard admin login.
- **Minimal write footprint.** QuecDeck writes only to `/usrdata` (persistent config and binaries) and `/tmp` (runtime state). The root filesystem is never written to after install, and everything can be removed cleanly.

### Web Server
[Lighttpd](https://www.lighttpd.net/) serves the frontend and CGI backend on port 443 (HTTPS), with port 80 redirecting to HTTPS.
- A pre-start script (`lighttpd_prestart.sh`) reads the current LAN IP, rewrites `lighttpd.conf` to bind to that IP, and regenerates a self-signed TLS certificate to match if the IP has changed.
- Authentication uses a custom session-based login with SHA-512 hashed passwords and a two-tier credential system (admin and developer).
- Sessions are managed via secure cookies, with a 15-minute lockout after 5 failed login attempts. Both passwords require a minimum of 8 characters.

### AT Command Layer
All modem communication goes through [atcli](https://github.com/megakerw/atcli_rust) (a fork of [atcli_rust](https://github.com/1alessandro1/atcli_rust)), a Rust-based AT command CLI that runs as a setuid binary. Since multiple CGI requests can arrive at the same time, a queue daemon (`atcmd_queue_daemon.sh`) serializes requests through named pipes to avoid race conditions. Responses are cached per endpoint to reduce modem load: 3 seconds for modem stats, 5 seconds for everything else.

### Firewall
A lightweight iptables-based firewall restricts access to ports 80, 443, and optionally 22 (SSH) to the LAN IP only, blocking WAN exposure. Custom chains (`FW`/`FW6`) survive QCMAP's automatic iptables rebuilds. IPv6 access to the admin UI is blocked by default.

### Security

QuecDeck runs on a device that operates as root, so keeping the attack surface small matters.

**Network exposure:** each service independently manages its own bind IP at startup (lighttpd via `lighttpd_prestart.sh`, sshd via `update_sshd_ip.sh`), so neither listens on the WAN interface even if the LAN IP changes. The firewall adds a second layer on top of this.

**Privileges:** the only component that needs elevated access to the modem's serial interface (`/dev/smd11`) is the `atcli` binary, which runs setuid. CGI scripts do not run as root.

**Web application:**
- All CGI endpoints validate the `Origin` header against the current host, blocking cross-origin requests and functioning as CSRF protection
- All state-changing endpoints are POST-only
- Login attempts are rate-limited with a 1-second delay per attempt and a 15-minute lockout after 5 failures; all login events are written to the access log
- Session tokens are 64-character random strings stored in a `chmod 700` directory; cookies are flagged `HttpOnly`, `Secure`, and `SameSite=Strict`; session file writes use `flock` to prevent race conditions
- Passwords must be at least 8 characters and are validated before any credential check is performed

**Data at rest:** the AT response cache, session directory, and log directory are all `chmod 700`. Pre-start scripts and anything running with elevated access are `chmod 700 root:root`.

### Frontend
The UI is built with [Bootstrap 5](https://getbootstrap.com/) and [Alpine.js](https://alpinejs.dev/) for reactive data binding. All assets are version-pinned with cache-busting query parameters managed by a pre-commit git hook.

### Installation
QuecDeck is installed and updated via shell scripts that download files directly from this repository. The installer (`quecdeck.sh`) handles Entware/opkg setup, firewall deployment, service registration, and root/console password configuration. On first access, a setup wizard guides the user through setting the admin and (optionally) developer passwords. State (watchcat config, scheduled restarts, lean mode) is preserved across updates.

### Optional Components
- **SSH:** OpenSSH server. A pre-start script (`update_sshd_ip.sh`) updates `sshd_config`'s `ListenAddress` to the current LAN IP before the daemon starts, restricting it to LAN only. Requires a root password to be set first.
- **Lean Mode:** disables the GPS/location stack on boot to free up resources when location services are not needed

## Credits

QuecDeck is based on [quectel-rgmii-toolkit](https://github.com/iamromulan/quectel-rgmii-toolkit) by [iamromulan](https://github.com/iamromulan), with contributions from:

- [Nate Carlson](https://github.com/natecarlson) — original telnet daemon/socat bridge and RGMII notes
- [aesthernr](https://github.com/aesthernr) — original Simple Admin
- [rbflurry](https://github.com/rbflurry/) — initial Simple Admin fixes
- [dr-dolomite](https://github.com/dr-dolomite) — major stat page improvements
- [tarunVreddy](https://github.com/tarunVreddy) — band aggregation parsing

### Projects

- [Entware/opkg](https://github.com/Entware/Entware) — package manager
- [TTYd](https://github.com/tsl0922/ttyd) — browser-based terminal
- [atcli_rust](https://github.com/1alessandro1/atcli_rust) by [1alessandro1](https://github.com/1alessandro1) — AT command CLI, forked by [megakerw](https://github.com/megakerw/atcli_rust)
