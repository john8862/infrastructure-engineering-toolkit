#!/usr/bin/env bash

: "${IPA_LOG_DIR:=/var/log/freeipa-bootstrap}"
: "${RUN_ID:=bootstrap-$$}"
: "${LOG_FILE:=}"
: "${RUN_COMMAND_EXTRA_LOG_FILE:=}"

log_init() {
    if ! is_install; then
        LOG_FILE=''
        return 0
    fi
    ensure_private_directory "$IPA_LOG_DIR" 'bootstrap log directory'
    LOG_FILE="$IPA_LOG_DIR/${RUN_ID}.log"
    umask 077
    [[ ! -e "$LOG_FILE" && ! -L "$LOG_FILE" ]] || {
        log_error "refusing to overwrite an existing or symlinked bootstrap log: $LOG_FILE"
        return 1
    }
    install -m 0600 /dev/null "$LOG_FILE"
}

log_emit() {
    local level=${1:?level required}
    shift
    local message=$*
    local timestamp
    timestamp=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
    local line="$timestamp [$level] [stage=${CURRENT_STAGE:-unknown}] $message"
    printf '%s\n' "$line" >&2
    if [[ -n "${LOG_FILE:-}" ]]; then
        printf '%s\n' "$line" >> "$LOG_FILE"
    fi
}

log_stage() {
    CURRENT_STAGE=$1
    log_info "stage started: $CURRENT_STAGE"
}

log_command() {
    log_info "command: $(redact_args "$@")"
}

# Run an operational child command with one data path: the child's combined
# stdout/stderr is written once to the console by tee and once to each selected
# log file.  Combining the streams preserves the order an operator sees when
# running the command directly; native command lines are intentionally not
# prefixed so tools such as dnf and ipa-server-install remain readable.
#
# The command is kept as an argv array by callers.  log_command/redact_args
# renders only a safe representation; the actual argv is never reconstructed
# through shell reconstruction or shell tracing.  PIPESTATUS is copied immediately after the
# pipeline so tee cannot mask the child's exit code.
run_command() {
    (( $# > 0 )) || {
        log_error 'run_command requires a command'
        return 2
    }

    local safe_command
    safe_command=$(redact_args "$@")
    if is_dry_run || is_check; then
        plan "execute $safe_command"
        return 0
    fi

    log_command "$@"

    local extra_log=${RUN_COMMAND_EXTRA_LOG_FILE:-}
    local -a tee_args=(-a)
    if [[ -n "${LOG_FILE:-}" ]]; then
        tee_args+=("$LOG_FILE")
    fi
    if [[ -n "$extra_log" && "$extra_log" != "${LOG_FILE:-}" ]]; then
        tee_args+=("$extra_log")
    fi

    local command_rc
    if (( ${#tee_args[@]} == 1 )); then
        if "$@"; then
            command_rc=0
        else
            command_rc=$?
        fi
        if (( command_rc != 0 )); then
            log_error "command failed with exit code $command_rc: $safe_command"
        fi
        return "$command_rc"
    fi

    local -a pipeline_status=()
    # Keep the pipeline in an if condition so set -e cannot terminate the
    # shell before PIPESTATUS is copied.  The branch itself is irrelevant;
    # the child and tee statuses are read from the saved array below.
    if "$@" 2>&1 | tee "${tee_args[@]}"; then
        pipeline_status=("${PIPESTATUS[@]}")
    else
        pipeline_status=("${PIPESTATUS[@]}")
    fi
    command_rc=${pipeline_status[0]:-125}
    local tee_rc=${pipeline_status[1]:-125}

    if (( tee_rc != 0 )); then
        log_error "command output logging failed with exit code $tee_rc"
    fi
    if (( command_rc != 0 )); then
        log_error "command failed with exit code $command_rc: $safe_command"
        return "$command_rc"
    fi
    return "$tee_rc"
}

# FreeIPA 4.13.x requires a 0022 process mask for server installation.  Keep
# the bootstrap's restrictive umask for its own logs/state, and change the
# mask only in the child-command subshell that needs the platform default.
run_command_with_umask() {
    (( $# >= 2 )) || {
        log_error 'run_command_with_umask requires a mask and command'
        return 2
    }
    local mask=$1
    shift
    [[ "$mask" =~ ^0?[0-7]{3}$ ]] || {
        log_error "invalid child command umask: $mask"
        return 2
    }
    (
        umask "$mask"
        run_command "$@"
    )
}
