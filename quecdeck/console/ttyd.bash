#!/bin/bash

if [ -f "/usrdata/quecdeck/atcli" ]; then
    serial_number=$(/usrdata/quecdeck/atcli 'AT+EGMR=0,5' | grep '+EGMR:' | cut -d '"' -f2)
    firmware_revision=$(/usrdata/quecdeck/atcli 'AT+QGMR' | grep -o 'RM[0-9A-Z].*')
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
