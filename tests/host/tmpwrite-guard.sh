# Shared definitions for the two runtime-path guards: .githooks/pre-commit and
# tests/host/ci-checks.sh. Sourced, not executed.
#
# THE RULE: a directory's owner is the only uid that writes inside it.
#
#   /run/quecdeck   root:root 0755   everything ROOT writes; www-data reads
#   /tmp/quecdeck   www-data 0700    everything WWW-DATA writes; root stays out
#
# Enforced as ONE check: root-context code may not name a path in a
# world-writable directory unless the line carries a written justification.
# No exceptions are inferred from what the line appears to do. Earlier versions
# allowed lines that merely CONTAINED "rm -f", which let a compound line such as
#   rm -f /tmp/a; chown www-data /tmp/quecdeck/sessions
# through untouched. Intent is declared, never guessed.
#
# Mechanical rather than a review item because this class produced four bugs
# here, all device-verified 2026-08-07:
#
#   1. In run_update.sh, www-data squats the log path. The fs.protected_regular setting then
#      denies root's OWN write, and the update wedges on "running" forever.
#   2. The atcmd-daemon log trim inside www-data's tree follows a planted symlink,
#      overwriting an arbitrary root file with attacker-chosen content.
#   3. In lighttpd.service, chown and chmod on /tmp/quecdeck/sessions follow symlinks,
#      handing www-data ownership of any root directory.
#   4. In quecdeck.sh, sshd.service staged in www-data's tree could be swapped
#      between sha256sum and cp, installing an unverified unit as root.
#
# Sticky /tmp does NOT save you: it stops deletion, not creation, and the
# fs.protected_* sysctls cover only sticky world-writable dirs, so they do
# nothing inside 0700 /tmp/quecdeck. This device has no SELinux, so uid is the
# entire boundary.

# Files that execute as root. Units are classified by the ABSENCE of
# User=www-data, so a new unit is root-context by default (fails safe).
TMPGUARD_UNIT_DIR='quecdeck/systemd'

# The three bootstrap/installer scripts, which nothing else declares: they are
# run directly by an operator as root, so they cannot be derived.
TMPGUARD_SEED='quecdeck.sh update_quecdeck.sh installentware.sh'

# Everything else is DERIVED rather than listed. A hand-maintained list is the
# part that rots: the first version of this guard silently omitted all six
# scripts in the sudoers rule, which are the highest-risk files in the tree
# (reachable from the web tier AND running as root). Both sources below already
# declare "this runs as root", so read them instead of restating them:
#
#   1. The NOPASSWD sudoers rule in update_quecdeck.sh (what www-data may run)
#   2. ExecStart/ExecStartPre of any unit WITHOUT User=www-data
#
# A new sudoers entry or a new root unit therefore comes into scope by itself.
# Reads the working tree in both callers. The run-tests.sh suite asserts that the result stays
# populated, so a broken pattern here fails loudly instead of silently
# shrinking the scope to nothing.
tmpguard_root_scripts() {
    {
        printf '%s\n' $TMPGUARD_SEED
        grep -hoE '/usrdata/quecdeck/[A-Za-z0-9_/.-]+\.(sh|bash)' update_quecdeck.sh 2>/dev/null
        for _u in "$TMPGUARD_UNIT_DIR"/*.service; do
            [ -f "$_u" ] || continue
            grep -q '^User=www-data' "$_u" && continue
            grep -hoE '/usrdata/quecdeck/[A-Za-z0-9_/.-]+\.(sh|bash)' "$_u" 2>/dev/null
        done
    } | sed 's|^/usrdata/quecdeck/|quecdeck/|' | sort -u
}

# Every world-writable directory on the device (all 1777, verified), not just
# /tmp: any of them has the same squat-and-plant exposure. Root's runtime state
# belongs in /run/quecdeck. /tmp/quecdeck belongs to www-data.
# The trailing separator is optional so bare uses (cd /tmp, TMPDIR=/tmp,
# mktemp -p /tmp, tar -C /tmp) are caught too, not just full paths. The leading
# guard keeps the path component anchored, so /opt/tmp (Entware's own dir,
# under root-owned /opt) does not match on the "/tmp" inside it.
TMPGUARD_RE='(^|[^[:alnum:]_.-])/(tmp|var/tmp|var/volatile|dev/shm)([/"'"'"' ]|$)'

# The single scanner both callers use, so the rule cannot drift between them.
# Reads a file on stdin, prints "<lineno>:<line>" for each violation.
#
# A line is exempt only if it carries "# tmpguard-ok: <reason>" itself, or the
# marker appears in the contiguous comment block immediately above it. The
# block form exists for systemd units, where a trailing comment on a directive
# would be parsed as part of the command and must never be used.
TMPGUARD_AWK='
{
    if ($0 ~ /^[[:space:]]*#/) {
        if ($0 ~ /# tmpguard-ok:/) blockmark = 1
        next
    }
    if ($0 ~ re && $0 !~ /# tmpguard-ok:/ && !blockmark)
        printf "%d:%s\n", NR, $0
    blockmark = 0
}
'
