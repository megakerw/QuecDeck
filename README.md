# QuecDeck

QuecDeck is a web-based management interface for the Quectel RM520N-GL. It runs directly on the modem and covers monitoring, configuration, and troubleshooting.

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

Run the following command on your modem through ADB shell or SSH:

```sh
cd /tmp && /usr/bin/curl -q --proto '=https' --proto-redir '=https' --cacert /etc/ssl/certs/ca-certificates.crt -fsSL -o quecdeck.sh https://raw.githubusercontent.com/megakerw/QuecDeck/main/quecdeck.sh && chmod +x quecdeck.sh && ./quecdeck.sh && cd /
```

Select **Install/Update QuecDeck** from the menu. On first access, a setup wizard will guide you through setting your passwords.

Every download the installer makes runs over verified HTTPS, with no HTTP fallback. For manual Entware commands afterwards, use `PATH=/opt/bin:/opt/sbin:$PATH opkg ...` so opkg picks up Entware's TLS-capable wget.

This release starts a new installation generation, so an older release cannot be updated in place. Run the installer, uninstall QuecDeck and Entware, reboot, then run it again to install. After that, update from the Update page in the web UI or by selecting **Install/Update QuecDeck** again. Settings are preserved across compatible updates.

## Features

Features are organised by page.

### Overview
Real-time overview of the modem's current status: signal strength, temperature, SIM status, internet connectivity, active band aggregation, and more. The footer shows how long the modem has been up, which is the box's uptime and not the connection's.

### Cellular Network
- Band locking for LTE, NR5G-NSA, and NR5G-SA
- APN configuration, PDP type, and roaming preferences
- Automatic APN/MBN selection
- SIM slot selection
- Network mode and RAT acquisition order
- NR5G mode control (NSA/SA)

### Cell Scan
Scan for nearby cells and display network, provider, band, frequency, PCI, and RSRP. The modem reports nothing until the sweep finishes, so results appear all at once at the end. A banner is shown across the UI while a scan runs, and Watchcat is paused so it cannot reboot on a scan-induced failure. Completed scans are logged in the Logs page.

### LAN & Modem Options
- LAN IP and DHCP range configuration
- One-click utilities: onboard DNS IPv4/IPv6 proxy, IP Passthrough (IPPT), auto-connect (QMAPWAC), GNSS toggle, and SIM hot-swap detection

Reboot is in the System menu in the navigation bar, reachable from any page.

### Security
- Change the web administrator password after confirming the current password. QuecDeck signs out active web sessions and warns if complete invalidation cannot be confirmed
- Change the developer access password after confirming the current developer password. Any active developer unlock is revoked

### SSH
- Install, update, and uninstall the OpenSSH server from the page itself. The installer menu offers the same actions
- Enable or disable the server and choose its LAN-only port. The firewall opens that port only while SSH is enabled
- Manage up to 5 root public keys. QuecDeck accepts Ed25519, ECDSA, and RSA keys without key options. Private keys are rejected
- Every change on this page requires both the administrator and the developer password, because SSH access grants root. The service does not start without a key or while disabled

### Watchcat and Scheduled Restart
- **Watchcat:** ping-based watchdog that reboots the modem when connectivity is lost, with ping statistics, failure tracking, and a persistent reboot log. A reboot takes at least three rounds in which every configured target failed, and repeated failed reboots back off rather than looping
- **Scheduled Restart:** daily or weekly reboots at a set time, following the modem's own clock and held until that clock reads a plausible date

Both features stay installed and boot-enabled, with their configuration deciding whether they actually run. A disabled feature exits without pinging or touching the modem.

### SMS
View, read, and delete SMS messages from the modem's inbox, newest first. A long message is stored as several parts, so deleting one can take many commands. If any parts are left behind, the page reports how many rather than claiming a success that did not happen.

### Device Information
- **Device & SIM:** manufacturer, model, firmware version, build time, IMEI, phone number, IMSI, and ICCID
- **Network:** LAN IP, WWAN IPv4/IPv6, primary/secondary DNS (IPv4 and IPv6 shown separately), and UPnP status
- **Services:** live status overview of all QuecDeck services (AT Daemon, Firewall, Connection Logger, Watchcat, Scheduled Restart, and SSH)

### Logs
- **Connection Events:** timestamped log of connection changes and failures. Keeps the last 500 entries, cleared on reboot.
- **Access Events:** timestamped log of UI access activity. Keeps the last 500 entries, cleared on reboot.
- **Watchcat Reboot Activity:** timestamped log of Watchcat reboot attempts and related failures, including the failure count and attempt number. Keeps up to 100 persistent entries, then clears the old history when the next event is recorded.
- **AT Daemon:** the last 100 lines from the AT command daemon, including timeouts and dropped connections. Cleared on reboot.

### Update
Check the installed version against the latest GitHub release and trigger an in-place update directly from the web UI. The update log streams in real time. If the update fails, the previous installation is automatically restored.

### Developer
Requires a separate developer password to unlock. Provides access to:
- **AT Terminal:** send AT commands directly to the modem, with support for multiple commands separated by a semicolon
- **Cell Locking:** lock the primary cell for LTE or NR5G-SA by EARFCN and PCI (not persistent across reboots)

### Password Recovery and Installer Access
Both passwords can be changed from the Security page. If the web interface is unavailable or a password is forgotten, run `/usrdata/root/bin/quecdeckpasswd` or `/usrdata/root/bin/quecdeckdevpasswd` through ADB or root SSH.

Download and run `quecdeck.sh` again to install or remove QuecDeck or manage the optional SSH service.

## Implementation

QuecDeck started as a fork of [Simple Admin](https://github.com/iamromulan/quectel-rgmii-toolkit) but most of the code has since been rewritten or redesigned from scratch.

### Approach

- **Fewer features, done well.** QuecDeck covers the basics: signal monitoring, band locking, network config, a handful of utilities. New functionality is only added when it fits that scope and can be implemented cleanly.
- **Minimize attack surface.** The web server and SSH bind only to the LAN IP, the firewall blocks WAN access, and the web application runs as `www-data`. Operations that genuinely require root are confined to systemd services and an enumerated sudoers allowlist.
- **Destructive features behind a separate auth wall.** Things that can cause real damage, such as the AT terminal and cell locking, require a separate developer password on top of the standard admin login. This is an application-level feature gate, not a sandbox against compromise of the web-server account. See **Threat model and limitations** below.
- **Minimal write footprint.** Persistent files live under `/usrdata`. Volatile root state uses `/run/quecdeck`, while web-owned state uses `/run/quecdeck-web`. Installation, updates, and service enablement briefly remount the root filesystem writable. Normal operation does not.

### Web Server
[Lighttpd](https://www.lighttpd.net/) serves the frontend and CGI backend on port 443, with port 80 redirecting to HTTPS. A pre-start script reads the current LAN IP, publishes it to a tmpfs fragment that `lighttpd.conf` includes, and regenerates the self-signed certificate if the IP changed, so the configuration file itself is never rewritten.

Login is session-based with SHA-512 hashed passwords and two tiers of credential, admin and developer. Sessions use secure cookies, both passwords need at least 12 characters, and 5 failed attempts lock an IP out for 15 minutes.

### AT Command Layer
All modem communication goes through [atcli](https://github.com/megakerw/atcli_rust) (a fork of [atcli_rust](https://github.com/1alessandro1/atcli_rust)), a Rust AT command CLI. Its daemon opens the modem port as root, drops to www-data, and serves one command per unix-socket connection, checking each caller's uid. The binary is not setuid, so the daemon is the only privileged path to the modem.

Shell code never calls atcli directly. Every caller goes through `script/at-lib.sh`, enforced by a pre-commit check. There is no silent fallback to the port: if the daemon is down, every caller gets empty output until systemd restarts it seconds later, and the UI tolerates the gap. A root operator can still reach the modem for recovery by passing `--direct`.

Because a reply cut short by a timeout looks exactly like a shorter complete one, the exit status rather than the output is what says whether the modem finished. Callers that must not parse a truncated record check it: `get_sms` refuses a short listing instead of serving it as a complete inbox, and the cell scan marks its results `PARTIAL`.

Responses are cached per endpoint, from 2 seconds for signal stats up to 1 hour for firmware version and build time, and several AT commands are batched into one request where possible.

### Firewall
An iptables firewall restricts ports 80, 443, and the SSH port when enabled to traffic arriving on the LAN bridge and addressed to the LAN IP. IPv4 DNS follows the same policy, IPv6 DNS is confined to link-local, and IPv6 access to the admin UI is blocked. DHCP stays firmware-managed. QuecDeck's own chains survive QCMAP's automatic iptables rebuilds, and both address families are verified after every apply.

Lighttpd is bound to the firewall's lifecycle: it will not start unless the firewall is up, and a firewall restart cycles it. The admin UI is therefore never served without the LAN-only rules in place.

### Security

**Network exposure:** lighttpd and sshd each resolve their own bind IP at startup, so neither listens on the WAN interface even after the LAN IP changes. The firewall is a second layer on top of that.

**Privileges:** QuecDeck ships no setuid binaries. The web server and its CGI scripts run as `www-data` with no supplementary groups, and the root actions available to them are limited to an enumerated sudoers allowlist of argument-fixed scripts. The only privileged path to the modem's serial interface is the AT daemon, reached over a uid-checked unix socket.

**Web application:** every CGI validates the `Origin` header, which also serves as CSRF protection, and all state-changing endpoints are POST-only. Session tokens are 64-character random strings in `0600` files, with cookies flagged `HttpOnly`, `Secure`, and `SameSite=Strict`. Login events are written to the access log. Changing a password is rejected if the replacement matches the other stored credential, and changing the developer password revokes any active developer unlock rather than leaving it valid until it expires. Path traversal is rejected twice over, once by lighttpd and once by the auth layer, in both literal and percent-encoded forms.

**Data at rest:** private web state is owned by `www-data` with `0700` directories and `0600` files, set at creation time rather than repaired afterwards. Password hashes are `root:root 600` and unreadable from the web tier: login checks pass the password over stdin to a small root helper, which answers with an exit code. SSH public keys are stored the same way. SSH accepts public keys only, with PAM, passwords, and keyboard-interactive login disabled, and the service stays inactive until it is enabled and at least one key exists.

#### Threat model and limitations

QuecDeck is intended for an owner-operated modem on a trusted local network. Its controls reduce exposure and contain ordinary web requests, but they do not turn the modem into a multi-user or hostile-tenant system.

- **First-time setup assumes a trusted LAN.** The setup wizard is available without credentials until the administrator password is created, and the first client to complete it becomes the administrator. Do it immediately, with no untrusted clients on the network.
- **A compromised web process can forge application sessions.** Session and developer-unlock state belongs to `www-data`, so code running as that account can mint an administrator session and reach developer AT commands. The developer password is a feature gate against an ordinary admin session, not containment of a compromised web tier.
- **Password throttling is pacing, not a lockout.** The per-IP lockout guards the HTTP login path, but `www-data` can call the root password-check helper directly. That helper serializes checks and delays failures, which bounds the rate without stopping it. Use strong, unrelated admin and developer passwords rather than relying on throttling. The shared per-credential lock also means sustained failed checks can briefly make legitimate logins return unavailable, which is an accepted trade.
- **SSH changes always require both passwords.** Installing, enabling, changing the port, and adding or removing a key all ask for the administrator and developer passwords, because SSH access grants root. A forged session carries no credential, so it cannot turn a key back on.
- **Release checksums detect corruption, not publisher compromise.** The release and its manifest come from the same repository, so verification cannot protect against a compromised publishing account.
- **HTTPS uses a self-signed device certificate.** Verify the expected certificate rather than dismissing an unexpected change, especially on an untrusted LAN.
- **Clean installation boundary.** Releases from before the current installation generation are not updated in place, so legacy login, SSH, and package configuration cannot be carried forward.
- **Local root, ADB, and physical access are trusted.** An attacker with any of these already controls the device.

### Frontend
The UI is built with [Bootstrap 5](https://getbootstrap.com/) and [Alpine.js](https://alpinejs.dev/). Assets carry a content-hashed cache-busting parameter maintained by a pre-commit hook, so they can be served as immutable for a year while a content change still applies immediately under its new URL.

### Installation and Updates
QuecDeck is installed via `quecdeck.sh`, which handles Entware/opkg setup, firewall deployment, and service registration. On first access, a setup wizard guides the user through setting the admin and developer passwords. Both are required.

Updates run from the Update page or by re-running `quecdeck.sh`. Both use the same installer, which verifies the release against its SHA-256 manifest, stages the new version alongside the running one, and swaps it in atomically. After the swap it checks that lighttpd holds the LAN HTTPS listener and that authentication still works, rolling back automatically if either fails.

Watchcat and Scheduled Restart settings survive updates between releases that share the current monitoring implementation. A release that changes that contract starts those features unconfigured rather than loading incompatible state.

### Optional Components
- **SSH:** OpenSSH server with public-key-only root login, bound to the LAN. The installer and unit files ship inside the QuecDeck release, so installing SSH always uses assets from the installed release. Install and manage it from the SSH page, or from the installer menu. QuecDeck does not replace the firmware's own login or password commands.

## Development

The repository includes the following host and device checks. The applicable host checks run on every push and pull request through GitHub Actions:

- **Test suite** (`tests/host/run-tests.sh`): host-side tests are grouped by domain under `tests/host/suites/` and share the small `tests/host/testlib.sh` harness. Run every suite or name selected suites such as `monitoring` or `sms`. Pass `--slow` to include timing-dependent cases such as login lockout. The fast set also runs from the pre-commit hook.
- **Integration tests** (`tests/host/integration/`): the auth.lua harness runs against a stubbed lighttpd request environment. It uses disposable root paths, so it runs only on Linux and skips itself elsewhere. The AT layer's integration tests live in the [atcli repo](https://github.com/megakerw/atcli_rust), where the daemon and client run end to end against a fake modem on a pty.
- **Repository integrity checks** (`tests/host/ci-checks.sh`): shell and JS syntax, the atcli access guard and its socket path, the runtime-path and dev-gate guards, unit self-identity, www-data file modes, shell dialect, checksum manifests and pinned bootstrap hashes, and asset version tokens. These mirror the pre-commit hook, so CI catches commits made without the hook configured. Assumes an LF checkout, so on Windows run the test suite instead.
- **On-device scripts** (`tests/device/device-test-*.sh`): copied to the device manually for behavior that host tests cannot verify, such as firmware networking, privilege dropping, and real modem timing. Run the relevant ones before tagging a release. Individual headers identify disruptive cases.

The pre-commit hook is enabled with `git config core.hooksPath .githooks`.

To test an unreleased branch on hardware, choose **Install/Update QuecDeck (development branch)** from the installer menu and enter the branch name. The manifest, the installer, and the release archive are all fetched from that branch and verified against each other, exactly as a release install is. The branch is unreleased code and can leave the modem without a working web interface, so it is not a supported way to run QuecDeck.

## Credits

QuecDeck is based on [quectel-rgmii-toolkit](https://github.com/iamromulan/quectel-rgmii-toolkit) by [iamromulan](https://github.com/iamromulan), with contributions from:

- [Nate Carlson](https://github.com/natecarlson) - original telnet daemon/socat bridge and RGMII notes
- [aesthernr](https://github.com/aesthernr) - original Simple Admin
- [rbflurry](https://github.com/rbflurry/) - initial Simple Admin fixes
- [dr-dolomite](https://github.com/dr-dolomite) - major stat page improvements
- [tarunVreddy](https://github.com/tarunVreddy) - band aggregation parsing

### Projects

- [Entware/opkg](https://github.com/Entware/Entware) - package manager
- [atcli_rust](https://github.com/1alessandro1/atcli_rust) by [1alessandro1](https://github.com/1alessandro1) - AT command CLI, forked by [megakerw](https://github.com/megakerw/atcli_rust)
