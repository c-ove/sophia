#!/bin/sh
set -u
umask 077

: "${ATHENA_SERVER_URL:?Set ATHENA_SERVER_URL to the Athena server URL}"
: "${ATHENA_TOKEN:?Set ATHENA_TOKEN to the ingestion token}"

if [ "$#" -ne 0 ]; then
    printf 'Usage: athena-history.sh\n' >&2
    exit 2
fi

curl --fail --silent --show-error --no-buffer --connect-timeout 3 --max-time 60 \
    --header "Authorization: Bearer $ATHENA_TOKEN" \
    "${ATHENA_SERVER_URL%/}/api/commands/export"
