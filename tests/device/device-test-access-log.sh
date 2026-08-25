#!/bin/bash
# Exercise access-log locking and rollover with the device's real flock.
# The test is non-disruptive. It runs as www-data in an isolated runtime fixture
# and does not read or modify the installed access, connection, or AT logs.
#
# Run as root on an installed device:
#
#     bash device-test-access-log.sh

FIXTURE=/run/quecdeck-web/access-log-test.$$
LOG="$FIXTURE/access_events.jsonl"
RESULTS="$FIXTURE/results"
READER="$FIXTURE/get_logs"
READER_FAILURE="$FIXTURE/reader.failed"
pass=0
fail=0

ok() {
    echo "  PASS: $1"
    pass=$((pass + 1))
}

bad() {
    echo "  FAIL: $1"
    fail=$((fail + 1))
}

cleanup() {
    rm -rf "$FIXTURE"
}
trap cleanup EXIT INT TERM

[ "$(id -u)" = "0" ] || {
    echo "Run this test as root."
    exit 2
}

command -v flock >/dev/null 2>&1 || {
    echo "flock is not installed."
    exit 2
}

mkdir -p "$RESULTS" || exit 2
cp /usrdata/quecdeck/www/cgi-bin/get_logs "$READER" || exit 2
sed -i \
    -e "s|^CONN_LOG=.*|CONN_LOG=$FIXTURE/connection_events.jsonl|" \
    -e "s|^ACCESS_LOG=.*|ACCESS_LOG=$LOG|" \
    -e "s|^ATCMD_LOG=.*|ATCMD_LOG=$FIXTURE/atcmd.log|" \
    "$READER" || exit 2
chown -R www-data:www-data "$FIXTURE" || exit 2
chmod 700 "$FIXTURE" "$RESULTS" || exit 2
chmod 700 "$READER" || exit 2

# Begin just below the production limit so the parallel writers cross the real
# 500-line boundary without launching hundreds of processes on the modem.
su -s /bin/bash www-data -c '
    umask 077
    for i in $(seq 1 490); do
        printf "{\"id\":%s}\n" "$i"
    done > "'"$LOG"'"
' || exit 2

# Read through the real get_logs implementation while independent writers
# append and rotate. Every observed body must be one complete JSON document.
su -s /bin/bash www-data -c '
    for i in $(seq 1 120); do
        body=$(REQUEST_METHOD=GET "'"$READER"'" | tail -1)
        if ! printf "%s\n" "$body" | grep -Eq \
            "^\{\"connection_events\":\[\],\"access_events\":\[\{\"id\":[0-9]+\}(,\{\"id\":[0-9]+\})*\],\"atcmd_log\":\[\]\}$"; then
            touch "'"$READER_FAILURE"'"
            exit 1
        fi
    done
' &
reader_pid=$!

su -s /bin/bash www-data -c '
    . /usrdata/quecdeck/script/cgi-lib.sh || exit 1
    for i in $(seq 491 530); do
        (log_access_event "'"$LOG"'" "{\"id\":$i}" && touch "'"$RESULTS"'/$i") &
    done
    wait
'
writer_rc=$?
wait "$reader_pid"
reader_rc=$?

[ "$writer_rc" = "0" ] && ok "parallel writer shell completed" || bad "parallel writer shell failed"
[ "$(find "$RESULTS" -type f | wc -l | tr -d ' ')" = "40" ] \
    && ok "all 40 concurrent writers succeeded" \
    || bad "one or more concurrent writers failed"
[ "$(wc -l < "$LOG" | tr -d ' ')" = "500" ] \
    && ok "the production 500-line limit is enforced" \
    || bad "the retained log does not contain 500 lines"
[ "$(grep -c '^{"id":[0-9][0-9]*}$' "$LOG")" = "500" ] \
    && ok "all retained records are complete JSON objects" \
    || bad "the retained log contains a partial record"
[ "$reader_rc" = "0" ] && [ ! -e "$READER_FAILURE" ] \
    && ok "get_logs stayed valid throughout rollover" \
    || bad "get_logs observed an incomplete replacement"
[ "$(find "$FIXTURE" -name 'access_events.jsonl.tmp.*' | wc -l | tr -d ' ')" = "0" ] \
    && ok "rollover left no temporary files" \
    || bad "rollover left a temporary file"
[ "$(stat -c %a "$LOG" 2>/dev/null)" = "600" ] \
    && ok "the access log is owner-only" \
    || bad "the access log mode is not 600"
[ "$(stat -c %a "$FIXTURE/access_events.lock" 2>/dev/null)" = "600" ] \
    && ok "the access-log lock is owner-only" \
    || bad "the access-log lock mode is not 600"

echo ""
echo "tests: $((pass + fail)), passed: $pass, failed: $fail"
[ "$fail" = "0" ]
