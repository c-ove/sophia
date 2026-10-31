if [ -z "${ATHENA_SESSION_DIR:-}" ] || [ -z "${ATHENA_RAW_LOG:-}" ]; then
    return 0
fi

_athena_active=0
_athena_sequence=0
_athena_at_prompt=1
_athena_in_precmd=0
_athena_previous_status=0

_athena_now_ms() {
    local value
    value=$(date +%s%3N 2>/dev/null)
    case "$value" in
        *[!0-9]*|"") printf '%s' "$(( $(date +%s) * 1000 ))" ;;
        *) printf '%s' "$value" ;;
    esac
}

_athena_now_iso() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

_athena_uuid() {
    if [ -r /proc/sys/kernel/random/uuid ]; then
        cat /proc/sys/kernel/random/uuid
    elif command -v uuidgen >/dev/null 2>&1; then
        uuidgen | tr 'A-F' 'a-f'
    else
        od -An -N16 -tx1 /dev/urandom | tr -d ' \n'
    fi
}

_athena_preexec() {
    local command="$1"
    [ -n "$command" ] || return 0
    _athena_sequence=$((_athena_sequence + 1))
    _athena_command="$command"
    _athena_started_at=$(_athena_now_iso)
    _athena_started_ms=$(_athena_now_ms)
    _athena_start_marker=$(printf '\033]999;ATHENA_START_%s_%s\a' "$ATHENA_SESSION_ID" "$_athena_sequence")
    printf '%s' "$_athena_start_marker"
    _athena_active=1
}

_athena_finish() {
    local exit_code="$1"
    [ "${_athena_active:-0}" = "1" ] || return 0
    _athena_active=0

    local end_marker start_offset end_offset attempts=0
    end_marker=$(printf '\033]999;ATHENA_END_%s_%s\a' "$ATHENA_SESSION_ID" "$_athena_sequence")
    printf '%s' "$end_marker"
    while [ "$attempts" -lt 100 ]; do
        start_offset=$(LC_ALL=C grep -aboF -- "$_athena_start_marker" "$ATHENA_RAW_LOG" 2>/dev/null | tail -n 1 | cut -d: -f1)
        end_offset=$(LC_ALL=C grep -aboF -- "$end_marker" "$ATHENA_RAW_LOG" 2>/dev/null | tail -n 1 | cut -d: -f1)
        [ -n "$start_offset" ] && [ -n "$end_offset" ] && break
        attempts=$((attempts + 1))
        sleep 0.02
    done

    local start=$(( ${start_offset:-0} + ${#_athena_start_marker} ))
    local length=0
    if [ -n "$start_offset" ] && [ -n "$end_offset" ] && [ "$end_offset" -gt "$start" ]; then
        length=$((end_offset - start))
    fi
    local max_bytes="${ATHENA_MAX_OUTPUT_BYTES:-65536}"
    local capture_length="$length"
    local truncated=false
    if [ "$length" -gt "$max_bytes" ]; then
        capture_length="$max_bytes"
        truncated=true
    fi

    local output_file="$ATHENA_SESSION_DIR/output-${_athena_sequence}.raw"
    if [ "$capture_length" -gt 0 ]; then
        tail -c +$((start + 1)) "$ATHENA_RAW_LOG" | head -c "$capture_length" > "$output_file"
    else
        : > "$output_file"
    fi

    local ended_ms ended_at duration command_b64 output_b64 event_id event_file
    ended_ms=$(_athena_now_ms)
    ended_at=$(_athena_now_iso)
    duration=$((ended_ms - ${_athena_started_ms:-$ended_ms}))
    [ "$duration" -ge 0 ] || duration=0
    command_b64=$(printf '%s' "$_athena_command" | base64 | tr -d '\r\n')
    output_b64=$(base64 "$output_file" | tr -d '\r\n')
    rm -f "$output_file"
    event_id=$(_athena_uuid)
    event_file="$ATHENA_SESSION_DIR/event-$(printf '%08d' "$_athena_sequence").json"

    printf '{"id":"%s","session_id":"%s","sequence":%s,"hostname":"%s","host_ip":"%s","shell":"%s","command_b64":"%s","output_b64":"%s","started_at":"%s","ended_at":"%s","exit_code":%s,"duration_ms":%s,"truncated":%s}\n' \
        "$event_id" "$ATHENA_SESSION_ID" "$_athena_sequence" "$ATHENA_HOSTNAME" \
        "$ATHENA_HOST_IP" "$ATHENA_CLIENT_SHELL" "$command_b64" "$output_b64" \
        "$_athena_started_at" "$ended_at" "$exit_code" "$duration" "$truncated" > "$event_file.tmp"
    mv "$event_file.tmp" "$event_file"

    local spool_count
    spool_count=$(find "$ATHENA_SPOOL_DIR" -type f -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
    if [ "$spool_count" -gt "${ATHENA_MAX_SPOOL_FILES:-1000}" ]; then
        rm -f "$event_file"
    fi
}

_athena_bash_preexec() {
    [ -z "${COMP_LINE:-}" ] || return 0
    [ "${_athena_in_precmd:-0}" = "0" ] || return 0
    [ "${_athena_at_prompt:-0}" = "1" ] || return 0
    case "$BASH_COMMAND" in
        _athena_capture_status|_athena_bash_precmd) return 0 ;;
    esac
    _athena_at_prompt=0
    local command
    command=$(HISTTIMEFORMAT= builtin history 1 | sed '1s/^ *[0-9][0-9]* *//')
    [ -n "$command" ] || command="$BASH_COMMAND"
    _athena_preexec "$command"
}

_athena_capture_status() {
    _athena_previous_status=$?
    _athena_in_precmd=1
    return "$_athena_previous_status"
}

_athena_bash_precmd() {
    _athena_finish "$_athena_previous_status"
    _athena_in_precmd=0
    _athena_at_prompt=1
    return "$_athena_previous_status"
}

_athena_zsh_precmd() {
    _athena_finish "$?"
}

if [ -n "${ZSH_VERSION:-}" ]; then
    autoload -Uz add-zsh-hook
    add-zsh-hook preexec _athena_preexec
    add-zsh-hook precmd _athena_zsh_precmd
elif [ -n "${BASH_VERSION:-}" ]; then
    _athena_in_precmd=1
    trap '_athena_bash_preexec' DEBUG
    case "${PROMPT_COMMAND:-}" in
        *PROMPT_COMMAND=*) PROMPT_COMMAND="_athena_capture_status;_athena_bash_precmd" ;;
        *) PROMPT_COMMAND="_athena_capture_status${PROMPT_COMMAND:+;$PROMPT_COMMAND};_athena_bash_precmd" ;;
    esac
    _athena_at_prompt=1
    _athena_in_precmd=0
fi
