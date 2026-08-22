#!/usr/bin/env bash

configure_requested_hostname() {
    log_stage hostname
    if [[ "${MANAGE_HOSTNAME:-$CONFIGURE_HOSTNAME}" == false ]]; then
        log_info "hostname configuration disabled; retaining the existing hostname"
        return 0
    fi
    if is_dry_run || is_check; then
        plan "set hostname to $IPA_HOSTNAME using hostnamectl"
        return 0
    fi
    command_exists hostnamectl || {
        log_error "hostnamectl is required when MANAGE_HOSTNAME=true"
        return 1
    }
    run_command hostnamectl set-hostname "$IPA_HOSTNAME"
    local current
    current=$(hostname --fqdn 2>/dev/null || hostname)
    [[ "${current,,}" == "${IPA_HOSTNAME,,}" ]] || {
        log_error "hostnamectl did not produce the requested FQDN; current hostname is '$current'"
        return 1
    }
    state_mark_resource hostname modified-by-bootstrap
    log_info "hostname configured as $IPA_HOSTNAME"
}
validate_existing_hostname() {
    local current
    current=$(hostname --fqdn 2>/dev/null || hostname 2>/dev/null || true)
    [[ "${current,,}" == "${IPA_HOSTNAME,,}" ]] || {
        log_error "existing FreeIPA hostname is '$current', expected '$IPA_HOSTNAME'; automatic hostname changes are disabled for a pre-existing installation"
        return 1
    }
}
