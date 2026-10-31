#!/bin/sh
set -u
umask 077

: "${SOPHIA_SERVER_URL:?SOPHIA_SERVER_URL is required}"
: "${SOPHIA_TOKEN:?SOPHIA_TOKEN is required}"
SOPHIA_SPOOL_DIR=${SOPHIA_SPOOL_DIR:-"$HOME/.cache/sophia/spool"}
SOPHIA_BATCH_SIZE=${SOPHIA_BATCH_SIZE:-20}
SOPHIA_MAX_BATCH_BYTES=${SOPHIA_MAX_BATCH_BYTES:-3000000}
SOPHIA_RETRY_SECONDS=${SOPHIA_RETRY_SECONDS:-5}
mkdir -p "$SOPHIA_SPOOL_DIR"

if command -v flock >/dev/null 2>&1; then
    exec 9>"${SOPHIA_SPOOL_DIR%/}/.forwarder.lock"
    flock -n 9 || exit 0
fi

send_batch() {
    set -- "$SOPHIA_SPOOL_DIR"/*/*.json
    [ -f "${1:-}" ] || return 0

    local_work=$(mktemp -d "${TMPDIR:-/tmp}/sophia-forward.XXXXXX") || return 1
    payload="$local_work/payload.json"
    files="$local_work/files"
    : > "$files"
    printf '{"events":[' > "$payload"
    count=0
    bytes=32
    first=true

    for event_file in "$SOPHIA_SPOOL_DIR"/*/*.json; do
        [ -f "$event_file" ] || continue
        size=$(stat -c %s "$event_file" 2>/dev/null || stat -f %z "$event_file" 2>/dev/null || printf '0')
        if [ "$count" -gt 0 ] && { [ "$count" -ge "$SOPHIA_BATCH_SIZE" ] || [ $((bytes + size)) -gt "$SOPHIA_MAX_BATCH_BYTES" ]; }; then
            break
        fi
        if [ "$first" = false ]; then
            printf ',' >> "$payload"
        fi
        cat "$event_file" >> "$payload"
        printf '%s\n' "$event_file" >> "$files"
        bytes=$((bytes + size + 1))
        count=$((count + 1))
        first=false
    done
    printf ']}\n' >> "$payload"

    if curl --fail --silent --show-error --connect-timeout 3 --max-time 20 \
        --header "Authorization: Bearer $SOPHIA_TOKEN" \
        --header 'Content-Type: application/json' \
        --data-binary "@$payload" \
        "${SOPHIA_SERVER_URL%/}/api/events" >/dev/null 2>&1; then
        while IFS= read -r sent_file; do
            rm -f "$sent_file"
        done < "$files"
        rm -rf "$local_work"
        return 0
    fi
    rm -rf "$local_work"
    return 1
}

while :; do
    if send_batch; then
        sleep 1
    else
        sleep "$SOPHIA_RETRY_SECONDS"
    fi
done
