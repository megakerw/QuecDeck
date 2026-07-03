#!/bin/bash

# atcli_direct rather than atcmd_run: this runs as root, and the queue FIFO
# is www-data-owned (SELinux blocks the cross-domain write).
if [ -f /usrdata/quecdeck/script/at-lib.sh ]; then
    . /usrdata/quecdeck/script/at-lib.sh
    serial_number=$(atcli_direct 'AT+EGMR=0,5' | grep '+EGMR:' | cut -d '"' -f2)
    firmware_revision=$(atcli_direct 'AT+QGMR' | grep -o 'RM[0-9A-Z].*')
else
    serial_number="UNKNOWN"
    firmware_revision="UNKNOWN"
fi

echo "=============================================================="
echo "QuecDeck v1.0"
echo "Firmware Revision: $firmware_revision"
echo "Serial Number: $serial_number"
echo "=============================================================="

# Start a login session
exec /bin/login
