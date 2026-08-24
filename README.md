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

To update, run the same command and select **Install/Update QuecDeck** again, or use the Update page in the web UI. Settings from the current implementation are preserved across updates. The monitoring migration exception is described below.

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
Scan for nearby cells and display network, provider, band, frequency, PCI, and RSRP. The modem reports nothing until the sweep finishes, so results appear all at once at the end rather than filling in as cells are found. While a scan is in progress, a banner is shown across the UI and all modem data is served from cache to avoid interfering with the scan. Watchcat is paused for the duration of the scan to prevent false reboots, staying running but not counting failures, and completed scans are logged in the Logs page.

### Settings
- LAN IP and DHCP range configuration
- One-click utilities: reboot, onboard DNS IPv4/IPv6 proxy, IP Passthrough (IPPT), auto-connect (QMAPWAC), GNSS toggle, and SIM hot-swap detection

### Monitoring
- **Watchcat:** ping-based watchdog that reboots the modem if connectivity is lost, with ping statistics, consecutive failure tracking, and a persistent reboot-activity log. Each round rotates which configured target is checked first and stops at the first response. A reboot requires at least three rounds where every target fails. If a reboot doesn't restore connectivity, Watchcat waits progressively longer before trying again instead of rebooting in a tight loop
- **Scheduled Restart:** schedule daily or weekly reboots at a specified time. The schedule follows the modem's own clock and remains held until that clock contains a plausible date and time

The monitoring units remain installed and boot-enabled. Their configuration determines whether monitoring is active. Disabled features exit cleanly without pinging or accessing the modem and are restarted when enabled from the UI.

### SMS
View, read, and delete SMS messages directly from the modem's inbox, newest first. A long message is stored as several parts, so deleting one can issue many delete commands. They are sent one at a time under an overall time limit, and if any parts are left behind the page reports how many rather than showing a success that did not happen.

### Device Information
- **Device & SIM:** manufacturer, model, firmware version, build time, IMEI, phone number, IMSI, and ICCID
- **Network:** LAN IP, WWAN IPv4/IPv6, primary/secondary DNS (IPv4 and IPv6 shown separately), and UPnP status
- **Services:** live status overview of all QuecDeck services (AT Daemon, Firewall, Connection Logger, Watchcat, Scheduled Restart, SSH, and ttyd)

### Logs
- **Connection Events:** timestamped log of connection changes and failures. Keeps the last 500 entries, cleared on reboot.
- **Access Events:** timestamped log of UI access activity. Keeps the last 500 entries, cleared on reboot.
- **Watchcat Reboot Activity:** timestamped log of Watchcat reboot attempts and related failures, including the failure count and attempt number. Keeps up to 100 persistent entries, then clears the old history when the next event is recorded.

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
- **Minimize attack surface.** The web server and SSH bind only to the LAN IP, the firewall blocks WAN access, and the web application runs as `www-data`. Operations that genuinely require root are confined to systemd services and an enumerated sudoers allowlist.
- **Destructive features behind a separate auth wall.** Things that can cause real damage (like the AT terminal and the web console) require a separate developer password on top of the standard admin login. This is an application-level feature gate, not a sandbox against compromise of the web-server account. See **Threat model and limitations** below.
- **Minimal write footprint.** Persistent files live under `/usrdata`, root-owned runtime files under `/run/quecdeck`, and web-owned runtime files under `/tmp/quecdeck`. Installation, updates, and service enablement briefly remount the root filesystem writable. Normal operation does not.

### Web Server
[Lighttpd](https://www.lighttpd.net/) serves the frontend and CGI backend on port 443 (HTTPS), with port 80 redirecting to HTTPS.
- A pre-start script (`lighttpd_prestart.sh`) reads the current LAN IP, rewrites `lighttpd.conf` to bind to that IP, and regenerates a self-signed TLS certificate to match if the IP has changed.
- Authentication uses a custom session-based login with SHA-512 hashed passwords and a two-tier credential system (admin and developer).
- Sessions are managed via secure cookies, with a 15-minute lockout after 5 failed login attempts. Both passwords require a minimum of 8 characters.

### AT Command Layer
All modem communication goes through [atcli](https://github.com/megakerw/atcli_rust) (a fork of [atcli_rust](https://github.com/1alessandro1/atcli_rust)), a Rust-based AT command CLI that emits clean newline-terminated output (modem `\r` framing is stripped at the source). That is a contract the shell side relies on rather than a convenience: nothing downstream re-strips carriage returns, so replies are parsed as they arrive.
The release stores the binary at `quecdeck/atcli`, matching its installed path at `/usrdata/quecdeck/atcli`.

- **Single gateway.** Shell code never invokes atcli directly. Every caller goes through `script/at-lib.sh`, enforced by a pre-commit check.
- **Serialization and privilege.** Serialization happens inside atcli itself. Its daemon side (`atcli --daemon`, unit `atcmd-daemon`) opens the modem port as root, drops to www-data, and serves one command per unix-socket connection, verifying each peer's uid via `SO_PEERCRED`. The atcli binary is not setuid: the daemon is the only privileged path to the modem.
- **No silent fallback.** There is no automatic fallback to the port, so a plain invocation never bypasses the serializer. If the daemon is down, every caller (root and www-data alike) gets empty output until systemd restarts it within seconds, and the UI tolerates the gap. A root operator can still reach the modem directly for recovery by passing `--direct` explicitly.
- **Sender lifecycle.** Commands whose sender has hung up are skipped instead of being sent to the modem. Fire-and-forget senders (modem reboots) pass `--detach`.
- **Reply completeness.** A reply cut short by a timeout is byte-for-byte a shorter complete one, so the exit status, not the output, is what says whether the modem finished. The atcli client exits 0 only when the modem terminated the reply itself. Both `OK` and `ERROR` count as terminated. It exits non-zero when the modem did not, leaving whatever arrived on stdout, and non-zero with empty stdout when nothing arrived at all (timeout, or the daemon down). Callers that must not parse a truncated record check the status and drop stdout: `get_sms` refuses a short `+CMGL` listing rather than serving it as a complete inbox, `run_cell_scan` appends a `PARTIAL` marker, the developer console labels an unterminated reply, and the updater's health probe warns. A pipe masks the status, so a caller that needs it assigns first, then pipes.
- **Caching.** Responses are cached per endpoint to reduce modem load, with TTLs tuned to how often the data actually changes: 2 seconds for signal stats, connection and SIM info, 5 seconds for network and settings data, and 1 hour for static device info like firmware version and build time. Where possible, multiple AT commands are batched into a single request to cut down on round trips.

### Firewall
A lightweight iptables-based firewall restricts access to ports 80, 443, and optionally 22 (SSH) to traffic entering through the LAN bridge and targeting the configured LAN IP. IPv4 DNS follows the same policy. IPv6 DNS is limited to the bridge's non-routable `fe80::/10` link-local destination, and all other DNS destinations are dropped. This prevents QCMAP's resolver from being used through additional IPPT or future global addresses. DHCP remains firmware-managed. Both address families are mandatory and verified after application. This keeps the policy independent of QCMAP's mode-dependent WAN rule ordering. Custom chains (`QUECDECK`/`QUECDECK6`) survive QCMAP's automatic iptables rebuilds. IPv6 access to the admin UI is blocked.

The web server is bound to the firewall's lifecycle: lighttpd will not start unless the firewall is up, and a firewall restart cycles the web server with it. The admin UI is therefore never served without the LAN-only rules in place, and it comes back automatically after the firewall is restarted.

### Security

QuecDeck runs on a device that operates as root, so keeping the attack surface small matters.

**Network exposure:** each service independently manages its own bind IP at startup (lighttpd via `lighttpd_prestart.sh`, sshd via `update_sshd_ip.sh`), so neither listens on the WAN interface even if the LAN IP changes. The firewall adds a second layer on top of this.

**Privileges:** QuecDeck ships no setuid binaries. The only privileged path to the modem's serial interface (`/dev/smd11`) is the AT daemon, which systemd starts as root and which drops to www-data after opening the port. Clients talk to it over a uid-checked unix socket. CGI scripts do not run as root, and the web server runs as `www-data:www-data` with no supplementary groups. Root actions available to the web tier are limited to an enumerated sudoers allowlist of argument-fixed scripts.

**Web application:**
- All CGI endpoints validate the `Origin` header against the current host, blocking cross-origin requests and functioning as CSRF protection
- All state-changing endpoints are POST-only
- Login attempts are rate-limited with a 1-second delay per attempt and a 15-minute lockout after 5 failures. All login events are written to the access log
- Session tokens are 64-character random strings stored in `0600` files inside a `0700` directory. Cookies are flagged `HttpOnly`, `Secure`, and `SameSite=Strict`. Session file writes are atomic (temp file plus rename), and the developer-unlock flag is kept in a separate per-session file to avoid write races
- Passwords must be at least 8 characters and are validated before any credential check is performed
- Path traversal is rejected in depth: lighttpd is pinned to reject encoded slashes (`%2f`) and dot-segments rather than silently decode them, and the auth layer independently rejects both literal `..` and percent-encoded (`%2e`) sequences before any access-exemption check

**Data at rest:** private web runtime state follows one invariant: it is owned by
`www-data`, directories are `0700`, and regular application-data files are
`0600`. Shell CGIs establish that file mode with `umask 077` in `cgi-lib.sh`.
systemd units use `UMask=0077` for Lua and standalone service writers. Modes are
restrictive at creation time, not repaired afterward with `chmod`. IPC entries
such as `atcli.sock` and its empty lock file use service-defined modes. Their
`0700` parent remains the access boundary. Root can inspect all of this state
through its normal DAC override. Password hashes are stored `root:root 600`,
unreadable from the web tier: login checks pass the password over stdin to a
small root helper via sudo, which answers with an exit code. Pre-start scripts
and anything running with elevated access are `chmod 700 root:root`.

For permission troubleshooting, start services through systemd so their unit
mask applies, and inspect the loaded setting and runtime tree as root:

```sh
systemctl show lighttpd -p UMask -p MainPID
find /tmp/quecdeck -maxdepth 3 -exec stat -c '%A %a %U:%G %n' {} +
```

Files that existed before a permission-policy update retain their old mode until
they are atomically replaced, rotated, or cleared with `/tmp` at reboot. A new
consumer running under another UID will not be able to read this private state
unless its access model is deliberately changed.

#### Threat model and limitations

QuecDeck is intended for an owner-operated modem on a trusted local network. Its controls reduce exposure and contain ordinary web requests, but they do not turn the modem into a multi-user or hostile-tenant system.

- **First-time setup assumes a trusted LAN.** Until the administrator password is created, the setup wizard is intentionally available without credentials. The first client that completes setup becomes the administrator, so initial configuration should be performed immediately and without untrusted clients on the LAN.
- **Developer unlock is an application-level gate.** It protects destructive features from an ordinary administrator session. Session and developer-unlock files are necessarily written by `www-data`, so arbitrary code execution as that account could forge both and reach developer AT commands. The ttyd console still presents the system login prompt, but the developer gate should not be treated as containment of a compromised web process.
- **Login throttling protects the HTTP login path.** Password hashes remain root-only, but a process already executing as `www-data` can invoke the narrowly allowed password-check helper directly and bypass the CGI's per-IP lockout. Use strong, unique admin and developer passwords rather than relying on throttling alone.
- **Release checksums detect corruption and inconsistent files, not publisher compromise.** The release and its checksum manifest are obtained from the same GitHub repository. Verification does not protect against compromise of the publishing account or replacement of both artifacts by an authorized publisher.
- **HTTPS uses a self-signed device certificate.** Encryption is provided after the certificate is accepted, but users should verify and trust the expected certificate rather than dismissing an unexpected certificate change, especially on an untrusted LAN.
- **Local root, ADB, and physical access are trusted.** An attacker with any of these already controls the device and is outside the security boundary QuecDeck attempts to enforce.

### Frontend
The UI is built with [Bootstrap 5](https://getbootstrap.com/) and [Alpine.js](https://alpinejs.dev/) for reactive data binding. All assets carry a content-hashed cache-busting query parameter, maintained by a pre-commit git hook, which lets them be served with a one-year `immutable` cache lifetime: a content change produces a new URL, so updates apply immediately while repeat visits skip revalidation. HTML pages are always sent `no-store` so they never pin stale asset URLs.

### Installation and Updates
QuecDeck is installed via `quecdeck.sh`, which handles Entware/opkg setup, firewall deployment, service registration, and root/console password configuration. On first access, a setup wizard guides the user through setting the admin and (optionally) developer passwords.

Updates can be triggered from the Update page in the web UI or by re-running `quecdeck.sh`. Both paths use the same update installer (`update_quecdeck.sh`), which:

1. Downloads the target release and verifies SHA-256 checksums for its files against `quecdeck/checksums.sha256`. This checks integrity, not independent publisher authenticity. See the limitation above.
2. Stages the new version alongside the running install, then moves the old install aside and swaps the new one in atomically.
3. Verifies that lighttpd owns the configured LAN HTTPS listener and that the authentication CGI executes correctly after the swap, rolling back to the previous version automatically if either check fails.

Watchcat and Scheduled Restart settings are preserved between releases that use the current monitoring implementation. When upgrading from an earlier implementation, its monitoring settings and history are removed and the new services start unconfigured. If a compatible update fails after the switch begins, rollback restores monitoring boot enablement and attempts to restart both workers.

### Optional Components
- **SSH:** OpenSSH server. A pre-start script (`update_sshd_ip.sh`) updates `sshd_config`'s `ListenAddress` to the current LAN IP before the daemon starts, restricting it to LAN only. Requires a root password to be set first.

## Development

The repository includes the following host and device checks. The applicable host checks run on every push and pull request through GitHub Actions:

- **Test suite** (`tests/host/run-tests.sh`): host-side tests are grouped by domain under `tests/host/suites/` and share the small `tests/host/testlib.sh` harness. Run every suite or name selected suites such as `monitoring` or `sms`. Pass `--slow` to include timing-dependent cases such as login lockout. The fast set also runs from the pre-commit hook.
- **Integration tests** (`tests/host/integration/`): the auth.lua harness runs against a stubbed lighttpd request environment. It uses disposable root paths, so it runs only on Linux and skips itself elsewhere. The AT layer's integration tests live in the [atcli repo](https://github.com/megakerw/atcli_rust), where the daemon and client run end to end against a fake modem on a pty.
- **Repository integrity checks** (`tests/host/ci-checks.sh`): shell syntax, JS syntax, the atcli access guard and socket path consistency, the developer-page dev-gate guard, a shell dialect guard (shebangs match what sources cgi-lib/at-lib and what systemd units exec), checksum manifest and pinned bootstrap hashes, and asset version tokens. These mirror the pre-commit hook, so CI catches commits made without the hook configured. Assumes an LF checkout, so on Windows run the test suite instead.
- **On-device scripts** (`tests/device/device-test-*.sh`): copied to the device manually for behavior that host tests cannot verify, including firmware networking, firewall behavior, privilege dropping, socket permissions, and real modem timing. Run the relevant tests before tagging a release. Individual headers identify disruptive cases.

The pre-commit hook is enabled with `git config core.hooksPath .githooks`.

**Shell performance rule** (measured on the device's single Cortex-A7): bash builtins are used only for small or fixed-size data. Bulk transformation of unbounded AT responses uses `tr`/`awk`, never bash pattern replacement, whose cost scales with size times match count (48 seconds on a 44 KB SMS list, versus 20 ms for `tr`). The atcli repo's CI guards the daemon path with a large-response test.

## Credits

QuecDeck is based on [quectel-rgmii-toolkit](https://github.com/iamromulan/quectel-rgmii-toolkit) by [iamromulan](https://github.com/iamromulan), with contributions from:

- [Nate Carlson](https://github.com/natecarlson) - original telnet daemon/socat bridge and RGMII notes
- [aesthernr](https://github.com/aesthernr) - original Simple Admin
- [rbflurry](https://github.com/rbflurry/) - initial Simple Admin fixes
- [dr-dolomite](https://github.com/dr-dolomite) - major stat page improvements
- [tarunVreddy](https://github.com/tarunVreddy) - band aggregation parsing

### Projects

- [Entware/opkg](https://github.com/Entware/Entware) - package manager
- [TTYd](https://github.com/tsl0922/ttyd) - browser-based terminal
- [atcli_rust](https://github.com/1alessandro1/atcli_rust) by [1alessandro1](https://github.com/1alessandro1) - AT command CLI, forked by [megakerw](https://github.com/megakerw/atcli_rust)
