#!/usr/bin/env bash

dns_provider_check() {
    log_stage dns-existing-check
    command_exists dig || {
        if is_dry_run; then
            plan "install bind-utils so existing DNS records can be checked"
            return 0
        fi
        log_error "existing DNS provider requires dig from bind-utils"
        return 1
    }
    if is_dry_run || is_check; then
        plan "read-only validate existing external DNS prerequisites; FreeIPA system records are captured only after ipa-server-install"
        return 0
    fi
    local plan_file="$IPA_GENERATED_DIR/freeipa-dns-prerequisites.txt"
    dns_generate_plan_file "$plan_file"
    state_set EXTERNAL_DNS_PREREQUISITES_FILE "$plan_file"
    log_info "generated external DNS prerequisite plan: $plan_file"
}

dns_provider_install() {
    log_info "existing DNS provider selected; no DNS packages or external DNS changes will be made"
}

dns_provider_configure() {
    log_info "existing DNS provider selected; configuration remains under external DNS administration"
}

dns_provider_configure_forwarders() {
    log_info "existing DNS provider selected; DNS_FORWARDERS is not applied to an external system"
}

dns_provider_create_forward_zone() {
    log_info "existing DNS provider requires the IPA forward zone to pre-exist; no zone will be created"
}

dns_provider_create_reverse_zone() {
    log_info "existing DNS provider requires the single IPA /24 reverse zone to pre-exist; no zone will be created"
}

dns_provider_create_record() {
    log_info "existing DNS provider will not modify record: ${1:-<unspecified>}"
}

dns_provider_validate() {
    log_stage dns-existing-validation
    if is_dry_run || (is_check && ! command_exists dig); then
        plan "validate external DNS prerequisites and, when available, the captured FreeIPA system records"
        return 0
    fi
    local generated
    if ! dns_validate_prerequisite_records "${DNS_VALIDATION_SERVER:-}"; then
        return 1
    fi
    generated=$(dns_find_generated_record_file)
    if [[ -n "$generated" ]]; then
        if ! dns_validate_records_file "$generated" "${DNS_VALIDATION_SERVER:-}"; then
            return 1
        fi
        EXTERNAL_DNS_STATUS=complete
        return 0
    fi
    log_warn "no captured FreeIPA system-record file is available; validating only the server A/PTR prerequisites"
    dns_validate_prerequisite_records "${DNS_VALIDATION_SERVER:-}"
}

dns_provider_validate_prerequisites() {
    log_stage dns-existing-prerequisites
    if is_dry_run; then
        plan "validate only the existing-DNS server A/PTR prerequisites before FreeIPA installation"
        return 0
    fi
    dns_validate_prerequisite_records "${DNS_VALIDATION_SERVER:-}"
}

dns_provider_sync_freeipa_records() {
    local path=${1:-}
    [[ -n "$path" && -f "$path" && ! -L "$path" ]] || {
        log_error "FreeIPA did not produce its external DNS record file; cannot complete existing-DNS validation"
        return 1
    }
    if is_dry_run; then
        plan "validate the installer-generated DNS record set from $path without changing external DNS"
        return 0
    fi
    local destination="$IPA_GENERATED_DIR/freeipa-dns-records-${RUN_ID}.db"
    dns_prepare_generated_directory
    [[ ! -e "$destination" && ! -L "$destination" ]] || {
        log_error "refusing to overwrite an existing generated DNS record file: $destination"
        return 1
    }
    cp -p -- "$path" "$destination"
    chmod 0640 "$destination"
    state_set EXTERNAL_RECORDS_FILE "$destination"
    log_info "preserved installer-generated DNS record set at $destination"
    EXTERNAL_DNS_STATUS=pending
    state_set EXTERNAL_DNS_STATUS pending
    if dns_validate_records_file "$path" "${DNS_VALIDATION_SERVER:-}"; then
        EXTERNAL_DNS_STATUS=complete
        state_set EXTERNAL_DNS_STATUS complete
        log_info "external DNS records are published and validated"
    else
        log_warn "FreeIPA installation completed successfully, but external DNS publication is still pending"
        log_warn "publish the records in $destination, then run ./install.sh --check to complete validation"
    fi
}

dns_provider_uninstall() {
    log_warn "existing DNS provider uninstall is a guarded no-op; this bootstrap never modifies or removes external DNS"
}

