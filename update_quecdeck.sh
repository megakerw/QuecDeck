#!/bin/bash
# QuecDeck self-updater. One committed file, two phases:
#   update_quecdeck.sh <tag>            bootstrap: register + start the install
#                                        service (this same file, --install)
#   update_quecdeck.sh --install <tag>  install: stage, verify, swap, roll back
# The install phase runs as the install_quecdeck systemd oneshot from /run
# (tmpfs) so it survives the web connection dropping when lighttpd restarts
# mid-update.

GITUSER="megakerw"
REPONAME="QuecDeck"
DIR_NAME="quecdeck"
SERVICE_FILE="/run/systemd/system/install_quecdeck.service"
SERVICE_NAME="install_quecdeck"
LOG_FILE="/run/quecdeck/install.log"
STATUS_FILE="/run/quecdeck/update.status"
QUECDECK_DIR="/usrdata/quecdeck"
INSTALL_GENERATION=2
umask 022
# Do not search the legacy root bin until harden_root_home has quarantined it.
export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/opt/bin:/opt/sbin

# All root-owned runtime state lives here. Root-owned and not world-writable,
# so www-data can read the log but cannot plant a name for root to follow.
# Reachable both from run_update.sh and a direct interactive run.
if [ -L /run/quecdeck ] || ! mkdir -p /run/quecdeck ||
   ! chown root:root /run/quecdeck || ! chmod 755 /run/quecdeck; then
    echo "FATAL: cannot create the root-owned update runtime directory." >&2
    exit 1
fi

# Convert the installer's persisted outcome into the bootstrap's user-facing
# result. The status file is authoritative. The systemctl result is only the synchronous
# wait mechanism and its return code is useful solely when no terminal status
# was committed.
report_install_outcome() { # report_install_outcome <status> <systemctl-rc>
    case "$1" in
        done)
            echo -e "\e[1;32mQuecDeck installed.\e[0m"
            return 0
            ;;
        failed:rollback_ok)
            echo -e "\e[1;31mQuecDeck update failed. The previous version was restored.\e[0m"
            return 1
            ;;
        failed:rollback_failed)
            echo -e "\e[1;31mQuecDeck update failed and rollback was not possible. Re-run the installer via ADB or SSH to recover.\e[0m"
            return 1
            ;;
        failed)
            echo -e "\e[1;31mQuecDeck update failed.\e[0m"
            return 1
            ;;
        *)
            echo -e "\e[1;31mInstall did not produce a valid final status (status='${1:-missing}', systemctl rc=$2). Check $LOG_FILE.\e[0m"
            return 1
            ;;
    esac
}

# ============================= INSTALL PHASE =============================
# Runs as the install_quecdeck systemd oneshot: stage, verify, swap, roll back.
# The release tag comes from the --install argument.
if [ "$1" = "--install" ]; then
# GITUSER/REPONAME/QUECDECK_DIR/PATH come from the shared header above.
GITTREE="${2:-main}"
GITROOT="https://raw.githubusercontent.com/$GITUSER/$REPONAME/$GITTREE"

STAGE_DIR="${QUECDECK_DIR}.new"
# Staging scratch on tmpfs. Top-level so the EXIT trap can clear them: a kill
# mid-download/extract would otherwise strand them in RAM until the next
# update or a reboot.
RELEASE_TARBALL=/run/quecdeck/release.tar.gz
RELEASE_EXTRACT_DIR=/run/quecdeck/release-extract
OLD_DIR="${QUECDECK_DIR}.old"
_monitoring_rollback_supported=0
export HOME=/usrdata/root

remount_rw() {
    mount -o remount,rw /
}

remount_ro() {
    mount -o remount,ro /
}

# Repair the legacy 0777 root home without trusting anything already inside it.
# The old bin is quarantined once, out of PATH, so legitimate custom files can
# be recovered manually. This updater is a standalone bootstrap, so it cannot
# source the equivalent helper from the incoming release tree.
harden_root_home() {
    _root_home="${1:-/usrdata/root}"
    _sentinel="$_root_home/.quecdeck-home-hardened"
    mkdir -p "$_root_home" || return 1
    chown root:root "$_root_home" && chmod 700 "$_root_home" || return 1

    _hardened=0
    if [ ! -L "$_sentinel" ] && [ -f "$_sentinel" ] && \
       [ "$(stat -c '%U %a' "$_sentinel" 2>/dev/null)" = "root 600" ] && \
       grep -qx '1' "$_sentinel" 2>/dev/null; then
        _hardened=1
    fi
    if [ "$_hardened" = "0" ]; then
        if [ -e "$_root_home/bin" ] || [ -L "$_root_home/bin" ]; then
            _quarantine="$_root_home/bin.pre-quecdeck-hardening.$(date +%s).$$"
            while [ -e "$_quarantine" ] || [ -L "$_quarantine" ]; do
                _quarantine="${_quarantine}.x"
            done
            mv "$_root_home/bin" "$_quarantine" || return 1
            echo "Previous root bin quarantined at $_quarantine"
        fi
        mkdir -m 755 "$_root_home/bin" || return 1
        chown root:root "$_root_home/bin" || return 1
        rm -f "$_root_home/.profile" "$_sentinel"
        printf '1\n' > "$_sentinel" || return 1
        chown root:root "$_sentinel" && chmod 600 "$_sentinel" || return 1
    elif [ -L "$_root_home/bin" ] || [ ! -d "$_root_home/bin" ]; then
        echo "FATAL: refusing unsafe $_root_home/bin after hardening."
        return 1
    else
        chown root:root "$_root_home/bin" && chmod 755 "$_root_home/bin" || return 1
    fi
}

# Normalize archive-derived modes before stage_release applies the narrower
# executable and root-only grants. Takes the stage path explicitly so the mode
# policy can be exercised against an isolated fixture on-device.
normalize_stage_modes() {
    local _stage_root="$1"
    [ -d "$_stage_root" ] || return 1
    find "$_stage_root" -type d -exec chmod 755 {} + &&
        find "$_stage_root" -type f -exec chmod 644 {} +
}

# Mutual exclusion and liveness are owned by systemd: this runs as the
# install_quecdeck oneshot, so a concurrent start coalesces and get_update_log
# reads state via 'systemctl is-active'. No lock or PID file needed.
if ! echo "running" > "${STATUS_FILE}.tmp" || ! chmod 644 "${STATUS_FILE}.tmp" || ! mv "${STATUS_FILE}.tmp" "$STATUS_FILE"; then
    rm -f "${STATUS_FILE}.tmp"
    echo "FATAL: cannot record update status. Refusing to install." >&2
    exit 1
fi

_update_status="failed"

# Atomically write the update status (temp file + rename). Called explicitly at
# the end of the main flow -- before the self-unit-removal/daemon-reload, which
# can make systemd cut this process short and skip the EXIT trap -- and again
# from the EXIT trap.
_write_status() {
    echo "$1" > "${STATUS_FILE}.tmp" && chmod 644 "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE" || rm -f "${STATUS_FILE}.tmp"
}
# Copy the install log off tmpfs so it survives the reboot a user reaches for
# when an update goes wrong. /usrdata is its own writable partition, so this
# needs no rootfs remount and works from the EXIT trap.
# quecdeck.sh also uses this path during uninstall, so keep the two in sync.
PERSIST_LOG=/usrdata/quecdeck_last_update.log
_persist_log() {
    cp -f "$LOG_FILE" "$PERSIST_LOG" 2>/dev/null && chmod 600 "$PERSIST_LOG" 2>/dev/null
}
_update_cleanup() {
    local _cleanup_restart_monitoring=0
    # A SIGTERM mid-swap (TimeoutStartSec expiry, systemctl stop) unwinds the
    # shell past the main flow's failure handling, which would leave the new
    # release half-configured with no rollback. Detect that here: the swap
    # started, but neither success nor a rollback attempt was recorded.
    if [ "${_swap_committed:-0}" = "1" ] && [ "${result_quecdeck:-}" != "OK" ] && [ "${result_rollback:-N/A}" = "N/A" ]; then
        echo "Install interrupted mid-swap. Attempting rollback."
        if _revert_swap; then
            _update_status="failed:rollback_ok"
            [ "${_monitoring_rollback_supported:-0}" = "1" ] && _cleanup_restart_monitoring=1
        else
            _update_status="failed:rollback_failed"
        fi
    fi
    _write_status "$_update_status"
    _persist_log
    # Staging is finished by every path that reaches here, so this only ever
    # collects what a kill mid-download/extract left on tmpfs. No-op otherwise.
    rm -rf "$RELEASE_TARBALL" "$RELEASE_EXTRACT_DIR"
    if remount_ro; then
        [ "$_cleanup_restart_monitoring" = "1" ] && _restart_monitoring_workers
    fi
}
trap '_update_cleanup' EXIT
# Convert SIGTERM/SIGINT (systemd stop, TimeoutStartSec expiry) into a normal
# exit so the EXIT trap still runs and restores the read-only rootfs. Without
# this, an uncaught signal would kill bash before cleanup and leave / mounted
# read-write. SIGKILL still can't be trapped, but a reboot remounts / read-only.
trap 'exit 1' INT TERM

if ! remount_rw; then
    echo "FATAL: could not remount / read-write. Refusing to install." >&2
    exit 1
fi

# No individual monitoring state is captured here. The explicit release
# generation marker determines whether rollback can restore the static services.

# --- Pure helpers, unit-tested in tests/host/run-tests.sh ---

# Strip a leading "v" from a release tag for the on-disk version file
# (v1.0.15 -> 1.0.15) so it matches how check_update compares versions.
_tag_to_version() {
    printf '%s' "${1#v}"
}

# Normalize lighttpd.conf's bind IP and :443 socket line to 0.0.0.0 on stdin.
# lighttpd_prestart.sh patches these to the live LAN IP, so the staged (repo,
# 0.0.0.0) and live confs must be normalized before diffing, or a mere IP patch
# would look like a config change and force an unnecessary lighttpd restart.
_normalize_bind() {
    sed 's/server\.bind = "[0-9.]*"/server.bind = "0.0.0.0"/;s/== "[0-9.]*:443"/== "0.0.0.0:443"/'
}

# True (rc 0) if X.Y.Z version $1 is strictly lower than $2. Field-by-field
# numeric comparison (1.0.9 < 1.0.10). Callers validate the format first.
_version_lt() {
    _va=${1%%.*}; _vr=${1#*.}; _vb=${_vr%%.*}; _vc=${_vr#*.}
    _wa=${2%%.*}; _wr=${2#*.}; _wb=${_wr%%.*}; _wc=${_wr#*.}
    [ "$_va" -ne "$_wa" ] && { [ "$_va" -lt "$_wa" ]; return; }
    [ "$_vb" -ne "$_wb" ] && { [ "$_vb" -lt "$_wb" ]; return; }
    [ "$_vc" -lt "$_wc" ]
}

_install_generation_supported() {
    [ ! -d "$QUECDECK_DIR/www" ] && return 0
    grep -qx "$INSTALL_GENERATION" "$QUECDECK_DIR/install-generation" 2>/dev/null || return 1
}

preflight_check() {
    if ! _install_generation_supported; then
        echo "FATAL: This release requires a clean installation."
        echo "Rerun the installer to uninstall QuecDeck and Entware, reboot, then install this release again."
        return 1
    fi

    echo "Running pre-flight checks..."

    # Downgrade guard: refuse a target release older than the installed one,
    # so a replayed old release URL can't reintroduce fixed vulnerabilities.
    # Equal versions pass (the UI's force-reinstall re-sends the installed
    # tag). Non-semver refs such as branch names and fresh installs skip the guard.
    # Deliberate downgrades run interactively with QUECDECK_ALLOW_DOWNGRADE=1.
    _installed_ver=$(cat "$QUECDECK_DIR/version" 2>/dev/null | tr -d '[:space:]')
    _target_ver=$(_tag_to_version "$GITTREE")
    if printf '%s' "$_target_ver" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' &&        printf '%s' "$_installed_ver" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' &&        [ "${QUECDECK_ALLOW_DOWNGRADE:-0}" != "1" ] &&        _version_lt "$_target_ver" "$_installed_ver"; then
        echo "FATAL: Target version $_target_ver is older than the installed $_installed_ver."
        echo "To downgrade deliberately, rerun the installer from ADB or root SSH with QUECDECK_ALLOW_DOWNGRADE=1."
        return 1
    fi

    _pf_checksums=/run/quecdeck/preflight.sha256

    /opt/bin/wget --timeout=30 --tries=2 -q -O "$_pf_checksums" "$GITROOT/quecdeck/checksums.sha256" || {
        echo "FATAL: Could not download release files. Check network connectivity and that the release tag exists."
        rm -f "$_pf_checksums"
        return 1
    }
    if [ ! -s "$_pf_checksums" ]; then
        echo "FATAL: Release checksums file is empty. The release tag may not exist."
        rm -f "$_pf_checksums"
        return 1
    fi
    rm -f "$_pf_checksums"

    # The new release is staged alongside the live install before swapping in,
    # so /usrdata briefly holds both copies at once. Require headroom for
    # roughly 2.2x the current install size (live + staged + a small margin
    # for the old copy that lingers until cleanup completes).
    _pf_needed=$(du -sk "$QUECDECK_DIR" 2>/dev/null | awk '{print int($1*2.2)}')
    _pf_needed=${_pf_needed:-4000}
    _pf_free=$(df -k /usrdata 2>/dev/null | awk 'NR==2 {print $4}')
    case "$_pf_free" in
        ''|*[!0-9]*)
            echo "FATAL: Could not determine free space on /usrdata. Aborting update."
            return 1
            ;;
    esac
    if [ "$_pf_free" -lt "$_pf_needed" ]; then
        echo "FATAL: Not enough free space on /usrdata (need ~${_pf_needed}KB, have ${_pf_free}KB). Aborting update."
        return 1
    fi

    # The download and extraction live in /run/quecdeck (tmpfs), a separate
    # filesystem from /usrdata AND from /tmp: the archive and the extracted
    # repo tree coexist briefly, so require ~2x the install size there as well.
    # Must track RELEASE_TARBALL/RELEASE_EXTRACT_DIR: measuring /tmp here would
    # check a filesystem the update no longer stages into.
    _pf_run_needed=$(du -sk "$QUECDECK_DIR" 2>/dev/null | awk '{print int($1*2)}')
    _pf_run_needed=${_pf_run_needed:-4000}
    # Keep 1 MiB available for systemd and other runtime state while staging.
    _pf_run_needed=$((_pf_run_needed + 1024))
    _pf_run_free=$(df -k /run 2>/dev/null | awk 'NR==2 {print $4}')
    case "$_pf_run_free" in
        ''|*[!0-9]*)
            echo "FATAL: Could not determine free space on /run. Aborting update."
            return 1
            ;;
    esac
    if [ "$_pf_run_free" -lt "$_pf_run_needed" ]; then
        echo "FATAL: Not enough free space on /run (need ~${_pf_run_needed}KB, have ${_pf_run_free}KB). Aborting update."
        return 1
    fi

    echo "Pre-flight checks passed."
    return 0
}

_stage_persistent_state() {
    local source_var="$QUECDECK_DIR/var" staged_var="$STAGE_DIR/var"

    mkdir -p "$staged_var" || {
        echo -e "\e[1;31mFATAL: Could not create the staged state directory.\e[0m"
        return 1
    }
    if [ -d "$source_var" ]; then
        cp -rf "$source_var/." "$staged_var/" 2>/dev/null || {
            echo -e "\e[1;31mFATAL: Could not preserve the existing QuecDeck state.\e[0m"
            return 1
        }
    fi

    # Preserve monitoring state only when both releases declare the same
    # service and state contract.
    if [ -s "$QUECDECK_DIR/monitoring-generation" ] \
        && cmp -s "$QUECDECK_DIR/monitoring-generation" "$STAGE_DIR/monitoring-generation"; then
        _monitoring_rollback_supported=1
    else
        if ! rm -f "$staged_var/watchcat.json" \
                   "$staged_var/watchcat_reboot_state.json" \
                   "$staged_var/scheduled_restart.json" \
                   "$staged_var/restart_log.jsonl"; then
            echo -e "\e[1;31mFATAL: Could not remove incompatible monitoring state from the staged release.\e[0m"
            return 1
        fi
        [ -d "$source_var" ] && echo "Legacy monitoring configuration and history were not carried into the new implementation."
    fi

    if ! chown -R www-data "$staged_var" || ! chmod 700 "$staged_var"; then
        echo -e "\e[1;31mFATAL: Could not secure the staged QuecDeck state.\e[0m"
        return 1
    fi
}

stage_release() {
    echo -e "\e[1;32mDownloading new release (ref: $GITTREE)...\e[0m"

    rm -rf "$STAGE_DIR"
    mkdir -p "$STAGE_DIR"

    # The quecdeck/ subtree comes down as one archive rather than one request
    # per file, so a dropped connection is a single unambiguous failure to
    # retry, not a partial set of missing files.
    _tarball_url="https://codeload.github.com/$GITUSER/$REPONAME/tar.gz/$GITTREE"
    rm -rf "$RELEASE_TARBALL" "$RELEASE_EXTRACT_DIR"

    echo "Downloading release archive..."
    _tarball_ok=0
    _attempt=1
    while [ "$_attempt" -le 4 ]; do
        rm -f "$RELEASE_TARBALL"
        if /opt/bin/wget --timeout=60 --tries=1 -q -O "$RELEASE_TARBALL" "$_tarball_url" && [ -s "$RELEASE_TARBALL" ]; then
            _tarball_ok=1
            break
        fi
        echo "Download attempt $_attempt failed, retrying..."
        _attempt=$((_attempt + 1))
        sleep 3
    done
    if [ "$_tarball_ok" != "1" ]; then
        echo -e "\e[1;31mFATAL: Could not download the release archive after multiple attempts.\e[0m"
        rm -f "$RELEASE_TARBALL"
        return 1
    fi

    mkdir -p "$RELEASE_EXTRACT_DIR"
    tar -xzf "$RELEASE_TARBALL" -C "$RELEASE_EXTRACT_DIR" || {
        echo -e "\e[1;31mFATAL: Failed to extract the release archive.\e[0m"
        rm -rf "$RELEASE_TARBALL" "$RELEASE_EXTRACT_DIR"
        return 1
    }
    rm -f "$RELEASE_TARBALL"

    # GitHub wraps the archive in a single top-level directory whose exact name
    # varies by ref type. Discover it rather than assuming a naming pattern. If
    # find ever returns more than one dir, the embedded newline makes the -d
    # check below fail on its own, so no separate count check is needed.
    _top_dir=$(find "$RELEASE_EXTRACT_DIR" -mindepth 1 -maxdepth 1 -type d)
    if [ ! -d "$_top_dir/quecdeck" ]; then
        echo -e "\e[1;31mFATAL: Unexpected release archive layout.\e[0m"
        rm -rf "$RELEASE_EXTRACT_DIR"
        return 1
    fi

    echo "Populating staged release..."
    cp -a "$_top_dir/quecdeck/." "$STAGE_DIR/"
    rm -rf "$RELEASE_EXTRACT_DIR"

    printf '%s\n' "$(_tag_to_version "$GITTREE")" > "$STAGE_DIR/version"

    echo "Release staged."

    cd /

    # Deterministic mode baseline before anything widens it. The release tarball
    # carries its own modes (664/775) and chmod +x is umask-relative, so both
    # leak a group-write bit into the deploy. Must stay ahead of the grants
    # below, which widen only what actually runs.
    if ! normalize_stage_modes "$STAGE_DIR"; then
        echo -e "\e[1;31mFATAL: Could not normalize staged release permissions.\e[0m"
        return 1
    fi

    chown root:root "$STAGE_DIR/atcli"
    # Deliberately NOT setuid (zero-setuid design): the daemon, started as
    # root by systemd, is the only thing that opens /dev/smd11 with
    # privilege. Clients reach its socket through its www-data ownership. The
    # daemon also verifies peers via SO_PEERCRED, so no caller needs
    # elevation. --direct is root-only and never taken implicitly.
    chmod 0755 "$STAGE_DIR/atcli"

    # cgi.assign executes ANY file under cgi-bin, so keep it root-owned and not
    # www-data-writable (755): a web-tier compromise can't drop/overwrite a CGI.
    chown -R root:www-data $STAGE_DIR/www/cgi-bin
    chmod 755 $STAGE_DIR/www/cgi-bin $STAGE_DIR/www/cgi-bin/*
    chmod 755 $STAGE_DIR/script/*
    chmod 755 $STAGE_DIR/console/.profile
    # Root-only scripts (sudo targets and root-unit payloads): root:root so
    # www-data can never replace a privileged entry point, 700 since nothing
    # unprivileged runs or reads them. The rest of script/ stays 755: www-data
    # sources or executes those.
    for _s in lighttpd_prestart.sh write_htpasswd.sh change_password.sh \
              ssh_keys.sh check_password.sh run_update.sh firewall.sh; do
        chown root:root "$STAGE_DIR/script/$_s"
        chmod 700 "$STAGE_DIR/script/$_s"
    done

    # An unexpectedly empty file fails checksum verification below like any
    # other mismatch (no file in the repo is legitimately zero-byte), so no
    # separate empty-file pass is needed first.

    # Verify integrity of all staged files against the manifest bundled in the
    # same archive they came from (no separate fetch: a second request against
    # a moving ref like main could return a newer manifest than what was
    # actually staged, failing a perfectly good install on a false mismatch).
    echo "Verifying file integrity..."
    CHECKSUMS_FILE="$STAGE_DIR/checksums.sha256"
    if [ ! -s "$CHECKSUMS_FILE" ]; then
        echo "FATAL: checksums.sha256 missing or empty in the staged release. Aborting."
        return 1
    fi
    verify_ok=1
    _manifest_inventory=/run/quecdeck/manifest-inventory.$$
    _stage_inventory=/run/quecdeck/stage-inventory.$$
    : > "$_manifest_inventory" || return 1
    while IFS= read -r line; do
        # Skip comments and blank lines
        case "$line" in '#'*|'') continue ;; esac
        expected=$(echo "$line" | awk '{print $1}')
        key=$(echo "$line" | awk '{print $2}')
        # Map the repository-relative path to its staged path. Skip entries outside quecdeck/.
        rel=${key#*quecdeck/}
        [ "$rel" = "$key" ] && continue
        file="$STAGE_DIR/$rel"
        printf '%s\n' "$rel" >> "$_manifest_inventory"
        if [ -f "$file" ]; then
            actual=$(sha256sum "$file" | awk '{print $1}')
            if [ "$actual" != "$expected" ]; then
                echo "ERROR: Checksum mismatch: $file"
                echo "  Expected: $expected"
                echo "  Got:      $actual"
                verify_ok=0
            fi
        else
            echo "ERROR: File missing from staged release: $file"
            verify_ok=0
        fi
    done < "$CHECKSUMS_FILE"
    # Checking manifest -> tree catches missing and modified files. Check the
    # reverse direction too: the archive copies the complete quecdeck subtree,
    # so an unlisted CGI, root script, unit, or symlink must never ride along
    # unchecked. The checksums.sha256 manifest cannot checksum itself, and version is made
    # locally from the selected tag. Those are the only inventory exceptions.
    printf '%s\n' checksums.sha256 version >> "$_manifest_inventory"
    sort "$_manifest_inventory" -o "$_manifest_inventory"
    if [ -n "$(uniq -d "$_manifest_inventory")" ]; then
        echo "ERROR: Duplicate staged paths in the release manifest."
        verify_ok=0
    fi
    find "$STAGE_DIR" \( -type f -o -type l \) -print | \
        sed "s|^$STAGE_DIR/||" | sort > "$_stage_inventory"
    if ! diff -u "$_manifest_inventory" "$_stage_inventory"; then
        echo "ERROR: Staged release contains files absent from the manifest (or manifest entries with no staged file)."
        verify_ok=0
    fi
    rm -f "$_manifest_inventory" "$_stage_inventory"
    # The manifest stays with the install as a record of what the release
    # shipped.
    if [ "$verify_ok" != "1" ]; then
        echo "FATAL: One or more files failed checksum verification. Staged release may be compromised."
        return 1
    fi
    echo "All checksums verified OK."

    # Copy persistent state into the staged tree. Monitoring compatibility is
    # filtered below. lan_ip and the TLS certificate remain valid across releases.
    _stage_persistent_state || return 1
    [ -f "$QUECDECK_DIR/server.crt" ] && cp -f "$QUECDECK_DIR/server.crt" "$STAGE_DIR/server.crt"
    [ -f "$QUECDECK_DIR/server.key" ] && cp -f "$QUECDECK_DIR/server.key" "$STAGE_DIR/server.key"

    # Generate a TLS certificate if one wasn't carried forward from a previous install
    if [ ! -f "$STAGE_DIR/server.crt" ] || [ ! -f "$STAGE_DIR/server.key" ]; then
        _cert_ip="192.168.225.1"
        if [ -f "/etc/data/mobileap_cfg.xml" ]; then
            _extracted=$(grep -o '<APIPAddr>[^<]*</APIPAddr>' "/etc/data/mobileap_cfg.xml" | sed 's/<APIPAddr>//;s/<\/APIPAddr>//')
            if printf '%s' "$_extracted" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' &&                printf '%s' "$_extracted" | awk -F. '$1<=255&&$2<=255&&$3<=255&&$4<=255{exit 0} {exit 1}'; then
                _cert_ip="$_extracted"
            fi
        fi
        _tmpconf=$(mktemp)
        printf '[req]\ndistinguished_name=dn\n[dn]\n[san]\nsubjectAltName=IP:%s\n' "$_cert_ip" > "$_tmpconf"
        openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509             -subj "/O=QuecDeck/CN=QuecDeck"             -config "$_tmpconf" -extensions san             -keyout "$STAGE_DIR/server.key" -out "$STAGE_DIR/server.crt" || {
            rm -f "$_tmpconf"
            echo -e "\e[1;31mFATAL: Failed to generate TLS certificate.\e[0m"
            return 1
        }
        rm -f "$_tmpconf"
    fi
    chmod 600 "$STAGE_DIR/server.key"

    # lighttpd is reinstalled only when actually necessary. Determining
    # that (presence AND staleness) requires a fresh opkg index, so do all of
    # this here in staging where it overlaps with the old site still serving.
    # Reading the installed-package database and comparing against the index
    # never touches the live lighttpd process. Only the eventual opkg install
    # (deferred to the swap, since its postinst scripts may restart the
    # service) needs that controlled window.
    echo "Checking lighttpd package status..."
    _lighttpd_pkgs="sudo lighttpd lighttpd-mod-cgi lighttpd-mod-magnet lighttpd-mod-openssl"
    _lighttpd_needs_install=0
    _lighttpd_index_fresh=1
    timeout 120 /opt/bin/opkg update >/dev/null 2>&1 || {
        echo -e "\e[1;33mWARNING: Could not refresh the opkg package index. Proceeding with a presence-only check (version-staleness can't be verified this run).\e[0m"
        _lighttpd_index_fresh=0
    }
    _lighttpd_installed=$(/opt/bin/opkg list-installed 2>/dev/null)
    [ "$_lighttpd_index_fresh" = "1" ] && _lighttpd_upgradable=$(/opt/bin/opkg list-upgradable 2>/dev/null)
    for _pkg in $_lighttpd_pkgs; do
        if ! printf '%s\n' "$_lighttpd_installed" | grep -q "^$_pkg "; then
            echo "  $_pkg: not installed"
            _lighttpd_needs_install=1
        elif [ "$_lighttpd_index_fresh" = "1" ] && printf '%s\n' "$_lighttpd_upgradable" | grep -q "^$_pkg "; then
            echo "  $_pkg: update available"
            _lighttpd_needs_install=1
        fi
    done
    if [ "$_lighttpd_needs_install" = "1" ]; then
        echo "Lighttpd packages will be (re)installed during the switch."
        result_lighttpd="PENDING"
    elif [ "$_lighttpd_index_fresh" = "1" ]; then
        echo "Lighttpd packages are present and up to date."
        result_lighttpd="SKIPPED"
    else
        echo "Lighttpd packages are present (staleness not verified this run)."
        result_lighttpd="SKIPPED"
    fi

    echo -e "\e[1;32mNew release staged.\e[0m"
    return 0
}

# Stop monitoring workers from the installed release before its tree is moved.
# Missing units are normal on a first install. A known unit must both accept the
# stop and report a terminal inactive state. Otherwise an old worker could keep
# executing the old script, or reboot the modem, while the new release is being
# swapped into place.
stop_monitoring_for_swap() {
    local unit state unit_file failed=0
    for unit in watchcat scheduled_restart; do
        unit_file="${MONITORING_UNIT_DIR:-/lib/systemd/system}/${unit}.service"
        # A missing file plus an inactive unit is a normal first install. Check
        # both: systemd can retain a loaded/running unit after its file vanished.
        if [ ! -f "$unit_file" ] && ! systemctl is-active "$unit" >/dev/null 2>&1; then
            continue
        fi
        if ! systemctl stop "$unit" 2>/dev/null; then
            echo -e "\e[1;31mFATAL: Could not stop legacy ${unit}. The existing installation was not changed.\e[0m"
            failed=1
            continue
        fi
        state=$(systemctl is-active "$unit" 2>/dev/null)
        case "$state" in
            inactive|failed) ;;
            *)
                echo -e "\e[1;31mFATAL: Legacy ${unit} is still ${state:-in an unknown state}. The existing installation was not changed.\e[0m"
                failed=1
                ;;
        esac
    done
    [ "$failed" = "0" ]
}

_restore_pre_swap_services() {
    local unit
    for unit in $_pre_swap_active_units; do
        systemctl start "$unit" 2>/dev/null || \
            echo -e "\e[1;33mWARNING: Could not restore previously active ${unit}. Re-run the installer from ADB or SSH.\e[0m"
    done
}

_restart_monitoring_workers() {
    local unit
    for unit in watchcat scheduled_restart; do
        systemctl reset-failed "$unit" >/dev/null 2>&1
        systemctl restart "$unit" || \
            echo -e "\e[1;33mWARNING: ${unit} did not start. Re-save its settings from the web UI.\e[0m"
    done
    return 0
}

swap_in_release() {
    _had_previous=0
    [ -d "$QUECDECK_DIR/www" ] && _had_previous=1

    # Snapshot the live release's systemd unit filenames before the swap. Unlike
    # everything else inside $QUECDECK_DIR (which the rename-based rollback
    # restores wholesale), unit files are copied out into /lib/systemd/system/
    # by name, so a brand-new unit introduced by this release would be left
    # behind as an orphan if we have to roll back, since the restored old
    # release's systemd/ directory never contained it. Diff the staged set
    # against this snapshot below so _revert_swap knows what to remove.
    _old_systemd_units=""
    [ "$_had_previous" = "1" ] && _old_systemd_units=$(ls "$QUECDECK_DIR/systemd/" 2>/dev/null)

    # Tracks whether we've actually started rearranging the live install. Only
    # then is there anything for _revert_swap to undo. A failure before this
    # point means the old site is still sitting at $QUECDECK_DIR untouched, so
    # reporting a "rollback" (let alone a failed one) would be actively misleading.
    _swap_committed=0

    # Only stop/start lighttpd if config, the unit file, or packages changed.
    # Pure content updates (HTML/JS/CSS/CGI/auth.lua) go live without a restart:
    # the mv is atomic so lighttpd serves new content immediately, and mod_magnet
    # reloads auth.lua on the next request when it detects the mtime change.
    _need_lighttpd_restart=0
    if [ "$_lighttpd_needs_install" = "1" ] || [ "$_had_previous" = "0" ]; then
        _need_lighttpd_restart=1
    else
        # lighttpd_prestart.sh patches server.bind and the socket line in the
        # live lighttpd.conf to the LAN IP, while the staged file (from the
        # repo) always has 0.0.0.0. Normalize both to 0.0.0.0 before diffing
        # so a mere IP patch doesn't force an unnecessary restart.
        diff -q <(_normalize_bind < "$STAGE_DIR/lighttpd.conf") <(_normalize_bind < "$QUECDECK_DIR/lighttpd.conf") >/dev/null 2>&1 || _need_lighttpd_restart=1
        diff -q "$STAGE_DIR/systemd/lighttpd.service" "/lib/systemd/system/lighttpd.service" >/dev/null 2>&1             || _need_lighttpd_restart=1
    fi

    # A firewall restart cycles lighttpd with it (lighttpd.service is
    # PartOf=firewall.service), so it interrupts the UI just like a lighttpd
    # restart. Computed pre-swap (staged vs live) so the message and the
    # post-swap health probe treat it as a restart, not a stayed-up swap.
    _need_firewall_restart=0
    if [ "$_had_previous" = "0" ]; then
        _need_firewall_restart=1
    else
        diff -q "$STAGE_DIR/script/firewall.sh" "$QUECDECK_DIR/script/firewall.sh" >/dev/null 2>&1                 || _need_firewall_restart=1
        diff -q "$STAGE_DIR/systemd/firewall.service" "/lib/systemd/system/firewall.service" >/dev/null 2>&1       || _need_firewall_restart=1
    fi

    # Single flag for "the web UI gets cycled": drives the message here and the
    # patient health probe after the swap. Keep both sites on this flag.
    _ui_restart=0
    if [ "$_need_lighttpd_restart" = "1" ] || [ "$_need_firewall_restart" = "1" ]; then
        _ui_restart=1
    fi

    if [ "$_ui_restart" = "1" ]; then
        echo -e "\e[1;32mSwitching to new release (web UI will be briefly unavailable)...\e[0m"
    else
        echo -e "\e[1;32mSwitching to new release (web UI stays up)...\e[0m"
    fi

    echo "Preparing for swap..."
    # Accepted limitation: a concurrent monitoring-settings request can restart
    # a worker after this check. Avoiding that rare operator race would require
    # interrupting the UI for every update or coordinating locks with old CGIs.
    # Restore exactly the services that were active if anything fails before
    # the first successful release-tree rename makes rollback available.
    _pre_swap_active_units=""
    for _u in watchcat scheduled_restart lighttpd atcmd-daemon connection-logger; do
        systemctl is-active "$_u" >/dev/null 2>&1 && _pre_swap_active_units="$_pre_swap_active_units $_u"
    done
    if ! stop_monitoring_for_swap; then
        _restore_pre_swap_services
        return 1
    fi
    [ "$_need_lighttpd_restart" = "1" ] && systemctl stop lighttpd 2>/dev/null
    systemctl stop atcmd-daemon 2>/dev/null
    systemctl stop connection-logger 2>/dev/null

    if ! rm -rf "$OLD_DIR"; then
        echo -e "\e[1;31mFailed to clear the previous rollback directory. Aborting swap.\e[0m"
        _restore_pre_swap_services
        return 1
    fi
    if [ "$_had_previous" = "1" ]; then
        if ! mv "$QUECDECK_DIR" "$OLD_DIR"; then
            echo -e "\e[1;31mFailed to move aside the current installation. Aborting swap. The existing files were not changed.\e[0m"
            _restore_pre_swap_services
            return 1
        fi
        _swap_committed=1
    elif [ -e "$QUECDECK_DIR" ]; then
        # Stale/partial directory from a previous failed run (no /www, so
        # nothing worth preserving). Clear it so the rename below replaces
        # rather than nests inside it.
        if ! rm -rf "$QUECDECK_DIR"; then
            echo -e "\e[1;31mFailed to remove the incomplete installation. Aborting swap.\e[0m"
            _restore_pre_swap_services
            return 1
        fi
    fi
    mv "$STAGE_DIR" "$QUECDECK_DIR" || { echo -e "\e[1;31mFailed to move the new release into place.\e[0m"; return 1; }
    _swap_committed=1

    # Delay the destructive one-time migration until the release is fully
    # staged and the rollback snapshot exists. A download/preflight failure
    # must not disturb the current root shell tools. PATH deliberately excludes
    # this directory before and during the migration.
    harden_root_home || { echo -e "\e[1;31mFATAL: could not harden /usrdata/root.\e[0m"; return 1; }

    # Diff the new release's unit filenames against the old snapshot. Anything
    # present now but absent before is new to this release and won't exist in
    # $OLD_DIR/systemd/ for _revert_swap to restore, so it'd be left orphaned
    # in /lib/systemd/system/ on a rollback unless we explicitly clean it up.
    _newly_introduced_units=""
    for _u in $(ls "$QUECDECK_DIR/systemd/" 2>/dev/null); do
        printf '%s\n' "$_old_systemd_units" | grep -qxF "$_u" || _newly_introduced_units="$_newly_introduced_units $_u"
    done

    # Remove retired menu entry points. Management stays in the fetched
    # installer and the standalone password helpers.
    [ "$(readlink /bin/menu 2>/dev/null)" != /usrdata/root/bin/menu ] || rm -f /bin/menu
    rm -f /usrdata/root/bin/menu
    if ! rm -f /usrdata/root/bin/atcli ||
       ! ln -sf "$QUECDECK_DIR/atcli" /usrdata/root/bin/atcli ||
       ! cp -f "$QUECDECK_DIR/console/.profile" /usrdata/root/.profile ||
       ! chmod 644 /usrdata/root/.profile; then
        echo -e "\e[1;31mFATAL: Could not install root shell entry points.\e[0m"
        return 1
    fi
    # QuecDeck password tools are copies, not symlinks, so a rollback cannot
    # leave dangling links. Their permission model matches this release's CGIs.
    if ! cp -f "$QUECDECK_DIR/quecdeckpasswd" /usrdata/root/bin/quecdeckpasswd ||
       ! cp -f "$QUECDECK_DIR/quecdeckdevpasswd" /usrdata/root/bin/quecdeckdevpasswd ||
       ! chmod 755 /usrdata/root/bin/quecdeckpasswd /usrdata/root/bin/quecdeckdevpasswd; then
        echo -e "\e[1;31mFATAL: Could not install QuecDeck password helpers.\e[0m"
        return 1
    fi

    # Tighten existing htpasswd files to root:root 600: the web tier verifies
    # passwords via the check_password.sh sudo helper and must not be able to
    # read stored hashes. No rollback restore: a rollback target that predates
    # the helper reads these as www-data and would need root:dialout 640 put
    # back (ADB or root SSH recovery: chown root:dialout + chmod 640).
    for _hf in /opt/etc/.htpasswd /opt/etc/.htpasswd_dev; do
        if [ -f "$_hf" ] && { ! chown root:root "$_hf" || ! chmod 600 "$_hf"; }; then
            echo -e "\e[1;31mFATAL: Could not secure $_hf.\e[0m"
            return 1
        fi
    done

    # Snapshot the live sudoers rule before rewriting it. _revert_swap restores
    # it so a rollback cannot pair the failed release's rules with the restored
    # release's CGIs.
    _sudoers_prev=$(cat /opt/etc/sudoers.d/www-data 2>/dev/null)

    # No start/stop watchcat here: modem operations pause it with a marker file
    # instead of stopping the unit, so the web tier never needs that privilege.
    # reset-failed is paired with each restart: five saves inside systemd's start
    # limit window park the unit in failed, where plain restart keeps refusing
    # until the failed state is cleared. It only clears that state, so it cannot
    # start, stop or reconfigure anything the rule does not already permit.
    _sudoers_rule="www-data ALL = (root) NOPASSWD: /bin/systemctl restart watchcat, /bin/systemctl reset-failed watchcat, /bin/systemctl restart scheduled_restart, /bin/systemctl reset-failed scheduled_restart, /usrdata/quecdeck/script/write_htpasswd.sh, /usrdata/quecdeck/script/change_password.sh, /usrdata/quecdeck/script/ssh_keys.sh, /usrdata/quecdeck/script/check_password.sh, /usrdata/quecdeck/script/run_update.sh"
    _sudoers_mode=$(stat -c '%a' /opt/etc/sudoers.d/www-data 2>/dev/null)
    if [ "$(cat /opt/etc/sudoers.d/www-data 2>/dev/null)" != "$_sudoers_rule" ] || [ "$_sudoers_mode" != "440" ]; then
        # On a from-scratch install, the sudo package (which would normally
        # create this directory) isn't installed until later in this
        # function, so it may not exist yet here.
        mkdir -p /opt/etc/sudoers.d || { echo -e "\e[1;31mFATAL: Could not create sudoers.d.\e[0m"; return 1; }
        _sudoers_tmp=$(mktemp /opt/etc/sudoers.d/.www-data.XXXXXX) || { echo -e "\e[1;31mFATAL: Could not create temp sudoers file.\e[0m"; return 1; }
        if ! printf '%s\n' "$_sudoers_rule" > "$_sudoers_tmp" ||
           ! chmod 440 "$_sudoers_tmp" ||
           ! mv "$_sudoers_tmp" /opt/etc/sudoers.d/www-data; then
            rm -f "$_sudoers_tmp"
            echo -e "\e[1;31mFATAL: Could not install the www-data sudoers rule.\e[0m"
            return 1
        fi
    fi

    rm -f /lib/systemd/system/lighttpd.service /lib/systemd/system/multi-user.target.wants/lighttpd.service
    rm -f /lib/systemd/system/atcmd-daemon.service /lib/systemd/system/multi-user.target.wants/atcmd-daemon.service
    rm -f /lib/systemd/system/connection-logger.service /lib/systemd/system/multi-user.target.wants/connection-logger.service
    # Remove the retired web console on devices that still carry its unit and
    # command link. The clean-install gate normally makes this a no-op, but the
    # cleanup keeps a partial or manually recovered installation coherent.
    systemctl stop ttyd >/dev/null 2>&1
    rm -f /lib/systemd/system/ttyd.service /lib/systemd/system/multi-user.target.wants/ttyd.service
    [ "$(readlink /bin/ttyd 2>/dev/null)" != /opt/bin/ttyd ] || rm -f /bin/ttyd
    rm -f /lib/systemd/system/multi-user.target.wants/watchcat.service
    rm -f /lib/systemd/system/multi-user.target.wants/scheduled_restart.service
    if ! cp -rf "$QUECDECK_DIR/systemd/"* /lib/systemd/system/; then
        echo -e "\e[1;31mFATAL: Could not install systemd units.\e[0m"
        return 1
    fi

    if ! ln -sf /lib/systemd/system/lighttpd.service /lib/systemd/system/multi-user.target.wants/lighttpd.service ||
       ! ln -sf /lib/systemd/system/firewall.service /lib/systemd/system/multi-user.target.wants/firewall.service ||
       ! ln -sf /lib/systemd/system/atcmd-daemon.service /lib/systemd/system/multi-user.target.wants/atcmd-daemon.service ||
       ! ln -sf /lib/systemd/system/connection-logger.service /lib/systemd/system/multi-user.target.wants/connection-logger.service; then
        echo -e "\e[1;31mFATAL: Could not enable systemd units.\e[0m"
        return 1
    fi
    for _m in watchcat scheduled_restart; do
        if ! ln -sf "/lib/systemd/system/${_m}.service" "/lib/systemd/system/multi-user.target.wants/${_m}.service"; then
            echo -e "\e[1;31mFATAL: Could not enable ${_m} at boot.\e[0m"
            return 1
        fi
    done

    # Whether lighttpd packages need installing was already determined (and
    # the opkg index already refreshed if so) back in stage_release, while
    # the old site was still serving. So this is just the actual install,
    # which only needs to happen here because opkg's postinst scripts may
    # restart the service (a restart is happening in this window anyway).
    if [ "$_lighttpd_needs_install" = "1" ]; then
        echo "Installing lighttpd packages..."
        timeout 300 /opt/bin/opkg install $_lighttpd_pkgs || { echo -e "\e[1;31mFailed to install lighttpd packages (or it timed out).\e[0m"; result_lighttpd="FAILED"; return 1; }
        result_lighttpd="UPDATED"
    fi

    # MUST run AFTER the opkg install: the lighttpd package's postinst
    # (re)creates /opt/etc/init.d/S80lighttpd, which rc.unslung would start at
    # boot as a second lighttpd on 0.0.0.0:80, stealing the port from our
    # systemd unit (which binds the LAN IP). Remove it so only our unit runs.
    for script in /opt/etc/init.d/*lighttpd*; do
        if [ -f "$script" ]; then
            echo "Removing opkg lighttpd init script: $script"
            rm "$script"
        fi
    done

    systemctl daemon-reload || { echo -e "\e[1;31mFATAL: systemd daemon-reload failed.\e[0m"; return 1; }
    # lighttpd and the firewall are managed independently here: lighttpd.service
    # is PartOf=firewall.service, so the firewall restart below cycles lighttpd
    # with it automatically.
    if [ "$_need_lighttpd_restart" = "1" ]; then
        systemctl start lighttpd || { echo -e "\e[1;31mWARNING: lighttpd failed to start. Check 'systemctl status lighttpd' for details.\e[0m"; return 1; }
    fi
    # _need_firewall_restart was computed pre-swap. If this restart fails,
    # lighttpd stays down (Requires=) and the health probe below rolls back.
    [ "$_need_firewall_restart" = "1" ] && { systemctl restart firewall || echo "WARNING: Firewall failed to restart."; }
    systemctl restart atcmd-daemon
    # Verify the AT daemon actually serves with one complete round trip. A
    # fresh install can need longer than two seconds, and a failed first start
    # is retried by systemd after five seconds. Retry briefly so that normal
    # recovery does not produce a false warning. Each attempt uses the new
    # release's at-lib.sh and the same socket path as the CGIs.
    _at_probe_ok=0
    _at_probe_attempt=0
    while [ "$_at_probe_attempt" -lt 10 ]; do
        if systemctl is-active atcmd-daemon >/dev/null 2>&1 &&
           ( . "$QUECDECK_DIR/script/at-lib.sh" && atcmd_run 'AT' 1000 ) >/dev/null 2>&1; then
            _at_probe_ok=1
            break
        fi
        _at_probe_attempt=$((_at_probe_attempt + 1))
        [ "$_at_probe_attempt" -lt 10 ] && sleep 1
    done
    if [ "$_at_probe_ok" = "1" ]; then
        echo "AT daemon serving."
    else
        echo -e "\e[1;33mWARNING: AT daemon not serving. AT data will be unavailable until it recovers.\e[0m"
        echo "Check /run/quecdeck/atcmd.log for the reason."
    fi
    systemctl restart connection-logger

    # Monitoring stays stopped until the complete update transaction, including
    # the health check, has finished. Neither an expected
    # network interruption nor a scheduled minute may reboot the modem here.

    # A modem-local HTTPS request enters INPUT through lo, not bridge0, and is
    # intentionally rejected by the LAN-ingress firewall policy. Check the
    # equivalent local invariants instead: the active lighttpd process owns the
    # configured LAN HTTPS listener, and the side-effect-free auth_login GET
    # branch executes as www-data.
    _probe_site() {
        systemctl is-active lighttpd >/dev/null 2>&1 || return 1
        _lighttpd_pid=$(systemctl show -p MainPID --value lighttpd 2>/dev/null)
        case "$_lighttpd_pid" in ''|0|*[!0-9]*) return 1 ;; esac
        _health_ip=$(grep -o '<APIPAddr>[^<]*</APIPAddr>' /etc/data/mobileap_cfg.xml 2>/dev/null | sed 's/<APIPAddr>//;s/<\/APIPAddr>//')
        printf '%s' "$_health_ip" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || return 1
        _health_hex=$(printf '%s\n' "$_health_ip" | awk -F. '{printf "%02X%02X%02X%02X", $4, $3, $2, $1}')
        _https_inode=$(awk -v endpoint="$_health_hex:01BB" '$2 == endpoint && $4 == "0A" { print $10; exit }' /proc/net/tcp)
        [ -n "$_https_inode" ] || return 1
        _lighttpd_owns_https=0
        for _fd in /proc/"$_lighttpd_pid"/fd/*; do
            [ "$(readlink "$_fd" 2>/dev/null)" = "socket:[$_https_inode]" ] && { _lighttpd_owns_https=1; break; }
        done
        [ "$_lighttpd_owns_https" = "1" ] || return 1
        _probe_out=$(su www-data -s /bin/bash -c \
            'REQUEST_METHOD=GET /usrdata/quecdeck/www/cgi-bin/auth_login' 2>/dev/null) || return 1
        printf '%s\n' "$_probe_out" | grep -q '^Status: 303 See Other' &&
            printf '%s\n' "$_probe_out" | grep -q '^Location: /'
    }
    _health_ok=0
    # The patient branch covers everything that cycled lighttpd, including a
    # firewall-only change (PartOf= propagation), via the pre-swap _ui_restart.
    if [ "$_ui_restart" = "1" ]; then
        echo "Verifying the new web stack..."
        for _i in 1 2 3 4 5 6 7 8 9 10; do
            sleep 2
            if _probe_site; then
                _health_ok=1
                break
            fi
        done
    else
        echo "Verifying the new web stack..."
        for _i in 1 2 3; do
            if _probe_site; then
                _health_ok=1
                break
            fi
            echo "Probe attempt $_i failed. Retrying..."
            sleep 2
        done
        [ "$_health_ok" = "1" ] && echo "lighttpd stayed up through the swap."
    fi
    if [ "$_health_ok" != "1" ]; then
        echo -e "\e[1;31mPost-swap health check failed. The web service or auth CGI is unhealthy.\e[0m"
        return 1
    fi

    rm -rf "$OLD_DIR"

    # Deliberately AFTER the OLD_DIR removal, i.e. past the point of no return:
    # _revert_swap needs $OLD_DIR, so nothing removed here can ever need
    # restoring. Doing it earlier would be unsafe, because a rollback re-copies
    # unit FILES from the restored tree but only relinks the seven names it
    # knows, so a dropped unit would come back disabled.
    #
    # Units a previous release shipped and this one dropped otherwise stay
    # installed and enabled forever: _newly_introduced_units covers the rollback
    # direction only, and nothing tracks the forward one. Ours identify
    # themselves with an Exec* path under /usrdata/quecdeck, which no manifest
    # can go stale against (marker asserted by tests/host/ci-checks.sh).
    # Enable state is a hand-made multi-user.target.wants symlink, so remove both.
    _dropped_units=0
    for _f in /lib/systemd/system/*.service; do
        [ -f "$_f" ] || continue
        grep -qE '^Exec(Start|StartPre|StartPost|Reload|Stop|StopPost)=.*/usrdata/quecdeck(/|[[:space:]]|$)' "$_f" 2>/dev/null || continue
        _u=$(basename "$_f")
        [ -f "$QUECDECK_DIR/systemd/$_u" ] && continue
        echo "Removing unit dropped by this release: $_u"
        systemctl stop "${_u%.service}" >/dev/null 2>&1
        rm -f "$_f" "/lib/systemd/system/multi-user.target.wants/$_u"
        _dropped_units=1
    done
    [ "$_dropped_units" = "1" ] && systemctl daemon-reload

    echo -e "\e[1;32mSwitch complete.\e[0m"
    return 0
}

_revert_swap() {
    echo ""
    echo -e "\e[1;31mRolling back to previous installation...\e[0m"
    if [ ! -d "$OLD_DIR" ]; then
        echo "No previous installation found. Cannot roll back automatically."
        echo "Re-run the installer via ADB or SSH to recover."
        return 1
    fi
    # Stop the monitoring workers before the tree moves back, mirroring the
    # forward swap. Otherwise a new-release worker keeps running against the
    # restored installation.
    systemctl stop watchcat 2>/dev/null
    systemctl stop scheduled_restart 2>/dev/null

    # Failure paths deliberately leave the workers stopped. A failed rollback
    # needs manual ADB/SSH recovery, and a watchdog reboot would fight it. Until
    # the explicit disablement below, existing enablement links are untouched.

    rm -rf "$QUECDECK_DIR" || return 1
    mv "$OLD_DIR" "$QUECDECK_DIR" || {
        echo "Failed to restore the previous installation directory."
        return 1
    }
    cp -f "$QUECDECK_DIR/console/.profile" /usrdata/root/.profile 2>/dev/null || true
    # Absolute mode, matching the forward path: cp inherits the source's bits,
    # and .profile is sourced by root's login shell, never executed.
    chmod 644 /usrdata/root/.profile 2>/dev/null || true
    # These are copies rather than links. Restore the versions paired with the
    # old CGIs, including after the one-time bin quarantine.
    cp -f "$QUECDECK_DIR/quecdeckpasswd" /usrdata/root/bin/quecdeckpasswd 2>/dev/null || true
    cp -f "$QUECDECK_DIR/quecdeckdevpasswd" /usrdata/root/bin/quecdeckdevpasswd 2>/dev/null || true
    chmod 755 /usrdata/root/bin/quecdeckpasswd /usrdata/root/bin/quecdeckdevpasswd 2>/dev/null || true
    cp -rf "$QUECDECK_DIR/systemd/"* /lib/systemd/system/ 2>/dev/null || {
        echo "Failed to restore the previous systemd units."
        return 1
    }
    # Put back the sudoers rule the swap may have rewritten (same temp+rename
    # write as the forward path).
    if [ -n "${_sudoers_prev:-}" ] && [ "$(cat /opt/etc/sudoers.d/www-data 2>/dev/null)" != "$_sudoers_prev" ]; then
        _sudoers_tmp=$(mktemp /opt/etc/sudoers.d/.www-data.XXXXXX) || return 1
        if ! printf '%s\n' "$_sudoers_prev" > "$_sudoers_tmp" ||
           ! chmod 440 "$_sudoers_tmp" ||
           ! mv "$_sudoers_tmp" /opt/etc/sudoers.d/www-data; then
            rm -f "$_sudoers_tmp"
            echo "Failed to restore the previous sudoers rule."
            return 1
        fi
    fi
    # Remove unit files this (failed) release introduced that the restored
    # release knows nothing about, otherwise they'd linger as orphans.
    for _u in $_newly_introduced_units; do
        [ -n "$_u" ] || continue
        echo "Removing orphaned unit from failed release: $_u"
        systemctl stop "$_u" 2>/dev/null
        rm -f "/lib/systemd/system/$_u" "/lib/systemd/system/multi-user.target.wants/$_u"
    done
    # Restore monitoring only when both releases declared the same contract.
    # Legacy releases stay disabled. No old worker or state format is inspected.
    if [ "${_monitoring_rollback_supported:-0}" = "1" ]; then
        for _m in watchcat scheduled_restart; do
            ln -sf "/lib/systemd/system/${_m}.service" "/lib/systemd/system/multi-user.target.wants/${_m}.service" \
                || echo -e "\e[1;33mWARNING: Could not restore ${_m} boot enablement. Re-run the installer from ADB or SSH.\e[0m"
        done
    else
        for _m in watchcat scheduled_restart; do
            rm -f "/lib/systemd/system/multi-user.target.wants/${_m}.service"
        done
        echo -e "\e[1;33mLegacy monitoring was left disabled after rollback.\e[0m"
    fi
    if ! ln -sf /lib/systemd/system/lighttpd.service /lib/systemd/system/multi-user.target.wants/lighttpd.service ||
       ! ln -sf /lib/systemd/system/firewall.service /lib/systemd/system/multi-user.target.wants/firewall.service ||
       ! ln -sf /lib/systemd/system/atcmd-daemon.service /lib/systemd/system/multi-user.target.wants/atcmd-daemon.service ||
       ! ln -sf /lib/systemd/system/connection-logger.service /lib/systemd/system/multi-user.target.wants/connection-logger.service ||
       ! systemctl daemon-reload; then
        echo "Failed to restore the previous mandatory service configuration."
        return 1
    fi
    # lighttpd may be missing if the swap failed mid-reinstall, so the start below may fail
    # Restart the firewall, then lighttpd. The rolled-back lighttpd.service may
    # predate PartOf=firewall.service, so start it explicitly rather than rely on
    # restart propagation. Ordering it after the firewall satisfies Requires=.
    systemctl restart firewall 2>/dev/null || {
        echo "Rollback restored files, but the firewall failed to restart."
        return 1
    }
    systemctl start lighttpd 2>/dev/null || {
        echo "Rollback restored files, but lighttpd failed to start."
        return 1
    }
    systemctl restart atcmd-daemon 2>/dev/null
    systemctl restart connection-logger 2>/dev/null
    # Compatible monitoring is restarted only after the updater has persisted
    # its rollback result, removed the transient unit and remounted / read-only.
    # Until then both workers remain unable to interrupt recovery.
    echo -e "\e[1;32mRollback complete. Previous version restored.\e[0m"
    return 0
}

result_stage="FAILED"
result_swap="FAILED"
result_quecdeck="FAILED"
# N/A means the step was never attempted because the update failed earlier.
# These entries are hidden from the summary.
result_firewall="N/A"
result_rollback="N/A"
result_lighttpd="N/A"
_lighttpd_needs_install=0

preflight_check || exit 1

stage_release && result_stage="OK" || rm -rf "$STAGE_DIR"

if [ "$result_stage" = "OK" ]; then
    swap_in_release && { result_swap="OK"; result_quecdeck="OK"; } || {
        rm -rf "$STAGE_DIR"
        if [ "$_swap_committed" = "1" ]; then
            _revert_swap && result_rollback="OK" || result_rollback="FAILED"
        elif [ "$_had_previous" = "1" ]; then
            echo -e "\e[1;33mThe switch never started. The previous installation is untouched and still serving.\e[0m"
        else
            echo -e "\e[1;33mThe switch never started. Nothing was installed.\e[0m"
        fi
    }
fi

systemctl is-active firewall >/dev/null 2>&1 && result_firewall="OK" || result_firewall="WARNING"

_show_result() {
    local label="$1" val="$2"
    case "$val" in
        OK|UPDATED) echo -e "  $(printf '%-22s' "$label") \e[1;32m$val\e[0m" ;;
        WARNING)    echo -e "  $(printf '%-22s' "$label") \e[1;33m$val\e[0m" ;;
        SKIPPED|PENDING) echo -e "  $(printf '%-22s' "$label") $val" ;;
        *)          echo -e "  $(printf '%-22s' "$label") \e[1;31m$val\e[0m" ;;
    esac
}

echo ""
echo -e "\e[1;32mInstall Summary\e[0m"
echo "============================================"
_show_result "Stage release"      "$result_stage"
_show_result "Switch to release"  "$result_swap"
_show_result "QuecDeck"           "$result_quecdeck"
_show_result "Firewall"           "$result_firewall"
[ "$result_lighttpd" != "N/A" ] && _show_result "Lighttpd"          "$result_lighttpd"
[ "$result_rollback" != "N/A" ] && _show_result "Rollback"          "$result_rollback"
echo "============================================"

_install_rc=1
if [ "$result_quecdeck" = "OK" ]; then
    _update_status="done"
    _install_rc=0
elif [ "$result_rollback" = "OK" ]; then
    _update_status="failed:rollback_ok"
elif [ "$result_rollback" = "FAILED" ]; then
    _update_status="failed:rollback_failed"
fi

# Persist the outcome now, before removing our own unit and daemon-reloading:
# doing that while running AS install_quecdeck can make systemd cut this process
# short, skipping the EXIT-trap write and leaving the UI without a final status.
# The EXIT trap writes it again. The atomic write prevents a corrupt status.
# Persist the log at the same point, for the same reason.
_write_status "$_update_status"
_persist_log

# Remove the transient unit from /run, plus any leftover on /lib (older installs
# wrote the install unit to the read-only rootfs). This runs inside the swap's
# rw window, so the /lib rm succeeds.
rm -f "$SERVICE_FILE" /lib/systemd/system/install_quecdeck.service
systemctl daemon-reload
_root_remounted=1
if ! remount_ro; then
    _root_remounted=0
    echo -e "\e[1;31mFATAL: installation finished, but / could not be remounted read-only.\e[0m" >&2
    _update_status="failed"
    _install_rc=1
    _write_status "$_update_status"
fi
# Warnings do not fail an otherwise good release or rollback: monitoring is
# optional and remains boot-enabled, so a later reboot also retries it. This is
# deliberately after status persistence, transient-unit cleanup and the
# read-only remount. Neither worker can interrupt the update transaction.
if [ "$_root_remounted" = "1" ] && { [ "$result_quecdeck" = "OK" ] \
    || { [ "$result_rollback" = "OK" ] && [ "${_monitoring_rollback_supported:-0}" = "1" ]; }; }; then
    _restart_monitoring_workers
fi
exit "$_install_rc"
fi

# ============================ BOOTSTRAP PHASE ============================
# Runs in the caller's context through run_update.sh or an interactive shell.
# It starts the install service and relays its log. This phase writes only under
# /run and never touches or remounts the read-only root filesystem.
GITTREE="${1:-main}"
GITROOT="https://raw.githubusercontent.com/$GITUSER/$REPONAME/$GITTREE"
# Resolve this file to an absolute path because the install service invokes it
# again with --install.
# It lives under /run (tmpfs, not swapped), so it survives the swap it drives.
SELF=$(readlink -f "$0" 2>/dev/null || echo "$0")

# Mutual exclusion via systemd: don't clobber an install already running (the
# web path also fast-fails earlier in run_update.sh).
_state=$(systemctl is-active "$SERVICE_NAME" 2>/dev/null)
if [ "$_state" = "activating" ] || [ "$_state" = "active" ]; then
    echo "An update is already in progress."
    exit 1
fi
systemctl reset-failed "$SERVICE_NAME" 2>/dev/null

# Transient unit on /run (tmpfs): standard systemd runtime path, no rootfs
# write, self-clears on reboot. The rm command clears any stale one from an interrupted
# prior run (can't fail on the read-only rootfs, unlike a /lib file).
_bootstrap_abort() {
    echo -e "\e[1;31m$1\e[0m" >&2
    echo "failed" > "${STATUS_FILE}.tmp" && chmod 644 "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE" || rm -f "${STATUS_FILE}.tmp"
    exit 1
}

mkdir -p /run/systemd/system || _bootstrap_abort "Cannot create systemd's runtime unit directory."
rm -f "$SERVICE_FILE" || _bootstrap_abort "Cannot replace the previous install unit."

if ! cat <<UNIT > "$SERVICE_FILE"
[Unit]
Description=Update $DIR_NAME temporary service

[Service]
Type=oneshot
# 15 min: above the slowest legitimate install, so a genuine hang gets
# force-failed into a recoverable "failed" state rather than sitting in
# "activating" forever (which would wedge the UI and block retries).
TimeoutStartSec=900
$([ "${QUECDECK_ALLOW_DOWNGRADE:-0}" = "1" ] && echo "Environment=QUECDECK_ALLOW_DOWNGRADE=1")
ExecStart=/bin/bash $SELF --install $GITTREE
StandardOutput=append:$LOG_FILE
StandardError=append:$LOG_FILE
UNIT
then
    _bootstrap_abort "Cannot write the install unit."
fi
chmod 644 "$SERVICE_FILE" || _bootstrap_abort "Cannot secure the install unit."

systemctl daemon-reload || _bootstrap_abort "systemd rejected the install unit."
rm -f "$LOG_FILE" || _bootstrap_abort "Cannot replace the install log."
touch "$LOG_FILE" && chmod 644 "$LOG_FILE" || _bootstrap_abort "Cannot prepare the install log."

# Replace any terminal status from an earlier run before starting systemd. If
# the service cannot exec the installer, the stale outcome can never be read as
# this run's result.
if ! echo "running" > "${STATUS_FILE}.tmp" || ! chmod 644 "${STATUS_FILE}.tmp" || ! mv "${STATUS_FILE}.tmp" "$STATUS_FILE"; then
    rm -f "${STATUS_FILE}.tmp"
    echo -e "\e[1;31mCannot record update status. Refusing to start the install service.\e[0m"
    exit 1
fi

# If stdout is an ADB or SSH terminal, stream the log while waiting.
# The unit's own output goes to $LOG_FILE. The web path redirects stdout to a
# file already, so this stays off there.
_tail_pid=""
if [ -t 1 ]; then
    tail -n +1 -f "$LOG_FILE" 2>/dev/null &
    _tail_pid=$!
fi

systemctl start $SERVICE_NAME
_start_rc=$?
# Let the background tail flush the final summary before we stop it.
[ -n "$_tail_pid" ] && sleep 2
[ -n "$_tail_pid" ] && { kill "$_tail_pid" 2>/dev/null; wait "$_tail_pid" 2>/dev/null; }
# The summary is diagnostic output only. Outcome comes exclusively from the
# root-owned status file below, including when systemctl itself returns an
# unexpected code after the transient unit removes its own file.
if [ -f "$LOG_FILE" ]; then
    # Non-terminal callers did not see the streamed log. Replay any summary
    # that exists on success or failure.
    if [ ! -t 1 ] && grep -q "Install Summary" "$LOG_FILE"; then
        echo ""
        sed -n '/Install Summary/,$p' "$LOG_FILE"
        echo ""
    fi
fi

_final_status=$(cat "$STATUS_FILE" 2>/dev/null)
case "$_final_status" in
    done|failed|failed:rollback_ok|failed:rollback_failed) ;;
    *)
        _invalid_status=$_final_status
        if ! echo "failed" > "${STATUS_FILE}.tmp" || ! chmod 644 "${STATUS_FILE}.tmp" || ! mv "${STATUS_FILE}.tmp" "$STATUS_FILE"; then
            rm -f "${STATUS_FILE}.tmp"
            echo -e "\e[1;31mWARNING: could not replace the invalid update status with 'failed'.\e[0m" >&2
        fi
        report_install_outcome "$_invalid_status" "$_start_rc"
        exit 1
        ;;
esac
report_install_outcome "$_final_status" "$_start_rc"
exit $?
