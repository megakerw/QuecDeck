# Behavioral regressions for updater input and the privileged SSH dispatcher.
# Sourced by the updater suite. All fixed device paths are rewritten into a
# private fixture; service starts and password checks only record calls.
_update_auth_fixture=$(mktemp -d)
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
    _args=(--service "$_action")
    [ "$_action" != install ] || _args+=(2222)
    t "direct $_action rejects absent credentials" "3::no" "$(_dispatch_case '' "${_args[@]}")"
    t "direct $_action checks developer even when admin fails" "3:admin,dev,:no" \
        "$(_dispatch_case $'wrong\ndeveloper-secret' "${_args[@]}")"
    t "direct $_action rejects incorrect developer" "3:admin,dev,:no" \
        "$(_dispatch_case $'admin-secret\nwrong' "${_args[@]}")"
    t "direct $_action reports unavailable verifier" "75:admin,dev,:no" \
        "$(_dispatch_case $'unavailable\ndeveloper-secret' "${_args[@]}")"
    t "direct $_action rejects extra credential lines" "3::no" \
        "$(_dispatch_case $'admin-secret\ndeveloper-secret\nextra' "${_args[@]}")"
    t "direct $_action accepts both credentials" "0:admin,dev,:yes" \
        "$(_dispatch_case $'admin-secret\ndeveloper-secret' "${_args[@]}")"
    t "$_action unit and output contain no credentials" "yes" \
        "$([ -f "$_update_auth_fixture/units/install_quecdeck_sshd.service" ] && ! grep -qE 'admin-secret|developer-secret' "$_update_auth_fixture/units/"* "$_update_auth_fixture/output" && echo yes || echo no)"
done
t "package check does not require passwords" "0::yes" "$(_dispatch_case '' --service check)"
t "direct worker entry cannot bypass credentials" "1::no" "$(_dispatch_case '' --service-run uninstall)"
t "oversized credential rejected before dispatch" "3::no" \
    "$(_dispatch_case "$(printf '%0257d' 0)"$'\ndeveloper-secret' --service uninstall)"
for _tag in $'v1.2.3\nExecStartPre=/bin/true' $'junk\nv1.2.3' $'v1.2.3\n' $'v1.2.3\r' 'v1.2.3 extra' ''; do
    t "root rejects malformed tag $(printf %q "$_tag")" "1::no" "$(_dispatch_case '' "$_tag")"
    t "fetch rejects malformed tag $(printf %q "$_tag")" "1::no" "$(_dispatch_case '' --fetch "$_tag")"
done
t "valid release tag dispatches" "0::yes" "$(_dispatch_case '' v1.2.3)"

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
        cgi_require_post() { return 0; }
        cgi_read_post() { post_data=$body; }
        cgi_output_json() { return 0; }
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
t "CGI accepts valid version tag" '{"ok":true,"tag":"v1.2.3"}' \
    "$(_update_cgi_case trigger_update 'tag=v1.2.3' 0)"
_ssh_form='action=install&port=2222&admin_password=admin-secret&developer_password=developer-secret'
t "SSH CGI forwards accepted dispatch" '{"ok":true}' "$(_update_cgi_case trigger_sshd_action "$_ssh_form" 0)"
t "SSH CGI passes both passwords only on stdin" $'admin-secret\ndeveloper-secret' "$(cat "$_update_auth_fixture/sudo-body")"
t "SSH CGI argv contains no passwords" "yes" \
    "$(! grep -qE 'admin-secret|developer-secret' "$_update_auth_fixture/sudo-args" && echo yes || echo no)"
t "SSH CGI counts root authentication failures" '{"ok":false,"error":"Administrator or developer password is incorrect"}' \
    "$(_update_cgi_case trigger_sshd_action "$_ssh_form" 3)"
t "SSH CGI records failure without clearing it" fail "$(cat "$_update_auth_fixture/bf")"
t "SSH CGI reports unavailable verification" '{"ok":false,"error":"Password verification is temporarily unavailable"}' \
    "$(_update_cgi_case trigger_sshd_action "$_ssh_form" 75)"
t "unavailable verification does not change failure counts" no "$([ -f "$_update_auth_fixture/bf" ] && echo yes || echo no)"
t "SSH CGI preserves busy response" '{"ok":false,"error":"An update is already in progress"}' \
    "$(_update_cgi_case trigger_sshd_action "$_ssh_form" 2)"
t "SSH CGI check dispatch remains available without credentials" '{"ok":true}' \
    "$(_update_cgi_case trigger_sshd_action 'action=check' 0)"
rm -rf "$_update_auth_fixture"
unset -f _dispatch_case _update_cgi_case
unset _update_auth_fixture _action _args _tag _ssh_form
