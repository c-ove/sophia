#!/bin/sh
set -u
umask 077

: "${SOPHIA_SERVER_URL:?Set SOPHIA_SERVER_URL to the Sophia server URL}"
: "${SOPHIA_TOKEN:?Set SOPHIA_TOKEN to the ingestion token}"

if [ "$#" -ne 0 ]; then
    printf 'Usage: sophia-history.sh\n' >&2
    exit 2
fi

curl --fail --silent --show-error --no-buffer --connect-timeout 3 --max-time 60 \
    --header "Authorization: Bearer $SOPHIA_TOKEN" \
    "${SOPHIA_SERVER_URL%/}/api/commands/export"
