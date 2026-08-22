#!/usr/bin/env bash

VALIDATION_FAILURES=()

validation_check() {
    local label=$1
    shift
    if "$@" >/dev/null 2>&1; then
        log_info "validation passed: $label"
    else
        VALIDATION_FAILURES+=("$label")
        log_error "validation failed: $label"
    fi
}
validate_freeipa_services() {
    command_exists ipactl || return 1
    ipactl status >/dev/null 2>&1
}

validate_freeipa_cli() {
    command_exists ipa || return 1
    ipa ping >/dev/null 2>&1
}

validate_kerberos() {
    command_exists kinit && command_exists klist || return 1
    kdestroy >/dev/null 2>&1 || true
    local principal=admin
    if [[ "${IPA_SERVER_ROLE:-primary}" == replica ]]; then
        principal=${IPA_REPLICA_PRINCIPAL:-admin}
    fi
    printf '%s\n' "$IPA_ADMIN_PASSWORD" | kinit "$principal" >/dev/null 2>&1
    klist -s
}

validate_ldap() {
    ipa server-show "$IPA_HOSTNAME" >/dev/null 2>&1
}

validate_ca() {
    freeipa_ca_enabled || return 0
    ipa ca-show ipa >/dev/null 2>&1
}

validate_replica_topology() {
    [[ "${IPA_SERVER_ROLE:-primary}" == replica ]] || return 0
    command_exists ipa || return 1
    ipa server-show "$IPA_HOSTNAME" >/dev/null 2>&1 || return 1
    ipa server-show "$IPA_REPLICA_SOURCE" >/dev/null 2>&1 || return 1
    local segments
    segments=$(ipa topologysegment-find 2>/dev/null) || return 1
    grep -Fqi "$IPA_HOSTNAME" <<< "$segments" || return 1
    grep -Fqi "$IPA_REPLICA_SOURCE" <<< "$segments"
}

validate_web_ui() {
    [[ -f /etc/ipa/ca.crt ]] || return 1
    command_exists curl || return 1
    curl --fail --silent --show-error --connect-timeout 10 --cacert /etc/ipa/ca.crt \
        "https://$IPA_HOSTNAME/ipa/ui/" -o /dev/null
}

validate_kra() {
    [[ "$IPA_SETUP_KRA" == true ]] || return 0
    freeipa_ca_enabled || return 1
    ipa vaultconfig-show >/dev/null 2>&1
}

validate_integrated_dns() {
    command_exists dig || return 1
    dns_validate_expected_records 127.0.0.1
}

run_full_validation() {
    log_stage validation
    if is_dry_run || is_check; then
        if freeipa_ca_enabled; then
            plan "validate FreeIPA services, CLI, Kerberos, LDAP, integrated CA, Web UI, DNS, NTP, and optional KRA"
        else
            plan "validate FreeIPA services, CLI, Kerberos, LDAP, CA-less Web UI trust, DNS, NTP, and no KRA"
        fi
        return 0
    fi
    VALIDATION_FAILURES=()
    validation_check 'FreeIPA service status' validate_freeipa_services
    validation_check 'FreeIPA CLI operation' validate_freeipa_cli
    validation_check 'administrator Kerberos ticket' validate_kerberos
    validation_check 'LDAP server object' validate_ldap
    if freeipa_ca_enabled; then
        validation_check 'integrated IPA CA' validate_ca
    else
        log_info 'validation skipped: integrated IPA CA is disabled (CA-less mode)'
    fi
    validation_check 'FreeIPA Web UI HTTPS' validate_web_ui
    validation_check 'NTP synchronization' ntp_validate
    if [[ "$IPA_DNS_MODE" == integrated ]]; then
        validation_check 'integrated DNS records' validate_integrated_dns
    elif [[ "${EXTERNAL_DNS_STATUS:-}" == pending ]]; then
        log_warn 'FreeIPA is installed successfully; external DNS publication remains pending and was not treated as a FreeIPA installation failure'
    else
        validation_check 'external DNS provider records' dns_provider_validate
    fi
    if [[ "${IPA_SERVER_ROLE:-primary}" == replica ]]; then
        validation_check 'FreeIPA replica topology and source server' validate_replica_topology
    fi
    if [[ "$IPA_SETUP_KRA" == true ]]; then
        validation_check 'KRA availability' validate_kra
    fi
    if (( ${#VALIDATION_FAILURES[@]} > 0 )); then
        log_error "validation failed for: ${VALIDATION_FAILURES[*]}"
        return 1
    fi
    log_info "all post-install validations passed"
}

print_installation_summary() {
    local status=${1:-installed}
    local reverse_zone
    reverse_zone=$(reverse_zone_for_ipv4 "$IPA_IP_ADDRESS")
    printf '\nFreeIPA bootstrap summary\n'
    printf '%s\n' '-------------------------'
    printf 'status:                 %s\n' "$status"
    printf 'hostname:               %s\n' "$IPA_HOSTNAME"
    printf 'domain:                 %s\n' "$IPA_DOMAIN"
    printf 'realm:                  %s\n' "$IPA_REALM"
    printf 'server IP:              %s\n' "$IPA_IP_ADDRESS"
    printf 'IPA server role:        %s\n' "${IPA_SERVER_ROLE:-primary}"
    if [[ "${IPA_SERVER_ROLE:-primary}" == replica ]]; then
        printf 'replica source:         %s\n' "$IPA_REPLICA_SOURCE"
    fi
    local ca_summary
    case "${CA_STATUS:-not-requested}" in
        installed) ca_summary='integrated Dogtag CA' ;;
        preserved) ca_summary='not requested (existing CA preserved)' ;;
        planned)
            if freeipa_ca_enabled; then
                ca_summary='integrated Dogtag CA (planned)'
            else
                ca_summary='not configured (CA-less mode planned)'
            fi
            ;;
        *)
            if freeipa_ca_enabled; then
                ca_summary='integrated Dogtag CA'
            else
                ca_summary='not configured (CA-less mode)'
            fi
            ;;
    esac
    printf 'CA:                     %s\n' "$ca_summary"
    printf 'KRA:                    %s\n' "$KRA_STATUS"
    printf 'SSH trust DNS (installer): %s\n' "$IPA_SSH_TRUST_DNS"
    printf 'subid (installer):       %s\n' "$IPA_SETUP_SUBID"
    printf 'DNS backend:            %s\n' "${DNS_BACKEND:-${DNS_PROVIDER:-integrated}}"
    printf 'DNS mode:               %s\n' "$IPA_DNS_MODE"
    if [[ "$IPA_DNS_MODE" == external ]]; then
        printf 'DNS provider:           %s\n' "$DNS_PROVIDER"
    else
        printf 'DNS provider:           FreeIPA integrated DNS\n'
    fi
    printf 'DNS server role:        %s\n' "${DNS_SERVER_ROLE:-primary}"
    if [[ "${DNS_SERVER_ROLE:-primary}" == secondary ]]; then
        printf 'DNS primary:            %s (%s)\n' "$(topology_primary_server)" "$(topology_primary_ip)"
    elif [[ -n "$(topology_secondary_server 2>/dev/null || true)" ]]; then
        printf 'DNS secondary:          %s (%s)\n' "$(topology_secondary_server)" "$(topology_secondary_ip)"
    fi
    printf 'forward zone:           %s\n' "$IPA_DOMAIN"
    printf 'reverse zone:           %s\n' "$(dns_reverse_zone_list 2>/dev/null | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
    printf 'DNS forwarders:         %s\n' "${DNS_FORWARDERS:-<none; root hints or provider defaults>}"
    printf 'NTP:                    %s\n' "${NTP_SERVERS:-existing system configuration}"
    printf 'firewall:               %s\n' "${FIREWALL_STATUS:-$FIREWALL_STATE}"
    printf 'server mkhomedir:       %s\n' "$CONFIGURE_SERVER_MKHOMEDIR"
    if [[ "$status" == planned ]]; then
        printf 'validation:              planned\n'
    elif [[ "${EXTERNAL_DNS_STATUS:-}" == pending ]]; then
        printf 'validation:              FreeIPA passed; external DNS publication pending\n'
    else
        printf 'validation:              passed\n'
    fi
    printf 'bootstrap log:          %s\n' "${LOG_FILE:-<not written in check/dry-run>}"
    if [[ -n "${STATE_FILE:-}" ]]; then
        printf 'state file:             %s\n' "$STATE_FILE"
    fi
    if [[ -n "${EXTERNAL_DNS_STATUS:-}" && "${EXTERNAL_DNS_STATUS:-}" != not-applicable ]]; then
        printf 'external DNS status:     %s\n' "$EXTERNAL_DNS_STATUS"
        if [[ -n "${STATE_FILE:-}" ]]; then
            printf 'external records file:   %s\n' "$(state_get EXTERNAL_RECORDS_FILE '<not captured>')"
        fi
    fi
    printf '\n'
}
