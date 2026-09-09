# Shared assertions and source helpers for host suites.
# Sourced by tests/host/run-tests.sh.

pass=0
fail=0

t() { # t <name> <expected> <actual>
    if [ "$2" = "$3" ]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1))
        printf 'FAIL: %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"
    fi
}

t_rc() { # t_rc <name> <expected_rc> <actual_rc>
    t "$1 (rc)" "$2" "$3"
}

# Pull a top-level function out of a script that cannot be sourced on the host.
extract_fn() {
    sed -n "/^$2() {/,/^}/p" "$1"
}

# `grep -q PATTERN f1 f2` stops at the FIRST match and returns 0 for the whole
# list, so a "both sides of this contract name the field" check passes when only
# one side does. This requires EVERY file to match, and fails on a missing file
# rather than treating it as a pass.
#
# The negative form needs no helper: ! grep -q PAT f1 f2 already means "none of
# them", which is the intended reading.
grep_all() { # grep_all <pattern> <file>...
    local pattern=$1 f
    shift
    for f in "$@"; do
        [ -f "$f" ] || return 1
        grep -q -- "$pattern" "$f" || return 1
    done
}

test_finish() {
    echo ""
    echo "tests: $((pass + fail)), passed: $pass, failed: $fail"
    [ "$fail" = "0" ] || return 1
}
