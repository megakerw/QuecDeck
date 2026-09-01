#!/bin/bash
# Root-only sudo helper for key-only SSH access. Operations and paths are fixed
# so the web tier cannot use this as a general root file writer.

PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin
umask 077
. /usrdata/quecdeck/script/lock-lib.sh || exit 1
. /usrdata/quecdeck/script/sshd-policy-lib.sh || exit 1

ROOT_HOME=/usrdata/root
SSH_DIR=$ROOT_HOME/.ssh
KEYS=$SSH_DIR/authorized_keys
LOCK=$ROOT_HOME/.quecdeck-ssh-keys.lock
SSHD_CONFIG=/opt/etc/ssh/sshd_config
ENABLED_MARKER=/opt/etc/ssh/quecdeck_enabled
MAX_KEYS=5
RUNTIME_DIR=/run/quecdeck

ssh_installed() {
    [ -x /opt/sbin/sshd ] && [ -f /lib/systemd/system/sshd.service ]
}

safe_root_home() {
    [ -d "$ROOT_HOME" ] && [ ! -L "$ROOT_HOME" ] &&
        [ "$(stat -c %u "$ROOT_HOME" 2>/dev/null)" = 0 ] &&
        [ "$(stat -c %a "$ROOT_HOME" 2>/dev/null)" = 700 ]
}

prepare_store() {
    safe_root_home || return 1
    [ ! -L "$SSH_DIR" ] || return 1
    if [ ! -e "$SSH_DIR" ]; then
        mkdir "$SSH_DIR" || return 1
        chown root:root "$SSH_DIR" && chmod 700 "$SSH_DIR" || return 1
    fi
    [ -d "$SSH_DIR" ] && [ ! -L "$SSH_DIR" ] || return 1
    [ "$(stat -c %u "$SSH_DIR" 2>/dev/null)" = 0 ] || return 1
    chmod 700 "$SSH_DIR" || return 1
    [ ! -L "$KEYS" ] || return 1
    if [ -e "$KEYS" ]; then
        [ -f "$KEYS" ] && [ ! -L "$KEYS" ] || return 1
        [ "$(stat -c %u "$KEYS" 2>/dev/null)" = 0 ] || return 1
        chmod 600 "$KEYS" || return 1
    fi
}

prepare_runtime_dir() {
    [ ! -L "$RUNTIME_DIR" ] || return 1
    mkdir -p "$RUNTIME_DIR" || return 1
    [ -d "$RUNTIME_DIR" ] && [ ! -L "$RUNTIME_DIR" ] || return 1
    chown root:root "$RUNTIME_DIR" && chmod 755 "$RUNTIME_DIR"
}

fingerprint_line() { # fingerprint_line <public key line>
    local tmp output bits fp rest
    prepare_runtime_dir || return 1
    tmp=$(mktemp "$RUNTIME_DIR/ssh-key.XXXXXX") || return 1
    printf '%s\n' "$1" > "$tmp"
    output=$(ssh-keygen -lf "$tmp" -E sha256 2>/dev/null)
    rm -f "$tmp"
    IFS=' ' read -r bits fp rest <<< "$output"
    [ -n "$fp" ] || return 1
    printf '%s' "$fp"
}

valid_key_syntax() { # valid_key_syntax <line>
    local type blob comment
    [ -n "$1" ] && [ "${#1}" -le 8192 ] || return 1
    type=${1%% *}
    case "$type" in
        ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521) ;;
        *) return 1 ;;
    esac
    blob=${1#* }
    [ "$blob" != "$1" ] || return 1
    blob=${blob%% *}
    case "$blob" in ''|*[!A-Za-z0-9+/=]*) return 1 ;; esac
    comment=${1#"$type $blob"}
    comment=${comment# }
    [ "${#comment}" -le 80 ] || return 1
    [ -z "$comment" ] || printf '%s' "$comment" | LC_ALL=C grep -qE '^[ -~]{1,80}$'
}

parse_key_line() { # parse_key_line <authorized_keys line>
    local line="$1" index
    local -a fields
    KEY_TYPE=""
    KEY_BLOB=""
    KEY_COMMENT=""
    read -r -a fields <<< "$line"
    for ((index = 0; index + 1 < ${#fields[@]}; index++)); do
        case "${fields[$index]}" in
            ssh-*|ecdsa-sha2-*|sk-ssh-*|sk-ecdsa-*)
                KEY_TYPE=${fields[$index]}
                KEY_BLOB=${fields[$((index + 1))]}
                case "$KEY_BLOB" in ''|*[!A-Za-z0-9+/=]*) continue ;; esac
                KEY_COMMENT=${line#*"$KEY_TYPE $KEY_BLOB"}
                KEY_COMMENT=${KEY_COMMENT# }
                return 0
                ;;
        esac
    done
    return 1
}

load_store() {
    local line fp
    KEY_COUNT=0
    KEY_USABLE_COUNT=0
    KEY_LINES=()
    KEY_FINGERPRINTS=()
    [ -f "$KEYS" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        [ -n "$line" ] || continue
        KEY_LINES+=("$line")
        KEY_COUNT=$((KEY_COUNT + 1))
        fp=$(fingerprint_line "$line") || fp=""
        KEY_FINGERPRINTS+=("$fp")
        [ -z "$fp" ] || KEY_USABLE_COUNT=$((KEY_USABLE_COUNT + 1))
    done < "$KEYS"
}

# Is any key in the store usable? ssh-keygen skips lines it cannot parse and
# still exits 0, so a non-empty listing answers this without collecting every
# fingerprint used by the management page.
has_usable_key() {
    [ -f "$KEYS" ] || return 1
    ssh-keygen -lf "$KEYS" -E sha256 2>/dev/null | grep -q .
}

keys_ready() {
    local effective listen
    safe_root_home || return 1
    [ -d "$SSH_DIR" ] && [ ! -L "$SSH_DIR" ] || return 1
    [ "$(stat -c '%u %a' "$SSH_DIR" 2>/dev/null)" = "0 700" ] || return 1
    [ -f "$KEYS" ] && [ ! -L "$KEYS" ] || return 1
    [ "$(stat -c '%u %a' "$KEYS" 2>/dev/null)" = "0 600" ] || return 1
    has_usable_key || return 1
    effective=$(/opt/sbin/sshd -T 2>/dev/null) || return 1
    # The bind address comes from a tmpfs Include fragment. sshd tolerates a
    # missing Include and then reports NO ListenAddress at all, which binds
    # every interface including WAN, and sshd -t accepts that too. So require a
    # positive result: at least one address, and no wildcard among them. An
    # empty list has to fail as loudly as an explicit 0.0.0.0, or this gate
    # would pass the very state it exists to catch.
    listen=$(printf '%s\n' "$effective" | grep -i '^listenaddress ')
    [ -n "$listen" ] || return 1
    printf '%s\n' "$listen" |
        grep -qiE '^listenaddress (0\.0\.0\.0|\[::\]|\[::0\]|0:0:0:0:0:0:0:0)' && return 1
    sshd_policy_ok "$effective"
}

configured_port() {
    local port count
    count=$(grep -c '^Port [0-9][0-9]*$' "$SSHD_CONFIG" 2>/dev/null) || return 1
    [ "$count" = 1 ] || return 1
    port=$(sed -n 's/^Port \([0-9][0-9]*\)$/\1/p' "$SSHD_CONFIG")
    valid_ssh_port "$port" || return 1
    printf '%s' "$port"
}

enabled_marker_safe() {
    [ -f "$ENABLED_MARKER" ] && [ ! -L "$ENABLED_MARKER" ] &&
        [ "$(stat -c '%u %a' "$ENABLED_MARKER" 2>/dev/null)" = "0 600" ] &&
        grep -qx 'enabled' "$ENABLED_MARKER"
}

validate_sshd_config() { # validate_sshd_config <path> <port>
    local effective
    /opt/sbin/sshd -t -f "$1" || return 1
    effective=$(/opt/sbin/sshd -T -f "$1" 2>/dev/null) || return 1
    sshd_policy_ok "$effective" || return 1
    printf '%s\n' "$effective" | grep -qx "port $2" || return 1
}

# Match sshd to the saved enabled state without changing the firewall.
sync_daemon() { # sync_daemon <0|1>
    if [ "$1" = 0 ]; then
        systemctl stop sshd >/dev/null 2>&1 || true
        return 0
    fi
    if ! keys_ready; then
        systemctl stop sshd >/dev/null 2>&1 || true
        return 0
    fi
    systemctl is-active --quiet sshd 2>/dev/null && return 0
    systemctl reset-failed sshd >/dev/null 2>&1
    systemctl start sshd >/dev/null 2>&1 || return 11
}

# Rebuild the firewall after a settings change, then match sshd to the saved
# state. A firewall failure leaves sshd stopped.
apply_network_policy() { # apply_network_policy <0|1>
    if ! systemctl is-active --quiet firewall 2>/dev/null ||
       ! /bin/bash /usrdata/quecdeck/script/firewall.sh >/dev/null 2>&1; then
        systemctl stop sshd >/dev/null 2>&1 || true
        return 10
    fi
    sync_daemon "$1"
}

apply_settings() { # apply_settings <0|1> <port>
    local enabled=$1 port=$2 current_port current_enabled=0 tmp
    case "$enabled" in 0|1) ;; *) return 1 ;; esac
    valid_ssh_port "$port" || return 1
    current_port=$(configured_port) || return 1
    if [ -e "$ENABLED_MARKER" ]; then
        enabled_marker_safe || return 1
        current_enabled=1
    fi
    # Avoid rewriting persistent state when the values are unchanged, but still
    # reapply the firewall before synchronizing the daemon. Settings saves are
    # rare, and one consistent recovery path is preferable to persisted proof
    # of a previous application.
    if [ "$enabled" = "$current_enabled" ] && [ "$port" = "$current_port" ]; then
        apply_network_policy "$enabled"
        return
    fi

    tmp=$(mktemp "${SSHD_CONFIG}.tmp.XXXXXX") || return 1
    sed "s/^Port [0-9][0-9]*$/Port $port/" "$SSHD_CONFIG" > "$tmp" || {
        rm -f "$tmp"
        return 1
    }
    chown root:root "$tmp" && chmod 600 "$tmp" && validate_sshd_config "$tmp" "$port" || {
        rm -f "$tmp"
        return 1
    }

    systemctl stop sshd >/dev/null 2>&1 || true
    mv -f "$tmp" "$SSHD_CONFIG" || {
        rm -f "$tmp"
        return 1
    }
    # The port is committed from here on. Marker failures return 12, not 1, so
    # the caller never reports an unchanged system after the config changed.
    # The marker was already validated above, under the same lock.
    if [ "$enabled" = 1 ]; then
        printf 'enabled\n' > "$ENABLED_MARKER" &&
            chown root:root "$ENABLED_MARKER" && chmod 600 "$ENABLED_MARKER" || return 12
    else
        rm -f "$ENABLED_MARKER" || return 12
    fi

    apply_network_policy "$enabled"
}

list_keys() {
    local line comment index=0
    load_store || return 1
    [ -f "$KEYS" ] || return 0
    for line in "${KEY_LINES[@]}"; do
        if [ -n "${KEY_FINGERPRINTS[$index]}" ] && parse_key_line "$line"; then
            comment=$(printf '%s' "$KEY_COMMENT" | tr -cd 'A-Za-z0-9@._+ -' | cut -c1-80)
            printf '%s\t%s\t%s\n' "${KEY_FINGERPRINTS[$index]}" "$KEY_TYPE" "$comment"
        fi
        index=$((index + 1))
    done
}

verify_admin_credential() { # verify_admin_credential <admin password>
    local rc
    printf '%s\n' "$1" | /usrdata/quecdeck/script/check_password.sh admin admin
    rc=${PIPESTATUS[1]}
    [ "$rc" != 75 ] || return 75
    [ "$rc" = 0 ]
}

verify_credentials() {
    local admin_rc dev_rc
    # Always check both credentials so timing and the generic error do not
    # reveal which one failed. A successful check has no pacing delay.
    printf '%s\n' "$1" | /usrdata/quecdeck/script/check_password.sh admin admin
    admin_rc=${PIPESTATUS[1]}
    printf '%s\n' "$2" | /usrdata/quecdeck/script/check_password.sh dev devadmin
    dev_rc=${PIPESTATUS[1]}
    [ "$admin_rc" != 75 ] && [ "$dev_rc" != 75 ] || return 75
    [ "$admin_rc" = 0 ] && [ "$dev_rc" = 0 ]
}

print_saved_state() {
    local port enabled=0
    port=$(configured_port) || return 1
    if [ -e "$ENABLED_MARKER" ] || [ -L "$ENABLED_MARKER" ]; then
        enabled_marker_safe || return 1
        enabled=1
    fi
    printf '%s\t%s\n' "$enabled" "$port"
}

managed_state_exists() {
    [ -e "$ENABLED_MARKER" ] || [ -L "$ENABLED_MARKER" ] ||
        [ "$(readlink /lib/systemd/system/sshd.service 2>/dev/null)" = /usrdata/quecdeck/optional/sshd/sshd.service ] ||
        grep -Fqx 'Include /run/quecdeck/sshd-listen.conf' "$SSHD_CONFIG" 2>/dev/null
}

# The installer can need to recover QuecDeck-managed settings after a partial
# installation that wrote the configuration but not the service link.
if [ "${1:-}" = saved-state ]; then
    [ "$#" -eq 1 ] || exit 1
    managed_state_exists || exit 3
    print_saved_state
    exit $?
fi

ssh_installed || exit 3
case "${1:-}" in
    status)
        [ "$#" -eq 1 ] || exit 1
        print_saved_state
        ;;
    # Gated on the ADMINISTRATOR password only, unlike add and remove which
    # need both. Enabling SSH or moving its port grants no access by itself:
    # without an authorized key both keys_ready and the unit's
    # ConditionPathExists refuse the start, and installing a key needs both
    # passwords. Requiring a password here is what stops a forged www-data
    # session from switching an existing key back on, since a forged session
    # carries no credential.
    #
    # The enabled state and port stay in argv because neither is a secret. The
    # password arrives on stdin. Both values are validated before they reach a
    # configuration file.
    settings)
        [ "$#" -eq 3 ] || exit 1
        safe_root_home || exit 9
        SSH_ENABLED=$2
        SSH_PORT=$3
        case "$SSH_ENABLED" in 0|1) ;; *) exit 1 ;; esac
        valid_ssh_port "$SSH_PORT" || exit 1
        PAYLOAD=$(
            head -c 1025
            printf .
        )
        PAYLOAD=${PAYLOAD%.}
        [ "${#PAYLOAD}" -le 1024 ] || exit 1
        PAYLOAD=${PAYLOAD%$'\n'}
        {
            IFS= read -r ADMIN_PASSWORD || exit 1
            IFS= read -r EXTRA && exit 1
        } <<< "$PAYLOAD"
        [ -n "$ADMIN_PASSWORD" ] && [ "${#ADMIN_PASSWORD}" -le 256 ] || exit 2
        exec 9>>"$LOCK" || exit 1
        chown root:root "$LOCK" && chmod 600 "$LOCK" || exit 1
        flock_wait 9 5 || exit 75
        verify_admin_credential "$ADMIN_PASSWORD"
        credential_rc=$?
        [ "$credential_rc" != 75 ] || exit 75
        [ "$credential_rc" = 0 ] || exit 2
        apply_settings "$SSH_ENABLED" "$SSH_PORT"
        ;;
    ready)
        [ "$#" -eq 1 ] || exit 1
        safe_root_home || exit 9
        enabled_marker_safe || exit 1
        keys_ready
        ;;
    list)
        [ "$#" -eq 1 ] || exit 1
        safe_root_home || exit 9
        [ ! -L "$SSH_DIR" ] || exit 1
        if [ -e "$SSH_DIR" ]; then
            [ -d "$SSH_DIR" ] && [ "$(stat -c %u "$SSH_DIR" 2>/dev/null)" = 0 ] || exit 1
        fi
        [ ! -L "$KEYS" ] || exit 1
        [ ! -e "$KEYS" ] || [ -f "$KEYS" ] || exit 1
        list_keys
        ;;
    add)
        [ "$#" -eq 1 ] || exit 1
        safe_root_home || exit 9
        [ -s /opt/etc/.htpasswd_dev ] || exit 8
        PAYLOAD=$(
            head -c 9001
            printf .
        )
        PAYLOAD=${PAYLOAD%.}
        [ "${#PAYLOAD}" -le 9000 ] || exit 1
        PAYLOAD=${PAYLOAD%$'\n'}
        {
            IFS= read -r ADMIN_PASSWORD || exit 1
            IFS= read -r DEV_PASSWORD || exit 1
            IFS= read -r KEY_LINE || exit 1
            IFS= read -r EXTRA && exit 1
        } <<< "$PAYLOAD"
        [ -n "$ADMIN_PASSWORD" ] && [ "${#ADMIN_PASSWORD}" -le 256 ] || exit 2
        [ -n "$DEV_PASSWORD" ] && [ "${#DEV_PASSWORD}" -le 256 ] || exit 2
        valid_key_syntax "$KEY_LINE" || exit 4
        fingerprint_line "$KEY_LINE" >/dev/null || exit 4
        exec 9>>"$LOCK" || exit 1
        chown root:root "$LOCK" && chmod 600 "$LOCK" || exit 1
        flock_wait 9 5 || exit 75
        verify_credentials "$ADMIN_PASSWORD" "$DEV_PASSWORD"
        credential_rc=$?
        [ "$credential_rc" != 75 ] || exit 75
        [ "$credential_rc" = 0 ] || exit 2
        prepare_store || exit 1
        load_store || exit 1
        [ "$KEY_USABLE_COUNT" -lt "$MAX_KEYS" ] || exit 5
        new_type=${KEY_LINE%% *}
        new_blob=${KEY_LINE#* }
        new_blob=${new_blob%% *}
        if [ -f "$KEYS" ]; then
            while IFS= read -r existing || [ -n "$existing" ]; do
                [ -n "$existing" ] || continue
                if parse_key_line "$existing"; then
                    [ "$KEY_TYPE $KEY_BLOB" != "$new_type $new_blob" ] || exit 6
                fi
            done < "$KEYS"
        fi
        TMP=$(mktemp "${KEYS}.tmp.XXXXXX") || exit 1
        if {
           if [ -f "$KEYS" ]; then
               while IFS= read -r existing || [ -n "$existing" ]; do
                   printf '%s\n' "$existing"
               done < "$KEYS"
           fi
           printf '%s\n' "$KEY_LINE"
           } > "$TMP" &&
           chown root:root "$TMP" && chmod 600 "$TMP" && mv -f "$TMP" "$KEYS"; then
            # Reapply the policy before the first usable key can start SSH.
            # Failure leaves the newly added key stored but the daemon stopped.
            if [ -e "$ENABLED_MARKER" ] || [ -L "$ENABLED_MARKER" ]; then
                if ! enabled_marker_safe; then
                    systemctl stop sshd >/dev/null 2>&1 || true
                    exit 14
                fi
                apply_network_policy 1 >/dev/null 2>&1
                policy_rc=$?
                if [ "$policy_rc" != 0 ]; then
                    systemctl stop sshd >/dev/null 2>&1 || true
                    exit 14
                fi
            fi
            exit 0
        fi
        rm -f "$TMP"
        exit 1
        ;;
    remove)
        [ "$#" -eq 2 ] || exit 1
        safe_root_home || exit 9
        [ -s /opt/etc/.htpasswd_dev ] || exit 8
        FINGERPRINT=${2:-}
        case "$FINGERPRINT" in
            SHA256:*) ;;
            *) exit 4 ;;
        esac
        fp_body=${FINGERPRINT#SHA256:}
        [ "${#fp_body}" -ge 20 ] && [ "${#fp_body}" -le 64 ] || exit 4
        case "$fp_body" in *[!A-Za-z0-9+/]*) exit 4 ;; esac
        PAYLOAD=$(
            head -c 1025
            printf .
        )
        PAYLOAD=${PAYLOAD%.}
        [ "${#PAYLOAD}" -le 1024 ] || exit 1
        PAYLOAD=${PAYLOAD%$'\n'}
        {
            IFS= read -r ADMIN_PASSWORD || exit 1
            IFS= read -r DEV_PASSWORD || exit 1
            IFS= read -r EXTRA && exit 1
        } <<< "$PAYLOAD"
        [ -n "$ADMIN_PASSWORD" ] && [ "${#ADMIN_PASSWORD}" -le 256 ] || exit 2
        [ -n "$DEV_PASSWORD" ] && [ "${#DEV_PASSWORD}" -le 256 ] || exit 2
        exec 9>>"$LOCK" || exit 1
        chown root:root "$LOCK" && chmod 600 "$LOCK" || exit 1
        flock_wait 9 5 || exit 75
        verify_credentials "$ADMIN_PASSWORD" "$DEV_PASSWORD"
        credential_rc=$?
        [ "$credential_rc" != 75 ] || exit 75
        [ "$credential_rc" = 0 ] || exit 2
        prepare_store || exit 1
        load_store || exit 1
        [ -f "$KEYS" ] || exit 7
        TMP=$(mktemp "${KEYS}.tmp.XXXXXX") || exit 1
        found=0
        index=0
        while IFS= read -r existing || [ -n "$existing" ]; do
            if [ -n "$existing" ] && [ "${KEY_FINGERPRINTS[$index]}" = "$FINGERPRINT" ]; then
                found=1
                index=$((index + 1))
                continue
            fi
            printf '%s\n' "$existing" >> "$TMP" || { rm -f "$TMP"; exit 1; }
            [ -z "$existing" ] || index=$((index + 1))
        done < "$KEYS"
        [ "$found" = 1 ] || { rm -f "$TMP"; exit 7; }
        chown root:root "$TMP" && chmod 600 "$TMP" && mv -f "$TMP" "$KEYS" || {
            rm -f "$TMP"
            exit 1
        }
        load_store || exit 1
        if [ "$KEY_COUNT" = 0 ]; then
            rm -f "$KEYS"
            systemctl stop sshd >/dev/null 2>&1 || true
        elif systemctl is-active --quiet sshd 2>/dev/null; then
            systemctl restart sshd >/dev/null 2>&1 || systemctl stop sshd >/dev/null 2>&1
        fi
        ;;
    *) exit 1 ;;
esac
