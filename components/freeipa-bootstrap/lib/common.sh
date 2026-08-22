#!/usr/bin/env bash

# Shared, side-effect-free helpers.  The executable entry point enables
# errexit/nounset; these functions deliberately return status to their callers
# so validation code can collect multiple actionable errors.

: "${MODE:=install}"
: "${CURRENT_STAGE:=initialisation}"
: "${LOG_FILE:=}"
PREFLIGHT_ERRORS=()
PREFLIGHT_WARNINGS=()
PARSED_WORDS=()
DNS_EXPECTED_RECORDS=()

is_dry_run() {
    [[ "${MODE:-install}" == "dry-run" ]]
}

is_check() {
    [[ "${MODE:-install}" == "check" ]]
}

is_install() {
    [[ "${MODE:-install}" == "install" ]]
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

log_info() {
    if declare -F log_emit >/dev/null 2>&1; then
        log_emit INFO "$*"
    else
        printf '[INFO] %s\n' "$*" >&2
    fi
}

log_warn() {
    if declare -F log_emit >/dev/null 2>&1; then
        log_emit WARN "$*"
    else
        printf '[WARN] %s\n' "$*" >&2
    fi
}

log_error() {
    if declare -F log_emit >/dev/null 2>&1; then
        log_emit ERROR "$*"
    else
        printf '[ERROR] %s\n' "$*" >&2
    fi
}

die() {
    log_error "$*"
    return 1
}

plan() {
    log_info "PLAN: $*"
}

preflight_error() {
    PREFLIGHT_ERRORS+=("$*")
    log_error "preflight: $*"
}

preflight_warning() {
    PREFLIGHT_WARNINGS+=("$*")
    log_warn "preflight: $*"
}

preflight_has_errors() {
    (( ${#PREFLIGHT_ERRORS[@]} > 0 ))
}

preflight_fail_if_errors() {
    if preflight_has_errors; then
        log_error "preflight failed with ${#PREFLIGHT_ERRORS[@]} error(s)"
        return 1
    fi
}

validate_bool() {
    [[ "$1" == true || "$1" == false ]]
}

validate_nonnegative_integer() {
    [[ "$1" =~ ^[0-9]+$ ]]
}

validate_positive_integer() {
    [[ "$1" =~ ^[1-9][0-9]*$ ]]
}

validate_tcp_port() {
    local value=${1:-}
    validate_positive_integer "$value" || return 1
    (( 10#$value <= 65535 ))
}

validate_ipv4() {
    local value=${1:-}
    local o1 o2 o3 o4 extra octet
    [[ "$value" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || return 1
    IFS=. read -r o1 o2 o3 o4 extra <<< "$value"
    [[ -z "${extra:-}" ]] || return 1
    for octet in "$o1" "$o2" "$o3" "$o4"; do
        [[ "$octet" =~ ^[0-9]+$ ]] || return 1
        (( 10#$octet <= 255 )) || return 1
    done
}

validate_ipv4_cidr() {
    local value=${1:-}
    local address prefix
    [[ "$value" == */* ]] || return 1
    address=${value%/*}
    prefix=${value#*/}
    validate_ipv4 "$address" || return 1
    [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
    (( 10#$prefix <= 32 ))
}

validate_dns_server() {
    local value=${1:-}
    if validate_ipv4 "$value"; then
        return 0
    fi
    # IPv6 is accepted for DNS forwarders, but is not used for the required
    # reverse-zone automation.  Keep the syntax check intentionally strict.
    if [[ "$value" =~ ^[0-9A-Fa-f:]+$ && "$value" == *:*:* ]]; then
        return 0
    fi
    validate_fqdn "$value"
}

validate_fqdn() {
    local value=${1:-}
    local label
    local -a labels=()
    [[ -n "$value" && ${#value} -le 253 ]] || return 1
    [[ "$value" != .* && "$value" != *.. && "$value" != *[!A-Za-z0-9.-]* ]] || return 1
    IFS=. read -r -a labels <<< "$value"
    (( ${#labels[@]} >= 2 )) || return 1
    for label in "${labels[@]}"; do
        [[ -n "$label" && ${#label} -le 63 ]] || return 1
        [[ "$label" != -* && "$label" != *- ]] || return 1
    done
}

validate_realm() {
    local value=${1:-}
    [[ -n "$value" && "$value" == "${value^^}" ]] || return 1
    [[ "$value" =~ ^[A-Z0-9][A-Z0-9.-]*[A-Z0-9]$ || "$value" =~ ^[A-Z0-9]$ ]]
}

reverse_zone_for_ipv4() {
    local address=${1:-}
    local o1 o2 o3 o4
    validate_ipv4 "$address" || return 1
    IFS=. read -r o1 o2 o3 o4 <<< "$address"
    printf '%s.%s.%s.in-addr.arpa' "$o3" "$o2" "$o1"
}

reverse_record_for_ipv4() {
    local address=${1:-}
    local o1 o2 o3 o4
    validate_ipv4 "$address" || return 1
    IFS=. read -r o1 o2 o3 o4 <<< "$address"
    printf '%s' "$o4"
}

parse_space_list() {
    local value=${1:-}
    PARSED_WORDS=()
    [[ -n "$value" ]] || return 0
    # Word splitting is intentional here: the configuration contract uses a
    # whitespace-separated list and does not permit shell syntax.
    read -r -a PARSED_WORDS <<< "$value"
}

normalize_fqdn() {
    local value=${1:-}
    value=${value%.}
    printf '%s' "${value,,}"
}

file_mode_octal() {
    local path=${1:-}
    if stat -c '%a' "$path" >/dev/null 2>&1; then
        stat -c '%a' "$path"
    else
        stat -f '%Lp' "$path"
    fi
}

file_has_restrictive_mode() {
    local path=${1:-}
    local mode
    [[ -f "$path" && ! -L "$path" ]] || return 1
    mode=$(file_mode_octal "$path") || return 1
    # Group and other permission digits must be zero.  Owner read/write or
    # owner read-only are both safe for the local environment file.
    [[ "$mode" =~ ^[0-7]+$ ]] || return 1
    local last_two=${mode: -2}
    [[ "$last_two" == 00 ]]
}

file_owner_uid() {
    local path=${1:-}
    if stat -c '%u' "$path" >/dev/null 2>&1; then
        stat -c '%u' "$path"
    else
        stat -f '%u' "$path"
    fi
}

ensure_private_directory() {
    local path=${1:?directory path required}
    local description=${2:-private directory}
    local mode owner

    if [[ -L "$path" || ( -e "$path" && ! -d "$path" ) ]]; then
        log_error "$description must be a real directory, not a symlink or another file: $path"
        return 1
    fi
    if [[ ! -e "$path" ]]; then
        install -d -m 0700 -- "$path"
    fi
    owner=$(file_owner_uid "$path") || {
        log_error "cannot determine owner of $description: $path"
        return 1
    }
    [[ "$owner" == 0 ]] || {
        log_error "$description must be root-owned: $path"
        return 1
    }
    mode=$(file_mode_octal "$path") || {
        log_error "cannot determine permissions of $description: $path"
        return 1
    }
    if [[ "${mode: -2}" != 00 ]]; then
        log_warn "$description has group/other permissions; tightening it to mode 700: $path"
        chmod 0700 "$path" || {
            log_error "could not restrict permissions on $description: $path"
            return 1
        }
    else
        chmod 0700 "$path"
    fi
}

redact_args() {
    local redact_next=false
    local arg
    local output=()
    for arg in "$@"; do
        if [[ "$redact_next" == true ]]; then
            output+=(REDACTED)
            redact_next=false
            continue
        fi
        case "$arg" in
            --ds-password|--admin-password|-p|-a|--password|--token-password|--api-token|--token|--client-secret|--secret|--master-password|--private-key|--dirsrv-pin|--http-pin|--pkinit-pin)
                output+=("$arg")
                redact_next=true
                ;;
            --ds-password=*|--admin-password=*|--password=*|--token-password=*|--api-token=*|--token=*|--client-secret=*|--secret=*|--master-password=*|--private-key=*|--dirsrv-pin=*|--http-pin=*|--pkinit-pin=*)
                output+=("${arg%%=*}=REDACTED")
                ;;
            *)
                output+=("$arg")
                ;;
        esac
    done
    printf '%q ' "${output[@]}"
}

resource_is_owned_by_current_run() {
    [[ "$1" == created-by-bootstrap || "$1" == modified-by-bootstrap ]]
}

retry_attempt_is_allowed() {
    local attempt=${1:-0}
    local maximum=${2:-0}
    [[ "$attempt" =~ ^[0-9]+$ && "$maximum" =~ ^[0-9]+$ ]] || return 1
    (( attempt < maximum ))
}

atomic_replace_file() {
    local source=${1:?source path required}
    local target=${2:?target path required}
    local mode=''
    local owner=''
    local group=''

    [[ -f "$source" ]] || return 1
    if [[ -e "$target" ]]; then
        mode=$(stat -c '%a' "$target" 2>/dev/null || stat -f '%Lp' "$target")
        owner=$(stat -c '%u' "$target" 2>/dev/null || stat -f '%u' "$target")
        group=$(stat -c '%g' "$target" 2>/dev/null || stat -f '%g' "$target")
    fi
    mv -f -- "$source" "$target" || return 1
    [[ -n "$mode" ]] && chmod "$mode" "$target"
    if [[ -n "$owner" && -n "$group" && "$(id -u)" -eq 0 ]]; then
        chown "$owner:$group" "$target" 2>/dev/null || true
    fi
}

run_with_log() {
    local output_file=${1:?output file required}
    shift
    RUN_COMMAND_EXTRA_LOG_FILE=$output_file run_command "$@"
}

