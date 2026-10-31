#!/bin/sh
set -u
umask 077

: "${ATHENA_SERVER_URL:?Set ATHENA_SERVER_URL to the Athena server URL}"
: "${ATHENA_TOKEN:?Set ATHENA_TOKEN to the ingestion token}"

assume_yes=false
if [ "${1:-}" = "--yes" ]; then
    assume_yes=true
    shift
fi

if [ "$#" -ne 1 ]; then
    printf 'Usage: athena-rerun.sh [--yes] EVENT_ID\n' >&2
    exit 2
fi

event_id=$1
if ! printf '%s' "$event_id" | grep -Eq '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'; then
    printf 'Invalid event ID: %s\n' "$event_id" >&2
    exit 2
fi

command=$(curl --fail --silent --show-error --connect-timeout 3 --max-time 15 \
    --header "Authorization: Bearer $ATHENA_TOKEN" \
    "${ATHENA_SERVER_URL%/}/api/commands/$event_id/command") || {
    printf 'Could not retrieve command %s\n' "$event_id" >&2
    exit 1
}

printf 'Re-running %s: %s\n' "$event_id" "$command"
if [ "$assume_yes" = false ]; then
    if [ ! -t 0 ]; then
        printf 'Confirmation required; rerun with --yes to execute without a prompt\n' >&2
        exit 2
    fi
    printf 'Execute this command? [y/N] '
    IFS= read -r answer
    case "$answer" in
        y|Y|yes|YES) ;;
        *) printf 'Cancelled\n'; exit 1 ;;
    esac
fi

shell=${ATHENA_CLIENT_SHELL:-${SHELL##*/}}
case "$shell" in
    bash|zsh) ;;
    *) printf 'Athena rerun supports bash or zsh\n' >&2; exit 2 ;;
esac
"$shell" -c "$command"
