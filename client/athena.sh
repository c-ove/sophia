#!/bin/sh
set -u
umask 077

CLIENT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
: "${ATHENA_SERVER_URL:?Set ATHENA_SERVER_URL to the Athena server URL}"
: "${ATHENA_TOKEN:?Set ATHENA_TOKEN to the ingestion token}"

requested_shell=${ATHENA_SHELL:-${SHELL##*/}}
if [ "${1:-}" = "--shell" ]; then
    requested_shell=${2:?--shell requires bash or zsh}
fi
case "$requested_shell" in
    bash|zsh) ;;
    *) printf 'Athena supports bash or zsh; use --shell bash or --shell zsh\n' >&2; exit 2 ;;
esac

for utility in script curl base64; do
    command -v "$utility" >/dev/null 2>&1 || {
        printf 'Required utility not found: %s\n' "$utility" >&2
        exit 1
    }
done

ATHENA_BASE_DIR=${ATHENA_BASE_DIR:-"$HOME/.cache/athena"}
ATHENA_SPOOL_DIR=${ATHENA_SPOOL_DIR:-"$ATHENA_BASE_DIR/spool"}
mkdir -p "$ATHENA_SPOOL_DIR"

new_uuid() {
    if [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
    elif command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr 'A-F' 'a-f'
    else
        od -An -N16 -tx1 /dev/urandom | tr -d ' \n'
    fi
}

detect_ip() {
    if [ -n "${ATHENA_HOST_IP:-}" ]; then
        printf '%s' "$ATHENA_HOST_IP"
    elif command -v ip >/dev/null 2>&1; then
        ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}'
    elif command -v hostname >/dev/null 2>&1; then
        hostname -I 2>/dev/null | awk '{print $1}'
    fi
}

ATHENA_SESSION_ID=$(new_uuid)
ATHENA_SESSION_DIR="$ATHENA_SPOOL_DIR/$ATHENA_SESSION_ID"
ATHENA_RAW_LOG="$ATHENA_SESSION_DIR/terminal.raw"
ATHENA_HOST_IP=${ATHENA_HOST_IP:-$(detect_ip)}
ATHENA_HOSTNAME=$(hostname -s 2>/dev/null || hostname)
ATHENA_HOSTNAME=$(printf '%s' "$ATHENA_HOSTNAME" | tr -cd '[:alnum:]._-')
ATHENA_CLIENT_SHELL="$requested_shell"
ATHENA_BASHRC="$CLIENT_DIR/bashrc"
ATHENA_ORIGINAL_ZDOTDIR=${ZDOTDIR:-$HOME}
ATHENA_MAX_OUTPUT_BYTES=${ATHENA_MAX_OUTPUT_BYTES:-65536}
ATHENA_MAX_SPOOL_FILES=${ATHENA_MAX_SPOOL_FILES:-1000}
mkdir -p "$ATHENA_SESSION_DIR"
: > "$ATHENA_RAW_LOG"

if [ -z "$ATHENA_HOST_IP" ]; then
    printf 'Could not determine host IP; set ATHENA_HOST_IP explicitly\n' >&2
    exit 1
fi

export ATHENA_SERVER_URL ATHENA_TOKEN ATHENA_BASE_DIR ATHENA_SPOOL_DIR
export ATHENA_SESSION_ID ATHENA_SESSION_DIR ATHENA_RAW_LOG ATHENA_HOST_IP
export ATHENA_HOSTNAME ATHENA_CLIENT_SHELL ATHENA_BASHRC ATHENA_ORIGINAL_ZDOTDIR
export ATHENA_MAX_OUTPUT_BYTES ATHENA_MAX_SPOOL_FILES

nohup "$CLIENT_DIR/athena-forwarder.sh" >> "$ATHENA_BASE_DIR/forwarder.log" 2>&1 &

if [ "$requested_shell" = "zsh" ]; then
    ZDOTDIR="$CLIENT_DIR/zdotdir"
    export ZDOTDIR
fi

if [ "$(uname -s)" = "Linux" ]; then
    if [ "$requested_shell" = "bash" ]; then
        script --quiet --flush --log-out "$ATHENA_RAW_LOG" --command 'bash --rcfile "$ATHENA_BASHRC" -i'
    else
        script --quiet --flush --log-out "$ATHENA_RAW_LOG" --command 'zsh -i'
    fi
else
    if [ "$requested_shell" = "bash" ]; then
        script -q "$ATHENA_RAW_LOG" bash --rcfile "$ATHENA_BASHRC" -i
    else
        script -q "$ATHENA_RAW_LOG" zsh -i
    fi
fi
shell_status=$?
rm -f "$ATHENA_RAW_LOG"
exit "$shell_status"
