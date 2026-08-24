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

test_finish() {
    echo ""
    echo "tests: $((pass + fail)), passed: $pass, failed: $fail"
    [ "$fail" = "0" ] || return 1
}
