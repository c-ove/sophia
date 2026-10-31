if [ -z "${SOPHIA_SESSION_DIR:-}" ] || [ -z "${SOPHIA_RAW_LOG:-}" ]; then
    return 0
fi

_sophia_active=0
_sophia_sequence=0
_sophia_at_prompt=1
_sophia_in_precmd=0
_sophia_previous_status=0

_sophia_now_ms() {
    local value
    value=$(date +%s%3N 2>/dev/null)
    case "$value" in
        *[!0-9]*|"") printf '%s' "$(( $(date +%s) * 1000 ))" ;;
        *) printf '%s' "$value" ;;
    esac
}

_sophia_now_iso() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

_sophia_uuid() {
    if [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
    elif command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr 'A-F' 'a-f'
    else
        od -An -N16 -tx1 /dev/urandom | tr -d ' \n'
    fi
}

_sophia_preexec() {
    local command="$1"
    [ -n "$command" ] || return 0
    _sophia_sequence=$((_sophia_sequence + 1))
    _sophia_command="$command"
    _sophia_started_at=$(_sophia_now_iso)
    _sophia_started_ms=$(_sophia_now_ms)
    _sophia_start_marker=$(printf '\033]999;SOPHIA_START_%s_%s\a' "$SOPHIA_SESSION_ID" "$_sophia_sequence")
    printf '%s' "$_sophia_start_marker"
    _sophia_active=1
}

_sophia_finish() {
    local exit_code="$1"
    [ "${_sophia_active:-0}" = "1" ] || return 0
    _sophia_active=0

    local end_marker start_offset end_offset attempts=0
    end_marker=$(printf '\033]999;SOPHIA_END_%s_%s\a' "$SOPHIA_SESSION_ID" "$_sophia_sequence")
    printf '%s' "$end_marker"
    while [ "$attempts" -lt 100 ]; do
        start_offset=$(LC_ALL=C grep -aboF -- "$_sophia_start_marker" "$SOPHIA_RAW_LOG" 2>/dev/null | tail -n 1 | cut -d: -f1)
        end_offset=$(LC_ALL=C grep -aboF -- "$end_marker" "$SOPHIA_RAW_LOG" 2>/dev/null | tail -n 1 | cut -d: -f1)
        [ -n "$start_offset" ] && [ -n "$end_offset" ] && break
        attempts=$((attempts + 1))
        sleep 0.02
    done

    local start=$(( ${start_offset:-0} + ${#_sophia_start_marker} ))
    local length=0
    if [ -n "$start_offset" ] && [ -n "$end_offset" ] && [ "$end_offset" -gt "$start" ]; then
        length=$((end_offset - start))
    fi
    local max_bytes="${SOPHIA_MAX_OUTPUT_BYTES:-65536}"
    local capture_length="$length"
    local truncated=false
    if [ "$length" -gt "$max_bytes" ]; then
        capture_length="$max_bytes"
        truncated=true
    fi

    local output_file="$SOPHIA_SESSION_DIR/output-${_sophia_sequence}.raw"
    if [ "$capture_length" -gt 0 ]; then
        tail -c +$((start + 1)) "$SOPHIA_RAW_LOG" | head -c "$capture_length" > "$output_file"
    else
        : > "$output_file"
    fi

    local ended_ms ended_at duration command_b64 output_b64 event_id event_file
    ended_ms=$(_sophia_now_ms)
    ended_at=$(_sophia_now_iso)
    duration=$((ended_ms - ${_sophia_started_ms:-$ended_ms}))
    [ "$duration" -ge 0 ] || duration=0
    command_b64=$(printf '%s' "$_sophia_command" | base64 | tr -d '\r\n')
    output_b64=$(base64 "$output_file" | tr -d '\r\n')
    rm -f "$output_file"
    event_id=$(_sophia_uuid)
    event_file="$SOPHIA_SESSION_DIR/event-$(printf '%08d' "$_sophia_sequence").json"

    printf '{"id":"%s","session_id":"%s","sequence":%s,"hostname":"%s","host_ip":"%s","shell":"%s","command_b64":"%s","output_b64":"%s","started_at":"%s","ended_at":"%s","exit_code":%s,"duration_ms":%s,"truncated":%s}\n' \
        "$event_id" "$SOPHIA_SESSION_ID" "$_sophia_sequence" "$SOPHIA_HOSTNAME" \
        "$SOPHIA_HOST_IP" "$SOPHIA_CLIENT_SHELL" "$command_b64" "$output_b64" \
        "$_sophia_started_at" "$ended_at" "$exit_code" "$duration" "$truncated" > "$event_file.tmp"
    mv "$event_file.tmp" "$event_file"

    local spool_count
    spool_count=$(find "$SOPHIA_SPOOL_DIR" -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
    if [ "$spool_count" -gt "${SOPHIA_MAX_SPOOL_FILES:-1000}" ]; then
        rm -f "$event_file"
    fi
}

_sophia_bash_preexec() {
    [ -z "${COMP_LINE:-}" ] || return 0
    [ "${_sophia_in_precmd:-0}" = "0" ] || return 0
    [ "${_sophia_at_prompt:-0}" = "1" ] || return 0
    case "$BASH_COMMAND" in
        _sophia_capture_status|_sophia_bash_precmd) return 0 ;;
    esac
    _sophia_at_prompt=0
    local command
    command=$(HISTTIMEFORMAT= builtin history 1 | sed '1s/^ *[0-9][0-9]* *//')
    [ -n "$command" ] || command="$BASH_COMMAND"
    _sophia_preexec "$command"
}

_sophia_capture_status() {
    _sophia_previous_status=$?
    _sophia_in_precmd=1
    return "$_sophia_previous_status"
}

_sophia_bash_precmd() {
    _sophia_finish "$_sophia_previous_status"
    _sophia_in_precmd=0
    _sophia_at_prompt=1
    return "$_sophia_previous_status"
}

_sophia_zsh_precmd() {
    _sophia_finish "$?"
}

if [ -n "${ZSH_VERSION:-}" ]; then
    autoload -Uz add-zsh-hook
    add-zsh-hook preexec _sophia_preexec
    add-zsh-hook precmd _sophia_zsh_precmd
elif [ -n "${BASH_VERSION:-}" ]; then
    _sophia_in_precmd=1
    trap '_sophia_bash_preexec' DEBUG
    case "${PROMPT_COMMAND:-}" in
        *PROMPT_COMMAND=*) PROMPT_COMMAND="_sophia_capture_status;_sophia_bash_precmd" ;;
        *) PROMPT_COMMAND="_sophia_capture_status${PROMPT_COMMAND:+;$PROMPT_COMMAND};_sophia_bash_precmd" ;;
    esac
    _sophia_at_prompt=1
    _sophia_in_precmd=0
fi
