#!/bin/bash

if [ -f /usrdata/quecdeck/script/at-lib.sh ]; then
    . /usrdata/quecdeck/script/at-lib.sh
    serial_number=$(atcmd_run 'AT+EGMR=0,5' | grep '+EGMR:' | cut -d '"' -f2)
    firmware_revision=$(atcmd_run 'AT+QGMR' | grep -o 'RM[0-9A-Z].*')
else
    serial_number="UNKNOWN"
    firmware_revision="UNKNOWN"
fi

# Version file holds a release number ("1.0.5") or a branch name ("main")
# for installs from an untagged tree.
quecdeck_version=$(cat /usrdata/quecdeck/version 2>/dev/null)
case "$quecdeck_version" in
    [0-9]*) quecdeck_version="v$quecdeck_version" ;;
esac

echo "=============================================================="
echo "QuecDeck${quecdeck_version:+ $quecdeck_version}"
echo "Firmware Revision: $firmware_revision"
echo "Serial Number: $serial_number"
echo "=============================================================="

# Start a login session
exec /bin/login
