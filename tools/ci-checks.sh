#!/bin/bash
# Repository integrity checks for CI (and manual runs on a clean checkout).
# Operates on the committed tree; the pre-commit hook enforces the same
# invariants against the index at commit time. CI's added value is catching
# commits made where the hook was never configured (core.hooksPath unset).
#
# File lists are extracted from .githooks/pre-commit so there is exactly one
# source of truth for what is checksummed and what is pinned.
#
# NOTE: the checksum and pin checks assume LF content, i.e. a Linux/CI
# checkout. On a Windows working tree with CRLF files they will report
# mismatches; that is expected there (run tools/run-tests.sh locally instead).

set -u
cd "$(dirname "$0")/.."
errors=0
err() { echo "ERROR: $*"; errors=1; }

hook_list() { # hook_list <ARRAY_NAME>
    sed -n "/^$1=(/,/^)/p" .githooks/pre-commit | grep -E '^\s+\S' | tr -d ' '
}

# ------------------------------------------------------- shell syntax ------
for f in quecdeck.sh update_quecdeck.sh installentware.sh \
         quecdeck/script/*.sh quecdeck/console/ttyd.bash \
         quecdeck/console/menu/*.sh tools/*.sh quecdeck/www/cgi-bin/*; do
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
else
    echo "SKIP: node unavailable, JS syntax not checked"
fi

# --------------------------------------------------------- atcli guard -----
# Runtime code (CGIs/scripts/console) must send AT commands through at-lib.sh
# (atcmd_run/atcmd_fire), never invoke the atcli binary directly. Same scope +
# pattern as the pre-commit hook's atcli guard; keep them in sync.
ATCLI_INVOKE_RE='(/atcli|\$[{]?_ATCLI[}]?)([^A-Za-z0-9._/-]|$)'
while IFS= read -r f; do
    [ "$f" = "quecdeck/script/at-lib.sh" ] && continue
    err "atcli guard: $f invokes atcli directly (use atcmd_run/atcmd_fire from at-lib.sh)"
done < <(grep -rlE "$ATCLI_INVOKE_RE" quecdeck/www/cgi-bin quecdeck/script quecdeck/console 2>/dev/null)

# ------------------------------------------ atcli socket path consistency ---
# The QuecDeck socket path is hardcoded in at-lib.sh (clients), the daemon unit
# (-s bind + ExecStopPost cleanup), and the updater health probe. They MUST
# agree: if the daemon binds one path while clients pass another, AT goes fully
# dark. The atcli binary's own DEFAULT_SOCKET is intentionally generic and is
# NOT part of this set. Keep in sync with the pre-commit hook.
_socks=$(grep -ohE '/[^ "}]*atcli\.sock' \
    quecdeck/script/at-lib.sh \
    quecdeck/systemd/atcmd-daemon.service \
    update_quecdeck.sh 2>/dev/null | sort -u)
if [ "$(printf '%s\n' "$_socks" | grep -c .)" -ne 1 ]; then
    err "atcli socket path drift (at-lib.sh / atcmd-daemon.service / updater must agree): $(printf '%s ' $_socks)"
fi

# ------------------------------------------------------- dev-gate guard ----
# Every CGI the developer page calls must be dev-gated in auth.lua, so a new
# dev endpoint can't silently ship admin-gated only. auth_dev is the unlock
# endpoint itself and stays admin-level.
gated_eps=$(sed -n '/requires_dev_unlocked = /,/^if /p' quecdeck/auth.lua | grep -oE '/cgi-bin/[a-z_]+')
while IFS= read -r ep; do
    [ "$ep" = "/cgi-bin/auth_dev" ] && continue
    echo "$gated_eps" | grep -qx "$ep" || \
        err "dev-gate: $ep is called by the developer page but not in auth.lua's requires_dev_unlocked"
done < <(grep -hoE '/cgi-bin/[a-z_]+' quecdeck/www/js/developer.js quecdeck/www/developer.html | sort -u)

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
