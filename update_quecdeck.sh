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
LOG_FILE="/tmp/install_quecdeck.log"
QUECDECK_DIR="/usrdata/quecdeck"
export PATH=/bin:/sbin:/usr/bin:/usr/sbin:/opt/bin:/opt/sbin:/usrdata/root/bin

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
RELEASE_TARBALL=/tmp/.quecdeck-release.tar.gz
RELEASE_EXTRACT_DIR=/tmp/.quecdeck-release-extract
OLD_DIR="${QUECDECK_DIR}.old"
STATUS_FILE=/tmp/quecdeck_update.status
export HOME=/usrdata/root

# ttyd does not publish checksums, so pin the hash of the known-good binary.
# To update: download the new release, sha256sum it, and update TTYD_HASH +
# TTYD_VERSION. Used by stage_release (carry-forward) and install_ttyd.
TTYD_VERSION="1.7.7"
TTYD_HASH="8240c8438b68d3b10b0e1a4e7c914d70fca6a7606b516f40bf40adfa1044d801"

remount_rw() {
    mount -o remount,rw /
}

remount_ro() {
    mount -o remount,ro /
}

# Mutual exclusion and liveness are owned by systemd: this runs as the
# install_quecdeck oneshot, so a concurrent start coalesces and get_update_log
# reads state via 'systemctl is-active'. No lock or PID file needed.
echo "running" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE"

remount_rw

_update_status="failed"

# Atomically write the update status (temp file + rename). Called explicitly at
# the end of the main flow -- before the self-unit-removal/daemon-reload, which
# can make systemd cut this process short and skip the EXIT trap -- and again
# from the EXIT trap.
_write_status() {
    echo "$1" > "${STATUS_FILE}.tmp" && mv "${STATUS_FILE}.tmp" "$STATUS_FILE" || rm -f "${STATUS_FILE}.tmp"
}
# Copy the install log off tmpfs so it survives the reboot a user reaches for
# when an update goes wrong. /usrdata is its own writable partition, so this
# needs no rootfs remount and works from the EXIT trap.
# Path is also hardcoded in quecdeck.sh's uninstall cleanup; keep in sync.
PERSIST_LOG=/usrdata/quecdeck_last_update.log
_persist_log() {
    cp -f "$LOG_FILE" "$PERSIST_LOG" 2>/dev/null && chmod 600 "$PERSIST_LOG" 2>/dev/null
}
_update_cleanup() {
    # A SIGTERM mid-swap (TimeoutStartSec expiry, systemctl stop) unwinds the
    # shell past the main flow's failure handling, which would leave the new
    # release half-configured with no rollback. Detect that here: the swap
    # started, but neither success nor a rollback attempt was recorded.
    if [ "${_swap_committed:-0}" = "1" ] && [ "${result_quecdeck:-}" != "OK" ] && [ "${result_rollback:-N/A}" = "N/A" ]; then
        echo "Install interrupted mid-swap; attempting rollback."
        _revert_swap && _update_status="failed:rollback_ok" || _update_status="failed:rollback_failed"
    fi
    _write_status "$_update_status"
    _persist_log
    # Staging is finished by every path that reaches here, so this only ever
    # collects what a kill mid-download/extract left on tmpfs. No-op otherwise.
    rm -rf "$RELEASE_TARBALL" "$RELEASE_EXTRACT_DIR"
    remount_ro
}
trap '_update_cleanup' EXIT
# Convert SIGTERM/SIGINT (systemd stop, TimeoutStartSec expiry) into a normal
# exit so the EXIT trap still runs and restores the read-only rootfs. Without
# this, an uncaught signal would kill bash before cleanup and leave / mounted
# read-write. SIGKILL still can't be trapped, but a reboot remounts / read-only.
trap 'exit 1' INT TERM

# Preserve lean mode, watchcat, and scheduled restart state across updates
lean_mode_was_installed=0
[ -L /lib/systemd/system/multi-user.target.wants/lean-mode.service ] && lean_mode_was_installed=1
watchcat_was_installed=0
[ -L /lib/systemd/system/multi-user.target.wants/watchcat.service ] && watchcat_was_installed=1
scheduled_restart_was_installed=0
[ -L /lib/systemd/system/multi-user.target.wants/scheduled_restart.service ] && scheduled_restart_was_installed=1

# --- Pure helpers, unit-tested in tools/run-tests.sh ---

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
# numeric compare (1.0.9 < 1.0.10); callers validate the format first.
_version_lt() {
    _va=${1%%.*}; _vr=${1#*.}; _vb=${_vr%%.*}; _vc=${_vr#*.}
    _wa=${2%%.*}; _wr=${2#*.}; _wb=${_wr%%.*}; _wc=${_wr#*.}
    [ "$_va" -ne "$_wa" ] && { [ "$_va" -lt "$_wa" ]; return; }
    [ "$_vb" -ne "$_wb" ] && { [ "$_vb" -lt "$_wb" ]; return; }
    [ "$_vc" -lt "$_wc" ]
}

preflight_check() {
    echo "Running pre-flight checks..."

    # Downgrade guard: refuse a target release older than the installed one,
    # so a replayed old release URL can't reintroduce fixed vulnerabilities.
    # Equal versions pass (the UI's force-reinstall re-sends the installed
    # tag). Non-semver refs (branch names) and fresh installs skip the guard;
    # deliberate downgrades run from the console with QUECDECK_ALLOW_DOWNGRADE=1.
    _installed_ver=$(cat "$QUECDECK_DIR/version" 2>/dev/null | tr -d '[:space:]')
    _target_ver=$(_tag_to_version "$GITTREE")
    if printf '%s' "$_target_ver" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' &&        printf '%s' "$_installed_ver" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$' &&        [ "${QUECDECK_ALLOW_DOWNGRADE:-0}" != "1" ] &&        _version_lt "$_target_ver" "$_installed_ver"; then
        echo "FATAL: Target version $_target_ver is older than the installed $_installed_ver."
        echo "To downgrade deliberately, run from the console: QUECDECK_ALLOW_DOWNGRADE=1 update_quecdeck.sh v$_target_ver"
        return 1
    fi

    _pf_checksums=/tmp/quecdeck_preflight.sha256

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
    if [ -n "$_pf_free" ] && [ "$_pf_free" -lt "$_pf_needed" ]; then
        echo "FATAL: Not enough free space on /usrdata (need ~${_pf_needed}KB, have ${_pf_free}KB). Aborting update."
        return 1
    fi

    # The download and extraction live on /tmp (tmpfs), a separate filesystem
    # from /usrdata: the archive and the extracted repo tree coexist briefly,
    # so require ~2x the install size there as well.
    _pf_tmp_needed=$(du -sk "$QUECDECK_DIR" 2>/dev/null | awk '{print int($1*2)}')
    _pf_tmp_needed=${_pf_tmp_needed:-4000}
    _pf_tmp_free=$(df -k /tmp 2>/dev/null | awk 'NR==2 {print $4}')
    if [ -n "$_pf_tmp_free" ] && [ "$_pf_tmp_free" -lt "$_pf_tmp_needed" ]; then
        echo "FATAL: Not enough free space on /tmp (need ~${_pf_tmp_needed}KB, have ${_pf_tmp_free}KB). Aborting update."
        return 1
    fi

    echo "Pre-flight checks passed."
    return 0
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
    # varies by ref type; discover it rather than assume a naming pattern. If
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

    # bin/atcli is staged directly at $STAGE_DIR/atcli (no bin/ subdir) so it is
    # reachable without a PATH entry outside the root console.
    [ -f "$STAGE_DIR/bin/atcli" ] && mv "$STAGE_DIR/bin/atcli" "$STAGE_DIR/atcli"
    # rmdir (not rm -rf): fails loudly in the log if bin/ ever gains a second
    # file, instead of silently discarding whatever wasn't moved out above.
    rmdir "$STAGE_DIR/bin"

    # ttyd files are intentionally not part of the staged release:
    # install_ttyd() fetches ttyd.bash/ttyd.service itself after the swap. One
    # list drives both this removal and the verify loop's "expected missing"
    # exemption. The console password tools are staged and verified like any
    # other file; swap_in_release copies them to /usrdata/root/bin.
    _STAGE_EXEMPT="console/ttyd.bash systemd/ttyd.service"
    for _f in $_STAGE_EXEMPT; do rm -f "$STAGE_DIR/$_f"; done

    printf '%s\n' "$(_tag_to_version "$GITTREE")" > "$STAGE_DIR/version"

    echo "Release staged."

    cd /

    chown root:root "$STAGE_DIR/atcli"
    # Deliberately NOT setuid (zero-setuid design): the daemon, started as
    # root by systemd, is the only thing that opens /dev/smd11 with
    # privilege. Clients reach its socket by uid (www-data owns it; the
    # daemon also verifies peers via SO_PEERCRED), so no caller needs
    # elevation. --direct is root-only and never taken implicitly.
    chmod 0755 "$STAGE_DIR/atcli"

    # cgi.assign executes ANY file under cgi-bin, so keep it root-owned and not
    # www-data-writable (755): a web-tier compromise can't drop/overwrite a CGI.
    chown -R root:www-data $STAGE_DIR/www/cgi-bin
    chmod 755 $STAGE_DIR/www/cgi-bin $STAGE_DIR/www/cgi-bin/*
    chmod +x $STAGE_DIR/script/*
    chmod +x $STAGE_DIR/console/menu/*
    chmod +x $STAGE_DIR/console/.profile
    # Root-only scripts (sudo targets and root-unit payloads): root:root so
    # www-data can never replace a privileged entry point, 700 since nothing
    # unprivileged runs or reads them. The rest of script/ stays 755: www-data
    # sources or executes those.
    for _s in create_watchcat.sh remove_watchcat.sh create_scheduled_restart.sh \
              remove_scheduled_restart.sh lighttpd_prestart.sh write_htpasswd.sh \
              check_password.sh run_update.sh firewall.sh lean_mode.sh; do
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
    while IFS= read -r line; do
        # Skip comments and blank lines
        case "$line" in '#'*|'') continue ;; esac
        expected=$(echo "$line" | awk '{print $1}')
        key=$(echo "$line" | awk '{print $2}')
        # Map repo-relative path to staged path; skip entries not under quecdeck/
        rel=${key#*quecdeck/}
        [ "$rel" = "$key" ] && continue
        # atcli is staged at $STAGE_DIR/atcli, not $STAGE_DIR/bin/atcli (see
        # stage_release); remap so its hash is checked here too.
        case "$rel" in
            bin/atcli) file="$STAGE_DIR/atcli" ;;
            *)         file="$STAGE_DIR/$rel" ;;
        esac
        if [ -f "$file" ]; then
            actual=$(sha256sum "$file" | awk '{print $1}')
            if [ "$actual" != "$expected" ]; then
                echo "ERROR: Checksum mismatch: $file"
                echo "  Expected: $expected"
                echo "  Got:      $actual"
                verify_ok=0
            fi
        else
            case " $_STAGE_EXEMPT " in
                *" $rel "*) ;;
                *)
                    echo "ERROR: File missing from staged release: $file"
                    verify_ok=0
                    ;;
            esac
        fi
    done < "$CHECKSUMS_FILE"
    # The manifest is kept in the staged tree and stays with the install:
    # install_ttyd verifies its post-swap fetches against it (no second
    # network fetch that could skew on a moving ref), and it remains on disk
    # afterward as a record of what this release shipped.
    if [ "$verify_ok" != "1" ]; then
        echo "FATAL: One or more files failed checksum verification. Staged release may be compromised."
        return 1
    fi
    echo "All checksums verified OK."

    # Carry forward state that lives outside the downloaded release: watchcat/
    # scheduled-restart config, lan_ip, and the TLS certificate (so HTTPS clients
    # don't have to re-trust a brand-new cert on every update).
    mkdir -p "$STAGE_DIR/var"
    if [ -d "$QUECDECK_DIR/var" ]; then
        cp -rf "$QUECDECK_DIR/var/." "$STAGE_DIR/var/" 2>/dev/null || true
    fi
    chown -R www-data "$STAGE_DIR/var"
    chmod 700 "$STAGE_DIR/var"
    [ -f "$QUECDECK_DIR/server.crt" ] && cp -f "$QUECDECK_DIR/server.crt" "$STAGE_DIR/server.crt"
    [ -f "$QUECDECK_DIR/server.key" ] && cp -f "$QUECDECK_DIR/server.key" "$STAGE_DIR/server.key"

    # Carry the ttyd binary forward when it matches the pinned hash: it only
    # changes when TTYD_HASH does, so skip the re-download on every update.
    # A stale/corrupt binary simply fails this check and gets re-fetched.
    if [ -f "$QUECDECK_DIR/console/ttyd" ] &&        [ "$(sha256sum "$QUECDECK_DIR/console/ttyd" | awk '{print $1}')" = "$TTYD_HASH" ]; then
        cp -f "$QUECDECK_DIR/console/ttyd" "$STAGE_DIR/console/ttyd"
    fi

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
    [ "$_need_lighttpd_restart" = "1" ] && systemctl stop lighttpd 2>/dev/null
    systemctl stop watchcat 2>/dev/null
    systemctl stop scheduled_restart 2>/dev/null
    systemctl stop atcmd-daemon 2>/dev/null
    systemctl stop connection-logger 2>/dev/null
    systemctl stop ttyd 2>/dev/null
    systemctl stop lean-mode 2>/dev/null

    rm -rf "$OLD_DIR"
    if [ "$_had_previous" = "1" ]; then
        mv "$QUECDECK_DIR" "$OLD_DIR" || { echo -e "\e[1;31mFailed to move aside the current installation. Aborting swap; the existing site was not touched.\e[0m"; return 1; }
        _swap_committed=1
    elif [ -e "$QUECDECK_DIR" ]; then
        # Stale/partial directory from a previous failed run (no /www, so
        # nothing worth preserving). Clear it so the rename below replaces
        # rather than nests inside it.
        rm -rf "$QUECDECK_DIR"
    fi
    mv "$STAGE_DIR" "$QUECDECK_DIR" || { echo -e "\e[1;31mFailed to move the new release into place.\e[0m"; return 1; }
    _swap_committed=1

    # Diff the new release's unit filenames against the old snapshot. Anything
    # present now but absent before is new to this release and won't exist in
    # $OLD_DIR/systemd/ for _revert_swap to restore, so it'd be left orphaned
    # in /lib/systemd/system/ on a rollback unless we explicitly clean it up.
    _newly_introduced_units=""
    for _u in $(ls "$QUECDECK_DIR/systemd/" 2>/dev/null); do
        printf '%s\n' "$_old_systemd_units" | grep -qxF "$_u" || _newly_introduced_units="$_newly_introduced_units $_u"
    done

    rm -f /usrdata/root/bin/atcli
    ln -sf "$QUECDECK_DIR/atcli" /usrdata/root/bin/atcli
    rm -f /usrdata/root/bin/menu
    ln -sf "$QUECDECK_DIR/console/menu/start_menu.sh" /usrdata/root/bin/menu
    cp -f "$QUECDECK_DIR/console/.profile" /usrdata/root/.profile
    chmod +x /usrdata/root/.profile
    # Console password tools: copies, not symlinks (a rollback must not leave
    # dangling links), so the perms scheme they write matches this release's CGIs.
    cp -f "$QUECDECK_DIR/quecdeckpasswd" /usrdata/root/bin/quecdeckpasswd
    cp -f "$QUECDECK_DIR/quecdeckdevpasswd" /usrdata/root/bin/quecdeckdevpasswd
    chmod +x /usrdata/root/bin/quecdeckpasswd /usrdata/root/bin/quecdeckdevpasswd

    # Tighten existing htpasswd files to root:root 600: the web tier verifies
    # passwords via the check_password.sh sudo helper and must not be able to
    # read stored hashes. No rollback restore: a rollback target that predates
    # the helper reads these as www-data and would need root:dialout 640 put
    # back (console fix: chown root:dialout + chmod 640).
    for _hf in /opt/etc/.htpasswd /opt/etc/.htpasswd_dev; do
        [ -f "$_hf" ] && chown root:root "$_hf" && chmod 600 "$_hf"
    done

    # Snapshot the live sudoers rule before rewriting it; _revert_swap restores
    # it so a rollback doesn't leave the failed release's rules paired with the
    # restored release's CGIs.
    _sudoers_prev=$(cat /opt/etc/sudoers.d/www-data 2>/dev/null)

    _sudoers_rule="www-data ALL = (root) NOPASSWD: /usrdata/quecdeck/script/create_watchcat.sh, /usrdata/quecdeck/script/remove_watchcat.sh, /usrdata/quecdeck/script/create_scheduled_restart.sh, /usrdata/quecdeck/script/remove_scheduled_restart.sh, /bin/systemctl start ttyd, /bin/systemctl stop ttyd, /bin/systemctl start watchcat, /bin/systemctl stop watchcat, /usrdata/quecdeck/script/write_htpasswd.sh, /usrdata/quecdeck/script/check_password.sh, /usrdata/quecdeck/script/run_update.sh"
    _sudoers_mode=$(stat -c '%a' /opt/etc/sudoers.d/www-data 2>/dev/null)
    if [ "$(cat /opt/etc/sudoers.d/www-data 2>/dev/null)" != "$_sudoers_rule" ] || [ "$_sudoers_mode" != "440" ]; then
        # On a from-scratch install, the sudo package (which would normally
        # create this directory) isn't installed until later in this
        # function, so it may not exist yet here.
        mkdir -p /opt/etc/sudoers.d
        _sudoers_tmp=$(mktemp /opt/etc/sudoers.d/.www-data.XXXXXX) || { echo -e "\e[1;31mFATAL: Could not create temp sudoers file.\e[0m"; return 1; }
        printf '%s\n' "$_sudoers_rule" > "$_sudoers_tmp"
        chmod 440 "$_sudoers_tmp"
        mv "$_sudoers_tmp" /opt/etc/sudoers.d/www-data
    fi

    rm -f /lib/systemd/system/lighttpd.service /lib/systemd/system/multi-user.target.wants/lighttpd.service
    rm -f /lib/systemd/system/atcmd-daemon.service /lib/systemd/system/multi-user.target.wants/atcmd-daemon.service
    rm -f /lib/systemd/system/connection-logger.service /lib/systemd/system/multi-user.target.wants/connection-logger.service
    rm -f /lib/systemd/system/ttyd.service /lib/systemd/system/multi-user.target.wants/ttyd.service
    rm -f /lib/systemd/system/lean-mode.service /lib/systemd/system/multi-user.target.wants/lean-mode.service
    rm -f /lib/systemd/system/multi-user.target.wants/watchcat.service
    rm -f /lib/systemd/system/multi-user.target.wants/scheduled_restart.service
    cp -rf "$QUECDECK_DIR/systemd/"* /lib/systemd/system/

    ln -sf /lib/systemd/system/lighttpd.service /lib/systemd/system/multi-user.target.wants/lighttpd.service
    ln -sf /lib/systemd/system/firewall.service /lib/systemd/system/multi-user.target.wants/firewall.service
    ln -sf /lib/systemd/system/atcmd-daemon.service /lib/systemd/system/multi-user.target.wants/atcmd-daemon.service
    ln -sf /lib/systemd/system/connection-logger.service /lib/systemd/system/multi-user.target.wants/connection-logger.service
    ln -sf /usrdata/quecdeck/console/ttyd /bin

    if [ "$lean_mode_was_installed" = "1" ]; then
        ln -sf /lib/systemd/system/lean-mode.service /lib/systemd/system/multi-user.target.wants/lean-mode.service
    fi
    if [ "$watchcat_was_installed" = "1" ] && [ -s "$QUECDECK_DIR/var/watchcat.json" ]; then
        ln -sf /lib/systemd/system/watchcat.service /lib/systemd/system/multi-user.target.wants/watchcat.service
    fi
    if [ "$scheduled_restart_was_installed" = "1" ] && [ -s "$QUECDECK_DIR/var/scheduled_restart.json" ]; then
        ln -sf /lib/systemd/system/scheduled_restart.service /lib/systemd/system/multi-user.target.wants/scheduled_restart.service
    fi

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

    systemctl daemon-reload
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
    # Verify the AT daemon actually serves: unit active plus one round trip
    # (binary -> socket -> daemon -> modem). -s must match the unit's bind
    # path; the atcli default is generic, not this socket. Warns, never rolls
    # back: the web UI stays up either way (AT panels go empty until the
    # daemon recovers; systemd restarts it every 5 s).
    sleep 2
    if systemctl is-active atcmd-daemon >/dev/null 2>&1 &&        "$QUECDECK_DIR/atcli" -s /tmp/quecdeck/atcli.sock -t 3000 'AT' >/dev/null 2>&1; then
        echo "AT daemon serving."
    else
        echo -e "\e[1;33mWARNING: AT daemon not serving; AT data will be unavailable until it recovers.\e[0m"
        echo "Check /tmp/quecdeck/logs/atcmd.log for the reason."
    fi
    systemctl restart connection-logger

    if [ "$lean_mode_was_installed" = "1" ]; then
        systemctl start --no-block lean-mode
        echo "Lean Mode preserved."
    fi
    if [ "$watchcat_was_installed" = "1" ] && [ -s "$QUECDECK_DIR/var/watchcat.json" ]; then
        systemctl restart watchcat
        echo "Watchcat preserved and restarted."
    fi
    if [ "$scheduled_restart_was_installed" = "1" ] && [ -s "$QUECDECK_DIR/var/scheduled_restart.json" ]; then
        systemctl restart scheduled_restart
        echo "Scheduled restart preserved and restarted."
    fi

    # Verify the new site is serving with one probe: an unauthenticated GET to
    # /cgi-bin/auth_login. It is allowlisted pre-auth in auth.lua and answers
    # GET with an immediate 303 and no side effects, and wget follows the
    # redirect chain to a 200 on the static login (or pre-setup: setup) page.
    # So a single request exercises TLS, auth.lua, mod_cgi, cgi-lib, and
    # static serving. If lighttpd was restarted, poll for up to ~20s to allow
    # for slow startup. If it stayed up, confirm CGIs still execute (the mv is
    # atomic so content is already live).
    _health_ip=$(grep -o '<APIPAddr>[^<]*</APIPAddr>' /etc/data/mobileap_cfg.xml 2>/dev/null | sed 's/<APIPAddr>//;s/<\/APIPAddr>//')
    printf '%s' "$_health_ip" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || _health_ip="192.168.225.1"
    _probe_site() {
        systemctl is-active lighttpd >/dev/null 2>&1 &&            /opt/bin/wget --timeout=10 --tries=1 -q -O /dev/null --no-check-certificate "https://$_health_ip/cgi-bin/auth_login"
    }
    _health_ok=0
    # The patient branch covers everything that cycled lighttpd, including a
    # firewall-only change (PartOf= propagation), via the pre-swap _ui_restart.
    if [ "$_ui_restart" = "1" ]; then
        echo "Verifying the new site responds on $_health_ip..."
        for _i in 1 2 3 4 5 6 7 8 9 10; do
            sleep 2
            if _probe_site; then
                _health_ok=1
                break
            fi
        done
    else
        echo "Verifying CGIs respond on $_health_ip..."
        for _i in 1 2 3; do
            if _probe_site; then
                _health_ok=1
                break
            fi
            echo "Probe attempt $_i failed; retrying..."
            sleep 2
        done
        [ "$_health_ok" = "1" ] && echo "lighttpd stayed up through the swap."
    fi
    if [ "$_health_ok" != "1" ]; then
        echo -e "\e[1;31mPost-swap health check failed. The new site is not responding on $_health_ip.\e[0m"
        return 1
    fi

    rm -rf "$OLD_DIR"
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
    rm -rf "$QUECDECK_DIR"
    mv "$OLD_DIR" "$QUECDECK_DIR"
    cp -f "$QUECDECK_DIR/console/.profile" /usrdata/root/.profile 2>/dev/null || true
    cp -rf "$QUECDECK_DIR/systemd/"* /lib/systemd/system/ 2>/dev/null || true
    # Put back the sudoers rule the swap may have rewritten (same temp+rename
    # write as the forward path).
    if [ -n "${_sudoers_prev:-}" ] && [ "$(cat /opt/etc/sudoers.d/www-data 2>/dev/null)" != "$_sudoers_prev" ]; then
        _sudoers_tmp=$(mktemp /opt/etc/sudoers.d/.www-data.XXXXXX) && {
            printf '%s\n' "$_sudoers_prev" > "$_sudoers_tmp"
            chmod 440 "$_sudoers_tmp"
            mv "$_sudoers_tmp" /opt/etc/sudoers.d/www-data
        }
    fi
    # Remove unit files this (failed) release introduced that the restored
    # release knows nothing about, otherwise they'd linger as orphans.
    for _u in $_newly_introduced_units; do
        [ -n "$_u" ] || continue
        echo "Removing orphaned unit from failed release: $_u"
        systemctl stop "$_u" 2>/dev/null
        rm -f "/lib/systemd/system/$_u" "/lib/systemd/system/multi-user.target.wants/$_u"
    done
    ln -sf /lib/systemd/system/lighttpd.service /lib/systemd/system/multi-user.target.wants/lighttpd.service
    ln -sf /lib/systemd/system/firewall.service /lib/systemd/system/multi-user.target.wants/firewall.service
    ln -sf /lib/systemd/system/atcmd-daemon.service /lib/systemd/system/multi-user.target.wants/atcmd-daemon.service
    ln -sf /lib/systemd/system/connection-logger.service /lib/systemd/system/multi-user.target.wants/connection-logger.service
    systemctl daemon-reload
    # lighttpd may be missing if the swap failed mid-reinstall, so the start below may fail
    # Restart the firewall, then lighttpd. The rolled-back lighttpd.service may
    # predate PartOf=firewall.service, so start it explicitly rather than rely on
    # restart propagation; ordering it after the firewall satisfies Requires=.
    systemctl restart firewall 2>/dev/null || echo "WARNING: Firewall failed to restart."
    systemctl start lighttpd 2>/dev/null || echo "WARNING: Could not restart lighttpd. Opkg packages may need reinstalling via ADB or SSH."
    systemctl restart atcmd-daemon 2>/dev/null
    systemctl restart connection-logger 2>/dev/null
    if [ "$lean_mode_was_installed" = "1" ]; then
        ln -sf /lib/systemd/system/lean-mode.service /lib/systemd/system/multi-user.target.wants/lean-mode.service
        systemctl start --no-block lean-mode 2>/dev/null
    fi
    if [ "$watchcat_was_installed" = "1" ] && [ -s "$QUECDECK_DIR/var/watchcat.json" ]; then
        ln -sf /lib/systemd/system/watchcat.service /lib/systemd/system/multi-user.target.wants/watchcat.service
        systemctl start watchcat 2>/dev/null || true
    fi
    if [ "$scheduled_restart_was_installed" = "1" ] && [ -s "$QUECDECK_DIR/var/scheduled_restart.json" ]; then
        ln -sf /lib/systemd/system/scheduled_restart.service /lib/systemd/system/multi-user.target.wants/scheduled_restart.service
        systemctl start scheduled_restart 2>/dev/null || true
    fi
    echo -e "\e[1;32mRollback complete. Previous version restored.\e[0m"
    return 0
}

install_ttyd() {
    echo -e "\e[1;32mInstalling ttyd...\e[0m"
    cd $QUECDECK_DIR/console || return 1
    # Binary was carried forward by stage_release when it matched TTYD_HASH;
    # only download when absent or the pin changed.
    if [ "$(sha256sum ttyd 2>/dev/null | awk '{print $1}')" = "$TTYD_HASH" ]; then
        echo "ttyd binary already current (carried forward)."
    else
        /opt/bin/wget --timeout=60 --tries=2 -q -O ttyd https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.armhf || { echo -e "\e[1;31mFailed to download ttyd.\e[0m"; return 1; }
        echo "${TTYD_HASH}  ttyd" | sha256sum -c >/dev/null || { echo -e "\e[1;31mIntegrity check failed for ttyd.\e[0m"; rm -f ttyd; return 1; }
    fi
    chmod +x ttyd
    # ttyd.bash and ttyd.service are fetched from the tag rather than the staged
    # tarball, so they miss stage_release's checksum verification. Verify them
    # against the manifest retained from the staged (already-verified) release,
    # since both run as root.
    _ttyd_sums="$QUECDECK_DIR/checksums.sha256"
    [ -s "$_ttyd_sums" ] || { echo -e "\e[1;31mRelease manifest missing; cannot verify ttyd files.\e[0m"; return 1; }

    /opt/bin/wget --timeout=30 --tries=2 -q "$GITROOT/quecdeck/console/ttyd.bash" || { echo -e "\e[1;31mFailed to download ttyd.bash.\e[0m"; return 1; }
    _exp=$(awk '$2=="*quecdeck/console/ttyd.bash"{print $1}' "$_ttyd_sums")
    [ -n "$_exp" ] && [ "$_exp" = "$(sha256sum ttyd.bash | awk '{print $1}')" ] || { echo -e "\e[1;31mIntegrity check failed for ttyd.bash.\e[0m"; rm -f ttyd.bash; return 1; }
    chmod +x ttyd.bash
    cd $QUECDECK_DIR/systemd/ || return 1
    /opt/bin/wget --timeout=30 --tries=2 -q "$GITROOT/quecdeck/systemd/ttyd.service" || { echo -e "\e[1;31mFailed to download ttyd.service.\e[0m"; return 1; }
    _exp=$(awk '$2=="*quecdeck/systemd/ttyd.service"{print $1}' "$_ttyd_sums")
    [ -n "$_exp" ] && [ "$_exp" = "$(sha256sum ttyd.service | awk '{print $1}')" ] || { echo -e "\e[1;31mIntegrity check failed for ttyd.service.\e[0m"; rm -f ttyd.service; return 1; }
    cp -f $QUECDECK_DIR/systemd/ttyd.service /lib/systemd/system/

    # Install the service but don't enable/start it; ttyd is launched
    # on demand from the Developer page.
    systemctl daemon-reload
    rm -f /lib/systemd/system/multi-user.target.wants/ttyd.service

    echo -e "\e[1;32mttyd installed.\e[0m"
}

result_stage="FAILED"
result_swap="FAILED"
result_quecdeck="FAILED"
# N/A = never attempted (update failed earlier); hidden from the summary.
result_ttyd="N/A"
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

if [ "$result_quecdeck" = "OK" ]; then
    install_ttyd && result_ttyd="OK" || result_ttyd="WARNING"
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
[ "$result_ttyd" != "N/A" ] && _show_result "ttyd"              "$result_ttyd"
[ "$result_lighttpd" != "N/A" ] && _show_result "Lighttpd"          "$result_lighttpd"
[ "$result_rollback" != "N/A" ] && _show_result "Rollback"          "$result_rollback"
echo "============================================"

if [ "$result_quecdeck" = "OK" ]; then
    _update_status="done"
elif [ "$result_rollback" = "OK" ]; then
    _update_status="failed:rollback_ok"
elif [ "$result_rollback" = "FAILED" ]; then
    _update_status="failed:rollback_failed"
fi

# Persist the outcome now, before removing our own unit and daemon-reloading:
# doing that while running AS install_quecdeck can make systemd cut this process
# short, skipping the EXIT-trap write and leaving the UI without a final status.
# The EXIT trap re-affirms it; the atomic write means it's never left corrupt.
# Persist the log at the same point, for the same reason.
_write_status "$_update_status"
_persist_log

# Remove the transient unit from /run, plus any leftover on /lib (older installs
# wrote the install unit to the read-only rootfs). This runs inside the swap's
# rw window, so the /lib rm succeeds.
rm -f "$SERVICE_FILE" /lib/systemd/system/install_quecdeck.service
systemctl daemon-reload
remount_ro
exit 0
fi

# ============================ BOOTSTRAP PHASE ============================
# Runs in the caller's context (run_update.sh via sudo, or the console). Sets up
# and starts the install service, then relays its log. Writes only to /run and
# /tmp; never touches or remounts the read-only rootfs.
GITTREE="${1:-main}"
GITROOT="https://raw.githubusercontent.com/$GITUSER/$REPONAME/$GITTREE"
# Absolute path to this file; the install service re-invokes it with --install.
# It lives in /tmp (tmpfs, not swapped), so it survives the swap it drives.
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
# write, self-clears on reboot. rm -f clears any stale one from an interrupted
# prior run (can't fail on the read-only rootfs, unlike a /lib file).
mkdir -p /run/systemd/system
rm -f "$SERVICE_FILE"

cat <<UNIT > "$SERVICE_FILE"
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

systemctl daemon-reload
rm -f "$LOG_FILE"
touch "$LOG_FILE"

# If stdout is a terminal (ADB/SSH/console), stream the log live while we wait;
# the unit's own output goes to $LOG_FILE. The web path redirects stdout to a
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
[ "$_start_rc" -ne 0 ] && { echo -e "\e[1;31mFailed to start install service. Check 'systemctl status $SERVICE_NAME' for details.\e[0m"; exit 1; }
if [ -f "$LOG_FILE" ]; then
    if grep -q "Install Summary" "$LOG_FILE"; then
        echo -e "\e[1;32mQuecDeck installed.\e[0m"
        # Non-terminal callers didn't see the streamed log; replay the summary.
        if [ ! -t 1 ]; then
            echo ""
            sed -n '/Install Summary/,$p' "$LOG_FILE"
            echo ""
        fi
    else
        echo -e "\e[1;31mInstall did not complete. Check $LOG_FILE for details.\e[0m"
        exit 1
    fi
fi
