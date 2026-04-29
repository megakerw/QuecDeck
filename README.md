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

Install the NDIS and ECM drivers from Quectel. Uninstall all other Quectel drivers before proceeding — do **not** use the RNDIS driver. The latest drivers are available from the [Quectel Download Zone](https://www.quectel.com/download-zone).

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

To update, run the same command and select **Install/Update QuecDeck** again — your settings and service state are preserved across updates.

## Features

Features are organised by page.

### Home
Real-time overview of the modem's current status: signal strength, temperature, SIM status, internet connectivity, and more.

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
- **Watchcat** — ping-based watchdog that reboots the modem if connectivity is lost, with ping statistics and consecutive failure tracking
- **Scheduled Restart** — schedule daily or weekly reboots at a specified time

### SMS
View, read, and delete SMS messages directly from the modem's inbox.

### Device Information
- **Device & SIM** — manufacturer, model, firmware version, build time, IMEI, phone number, IMSI, and ICCID
- **Network** — LAN IP, WWAN IPv4/IPv6, primary/secondary DNS (IPv4 and IPv6), and UPnP status
- **Services** — live status overview of all QuecDeck services (AT Daemon, Firewall, Connection Logger, Watchcat, Scheduled Restart, SSH, Lean Mode, and ttyd)

### Logs
- **Connection Events** — timestamped log of connection changes and failures
- **Access Events** — timestamped log of UI access activity

Both logs keep the last 500 entries and are cleared on reboot.

### Developer
Requires a separate developer password to unlock. Provides access to:
- **AT Terminal** — send AT commands directly to the modem, with support for multiple commands separated by a semicolon
- **Cell Locking** — lock the primary cell for LTE or NR5G-SA by EARFCN and PCI (not persistent across reboots)
- **Web Console (ttyd)** — start/stop the browser-based terminal and open it directly from the UI

## Implementation

QuecDeck is designed to run entirely on-device with minimal dependencies. The web server, backend, and services live on the modem's writable `/usrdata` partition, with systemd service files installed to the root filesystem during setup.

### Web Server
[Lighttpd](https://www.lighttpd.net/) serves the frontend and CGI backend on port 443 (HTTPS). Port 80 redirects to HTTPS. Before starting, the server reads the current LAN IP from the modem's configuration, rewrites `lighttpd.conf` to bind to that IP, and regenerates a self-signed TLS certificate with a Subject Alternative Name matching the IP — this allows browsers (including iOS Safari) to store the trust exception durably. The certificate is regenerated automatically whenever the LAN IP changes. Authentication uses a custom session-based login with SHA-512 hashed passwords and a two-tier credential system — a standard admin account and a developer account for advanced access. Sessions are managed via secure cookies, with a 15-minute lockout enforced after 5 failed login attempts.

### AT Command Layer
All modem communication goes through [atcli](https://github.com/megakerw/atcli_rust) (a fork of [atcli_rust](https://github.com/1alessandro1/atcli_rust)), a Rust-based AT command CLI running as a setuid binary. A queue daemon (`atcmd_queue_daemon.sh`) serializes all AT command requests through named pipes, preventing race conditions when multiple CGI requests arrive simultaneously. Responses are cached per endpoint to reduce modem load: modem stats at 3 seconds, and all other endpoints at 5 seconds.

### Firewall
A lightweight iptables-based firewall restricts access to ports 80, 443, and optionally 22 (SSH) to the LAN IP only, blocking WAN exposure. Custom chains (`FW`/`FW6`) survive QCMAP's automatic iptables rebuilds. IPv6 access to the admin UI is blocked by default.

### Security

QuecDeck runs on a device that inherently operates as root, so several layers of mitigation are in place to limit exposure.

**Network exposure** is reduced through defense in depth: at startup, the web server rewrites its configuration to bind to the current LAN IP before starting, and SSH does the same — neither listens on the WAN interface. The firewall provides a second layer on top of this.

**Privilege minimization**: the only component that requires elevated access to the modem's serial interface (`/dev/smd11`) is the `atcli` binary, which runs setuid. CGI scripts themselves do not run as root.

**Web application security**:
- All CGI endpoints validate the `Origin` header against the current host, blocking cross-origin requests and functioning as CSRF protection
- All state-changing endpoints are POST-only
- Login attempts are rate-limited with a 1-second per-attempt delay and a 15-minute IP-based lockout after 5 failures; all login events are written to the access log
- Session tokens are 64-character random strings stored in a `chmod 700` directory; cookies are flagged `HttpOnly`, `Secure`, and `SameSite=Strict`
- Username and password inputs are validated before any credential check is performed

**Data at rest**: the AT response cache directory is `chmod 700` since it contains sensitive modem data — IP addresses, APN configuration, and cell information.

### Frontend
The UI is built with [Bootstrap 5](https://getbootstrap.com/) and [Alpine.js](https://alpinejs.dev/) for reactive data binding. All assets are version-pinned with cache-busting query parameters managed by a pre-commit git hook.

### Installation
QuecDeck is installed and updated via shell scripts that download files directly from this repository. The installer (`quecdeck.sh`) handles Entware/opkg setup, firewall deployment, service registration, and root/console password configuration. On first access, a setup wizard guides the user through setting the admin and (optionally) developer passwords. State (watchcat config, scheduled restarts, lean mode) is preserved across updates.

### Optional Components
- **SSH** — OpenSSH server, dynamically bound to the LAN IP at startup and restricted to LAN, requires a root password to be set first
- **Lean Mode** — disables the GPS/location stack on boot to free up resources on data-only devices

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
