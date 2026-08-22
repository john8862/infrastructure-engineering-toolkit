#!/usr/bin/env bash

NTP_MANAGED_BEGIN='# BEGIN FREEIPA-BOOTSTRAP NTP'
NTP_MANAGED_END='# END FREEIPA-BOOTSTRAP NTP'

ntp_expected_config_block() {
    local server
    printf '%s\n' "$NTP_MANAGED_BEGIN"
    parse_space_list "$NTP_SERVERS"
    for server in "${PARSED_WORDS[@]}"; do
        printf 'server %s iburst\n' "$server"
    done
    printf '%s\n' "$NTP_MANAGED_END"
}

ntp_configure() {
    log_stage ntp
    if [[ -z "$NTP_SERVERS" ]]; then
        log_info "NTP_SERVERS is empty; existing system time configuration will be retained"
        return 0
    fi
    if is_dry_run || is_check; then
        plan "install chrony if needed and manage the NTP block in $NTP_CHRONY_CONFIG_FILE for: $NTP_SERVERS"
        return 0
    fi
    command_exists systemctl || {
        log_error "systemctl is required to configure chrony on a supported target"
        return 1
    }
    [[ -f "$NTP_CHRONY_CONFIG_FILE" ]] || {
        log_error "$NTP_CHRONY_CONFIG_FILE does not exist after chrony package preparation"
        return 1
    }
    state_record_backup "$NTP_CHRONY_CONFIG_FILE"
    local temporary
    temporary=$(mktemp "$(dirname "$NTP_CHRONY_CONFIG_FILE")/.chrony.XXXXXX")
    chmod 0600 "$temporary"
    awk -v begin="$NTP_MANAGED_BEGIN" -v end="$NTP_MANAGED_END" '
        $0 == begin { skip=1; next }
        $0 == end { skip=0; next }
        !skip { print }
    ' "$NTP_CHRONY_CONFIG_FILE" > "$temporary"
    ntp_expected_config_block >> "$temporary"
    atomic_replace_file "$temporary" "$NTP_CHRONY_CONFIG_FILE"
    state_mark_resource chrony-config modified-by-bootstrap
    run_command systemctl enable --now chronyd
    log_info "chrony configured with requested NTP servers"
}

ntp_validate() {
    if is_dry_run; then
        plan "validate chrony or the existing system time-synchronization service before FreeIPA installation"
        return 0
    fi
    if [[ -n "$NTP_SERVERS" ]] && ! command_exists chronyc; then
        log_error "NTP_SERVERS is configured but chronyc is unavailable; chrony must be installed and healthy before FreeIPA installation"
        return 1
    fi
    if command_exists chronyc; then
        local tracking_output
        tracking_output=$(chronyc tracking 2>/dev/null || true)
        if [[ "$tracking_output" == *'Leap status'*'Normal'* ]]; then
            if [[ -n "$NTP_SERVERS" ]]; then
                local source_output
                source_output=$(chronyc sources -n 2>/dev/null || true)
                [[ -n "$source_output" && "$source_output" == *$'\n'* ]] || {
                    log_error "chrony has no reported sources after NTP_SERVERS configuration"
                    return 1
                }
                grep -Eq '^[[:space:]]*[\^=][*+]' <<< "$source_output" || {
                    log_error "chrony does not report a selected or usable configured source"
                    return 1
                }
            fi
            log_info "NTP validation passed through chrony"
            return 0
        fi
    fi
    if [[ -n "$NTP_SERVERS" ]]; then
        log_error "configured chrony sources are not synchronized"
        return 1
    fi
    if command_exists timedatectl && [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)" == yes ]]; then
        log_info "NTP validation passed through system time synchronization status"
        return 0
    fi
    if command_exists ntpq; then
        local ntpq_output
        ntpq_output=$(ntpq -pn 2>/dev/null || true)
        if [[ "$ntpq_output" == *$'\n'* ]] && grep -Eq '^[[:space:]]*[\*+]' <<< "$ntpq_output"; then
            log_info "NTP validation passed through ntpq"
            return 0
        fi
    fi
    log_error "time synchronization is not healthy; inspect chronyc tracking or timedatectl"
    return 1
}

