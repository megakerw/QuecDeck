#!/bin/bash
# Host-side test runner. Runs on the development machine without a device.
#
# Usage:
#   tests/host/run-tests.sh
#   tests/host/run-tests.sh --slow
#   tests/host/run-tests.sh monitoring
#   tests/host/run-tests.sh --slow libraries security
#
# Suites are sourced in one shell to preserve the existing fixture lifecycle.
# Keep each suite responsible for cleaning up the state it creates.

set -u
cd "$(dirname "$0")/../.."

SLOW=0
selected_suites=()
for arg in "$@"; do
    case "$arg" in
        --slow) SLOW=1 ;;
        *) selected_suites+=("$arg") ;;
    esac
done

all_suites=(
    libraries
    sms
    monitoring
    connection-logger
    updater
    security
    firewall
    structure
)
[ "${#selected_suites[@]}" -gt 0 ] || selected_suites=("${all_suites[@]}")

. tests/host/testlib.sh

run_suites=()
add_suite() {
    local candidate="$1" existing
    for existing in "${run_suites[@]}"; do
        [ "$existing" = "$candidate" ] && return 0
    done
    run_suites+=("$candidate")
}

for suite in "${selected_suites[@]}"; do
    suite_path="tests/host/suites/${suite}.sh"
    if [ ! -f "$suite_path" ]; then
        echo "Unknown host test suite: $suite" >&2
        echo "Available suites: ${all_suites[*]}" >&2
        exit 2
    fi
    case "$suite" in
        sms) add_suite libraries ;;
    esac
    add_suite "$suite"
done

for suite in "${run_suites[@]}"; do
    suite_path="tests/host/suites/${suite}.sh"
    . "$suite_path"
done

test_finish
