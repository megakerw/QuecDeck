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

To update, run the same command and select **Install/Update QuecDeck** again, or use the Update page in the web UI. Your settings and service state are preserved across updates.

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
- One-click utilities: reboot, onboard DNS IPv4/IPv6 proxy, IP Passthrough (IPPT), auto-connect (QMAPWAC), GNSS toggle, and SIM hot-swap detection

### Monitoring
- **Watchcat:** ping-based watchdog that reboots the modem if connectivity is lost, with ping statistics, consecutive failure tracking, and a persistent reboot history log. If a reboot doesn't restore connectivity, Watchcat waits progressively longer before trying again instead of rebooting in a tight loop
- **Scheduled Restart:** schedule daily or weekly reboots at a specified time

### SMS
View, read, and delete SMS messages directly from the modem's inbox, newest first.

### Device Information
- **Device & SIM:** manufacturer, model, firmware version, build time, IMEI, phone number, IMSI, and ICCID
- **Network:** LAN IP, WWAN IPv4/IPv6, primary/secondary DNS (IPv4 and IPv6 shown separately), and UPnP status
- **Services:** live status overview of all QuecDeck services (AT Daemon, Firewall, Connection Logger, Watchcat, Scheduled Restart, SSH, Lean Mode, and ttyd)

### Logs
- **Connection Events:** timestamped log of connection changes and failures. Keeps the last 500 entries, cleared on reboot.
- **Access Events:** timestamped log of UI access activity. Keeps the last 500 entries, cleared on reboot.
- **Watchcat Restarts:** timestamped log of watchcat-triggered reboots, including the failure count and reboot streak number (when backoff is enabled). Keeps the last 50 entries and persists across reboots.

### Update
Check the installed version against the latest GitHub release and trigger an in-place update directly from the web UI. The update log streams in real time. If the update fails, the previous installation is automatically restored.

### Developer
Requires a separate developer password to unlock. Provides access to:
- **AT Terminal:** send AT commands directly to the modem, with support for multiple commands separated by a semicolon
- **Cell Locking:** lock the primary cell for LTE or NR5G-SA by EARFCN and PCI (not persistent across reboots)
- **Web Console (ttyd):** start/stop the browser-based terminal and open it directly from the UI
- **Console Menu:** an interactive shell menu (`menu` command) available over ADB, SSH, or ttyd. Provides access to modem apps (file browser, disk usage, task manager) and password management (admin, developer, and root passwords).

## Implementation

QuecDeck started as a fork of [Simple Admin](https://github.com/iamromulan/quectel-rgmii-toolkit) but most of the code has since been rewritten or redesigned from scratch.

### Approach

- **Fewer features, done well.** QuecDeck covers the basics: signal monitoring, band locking, network config, a handful of utilities. New functionality is only added when it fits that scope and can be implemented cleanly.
- **Minimize attack surface.** The web server and SSH bind only to the LAN IP, the firewall blocks WAN access, and the only component with elevated privileges is the AT daemon that needs them. Everything else runs with the minimum access required.
- **Destructive features behind a separate auth wall.** Things that can cause real damage (like the AT terminal and the web console) require a separate developer password on top of the standard admin login.
- **Minimal write footprint.** QuecDeck writes only to `/usrdata` (persistent config and binaries) and `/tmp` (runtime state). The root filesystem is never written to after install, and everything can be removed cleanly.

### Web Server
[Lighttpd](https://www.lighttpd.net/) serves the frontend and CGI backend on port 443 (HTTPS), with port 80 redirecting to HTTPS.
- A pre-start script (`lighttpd_prestart.sh`) reads the current LAN IP, rewrites `lighttpd.conf` to bind to that IP, and regenerates a self-signed TLS certificate to match if the IP has changed.
- Authentication uses a custom session-based login with SHA-512 hashed passwords and a two-tier credential system (admin and developer).
- Sessions are managed via secure cookies, with a 15-minute lockout after 5 failed login attempts. Both passwords require a minimum of 8 characters.

### AT Command Layer
All modem communication goes through [atcli](https://github.com/megakerw/atcli_rust) (a fork of [atcli_rust](https://github.com/1alessandro1/atcli_rust)), a Rust-based AT command CLI that emits clean newline-terminated output (modem `\r` framing is stripped at the source).

- **Single gateway.** Shell code never invokes atcli directly; every caller goes through `script/at-lib.sh`, enforced by a pre-commit check.
- **Serialization and privilege.** Serialization happens inside atcli itself. Its daemon side (`atcli --daemon`, unit `atcmd-daemon`) opens the modem port as root, drops to www-data, and serves one command per unix-socket connection, verifying each peer's uid via `SO_PEERCRED`. atcli is not setuid: the daemon is the only privileged path to the modem.
- **No silent fallback.** There is no automatic fallback to the port, so a plain invocation never bypasses the serializer. If the daemon is down, every caller (root and www-data alike) gets empty output until systemd restarts it within seconds, and the UI tolerates the gap. A root operator can still reach the modem directly for recovery by passing `--direct` explicitly.
- **Sender lifecycle.** Commands whose sender has hung up are skipped instead of being sent to the modem; fire-and-forget senders (modem reboots) pass `--detach`.
- **Caching.** Responses are cached per endpoint to reduce modem load, with TTLs tuned to how often the data actually changes: 3 seconds for signal stats and connection info, 5 seconds for network and settings data, and 1 hour for static device info like firmware version and build time. Where possible, multiple AT commands are batched into a single request to cut down on round trips.

### Firewall
A lightweight iptables-based firewall restricts access to ports 80, 443, and optionally 22 (SSH) to the LAN IP only, blocking WAN exposure. Custom chains (`QUECDECK`/`QUECDECK6`) survive QCMAP's automatic iptables rebuilds. IPv6 access to the admin UI is blocked by default.

### Security

QuecDeck runs on a device that operates as root, so keeping the attack surface small matters.

**Network exposure:** each service independently manages its own bind IP at startup (lighttpd via `lighttpd_prestart.sh`, sshd via `update_sshd_ip.sh`), so neither listens on the WAN interface even if the LAN IP changes. The firewall adds a second layer on top of this.

**Privileges:** QuecDeck ships no setuid binaries. The only privileged path to the modem's serial interface (`/dev/smd11`) is the AT daemon, which systemd starts as root and which drops to www-data after opening the port; clients talk to it over a uid-checked unix socket. CGI scripts do not run as root.

**Web application:**
- All CGI endpoints validate the `Origin` header against the current host, blocking cross-origin requests and functioning as CSRF protection
- All state-changing endpoints are POST-only
- Login attempts are rate-limited with a 1-second delay per attempt and a 15-minute lockout after 5 failures; all login events are written to the access log
- Session tokens are 64-character random strings stored in a `chmod 700` directory; cookies are flagged `HttpOnly`, `Secure`, and `SameSite=Strict`; session file writes are atomic (temp file plus rename), and the developer-unlock flag is kept in a separate per-session file to avoid write races
- Passwords must be at least 8 characters and are validated before any credential check is performed
- Path traversal is rejected in depth: lighttpd is pinned to reject encoded slashes (`%2f`) and dot-segments rather than silently decode them, and the auth layer independently rejects both literal `..` and percent-encoded (`%2e`) sequences before any access-exemption check

**Data at rest:** the AT response cache, session directory, and log directory are all `chmod 700`. Pre-start scripts and anything running with elevated access are `chmod 700 root:root`.

### Frontend
The UI is built with [Bootstrap 5](https://getbootstrap.com/) and [Alpine.js](https://alpinejs.dev/) for reactive data binding. All assets carry a content-hashed cache-busting query parameter, maintained by a pre-commit git hook, which lets them be served with a one-year `immutable` cache lifetime: a content change produces a new URL, so updates apply immediately while repeat visits skip revalidation. HTML pages are always sent `no-store` so they never pin stale asset URLs.

### Installation and Updates
QuecDeck is installed via `quecdeck.sh`, which handles Entware/opkg setup, firewall deployment, service registration, and root/console password configuration. On first access, a setup wizard guides the user through setting the admin and (optionally) developer passwords.

Updates can be triggered from the Update page in the web UI or by re-running `quecdeck.sh`. Both paths use the same update installer (`update_quecdeck.sh`), which:

1. Downloads the target release and verifies SHA-256 checksums for every file against `quecdeck/checksums.sha256`.
2. Stages the new version alongside the running install, then moves the old install aside and swaps the new one in atomically.
3. Runs a health check after the swap, rolling back to the previous version automatically if it fails.

State (watchcat config, scheduled restarts, lean mode) is preserved across updates.

### Optional Components
- **SSH:** OpenSSH server. A pre-start script (`update_sshd_ip.sh`) updates `sshd_config`'s `ListenAddress` to the current LAN IP before the daemon starts, restricting it to LAN only. Requires a root password to be set first.
- **Lean Mode:** disables the GPS/location stack on boot to free up resources when location services are not needed

## Development

Two check suites run on every push and pull request via GitHub Actions, and can be run locally:

- **Test suite** (`tools/run-tests.sh`): host-side unit tests for the pure shell functions (JSON parsing, CGI helpers, watchcat backoff math) and JS structure checks. Runs on the dev machine with no device needed; pass `--slow` to include tests that sleep (login lockout). The fast set also runs from the pre-commit hook.
- **Integration tests** (`tools/host-test-authlua.sh`): runs the real auth.lua against a stubbed lighttpd request environment. Linux-only (disposable root paths); self-skips elsewhere and runs in CI. The AT layer's integration tests live in the [atcli repo](https://github.com/megakerw/atcli_rust): daemon and client exercised end to end against a fake modem on a pty, including a large-response test.
- **Repository integrity checks** (`tools/ci-checks.sh`): shell syntax, JS syntax, the atcli access guard and socket path consistency, the developer-page dev-gate guard, a shell dialect guard (shebangs match what sources cgi-lib/at-lib and what systemd units exec), checksum manifest and pinned bootstrap hashes, and asset version tokens. These mirror the pre-commit hook, so CI catches commits made without the hook configured. Assumes an LF checkout, so on Windows run the test suite instead.
- **On-device scripts** (`tools/device-test-*.sh`): copied to the device manually for what host tests cannot verify: SELinux domain interactions, the daemon's privilege drop and socket permissions, and real modem timing and payload sizes. Run before tagging a release.

The pre-commit hook is enabled with `git config core.hooksPath .githooks`.

**Shell performance rule** (measured on the device's single Cortex-A7): bash builtins are used only for small or fixed-size data; bulk transformation of unbounded AT responses uses `tr`/`awk`, never bash pattern replacement, whose cost scales with size times match count (48 seconds on a 44 KB SMS list, versus 20 ms for `tr`). The atcli repo's CI guards the daemon path with a large-response test.

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
