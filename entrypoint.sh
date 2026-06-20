#!/bin/bash
set -euo pipefail

CRON_SCHEDULE="${CRON_SCHEDULE:-0 2 * * *}"
MIN_AGE_DAYS="${MIN_AGE_DAYS:-0}"

echo "Adding job to cron"

echo "$CRON_SCHEDULE MIN_AGE_DAYS=$MIN_AGE_DAYS /usr/local/bin/ssd-to-hdd.sh sync >> /proc/1/fd/1 2>&1" > /etc/crontabs/root

echo "Will start initial sync in 3 minutes."
sleep 180

/usr/local/bin/ssd-to-hdd.sh sync

echo "Starting cron scheduler"

exec crond -f -l 2
