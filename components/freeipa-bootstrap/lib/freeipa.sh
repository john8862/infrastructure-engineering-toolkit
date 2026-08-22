#!/usr/bin/env bash

: "${FREEIPA_STATE:=unknown}"
: "${FREEIPA_PREEXISTING:=unknown}"
: "${IPA_INSTALL_HELP:=}"
: "${IPA_INSTALL_LOG:=/var/log/ipaserver-install.log}"
: "${IPA_REPLICA_INSTALL_LOG:=/var/log/ipareplica-install.log}"
: "${KRA_STATUS:=not-requested}"
: "${CA_STATUS:=not-requested}"
: "${FREEIPA_INSTALLED_ROLE:=unknown}"
FREEIPA_INSTALL_UMASK=022

freeipa_detect_state() {
    if command_exists ipactl && ipactl status >/dev/null 2>&1; then
        FREEIPA_STATE=healthy
    elif [[ -e /etc/ipa/default.conf || -e /var/lib/ipa/sysrestore/sysrestore.state ]] || compgen -G '/etc/dirsrv/slapd-*' >/dev/null 2>&1; then
        FREEIPA_STATE=partial
    else
        FREEIPA_STATE=absent
    fi
    if [[ "${FREEIPA_PREEXISTING:-unknown}" == unknown ]]; then
        FREEIPA_PREEXISTING=$FREEIPA_STATE
    fi
    log_info "FreeIPA discovery: $FREEIPA_STATE"
}

freeipa_prepare_credentials() {
    if ! is_install; then
        return 0
    fi
    IPA_CREDENTIALS_DIR=$(mktemp -d)
    chmod 0700 "$IPA_CREDENTIALS_DIR"
    IPA_KRB_CACHE=$(mktemp "$IPA_CREDENTIALS_DIR/krb5cc.XXXXXX")
    chmod 0600 "$IPA_KRB_CACHE"
    export KRB5CCNAME="FILE:$IPA_KRB_CACHE"
}

freeipa_ca_enabled() {
    if [[ "${IPA_SERVER_ROLE:-primary}" == replica ]]; then
        [[ "${IPA_REPLICA_SETUP_CA:-true}" == true ]]
    else
        [[ "${IPA_SETUP_CA:-true}" == true ]]
    fi
}

freeipa_role_marker_path() {
    printf '%s/deployment-role.env' "${IPA_STATE_DIR:-/var/lib/freeipa-bootstrap}"
}

freeipa_read_role_marker() {
    local marker value decoded
    marker=$(freeipa_role_marker_path)
    [[ -f "$marker" && ! -L "$marker" ]] || return 1
    value=$(awk -F= '$1 == "IPA_SERVER_ROLE" { value=$0; sub(/^[^=]*=/, "", value) } END { if (value != "") print value }' "$marker")
    [[ -n "$value" ]] || return 1
    printf -v decoded '%b' "$value"
    [[ "$decoded" == primary || "$decoded" == replica ]] || return 1
    printf '%s' "$decoded"
}

freeipa_detect_existing_role() {
    FREEIPA_INSTALLED_ROLE=unknown
    [[ "${FREEIPA_STATE:-unknown}" == healthy ]] || return 0
    local marker_role
    marker_role=$(freeipa_read_role_marker 2>/dev/null || true)
    if [[ -n "$marker_role" ]]; then
        FREEIPA_INSTALLED_ROLE=$marker_role
        return 0
    fi

    # The initial server is the only healthy server with no topology segment.
    # A host participating in a segment could be either the initial server or
    # a replica, so an unmarked multi-server installation is deliberately
    # treated as ambiguous rather than converted by configuration drift.
    if command_exists ipa; then
        local topology_output
        if topology_output=$(ipa topologysegment-find 2>/dev/null); then
            if grep -Eqi 'number of entries returned[[:space:]]+0|0[[:space:]]+topology segment|no entries' <<< "$topology_output"; then
                FREEIPA_INSTALLED_ROLE=primary
            else
                FREEIPA_INSTALLED_ROLE=unknown
            fi
        fi
    fi
}

freeipa_validate_existing_role() {
    freeipa_detect_existing_role
    if [[ "$FREEIPA_INSTALLED_ROLE" == unknown ]]; then
        if [[ "${IPA_SERVER_ROLE:-primary}" == replica ]]; then
            log_error "healthy FreeIPA role is ambiguous; refusing to run ipa-replica-install or convert an existing server without the bootstrap role marker $(freeipa_role_marker_path)"
            return 1
        fi
        log_warn "healthy FreeIPA role marker is absent or ambiguous; preserving the existing server and refusing any role conversion"
        return 0
    fi
    if [[ "$FREEIPA_INSTALLED_ROLE" != "${IPA_SERVER_ROLE:-primary}" ]]; then
        log_error "configured IPA_SERVER_ROLE=${IPA_SERVER_ROLE:-primary} conflicts with the installed FreeIPA role $FREEIPA_INSTALLED_ROLE; role conversion is not automated"
        return 1
    fi
    log_info "existing FreeIPA role matches IPA_SERVER_ROLE=$IPA_SERVER_ROLE"
}

freeipa_persist_role() {
    is_install || return 0
    local marker temporary
    marker=$(freeipa_role_marker_path)
    ensure_private_directory "$(dirname "$marker")" 'FreeIPA topology state directory' || return 1
    if [[ -e "$marker" ]]; then
        local existing
        existing=$(freeipa_read_role_marker 2>/dev/null || true)
        [[ "$existing" == "${IPA_SERVER_ROLE:-primary}" ]] || {
            log_error "refusing to overwrite an existing conflicting FreeIPA topology role marker: $marker"
            return 1
        }
        return 0
    fi
    temporary=$(mktemp "$(dirname "$marker")/.deployment-role.XXXXXX")
    chmod 0600 "$temporary"
    printf 'IPA_SERVER_ROLE=%q\n' "${IPA_SERVER_ROLE:-primary}" > "$temporary"
    atomic_replace_file "$temporary" "$marker"
    chmod 0600 "$marker"
    state_set IPA_SERVER_ROLE "${IPA_SERVER_ROLE:-primary}"
    state_mark_resource freeipa-topology-role created-by-bootstrap
}

freeipa_validate_replica_source() {
    [[ "${IPA_SERVER_ROLE:-primary}" == replica ]] || return 0
    if is_dry_run || is_check; then
        plan "validate that IPA_REPLICA_SOURCE resolves, matches the configured domain/realm through the supported replica connection check, and is reachable before ipa-replica-install"
        return 0
    fi
    command_exists ipa-replica-conncheck || {
        log_error "ipa-replica-conncheck is unavailable; refusing to install a replica without the platform connection check"
        return 1
    }
    local conncheck_help
    conncheck_help=$(ipa-replica-conncheck --help 2>&1 || true)
    local required
    for required in --master --auto-master-check --realm --hostname --principal --password; do
        grep -Eq -- "$required" <<< "$conncheck_help" || {
            log_error "installed ipa-replica-conncheck does not advertise required option $required; refusing to guess source validation syntax"
            return 1
        }
    done
    local -a args=(ipa-replica-conncheck
        "--master=$IPA_REPLICA_SOURCE"
        --auto-master-check
        "--realm=$IPA_REALM"
        "--hostname=$IPA_HOSTNAME"
        "--principal=$IPA_REPLICA_PRINCIPAL"
        "--password=${IPA_ADMIN_PASSWORD:-REDACTED}")
    run_command "${args[@]}"
}

freeipa_install_help_contains() {
    grep -Eq -- "$1" <<< "$IPA_INSTALL_HELP"
}

freeipa_validate_replica_installer_options() {
    if ! command_exists ipa-replica-install; then
        if is_dry_run; then
            IPA_INSTALL_HELP='--unattended --hostname --ip-address --server --domain --realm --principal --admin-password --no-ntp --setup-ca --dirsrv-cert-file --http-cert-file --ca-cert-file --dirsrv-pin --http-pin --pkinit-cert-file --pkinit-pin --no-pkinit --ssh-trust-dns --subid'
            return 0
        fi
        log_error "ipa-replica-install is unavailable after FreeIPA package preparation"
        return 1
    fi
    IPA_INSTALL_HELP=$(ipa-replica-install --help 2>&1 || true)
    local required
    for required in --unattended --hostname --ip-address --server --domain --realm --principal --admin-password --no-ntp; do
        freeipa_install_help_contains "$required" || {
            log_error "installed ipa-replica-install does not advertise required option $required; refusing to guess version-specific syntax"
            return 1
        }
    done
    if [[ "${IPA_REPLICA_SETUP_CA:-true}" == true ]]; then
        freeipa_install_help_contains --setup-ca || {
            log_error "IPA_REPLICA_SETUP_CA=true but installed ipa-replica-install does not advertise --setup-ca"
            return 1
        }
    else
        for required in --dirsrv-cert-file --http-cert-file; do
            freeipa_install_help_contains "$required" || {
                log_error "CA-less replica installation requires ipa-replica-install option $required"
                return 1
            }
        done
        if [[ -n "${IPA_CA_CERT_FILES:-}" ]]; then
            freeipa_install_help_contains --ca-cert-file || {
                log_error "IPA_CA_CERT_FILES is configured but ipa-replica-install does not advertise --ca-cert-file"
                return 1
            }
        fi
        if [[ -n "${IPA_PKINIT_CERT_FILES:-}" ]]; then
            freeipa_install_help_contains --pkinit-cert-file || {
                log_error "IPA_PKINIT_CERT_FILES is configured but ipa-replica-install does not advertise --pkinit-cert-file"
                return 1
            }
        else
            freeipa_install_help_contains --no-pkinit || {
                log_error "CA-less replica installation requires --no-pkinit or configured PKINIT certificates"
                return 1
            }
        fi
    fi
    if [[ "${IPA_DNS_MODE:-external}" == integrated ]]; then
        for required in --setup-dns --forwarder --no-forwarders --no-reverse; do
            freeipa_install_help_contains "$required" || {
                log_error "installed ipa-replica-install does not advertise required integrated-DNS option $required"
                return 1
            }
        done
    fi
    if [[ "${IPA_SSH_TRUST_DNS:-false}" == true ]]; then
        freeipa_install_help_contains --ssh-trust-dns || {
            log_error "IPA_SSH_TRUST_DNS=true but installed ipa-replica-install does not advertise --ssh-trust-dns"
            return 1
        }
    fi
    if [[ "${IPA_SETUP_SUBID:-false}" == true ]]; then
        freeipa_install_help_contains --subid || {
            log_error "IPA_SETUP_SUBID=true but installed ipa-replica-install does not advertise --subid"
            return 1
        }
    fi
}

freeipa_validate_installer_options() {
    if [[ "${IPA_SERVER_ROLE:-primary}" == replica ]]; then
        freeipa_validate_replica_installer_options
        return $?
    fi
    if ! command_exists ipa-server-install; then
        if is_dry_run; then
            IPA_INSTALL_HELP='--unattended --realm --hostname --ip-address --ds-password --admin-password --no-ntp --domain --setup-dns --forwarder --no-forwarders --no-reverse --dirsrv-cert-file --http-cert-file --ca-cert-file --dirsrv-pin --http-pin --pkinit-cert-file --pkinit-pin --ssh-trust-dns --subid'
            return 0
        fi
        log_error "ipa-server-install is unavailable after FreeIPA package preparation"
        return 1
    fi
    IPA_INSTALL_HELP=$(ipa-server-install --help 2>&1 || true)
    local required
    for required in --unattended --realm --hostname --ip-address --ds-password --admin-password --no-ntp; do
        freeipa_install_help_contains "$required" || {
            log_error "installed ipa-server-install does not advertise required option $required; refusing to guess version-specific syntax"
            return 1
        }
    done
    if [[ "$IPA_DNS_MODE" == integrated ]]; then
        for required in --setup-dns --forwarder --no-forwarders --no-reverse; do
            freeipa_install_help_contains "$required" || {
                log_error "installed ipa-server-install does not advertise required integrated-DNS option $required"
                return 1
            }
        done
    fi
    if [[ "$IPA_SETUP_CA" == false ]]; then
        for required in --dirsrv-cert-file --http-cert-file; do
            freeipa_install_help_contains "$required" || {
                log_error "IPA_SETUP_CA=false requires ipa-server-install option $required for CA-less installation"
                return 1
            }
        done
        if [[ -n "$IPA_CA_CERT_FILES" ]]; then
            freeipa_install_help_contains --ca-cert-file || {
                log_error "IPA_CA_CERT_FILES is configured but ipa-server-install does not advertise --ca-cert-file"
                return 1
            }
        fi
        if [[ -n "$IPA_DIRSRV_CERT_PIN" ]]; then
            freeipa_install_help_contains --dirsrv-pin || {
                log_error "IPA_DIRSRV_CERT_PIN is configured but ipa-server-install does not advertise --dirsrv-pin"
                return 1
            }
        fi
        if [[ -n "$IPA_HTTP_CERT_PIN" ]]; then
            freeipa_install_help_contains --http-pin || {
                log_error "IPA_HTTP_CERT_PIN is configured but ipa-server-install does not advertise --http-pin"
                return 1
            }
        fi
        if [[ -n "$IPA_PKINIT_CERT_FILES" ]]; then
            freeipa_install_help_contains --pkinit-cert-file || {
                log_error "IPA_PKINIT_CERT_FILES is configured but ipa-server-install does not advertise --pkinit-cert-file"
                return 1
            }
        fi
        if [[ -n "$IPA_PKINIT_CERT_PIN" ]]; then
            freeipa_install_help_contains --pkinit-pin || {
                log_error "IPA_PKINIT_CERT_PIN is configured but ipa-server-install does not advertise --pkinit-pin"
                return 1
            }
        fi
    fi
    if [[ "$IPA_SSH_TRUST_DNS" == true ]]; then
        freeipa_install_help_contains --ssh-trust-dns || {
            log_error "IPA_SSH_TRUST_DNS=true but installed ipa-server-install does not advertise --ssh-trust-dns"
            return 1
        }
    fi
    if [[ "$IPA_SETUP_SUBID" == true ]]; then
        freeipa_install_help_contains --subid || {
            log_error "IPA_SETUP_SUBID=true but installed ipa-server-install does not advertise --subid"
            return 1
        }
    fi
}

freeipa_build_replica_install_args() {
    freeipa_validate_replica_installer_options || return 1
    IPA_INSTALL_ARGS=(
        ipa-replica-install
        --unattended
        "--hostname=$IPA_HOSTNAME"
        "--realm=$IPA_REALM"
        "--domain=$IPA_DOMAIN"
        "--ip-address=$IPA_IP_ADDRESS"
        "--server=$IPA_REPLICA_SOURCE"
        "--principal=$IPA_REPLICA_PRINCIPAL"
        "--admin-password=${IPA_ADMIN_PASSWORD:-REDACTED}"
        --no-ntp
    )
    [[ "${IPA_SSH_TRUST_DNS:-false}" == true ]] && IPA_INSTALL_ARGS+=(--ssh-trust-dns)
    [[ "${IPA_SETUP_SUBID:-false}" == true ]] && IPA_INSTALL_ARGS+=(--subid)

    if [[ "${IPA_REPLICA_SETUP_CA:-true}" == true ]]; then
        IPA_INSTALL_ARGS+=(--setup-ca)
    else
        local certificate_file
        parse_space_list "$IPA_DIRSRV_CERT_FILES"
        for certificate_file in "${PARSED_WORDS[@]}"; do
            IPA_INSTALL_ARGS+=("--dirsrv-cert-file=$certificate_file")
        done
        parse_space_list "$IPA_HTTP_CERT_FILES"
        for certificate_file in "${PARSED_WORDS[@]}"; do
            IPA_INSTALL_ARGS+=("--http-cert-file=$certificate_file")
        done
        parse_space_list "${IPA_CA_CERT_FILES:-}"
        for certificate_file in "${PARSED_WORDS[@]}"; do
            IPA_INSTALL_ARGS+=("--ca-cert-file=$certificate_file")
        done
        [[ -z "${IPA_DIRSRV_CERT_PIN:-}" ]] || IPA_INSTALL_ARGS+=("--dirsrv-pin=$IPA_DIRSRV_CERT_PIN")
        [[ -z "${IPA_HTTP_CERT_PIN:-}" ]] || IPA_INSTALL_ARGS+=("--http-pin=$IPA_HTTP_CERT_PIN")
        if [[ -n "${IPA_PKINIT_CERT_FILES:-}" ]]; then
            parse_space_list "$IPA_PKINIT_CERT_FILES"
            for certificate_file in "${PARSED_WORDS[@]}"; do
                IPA_INSTALL_ARGS+=("--pkinit-cert-file=$certificate_file")
            done
            [[ -z "${IPA_PKINIT_CERT_PIN:-}" ]] || IPA_INSTALL_ARGS+=("--pkinit-pin=$IPA_PKINIT_CERT_PIN")
        else
            IPA_INSTALL_ARGS+=(--no-pkinit)
        fi
    fi

    if [[ "${IPA_DNS_MODE:-external}" == integrated ]]; then
        IPA_INSTALL_ARGS+=(--setup-dns --no-reverse)
        parse_space_list "$DNS_FORWARDERS"
        if (( ${#PARSED_WORDS[@]} == 0 )); then
            IPA_INSTALL_ARGS+=(--no-forwarders)
        else
            local forwarder
            for forwarder in "${PARSED_WORDS[@]}"; do
                IPA_INSTALL_ARGS+=("--forwarder=$forwarder")
            done
        fi
    fi
}

freeipa_build_install_args() {
    if [[ "${IPA_SERVER_ROLE:-primary}" == replica ]]; then
        freeipa_build_replica_install_args
        return $?
    fi
    freeipa_validate_installer_options || return 1
    IPA_INSTALL_ARGS=(
        ipa-server-install
        --unattended
        "--hostname=$IPA_HOSTNAME"
        "--realm=$IPA_REALM"
        "--ip-address=$IPA_IP_ADDRESS"
        "--ds-password=${IPA_DIRECTORY_MANAGER_PASSWORD:-REDACTED}"
        "--admin-password=${IPA_ADMIN_PASSWORD:-REDACTED}"
        --no-ntp
    )
    if freeipa_install_help_contains --domain; then
        IPA_INSTALL_ARGS+=("--domain=$IPA_DOMAIN")
    elif freeipa_install_help_contains '(^|[[:space:]])-n([,[:space:]])'; then
        IPA_INSTALL_ARGS+=(-n "$IPA_DOMAIN")
    else
        log_error "installed ipa-server-install exposes neither --domain nor -n; refusing to infer the domain option"
        return 1
    fi

    [[ "$IPA_SSH_TRUST_DNS" == true ]] && IPA_INSTALL_ARGS+=(--ssh-trust-dns)
    [[ "$IPA_SETUP_SUBID" == true ]] && IPA_INSTALL_ARGS+=(--subid)

    if [[ "$IPA_SETUP_CA" == false ]]; then
        local certificate_file
        parse_space_list "$IPA_DIRSRV_CERT_FILES"
        for certificate_file in "${PARSED_WORDS[@]}"; do
            IPA_INSTALL_ARGS+=( "--dirsrv-cert-file=$certificate_file" )
        done
        parse_space_list "$IPA_HTTP_CERT_FILES"
        for certificate_file in "${PARSED_WORDS[@]}"; do
            IPA_INSTALL_ARGS+=( "--http-cert-file=$certificate_file" )
        done
        parse_space_list "$IPA_CA_CERT_FILES"
        for certificate_file in "${PARSED_WORDS[@]}"; do
            IPA_INSTALL_ARGS+=( "--ca-cert-file=$certificate_file" )
        done
        parse_space_list "$IPA_PKINIT_CERT_FILES"
        for certificate_file in "${PARSED_WORDS[@]}"; do
            IPA_INSTALL_ARGS+=( "--pkinit-cert-file=$certificate_file" )
        done
        [[ -z "$IPA_DIRSRV_CERT_PIN" ]] || IPA_INSTALL_ARGS+=( "--dirsrv-pin=$IPA_DIRSRV_CERT_PIN" )
        [[ -z "$IPA_HTTP_CERT_PIN" ]] || IPA_INSTALL_ARGS+=( "--http-pin=$IPA_HTTP_CERT_PIN" )
        [[ -z "$IPA_PKINIT_CERT_PIN" ]] || IPA_INSTALL_ARGS+=( "--pkinit-pin=$IPA_PKINIT_CERT_PIN" )
    fi

    if [[ "$IPA_DNS_MODE" == integrated ]]; then
        IPA_INSTALL_ARGS+=(--setup-dns --no-reverse)
        parse_space_list "$DNS_FORWARDERS"
        if (( ${#PARSED_WORDS[@]} == 0 )); then
            IPA_INSTALL_ARGS+=(--no-forwarders)
        else
            local forwarder
            for forwarder in "${PARSED_WORDS[@]}"; do
                IPA_INSTALL_ARGS+=("--forwarder=$forwarder")
            done
        fi
    fi
}

freeipa_find_installer_record_file() {
    local candidate newest='' marker=''
    if [[ -n "${STATE_FILE:-}" ]]; then
        marker=$(state_get IPA_RECORD_MARKER '')
    fi
    for candidate in /tmp/ipa.system.records.*.db; do
        [[ -f "$candidate" && ! -L "$candidate" ]] || continue
        if [[ -n "$marker" && ! "$candidate" -nt "$marker" ]]; then
            continue
        fi
        if [[ -z "$newest" || "$candidate" -nt "$newest" ]]; then
            newest=$candidate
        fi
    done
    printf '%s' "$newest"
}

freeipa_generate_external_dns_records() {
    command_exists ipa || {
        log_error "the installed ipa CLI is required to generate the supported external-DNS record output"
        return 1
    }
    [[ -n "${STATE_RUN_DIR:-}" && -d "$STATE_RUN_DIR" ]] || {
        log_error "the current bootstrap state run directory is required to capture FreeIPA DNS records"
        return 1
    }

    local nsupdate_file="$STATE_RUN_DIR/ipa-system-records-${RUN_ID}.nsupdate"
    local normalized_file="$STATE_RUN_DIR/ipa-system-records-${RUN_ID}.db"
    [[ ! -e "$nsupdate_file" && ! -L "$nsupdate_file" ]] || {
        log_error "refusing to overwrite the captured FreeIPA nsupdate file: $nsupdate_file"
        return 1
    }
    [[ ! -e "$normalized_file" && ! -L "$normalized_file" ]] || {
        log_error "refusing to overwrite the normalized FreeIPA DNS record file: $normalized_file"
        return 1
    }

    log_info "capturing FreeIPA external-DNS records with ipa dns-update-system-records --dry-run"
    run_command ipa dns-update-system-records --dry-run --out "$nsupdate_file" || return $?
    [[ -f "$nsupdate_file" && ! -L "$nsupdate_file" && -s "$nsupdate_file" ]] || {
        log_error "ipa dns-update-system-records did not create a non-empty nsupdate file"
        return 1
    }
    chmod 0600 "$nsupdate_file"

    # RHEL's supported command emits an nsupdate transaction, not a zone-file
    # record list.  Keep only update-add statements and normalize them to the
    # provider contract consumed by BIND and the read-only DNS validators.
    {
        printf '# Normalized from ipa dns-update-system-records --dry-run --out %s\n' "$nsupdate_file"
        awk '
            $1 == "zone" && NF >= 2 { zone=$2; next }
            $1 == "update" && $2 == "add" && NF >= 7 {
                name=$3
                if (name == "@" && zone != "") name=zone
                ttl=$4
                class=$5
                type=$6
                if (ttl !~ /^[0-9]+$/ || class != "IN") next
                if (type !~ /^(A|AAAA|CNAME|PTR|SRV|TXT|URI)$/) next
                printf "%s %s %s %s", name, ttl, class, type
                for (i=7; i<=NF; i++) printf " %s", $i
                printf "\n"
            }
        ' "$nsupdate_file"
    } > "$normalized_file"
    chmod 0640 "$normalized_file"
    if ! awk 'NF >= 5 && $1 !~ /^#/ { found=1 } END { exit(found ? 0 : 1) }' "$normalized_file"; then
        log_error "the supported FreeIPA DNS output contained no usable update-add records"
        return 1
    fi
    state_set IPA_RECORD_NSUPDATE_FILE "$nsupdate_file"
    printf '%s' "$normalized_file"
}

freeipa_run_install_attempt() {
    local attempt=$1
    local installer_name=${IPA_INSTALL_ARGS[0]:-ipa-server-install}
    local attempt_log="$STATE_RUN_DIR/${installer_name##*/}-attempt-${attempt}.log"
    state_set INSTALL_ATTEMPT "$attempt"
    state_set INSTALL_STARTED true
    : > "$attempt_log"
    chmod 0600 "$attempt_log"
    log_info "running $installer_name attempt $attempt with password-bearing arguments redacted from logs"
    if RUN_COMMAND_EXTRA_LOG_FILE="$attempt_log" run_command_with_umask "$FREEIPA_INSTALL_UMASK" "${IPA_INSTALL_ARGS[@]}"; then
        log_info "$installer_name attempt $attempt completed"
        state_set INSTALL_COMPLETED true
        state_set IPA_INSTALL_ATTEMPT_LOG "$attempt_log"
        return 0
    else
        local rc=$?
        state_set IPA_INSTALL_ATTEMPT_LOG "$attempt_log"
        state_set INSTALL_COMPLETED false
        local installer_log=$IPA_INSTALL_LOG
        [[ "$installer_name" == ipa-replica-install ]] && installer_log=$IPA_REPLICA_INSTALL_LOG
        log_error "$installer_name attempt $attempt failed with exit code $rc; installer log: $installer_log; captured output: $attempt_log"
        return "$rc"
    fi
}

freeipa_uninstall_current_run_partial() {
    [[ "$FREEIPA_PREEXISTING" == absent ]] || {
        log_error "automatic FreeIPA uninstall blocked because the installation was not absent at bootstrap start"
        return 1
    }
    freeipa_detect_state
    [[ "$FREEIPA_STATE" == partial ]] || {
        log_info "no partial FreeIPA configuration remains; supported uninstall is not required"
        return 0
    }
    command_exists ipa-server-install || {
        log_error "ipa-server-install is unavailable; refusing filesystem cleanup"
        return 1
    }
    local uninstall_help
    uninstall_help=$(ipa-server-install --help 2>&1 || true)
    grep -Eq -- --uninstall <<< "$uninstall_help" || {
        log_error "ipa-server-install does not advertise --uninstall; refusing filesystem cleanup"
        return 1
    }
    local -a uninstall_args=(ipa-server-install --uninstall)
    if grep -Eq -- --unattended <<< "$uninstall_help"; then
        uninstall_args+=(--unattended)
    else
        log_error "ipa-server-install uninstall cannot be made unattended on this version; manual cleanup is required before retry"
        return 1
    fi
    local uninstall_log="$STATE_RUN_DIR/ipa-server-uninstall.log"
    umask 077
    : > "$uninstall_log"
    chmod 0600 "$uninstall_log"
    log_info "removing only the partial FreeIPA configuration created by this run using the supported uninstall command"
    RUN_COMMAND_EXTRA_LOG_FILE="$uninstall_log" run_command_with_umask "$FREEIPA_INSTALL_UMASK" "${uninstall_args[@]}"
    state_set AUTO_UNINSTALL_PERFORMED true
    freeipa_detect_state
    [[ "$FREEIPA_STATE" == absent ]] || {
        log_error "supported FreeIPA uninstall did not leave a clean system; automatic retry is blocked"
        return 1
    }
}

freeipa_install_with_retry() {
    log_stage freeipa-install
    freeipa_build_install_args || return 1
    local attempt
    local rc
    for (( attempt=1; attempt<=IPA_INSTALL_MAX_ATTEMPTS; attempt++ )); do
        local record_marker="$STATE_RUN_DIR/ipa-records-before-attempt-${attempt}"
        : > "$record_marker"
        chmod 0600 "$record_marker"
        state_set IPA_RECORD_MARKER "$record_marker"
        if freeipa_run_install_attempt "$attempt"; then
            freeipa_detect_state
            if [[ "$FREEIPA_STATE" == healthy ]]; then
                freeipa_persist_role || return 1
                return 0
            fi
            rc=1
            log_error "ipa-server-install returned success but FreeIPA is not healthy; treating as failed installation"
        else
            rc=$?
        fi

        freeipa_detect_state
        if [[ "$FREEIPA_PREEXISTING" != absent ]]; then
            log_error "FreeIPA was present before this bootstrap run; automatic uninstall/retry is forbidden"
            return "$rc"
        fi
        if [[ "$FREEIPA_STATE" != partial ]]; then
            log_error "FreeIPA failed without a current-run partial configuration that can be safely removed"
            return "$rc"
        fi
        if ! retry_attempt_is_allowed "$attempt" "$IPA_INSTALL_MAX_ATTEMPTS"; then
            log_error "FreeIPA installation failed after $attempt attempt(s); manual remediation is required"
            return "$rc"
        fi
        log_warn "current-run partial FreeIPA configuration detected; supported uninstall will run before retry $((attempt + 1))"
        freeipa_uninstall_current_run_partial || return 1
    done
    return 1
}

freeipa_authenticate_admin() {
    if is_dry_run || is_check; then
        plan "obtain a root-only Kerberos credential cache for admin validation"
        return 0
    fi
    [[ -n "${IPA_KRB_CACHE:-}" ]] || freeipa_prepare_credentials
    local principal=admin
    if [[ "${IPA_SERVER_ROLE:-primary}" == replica ]]; then
        principal=${IPA_REPLICA_PRINCIPAL:-admin}
    fi
    run_command kinit "$principal" <<< "$IPA_ADMIN_PASSWORD"
}

freeipa_ca_is_configured() {
    command_exists ipa || return 1
    ipa ca-show ipa >/dev/null 2>&1
}

freeipa_ensure_ca() {
    log_stage ca
    if ! freeipa_ca_enabled; then
        CA_STATUS=not-requested
        if is_dry_run || is_check; then
            plan "skip the integrated Dogtag CA for this server and use the configured CA-less certificate inputs"
            return 0
        fi
        if freeipa_ca_is_configured; then
            CA_STATUS=preserved
            log_warn "integrated CA setup is disabled for this server; an existing IPA CA was detected and will be preserved"
        else
            log_info "integrated IPA CA setup is disabled; CA-less mode is active"
        fi
        return 0
    fi

    if is_dry_run || is_check; then
        CA_STATUS=planned
        plan "validate an existing integrated IPA CA and skip any separate CA installer; a new server uses ipa-server-install's default integrated CA"
        return 0
    fi

    if freeipa_ca_is_configured; then
        CA_STATUS=installed
        state_set CA_CONFIGURED true
        log_info "integrated IPA CA is already configured and healthy; skipping CA installation"
        return 0
    fi

    if [[ "${FREEIPA_PREEXISTING:-unknown}" == healthy ]]; then
        log_error "integrated CA setup was requested but the pre-existing FreeIPA server has no usable IPA CA; this bootstrap will not convert a CA-less server in place"
        return 1
    fi
    log_error "ipa-server-install completed without a usable integrated IPA CA; review the installer log before retrying"
    return 1
}

freeipa_kra_is_configured() {
    command_exists ipa || return 1
    ipa vaultconfig-show >/dev/null 2>&1
}

freeipa_install_kra() {
    if [[ "$IPA_SETUP_KRA" == false ]]; then
        KRA_STATUS=not-requested
        log_info "KRA installation disabled (IPA_SETUP_KRA=false)"
        return 0
    fi
    if ! freeipa_ca_enabled; then
        log_error "IPA_SETUP_KRA=true requires an integrated CA on this server because KRA depends on the IPA CA"
        return 1
    fi
    log_stage kra
    if is_dry_run || is_check; then
        plan "check whether KRA is already configured; run ipa-kra-install only when KRA is absent"
        KRA_STATUS=planned
        return 0
    fi
    if freeipa_kra_is_configured; then
        KRA_STATUS=installed
        state_set KRA_CONFIGURED true
        log_info "KRA is already configured and healthy; skipping ipa-kra-install"
        return 0
    fi
    command_exists ipa-kra-install || {
        log_error "IPA_SETUP_KRA=true but ipa-kra-install is unavailable after package installation"
        return 1
    }
    local kra_help
    kra_help=$(ipa-kra-install --help 2>&1 || true)
    grep -Eq -- '(^|[[:space:]])(-p|--password)' <<< "$kra_help" || {
        log_error "installed ipa-kra-install does not advertise a Directory Manager password option; refusing to guess"
        return 1
    }
    local -a args=(ipa-kra-install -p "$IPA_DIRECTORY_MANAGER_PASSWORD")
    if grep -Eq -- '(^|[[:space:]])(-U|--unattended)' <<< "$kra_help"; then
        args+=(-U)
    fi
    local kra_log="$STATE_RUN_DIR/ipa-kra-install.log"
    : > "$kra_log"
    chmod 0600 "$kra_log"
    log_info "running ipa-kra-install with password arguments redacted from logs"
    RUN_COMMAND_EXTRA_LOG_FILE="$kra_log" run_command_with_umask "$FREEIPA_INSTALL_UMASK" "${args[@]}"
    KRA_STATUS=installed
    state_set KRA_CONFIGURED true
}

freeipa_configure_directory_defaults() {
    log_stage freeipa-defaults
    if is_dry_run || is_check; then
        plan "set future FreeIPA user defaults: shell=$IPA_DEFAULT_SHELL, home-root=$IPA_HOME_ROOT"
        return 0
    fi
    local current_config current_shell current_home
    current_config=$(ipa config-show 2>&1) || {
        log_error "could not read the current FreeIPA directory defaults"
        return 1
    }
    current_shell=$(awk -F': ' '{ key=$1; sub(/^[[:space:]]+/, "", key); if (key == "Default shell") { print $2; exit } }' <<< "$current_config")
    current_home=$(awk -F': ' '{ key=$1; sub(/^[[:space:]]+/, "", key); if (key == "Home directory base") { print $2; exit } }' <<< "$current_config")
    if [[ "$current_shell" == "$IPA_DEFAULT_SHELL" && "$current_home" == "$IPA_HOME_ROOT" ]]; then
        log_info "FreeIPA directory defaults already match; no modification is needed"
        state_set FREEIPA_DEFAULTS_CONFIGURED true
        return 0
    fi
    local -a args=(ipa config-mod --defaultshell "$IPA_DEFAULT_SHELL" --homedirectory "$IPA_HOME_ROOT")
    run_command "${args[@]}" || return $?
    state_set FREEIPA_DEFAULTS_CONFIGURED true
}

freeipa_configure_server_mkhomedir() {
    if [[ "$CONFIGURE_SERVER_MKHOMEDIR" == false ]]; then
        log_info "server mkhomedir configuration disabled; no PAM/SSSD login behavior will be changed"
        return 0
    fi
    log_stage server-mkhomedir
    if is_dry_run || is_check; then
        plan "enable authselect with-mkhomedir and enable oddjobd for local IPA-user logins"
        return 0
    fi
    command_exists authselect || {
        log_error "CONFIGURE_SERVER_MKHOMEDIR=true requires authselect"
        return 1
    }
    if ! authselect current -r 2>/dev/null | grep -qw with-mkhomedir; then
        run_command authselect enable-feature with-mkhomedir
    fi
    run_command systemctl enable --now oddjobd
    state_set SERVER_MKHOMEDIR_CONFIGURED true
}

