# Behavioral regressions for updater input and the privileged SSH dispatcher.
# Sourced by the updater suite. All fixed device paths are rewritten into a
# private fixture. Service starts and password checks only record calls.
_update_auth_fixture=$(mktemp -d)
_operation_id=0123456789abcdef0123456789abcdef
mkdir -p "$_update_auth_fixture/release/script"
sed -e "s|/run/quecdeck|$_update_auth_fixture/run|g" \
    -e "s|/run/systemd/system|$_update_auth_fixture/units|g" \
    -e "s|/usrdata/quecdeck|$_update_auth_fixture/release|g" \
    quecdeck/script/run_update.sh > "$_update_auth_fixture/dispatch.sh"
cp quecdeck/script/lock-lib.sh "$_update_auth_fixture/release/script/lock-lib.sh"
cat > "$_update_auth_fixture/release/script/check_password.sh" <<'EOF'
#!/bin/bash
IFS= read -r password
printf '%s\n' "$1" >> "$REVIEW_CHECKS"
[ "$password" != unavailable ] || exit 75
case "$1:$password" in admin:admin-secret|dev:developer-secret) exit 0 ;; esac
exit 1
EOF
chmod +x "$_update_auth_fixture/release/script/check_password.sh"

_dispatch_case() { # <body> <arguments...> -> rc:checks:dispatched
    local body=$1 result
    shift
    rm -f "$_update_auth_fixture/checks" "$_update_auth_fixture/calls"
    rm -rf "$_update_auth_fixture/units"
    (
        export REVIEW_CHECKS="$_update_auth_fixture/checks"
        systemctl() {
            printf '%s\n' "$*" >> "$_update_auth_fixture/calls"
            if [ "$1" = is-active ]; then echo inactive; return 3; fi
            return 0
        }
        chown() { return 0; }
        flock() { return 0; }
        sleep() { return 0; }
        unset QD_SERVICE_UNIT QD_FETCH_UNIT
        . "$_update_auth_fixture/dispatch.sh" "$@"
    ) <<< "$body" > "$_update_auth_fixture/output" 2>&1
    result=$?
    printf '%s:%s:%s' "$result" \
        "$(tr '\n' ',' 2>/dev/null < "$_update_auth_fixture/checks")" \
        "$([ -d "$_update_auth_fixture/units" ] && echo yes || echo no)"
}

for _action in install update uninstall; do
    _args=(--service "$_action" "$_operation_id")
    [ "$_action" != install ] || _args+=(2222)
    t "direct $_action rejects absent credentials" "3::no" "$(_dispatch_case '' "${_args[@]}")"
    t "direct $_action rejects incorrect developer" "3:dev,:no" \
        "$(_dispatch_case 'wrong' "${_args[@]}")"
    t "direct $_action reports unavailable verifier" "75:dev,:no" \
        "$(_dispatch_case 'unavailable' "${_args[@]}")"
    t "direct $_action never checks the administrator credential" "3:dev,:no" \
        "$(_dispatch_case 'admin-secret' "${_args[@]}")"
    t "direct $_action rejects extra credential lines" "3::no" \
        "$(_dispatch_case $'developer-secret\nextra' "${_args[@]}")"
    t "direct $_action accepts the developer credential" "0:dev,:yes" \
        "$(_dispatch_case 'developer-secret' "${_args[@]}")"
    t "$_action publishes one atomic operation record" \
        "$_operation_id sshd:$_action running 0 none" \
        "$(cat "$_update_auth_fixture/run/update.operation" 2>/dev/null)"
    t "$_action unit and output contain no credentials" "yes" \
        "$([ -f "$_update_auth_fixture/units/install_quecdeck_sshd.service" ] && ! grep -qE 'admin-secret|developer-secret' "$_update_auth_fixture/units/"* "$_update_auth_fixture/output" && echo yes || echo no)"
done
t "root rejects malformed operation IDs" "1::no" \
    "$(_dispatch_case 'developer-secret' --service update bad)"
t "package check does not require passwords" "0::yes" "$(_dispatch_case '' --service check "$_operation_id")"
t "direct worker entry cannot bypass credentials" "1::no" "$(_dispatch_case '' --service-run uninstall "$_operation_id")"
t "direct fetch entry preserves operation state" "yes" "$(
    printf '%s sshd:update done 0 none\n' "$_operation_id" > "$_update_auth_fixture/run/update.operation"
    _dispatch_case '' --fetch v1.2.3 "$_operation_id" >/dev/null
    grep -qx "$_operation_id sshd:update done 0 none" "$_update_auth_fixture/run/update.operation" && echo yes || echo no
)"
t "oversized credential rejected before dispatch" "3::no" \
    "$(_dispatch_case "$(printf '%0257d' 0)" --service uninstall "$_operation_id")"
for _tag in $'v1.2.3\nExecStartPre=/bin/true' $'junk\nv1.2.3' $'v1.2.3\n' $'v1.2.3\r' 'v1.2.3 extra' ''; do
    t "root rejects malformed tag $(printf %q "$_tag")" "1::no" "$(_dispatch_case '' "$_tag" "$_operation_id")"
    t "fetch rejects malformed tag $(printf %q "$_tag")" "1::no" "$(_dispatch_case '' --fetch "$_tag" "$_operation_id")"
done
t "valid release tag dispatches" "0::yes" "$(_dispatch_case '' v1.2.3 "$_operation_id")"
t "release dispatch publishes its operation record" \
    "$_operation_id quecdeck running 0 none" \
    "$(cat "$_update_auth_fixture/run/update.operation" 2>/dev/null)"

# Acknowledgement must match the terminal operation ID.
_other_operation_id=fedcba9876543210fedcba9876543210
mkdir -p "$_update_auth_fixture/run"
printf '%s sshd:update done 0 none\n' "$_operation_id" > "$_update_auth_fixture/run/update.operation"
_dispatch_case '' --clear-status "$_other_operation_id" >/dev/null
t "stale acknowledgement preserves a newer terminal result" yes \
    "$([ -f "$_update_auth_fixture/run/update.operation" ] && echo yes || echo no)"
_dispatch_case '' --clear-status "$_operation_id" >/dev/null
t "matching acknowledgement clears its terminal result" no \
    "$([ -f "$_update_auth_fixture/run/update.operation" ] && echo yes || echo no)"
printf '%s sshd:update running 0 none\n' "$_operation_id" > "$_update_auth_fixture/run/update.operation"
_dispatch_case '' --clear-status "$_operation_id" >/dev/null
t "acknowledgement cannot clear a running operation" yes \
    "$([ -f "$_update_auth_fixture/run/update.operation" ] && echo yes || echo no)"

# Run the complete CGIs with only their external dependencies stubbed. Decode
# form input using the real CGI library, including encoded newline payloads.
_update_cgi_case() { # <CGI> <form body> <sudo status>
    local script=$1 body=$2 sudo_rc=$3
    rm -f "$_update_auth_fixture/sudo-args" "$_update_auth_fixture/sudo-body" "$_update_auth_fixture/bf"
    sed -e '\|^\. /usrdata/quecdeck/script/cgi-lib.sh$|d' \
        -e 's|/opt/bin/sudo|review_sudo|g' "quecdeck/www/cgi-bin/$script" > "$_update_auth_fixture/cgi.sh"
    (
        eval "$(extract_fn quecdeck/script/cgi-lib.sh urldecode)"
        eval "$(extract_fn quecdeck/script/cgi-lib.sh get_post_param)"
        eval "$(extract_fn quecdeck/script/cgi-lib.sh cgi_new_operation_id)"
        cgi_require_post() { return 0; }
        cgi_read_post() { post_data=$body; }
        cgi_output_json() { return 0; }
        od() { printf ' 01 23 45 67 89 ab cd ef 01 23 45 67 89 ab cd ef\n'; }
        cgi_client_ip() { echo 192.0.2.1; }
        cgi_flock_available() { return 0; }
        bf_lock() { return 0; }
        bf_locked() { return 1; }
        bf_unlock() { return 0; }
        bf_fail() { echo fail >> "$_update_auth_fixture/bf"; BF_FAIL_RESULT=invalid; }
        bf_clear() { echo clear >> "$_update_auth_fixture/bf"; }
        review_sudo() {
            printf '%s\n' "$@" > "$_update_auth_fixture/sudo-args"
            cat > "$_update_auth_fixture/sudo-body"
            return "$sudo_rc"
        }
        . "$_update_auth_fixture/cgi.sh"
    ) </dev/null
}
for _tag in 'v1.2.3%0AExecStartPre=/bin/true' 'junk%0Av1.2.3' 'v1.2.3%0D' 'v1.2.3%0Aextra'; do
    t "CGI rejects encoded malformed tag $_tag" '{"ok":false,"error":"Invalid version tag"}' \
        "$(_update_cgi_case trigger_update "tag=$_tag" 0)"
    t "invalid tag never calls sudo" "no" "$([ -f "$_update_auth_fixture/sudo-args" ] && echo yes || echo no)"
done
t "CGI accepts valid version tag" '{"ok":true,"tag":"v1.2.3","operation_id":"0123456789abcdef0123456789abcdef"}' \
    "$(_update_cgi_case trigger_update 'tag=v1.2.3' 0)"
_ssh_form='action=install&port=2222&developer_password=developer-secret'
t "SSH CGI forwards accepted dispatch" '{"ok":true,"operation_id":"0123456789abcdef0123456789abcdef"}' "$(_update_cgi_case trigger_sshd_action "$_ssh_form" 0)"
t "SSH CGI passes the developer password only on stdin" developer-secret "$(cat "$_update_auth_fixture/sudo-body")"
t "SSH CGI argv contains no passwords" "yes" \
    "$(! grep -qE 'admin-secret|developer-secret' "$_update_auth_fixture/sudo-args" && echo yes || echo no)"
t "SSH CGI counts root authentication failures" '{"ok":false,"error":"Developer password is incorrect"}' \
    "$(_update_cgi_case trigger_sshd_action "$_ssh_form" 3)"
t "SSH CGI records failure without clearing it" fail "$(cat "$_update_auth_fixture/bf")"
t "SSH CGI reports unavailable verification" '{"ok":false,"error":"Password verification is temporarily unavailable"}' \
    "$(_update_cgi_case trigger_sshd_action "$_ssh_form" 75)"
t "unavailable verification does not change failure counts" no "$([ -f "$_update_auth_fixture/bf" ] && echo yes || echo no)"
t "SSH CGI preserves busy response" '{"ok":false,"error":"An update is already in progress"}' \
    "$(_update_cgi_case trigger_sshd_action "$_ssh_form" 2)"
t "SSH CGI check dispatch remains available without credentials" '{"ok":true,"operation_id":"0123456789abcdef0123456789abcdef"}' \
    "$(_update_cgi_case trigger_sshd_action 'action=check' 0)"

_update_log_case() { # <method> <query> <body> <record> <log>
    local method=$1 query=$2 body=$3 record=$4 log=$5
    rm -rf "$_update_auth_fixture/run"
    mkdir -p "$_update_auth_fixture/run" "$_update_auth_fixture/release"
    [ "$record" = absent ] || printf '%s\n' "$record" > "$_update_auth_fixture/run/update.operation"
    printf '%s' "$log" > "$_update_auth_fixture/run/install.log"
    printf '%s\n' 1.2.3 > "$_update_auth_fixture/release/version"
    rm -f "$_update_auth_fixture/log-sudo-args"
    sed -e '\|^\. /usrdata/quecdeck/script/cgi-lib.sh$|d' \
        -e "s|/run/quecdeck|$_update_auth_fixture/run|g" \
        -e "s|/usrdata/quecdeck|$_update_auth_fixture/release|g" \
        -e 's|/opt/bin/sudo|review_sudo|g' \
        quecdeck/www/cgi-bin/get_update_log > "$_update_auth_fixture/get-update-log.sh"
    (
        eval "$(extract_fn quecdeck/script/cgi-lib.sh urldecode)"
        eval "$(extract_fn quecdeck/script/cgi-lib.sh get_post_param)"
        cgi_check_cors() { return 0; }
        cgi_output_json() { return 0; }
        cgi_read_post() { post_data=$body; }
        systemctl() { echo inactive; }
        review_sudo() { printf '%s\n' "$@" > "$_update_auth_fixture/log-sudo-args"; }
        REQUEST_METHOD=$method QUERY_STRING=$query . "$_update_auth_fixture/get-update-log.sh"
    )
}

t "update log reports idle without an operation" \
    '{"log":"","offset":0,"status":"idle","kind":"","operation_id":"","code":0,"rollback":"none","version":""}' \
    "$(_update_log_case GET '' '' absent '')"
t "update log returns a complete matching snapshot" \
    '{"log":"YWJj","offset":3,"status":"running","rollback":"none","version":"","kind":"quecdeck","operation_id":"0123456789abcdef0123456789abcdef","code":0}' \
    "$(_update_log_case GET 'offset=0' '' "$_operation_id quecdeck running 0 none" abc)"
t "update log returns an SSH installer exit code" \
    '{"log":"","offset":0,"status":"failed","rollback":"none","version":"","kind":"sshd:update","operation_id":"0123456789abcdef0123456789abcdef","code":17}' \
    "$(_update_log_case GET '' '' "$_operation_id sshd:update failed 17 none" '')"
t "update log rejects a corrupt operation record as a unit" \
    '{"log":"","offset":0,"status":"idle","kind":"","operation_id":"","code":0,"rollback":"none","version":""}' \
    "$(_update_log_case GET '' '' 'bad quecdeck done 0 none' abc)"
t "update log rejects a noncanonical exit code" \
    '{"log":"","offset":0,"status":"idle","kind":"","operation_id":"","code":0,"rollback":"none","version":""}' \
    "$(_update_log_case GET '' '' "$_operation_id sshd:update failed 008 none" abc)"
t "update log bounds an oversized offset" \
    '{"log":"YWJj","offset":3,"status":"running","rollback":"none","version":"","kind":"quecdeck","operation_id":"0123456789abcdef0123456789abcdef","code":0}' \
    "$(_update_log_case GET 'offset=99999999999' '' "$_operation_id quecdeck running 0 none" abc)"
t "update log acknowledgement is a scoped root call" \
    '/usrdata/quecdeck/script/run_update.sh,--clear-status,0123456789abcdef0123456789abcdef,' \
    "$(_update_log_case POST '' "operation_id=$_operation_id" absent '' >/dev/null; tr '\n' ',' < "$_update_auth_fixture/log-sudo-args" | sed "s|$_update_auth_fixture/release|/usrdata/quecdeck|")"
t "update log rejects unsupported methods" 'Status: 405 Method Not Allowed' \
    "$(_update_log_case PUT '' '' absent '' 2>/dev/null | tr -d '\r' | head -1)"
rm -rf "$_update_auth_fixture"
unset -f _dispatch_case _update_cgi_case _update_log_case
unset _update_auth_fixture _operation_id _other_operation_id _action _args _tag _ssh_form
