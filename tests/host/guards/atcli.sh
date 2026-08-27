# Shared definitions for the two atcli guards: .githooks/pre-commit and
# tests/host/ci-checks.sh. Only the pattern and file scope live here. The
# iteration deliberately does not: the hook reads the Git index (what is being
# committed), ci-checks reads the working tree, and collapsing that difference
# would let the hook pass on unstaged content.
#
# Sourced, not executed. Callers use plain word-splitting on the lists, so no
# path here may contain spaces.

# Runtime code must reach the modem through at-lib.sh, never the binary. Catches
# the path (any /atcli), the root helper symlink, and the $_ATCLI variable, but
# not $_ATCLI_SOCK or the atcli.sock path.
ATCLI_INVOKE_RE='(/atcli|\$[{]?_ATCLI[}]?)([^A-Za-z0-9._/-]|$)'

# Scoped to runtime code, so the daemon-launch unit, docs, and dev tools are not
# swept in. The at-lib.sh file is the gateway itself and is exempt.
ATCLI_GUARD_DIRS='quecdeck/www/cgi-bin quecdeck/script quecdeck/console'
ATCLI_GUARD_EXEMPT='quecdeck/script/at-lib.sh'

# The socket path must be identical in every file that names it, or the daemon
# binds one path while clients hit another (total AT outage). The updater's
# health probe sources at-lib.sh rather than naming the path, and stays in this
# list so a reintroduced hardcoded path is still caught. The binary's own
# generic DEFAULT_SOCKET is not part of this set.
ATCLI_SOCK_FILES='quecdeck/script/at-lib.sh quecdeck/systemd/atcmd-daemon.service update_quecdeck.sh'

# These two must each name the path at least once: at-lib.sh holds the client
# default, the unit holds the -s bind. Uniqueness alone cannot catch a path that
# vanishes, since the remaining matches still agree and the count stays 1.
ATCLI_SOCK_REQUIRED='quecdeck/script/at-lib.sh quecdeck/systemd/atcmd-daemon.service'

# The unit needs a second, stricter test. Its ExecStopPost also names the socket
# (to clean it up), so "the file mentions the path" stays true even if -s is
# dropped from ExecStart. Assert the bind flag itself.
ATCLI_SOCK_BIND_FILE='quecdeck/systemd/atcmd-daemon.service'
ATCLI_SOCK_BIND_RE='-s +/[^ "}]*atcli\.sock'

# The unit passes this option explicitly, so an older otherwise valid ARM
# binary would fail at startup. Search the binary's argument table without
# executing a foreign-architecture program on the host.
atcli_supports_log_limit() {
    LC_ALL=C grep -aq -- '--log-bytes'
}

# The modem requires a static 32-bit little-endian ARM EABI5 binary using the
# VFP argument convention. A wrong-toolchain build can still look like a valid
# ARM ELF file while systemd fails it with 203/EXEC. Read only the fixed ELF
# header so this works on hosts without readelf and never executes the binary.
atcli_target_elf() {
    local header
    header=$(od -An -v -tx1 -N40 | tr -d ' \n')
    [ "${#header}" -eq 80 ] || return 1
    [ "${header:0:12}" = '7f454c460101' ] || return 1
    [ "${header:36:4}" = '2800' ] || return 1
    [ "${header:72:8}" = '00040005' ]
}
