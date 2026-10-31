#!/bin/sh
set -u
umask 077

CLIENT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
: "${SOPHIA_SERVER_URL:?Set SOPHIA_SERVER_URL to the Sophia server URL}"
: "${SOPHIA_TOKEN:?Set SOPHIA_TOKEN to the ingestion token}"

requested_shell=${SOPHIA_SHELL:-${SHELL##*/}}
if [ "${1:-}" = "--shell" ]; then
    requested_shell=${2:?--shell requires bash or zsh}
fi
case "$requested_shell" in
    bash|zsh) ;;
    *) printf 'Sophia supports bash or zsh; use --shell bash or --shell zsh\n' >&2; exit 2 ;;
esac

for utility in script curl base64; do
    command -v "$utility" >/dev/null 2>&1 || {
        printf 'Required utility not found: %s\n' "$utility" >&2
        exit 1
    }
done

SOPHIA_BASE_DIR=${SOPHIA_BASE_DIR:-"$HOME/.cache/sophia"}
SOPHIA_SPOOL_DIR=${SOPHIA_SPOOL_DIR:-"$SOPHIA_BASE_DIR/spool"}
mkdir -p "$SOPHIA_SPOOL_DIR"

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
    if [ -n "${SOPHIA_HOST_IP:-}" ]; then
        printf '%s' "$SOPHIA_HOST_IP"
    elif command -v ip >/dev/null 2>&1; then
        ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "src") {print $(i+1); exit}}'
    elif command -v hostname >/dev/null 2>&1; then
        hostname -I 2>/dev/null | awk '{print $1}'
    fi
}

SOPHIA_SESSION_ID=$(new_uuid)
SOPHIA_SESSION_DIR="$SOPHIA_SPOOL_DIR/$SOPHIA_SESSION_ID"
SOPHIA_RAW_LOG="$SOPHIA_SESSION_DIR/terminal.raw"
SOPHIA_HOST_IP=${SOPHIA_HOST_IP:-$(detect_ip)}
SOPHIA_HOSTNAME=$(hostname -s 2>/dev/null || hostname)
SOPHIA_HOSTNAME=$(printf '%s' "$SOPHIA_HOSTNAME" | tr -cd '[:alnum:]._-')
SOPHIA_CLIENT_SHELL="$requested_shell"
SOPHIA_BASHRC="$CLIENT_DIR/bashrc"
SOPHIA_ORIGINAL_ZDOTDIR=${ZDOTDIR:-$HOME}
SOPHIA_MAX_OUTPUT_BYTES=${SOPHIA_MAX_OUTPUT_BYTES:-65536}
SOPHIA_MAX_SPOOL_FILES=${SOPHIA_MAX_SPOOL_FILES:-1000}
mkdir -p "$SOPHIA_SESSION_DIR"
: > "$SOPHIA_RAW_LOG"

if [ -z "$SOPHIA_HOST_IP" ]; then
    printf 'Could not determine host IP; set SOPHIA_HOST_IP explicitly\n' >&2
    exit 1
fi

export SOPHIA_SERVER_URL SOPHIA_TOKEN SOPHIA_BASE_DIR SOPHIA_SPOOL_DIR
export SOPHIA_SESSION_ID SOPHIA_SESSION_DIR SOPHIA_RAW_LOG SOPHIA_HOST_IP
export SOPHIA_HOSTNAME SOPHIA_CLIENT_SHELL SOPHIA_BASHRC SOPHIA_ORIGINAL_ZDOTDIR
export SOPHIA_MAX_OUTPUT_BYTES SOPHIA_MAX_SPOOL_FILES

nohup "$CLIENT_DIR/sophia-forwarder.sh" >> "$SOPHIA_BASE_DIR/forwarder.log" 2>&1 &

if [ "$requested_shell" = "zsh" ]; then
    ZDOTDIR="$CLIENT_DIR/zdotdir"
    export ZDOTDIR
fi

if [ "$(uname -s)" = "Linux" ]; then
    if [ "$requested_shell" = "bash" ]; then
        script --quiet --flush --log-out "$SOPHIA_RAW_LOG" --command 'bash --rcfile "$SOPHIA_BASHRC" -i'
    else
        script --quiet --flush --log-out "$SOPHIA_RAW_LOG" --command 'zsh -i'
    fi
else
    if [ "$requested_shell" = "bash" ]; then
        script -q "$SOPHIA_RAW_LOG" bash --rcfile "$SOPHIA_BASHRC" -i
    else
        script -q "$SOPHIA_RAW_LOG" zsh -i
    fi
fi
shell_status=$?
rm -f "$SOPHIA_RAW_LOG"
exit "$shell_status"
