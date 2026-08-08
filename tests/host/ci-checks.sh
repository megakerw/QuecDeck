#!/bin/bash
# Repository integrity checks for CI (and manual runs on a clean checkout).
# Operates on the committed tree. The pre-commit hook enforces the same
# invariants against the index at commit time. CI's added value is catching
# commits made where the hook was never configured (core.hooksPath unset).
#
# File lists are extracted from .githooks/pre-commit so there is exactly one
# source of truth for what is checksummed and what is pinned.
#
# NOTE: the checksum and pin checks assume LF content, i.e. a Linux/CI
# checkout. On a Windows working tree with CRLF files they will report
# mismatches. That is expected there, so run tests/host/run-tests.sh locally instead.

set -u
cd "$(dirname "$0")/../.."
errors=0
err() { echo "ERROR: $*"; errors=1; }

hook_list() { # hook_list <ARRAY_NAME>
    sed -n "/^$1=(/,/^)/p" .githooks/pre-commit | grep -E '^\s+\S' | tr -d ' '
}

# ------------------------------------------------------- shell syntax ------
for f in quecdeck.sh update_quecdeck.sh installentware.sh \
         quecdeck/script/*.sh quecdeck/console/ttyd.bash \
         quecdeck/console/menu/*.sh tools/*.sh tests/host/*.sh \
         tests/device/*.sh quecdeck/www/cgi-bin/*; do
    bash -n "$f" 2>/dev/null || err "syntax: $f fails bash -n"
done

# ---------------------------------------------------------- JS syntax ------
# Real parse via node (present on CI runners; the dev machine has no JS
# runtime, there run-tests.sh's structural check instead). Skips .min.js:
# vendored, and any corruption is caught by the checksum manifest.
if command -v node >/dev/null 2>&1; then
    for f in quecdeck/www/js/*.js; do
        case "$f" in *.min.js) continue ;; esac
        node --check "$f" || err "syntax: $f fails node --check"
    done
    # The SMS PDU decoder is the one piece of JS whose behaviour is worth
    # asserting rather than just parsing: bit-level field decoding that fails
    # as quietly wrong text rather than as an error.
    node tests/host/test-sms-pdu.js >/dev/null || err "tests/host/test-sms-pdu.js failed (run it directly for detail)"
else
    echo "SKIP: node unavailable, JS syntax and the SMS PDU test not run"
fi

# --------------------------------------------------------- atcli guard -----
# Pattern and scope come from the shared file. This pass reads the working tree
# (the pre-commit hook runs the same rules against the index).
if [ ! -f tests/host/atcli-guard.sh ]; then
    err "tests/host/atcli-guard.sh missing: the atcli guards cannot run"
else
. tests/host/atcli-guard.sh

while IFS= read -r f; do
    [ "$f" = "$ATCLI_GUARD_EXEMPT" ] && continue
    err "atcli guard: $f invokes atcli directly (use atcmd_run/atcmd_fire from at-lib.sh)"
done < <(grep -rlE "$ATCLI_INVOKE_RE" $ATCLI_GUARD_DIRS 2>/dev/null)

# ------------------------------------------ atcli socket path consistency ---
_socks=$(grep -ohE '/[^ "}]*atcli\.sock' $ATCLI_SOCK_FILES 2>/dev/null | sort -u)
if [ "$(printf '%s\n' "$_socks" | grep -c .)" -ne 1 ]; then
    err "atcli socket path drift ($ATCLI_SOCK_FILES must agree): $(printf '%s ' $_socks)"
fi
for _f in $ATCLI_SOCK_REQUIRED; do
    grep -qE '/[^ "}]*atcli\.sock' "$_f" 2>/dev/null \
        || err "atcli socket path missing from $_f (a dropped -s or default passes the uniqueness check)"
done
grep -qE -- "$ATCLI_SOCK_BIND_RE" "$ATCLI_SOCK_BIND_FILE" 2>/dev/null \
    || err "$ATCLI_SOCK_BIND_FILE has no '-s <path>' bind; the daemon would fall back to the atcli default"
fi

# --------------------------------------------------- runtime-path guard ----
# Root-context code must not name a /tmp path: root's runtime state belongs in
# /run/quecdeck, and /tmp/quecdeck belongs to www-data. See tests/host/tmpwrite-guard.sh
# for the four bugs this class produced.
if [ ! -f tests/host/tmpwrite-guard.sh ]; then
    err "tests/host/tmpwrite-guard.sh missing: the runtime-path guard cannot run"
else
. tests/host/tmpwrite-guard.sh

_tmpguard_scan() { # _tmpguard_scan <file>
    # Process substitution, not a pipe: a pipeline would run err in a subshell
    # and the errors flag would never reach the exit status.
    while IFS= read -r hit; do
        err "runtime-path guard: $1:$hit"
        echo "    root-context code must write /run/quecdeck, not a world-writable dir."
        echo "    If it is genuinely safe, add '# tmpguard-ok: <reason>' (see tests/host/tmpwrite-guard.sh)."
    done < <(awk -v re="$TMPGUARD_RE" "$TMPGUARD_AWK" "$1" 2>/dev/null)
}
_tmpguard_scope=$(tmpguard_root_scripts)
# A collapsed scope would make every check below pass vacuously.
[ "$(printf '%s\n' "$_tmpguard_scope" | grep -c .)" -ge 8 ] || \
    err "runtime-path guard: derived root-context scope collapsed to '$_tmpguard_scope'"
for _f in $_tmpguard_scope; do
    [ -f "$_f" ] && _tmpguard_scan "$_f"
done
# A unit without User=www-data runs as root, so new units are in scope by default.
for _u in "$TMPGUARD_UNIT_DIR"/*.service; do
    [ -f "$_u" ] || continue
    grep -q '^User=www-data' "$_u" && continue
    _tmpguard_scan "$_u"
done
fi

# ------------------------------------------------------- dev-gate guard ----
# Every CGI the developer page calls must be dev-gated in auth.lua, so a new
# dev endpoint can't silently ship admin-gated only. The auth_dev endpoint is the unlock
# endpoint itself and stays admin-level.
gated_eps=$(sed -n '/requires_dev_unlocked = /,/^if /p' quecdeck/auth.lua | grep -oE '/cgi-bin/[a-z_]+')
while IFS= read -r ep; do
    [ "$ep" = "/cgi-bin/auth_dev" ] && continue
    echo "$gated_eps" | grep -qx "$ep" || \
        err "dev-gate: $ep is called by the developer page but not in auth.lua's requires_dev_unlocked"
done < <(grep -hoE '/cgi-bin/[a-z_]+' quecdeck/www/js/developer.js quecdeck/www/developer.html | sort -u)

# --------------------------------------------------- unit self-identity ----
# Both orphan sweeps (uninstall in quecdeck.sh, dropped-unit cleanup in
# update_quecdeck.sh) find our units by an Exec* path under /usrdata/quecdeck,
# because no manifest survives a release that drops a unit AND deletes its
# removal line. Comments do not count as ownership evidence.
for _u in quecdeck/systemd/*.service; do
    [ -f "$_u" ] || continue
    grep -qE '^Exec(Start|StartPre|StartPost|Reload|Stop|StopPost)=.*/usrdata/quecdeck(/|[[:space:]]|$)' "$_u" || \
        err "unit self-identity: $_u has no QuecDeck Exec* path, so the orphan sweeps cannot recognise it as ours"
done

# ------------------------------------------------------- dialect guard -----
for f in quecdeck/script/*.sh quecdeck/www/cgi-bin/* quecdeck/console/*; do
    [ -f "$f" ] || continue
    grep -qE '^[[:space:]]*\.[[:space:]]+/usrdata/quecdeck/script/(cgi-lib|at-lib)\.sh' "$f" || continue
    [ "$(head -1 "$f")" = "#!/bin/bash" ] || err "dialect: $f sources cgi-lib/at-lib but is not #!/bin/bash"
done
for u in quecdeck/systemd/*.service; do
    while IFS= read -r line; do
        interp=$(echo "$line" | sed -nE 's,^Exec[A-Za-z]+=(/bin/(sh|bash)) /usrdata/quecdeck/.*,\1,p')
        script=$(echo "$line" | sed -nE 's,^Exec[A-Za-z]+=/bin/(sh|bash) (/usrdata/quecdeck/[^ ]+).*,\2,p')
        [ -z "$interp" ] || [ -z "$script" ] && continue
        repo_path="quecdeck${script#/usrdata/quecdeck}"
        [ -f "$repo_path" ] || continue
        [ "$(head -1 "$repo_path")" = "#!$interp" ] || \
            err "dialect: $u launches $script with $interp but its shebang is '$(head -1 "$repo_path")'"
    done < <(grep -E '^Exec[A-Za-z]+=' "$u")
done

# --------------------------------------- checksums match the committed tree
# Regenerate checksums.sha256 exactly as the hook does and diff. A mismatch
# means a commit bypassed the hook.
tmp_sums=$(mktemp)
{
    echo "# SHA256 checksums for QuecDeck files"
    echo "# Auto-generated by .githooks/pre-commit; do not edit manually"
    echo "# NOTE: protects against partial repo tampering; a full repo compromise"
    echo "# would require updating this file too."
    echo ""
    while IFS= read -r f; do
        [ -f "$f" ] || continue
        printf '%s *%s\n' "$(sha256sum "$f" | awk '{print $1}')" "$f"
    done < <(hook_list CHECKSUMMED_FILES)
} > "$tmp_sums"
if ! diff -q "$tmp_sums" quecdeck/checksums.sha256 >/dev/null 2>&1; then
    err "checksums.sha256 does not match the tree (commit made without the pre-commit hook?)"
    diff "$tmp_sums" quecdeck/checksums.sha256 | head -10
fi
rm -f "$tmp_sums"

# Every tracked release file must be represented too. The updater downloads the
# complete quecdeck/ subtree, so checking only the hand-maintained list would let
# a newly added CGI, root script, or unit ride in the archive unverified.
_manifest_paths=$(mktemp)
_release_paths=$(mktemp)
awk '/^[a-f0-9]{64} \*/ { sub(/^[^*]*\*/, ""); if ($0 ~ /^quecdeck\//) print }' \
    quecdeck/checksums.sha256 | sort > "$_manifest_paths"
git ls-files quecdeck | grep -v '^quecdeck/checksums\.sha256$' | sort > "$_release_paths"
if ! diff -q "$_manifest_paths" "$_release_paths" >/dev/null 2>&1; then
    err "manifest inventory does not cover exactly the tracked quecdeck release files"
    diff -u "$_manifest_paths" "$_release_paths" | head -20
fi
rm -f "$_manifest_paths" "$_release_paths"

# ------------------------------------------------ pinned bootstrap hashes --
while IFS= read -r f; do
    [ -f "$f" ] || continue
    actual=$(sha256sum "$f" | awk '{print $1}')
    expected=$(grep -o "[a-f0-9]\{64\}.*$(basename "$f")" quecdeck.sh | awk '{print $1}' | head -1)
    [ -z "$expected" ] && continue
    [ "$actual" = "$expected" ] || err "pinned hash stale for $f (update quecdeck.sh)"
done < <(hook_list PINNED_FILES)

# The updater fetches the whole quecdeck/ subtree as one archive rather than
# per-file, so a manifest-vs-per-file-download-URL diff no longer applies:
# every checksummed file is fetched by construction. The old drift hazard
# between stage_release()'s exclusion list and the verify loop's "expected
# missing" whitelist is gone too: both are driven by the single _STAGE_EXEMPT
# list in stage_release().

# --------------------------------------------- asset version consistency ---
# The ?v= token in every HTML must equal the hash the hook derives from the
# checksummed JS+CSS content.
expected_v=$(
    while IFS= read -r f; do
        case "$f" in *.js|*.css) cat "$f" ;; esac
    done < <(hook_list CHECKSUMMED_FILES) | sha256sum | cut -c1-8
)
stray_v=$(grep -rhoE '\?v=[a-f0-9]+' quecdeck/www/*.html | sort -u | grep -v "?v=$expected_v" || true)
[ -n "$stray_v" ] && err "HTML asset version tokens out of date: found $stray_v, expected ?v=$expected_v"

# The updater no longer generates its installer via a heredoc: update_quecdeck.sh
# runs its install phase directly (update_quecdeck.sh --install <tag>), so it is
# ordinary committed code covered by the bash -n loop at the top of this file.
# The old heredoc-escaping validator was removed with that refactor.

# ----------------------------------------------------------------------------
if [ "$errors" = "0" ]; then
    echo "ci-checks: all passed"
    exit 0
fi
exit 1
