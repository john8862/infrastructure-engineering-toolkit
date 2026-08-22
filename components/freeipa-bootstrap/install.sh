#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export SCRIPT_DIR
PROJECT_VERSION_FILE="$SCRIPT_DIR/VERSION"
MODE=install
CURRENT_STAGE=initialisation
RUN_ID=''
IPA_CREDENTIALS_DIR=''
STATE_FILE=''
STATE_RUN_DIR=''
DNS_FIREWALL_REQUIRED=''
DNS_RECORDS_SYNC_FILE=''

project_version() {
    local version
    if [[ ! -f "$PROJECT_VERSION_FILE" || -L "$PROJECT_VERSION_FILE" ]]; then
        printf 'project version file is missing or unsafe: %s\n' "$PROJECT_VERSION_FILE" >&2
        return 1
    fi
    version=$(<"$PROJECT_VERSION_FILE")
    if [[ ! "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
        printf 'project version is not valid Semantic Versioning: %s\n' "$version" >&2
        return 1
    fi
    printf '%s' "$version"
}

usage() {
    printf 'FreeIPA Infrastructure Installer %s\n\n' "$(project_version)"
    cat <<'EOF'
Usage: ./install.sh [--version|--check|--dry-run|--sync-freeipa-records FILE]

  --version     Show the project version and exit.
  --check       Run read-only preflight checks only.
  --dry-run     Validate and print the planned actions without changing the host.
  --sync-freeipa-records FILE
                On a healthy managed-DNS primary, import the normalized FreeIPA
                external-DNS record output captured from a primary/replica.
  -h, --help    Show this help.

Normal execution requires a supported RHEL-family Linux host and root
privileges.  Configuration is loaded from exported variables first, then
./.env, then secure interactive prompts for required passwords.
EOF
}

while (( $# > 0 )); do
    case "$1" in
        --version) printf 'FreeIPA Infrastructure Installer %s\n' "$(project_version)"; exit 0 ;;
        --check) MODE=check ;;
        --dry-run) MODE=dry-run ;;
        --sync-freeipa-records)
            (( $# >= 2 )) || { printf '%s\n' '--sync-freeipa-records requires a record file path' >&2; exit 2; }
            DNS_RECORDS_SYNC_FILE=$2
            shift
            ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'Unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done
export MODE

# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/logging.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/env.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/topology.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/state.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/packages.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/preflight.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/hostname.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/ntp.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/firewall.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/dns/provider.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/freeipa.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/validation.sh"

on_error() {
    local rc=$?
    log_error "bootstrap stopped at stage '$CURRENT_STAGE' with exit code $rc"
    if [[ -n "${LOG_FILE:-}" ]]; then
        log_error "review bootstrap log: $LOG_FILE"
    fi
    exit "$rc"
}

cleanup_credentials() {
    if [[ -n "${IPA_CREDENTIALS_DIR:-}" && -d "$IPA_CREDENTIALS_DIR" ]]; then
        rm -rf -- "$IPA_CREDENTIALS_DIR"
    fi
    release_install_lock
}

trap on_error ERR
trap cleanup_credentials EXIT

load_environment
validate_env_configuration
preflight_fail_if_errors

RUN_ID="$(date -u '+%Y%m%dT%H%M%SZ')-$$"
export RUN_ID

# Discover FreeIPA before checking service conflicts.  A healthy integrated
# DNS installation is allowed to have named active; a clean install is not.
freeipa_detect_state
if [[ "$FREEIPA_STATE" == healthy ]]; then
    freeipa_validate_existing_role
fi
preflight_initial
preflight_fail_if_errors

if is_install; then
    acquire_install_lock
    log_init
fi

if [[ "$FREEIPA_STATE" == partial ]]; then
    log_error "a partial FreeIPA installation existed before this run; automatic uninstall/retry is forbidden"
    log_error "use the supported 'ipa-server-install --uninstall' procedure after reviewing the host and DNS topology"
    exit 1
fi

if [[ -n "$DNS_RECORDS_SYNC_FILE" ]]; then
    [[ "$MODE" == install ]] || {
        log_error "--sync-freeipa-records is a normal-mode operation; use --check separately after publication"
        exit 2
    }
    [[ -f "$DNS_RECORDS_SYNC_FILE" && ! -L "$DNS_RECORDS_SYNC_FILE" ]] || {
        log_error "FreeIPA DNS record sync input must be a non-symlink regular file: $DNS_RECORDS_SYNC_FILE"
        exit 1
    }
    [[ "$FREEIPA_STATE" == healthy ]] || {
        log_error "--sync-freeipa-records requires a healthy existing FreeIPA installation"
        exit 1
    }
    [[ "$DNS_BACKEND" == bind9_webmin || "$DNS_BACKEND" == technitium ]] || {
        log_error "--sync-freeipa-records requires DNS_BACKEND=bind9_webmin or DNS_BACKEND=technitium"
        exit 1
    }
    [[ "${DNS_SERVER_ROLE:-primary}" == primary ]] || {
        log_error "--sync-freeipa-records must run on the authoritative DNS primary; secondary hosts do not edit slave files"
        exit 1
    }
    [[ "$(topology_primary_server)" == "$IPA_HOSTNAME" ]] || {
        log_error "--sync-freeipa-records requires the local host to be the configured DNS primary"
        exit 1
    }
    if [[ -z "${IPA_ADMIN_PASSWORD:-}" ]]; then
        prompt_for_secret IPA_ADMIN_PASSWORD 'IPA admin password' || exit 1
    fi
    freeipa_prepare_credentials
    state_init
    state_set FREEIPA_PREEXISTING "$FREEIPA_PREEXISTING"
    dns_provider_load
    dns_provider_call sync_freeipa_records "$DNS_RECORDS_SYNC_FILE"
    freeipa_authenticate_admin
    run_full_validation
    print_installation_summary 'external DNS records synchronized'
    exit 0
fi

if is_check; then
    preflight_runtime
    preflight_fail_if_errors
    if [[ "$IPA_DNS_MODE" == external ]]; then
        dns_provider_load
        dns_provider_call check
        dns_provider_call validate
    fi
    ntp_validate
    if [[ "$IPA_DNS_MODE" == integrated || "$DNS_BACKEND" == bind9_webmin || "$DNS_BACKEND" == technitium ]]; then
        DNS_FIREWALL_REQUIRED=true
    fi
    firewall_configure
    printf 'Read-only preflight checks passed. No packages, files, services, firewall, SELinux, DNS, hostname, NTP, or FreeIPA state was changed.\n'
    exit 0
fi

if is_dry_run; then
    preflight_runtime
    preflight_fail_if_errors
    if [[ "$FREEIPA_STATE" == healthy ]]; then
        log_info "healthy FreeIPA detected; the package transaction and ipa-server-install will be skipped"
        validate_existing_hostname
        ntp_validate
        if [[ "$IPA_DNS_MODE" == external ]]; then
            dns_provider_load
            dns_provider_call check
            dns_provider_call validate
        else
            dns_integrated_reverse_zone_configure
        fi
        freeipa_authenticate_admin
        freeipa_ensure_ca
        freeipa_install_kra
        freeipa_configure_directory_defaults
        freeipa_configure_server_mkhomedir
        if [[ "$IPA_DNS_MODE" == integrated || "$DNS_BACKEND" == bind9_webmin || "$DNS_BACKEND" == technitium ]]; then
            DNS_FIREWALL_REQUIRED=true
        fi
        plan "skip FreeIPA package installation and ipa-server-install because the existing server is healthy"
        firewall_configure
        run_full_validation
        print_installation_summary planned
        exit 0
    fi
    configure_requested_hostname
    ntp_configure
    ntp_validate
    freeipa_validate_replica_source
    if [[ "$IPA_DNS_MODE" == external ]]; then
        dns_provider_load
        dns_provider_call check
        dns_provider_call install
        dns_provider_call configure_forwarders
        dns_provider_call create_forward_zone
        dns_provider_call create_reverse_zone
        dns_prerequisite_records
        if [[ "${DNS_SERVER_ROLE:-primary}" == primary ]]; then
            for record in "${DNS_PREREQUISITE_RECORDS[@]}"; do
                dns_provider_call create_record "$record"
            done
        else
            log_info "DNS secondary mode leaves all authoritative record changes on the primary; no slave zone file will be edited"
        fi
        dns_provider_call configure
        dns_provider_call validate_prerequisites
    else
        log_info "PLAN: use FreeIPA integrated DNS with repeated --forwarder options and --no-reverse"
        plan "create only the integrated reverse zone $IPA_REVERSE_ZONE after installation"
    fi
    if [[ "$IPA_DNS_MODE" == integrated || "$DNS_BACKEND" == bind9_webmin || "$DNS_BACKEND" == technitium ]]; then
        DNS_FIREWALL_REQUIRED=true
    fi
    freeipa_build_install_args
    if freeipa_ca_enabled; then
        plan "install FreeIPA with the platform's default integrated Dogtag CA; command shape: $(redact_args "${IPA_INSTALL_ARGS[@]}")"
    else
        plan "install FreeIPA without an integrated CA using the configured external server certificates; command shape: $(redact_args "${IPA_INSTALL_ARGS[@]}")"
    fi
    freeipa_install_kra
    freeipa_configure_directory_defaults
    freeipa_configure_server_mkhomedir
    firewall_configure
    print_installation_summary planned
    exit 0
fi

load_required_secrets
freeipa_prepare_credentials

if [[ "$FREEIPA_STATE" == healthy ]]; then
    log_info "healthy FreeIPA detected; skipping FreeIPA package installation and ipa-server-install"
    preflight_runtime
    preflight_fail_if_errors
    state_init
    state_set FREEIPA_PREEXISTING "$FREEIPA_PREEXISTING"
    validate_existing_hostname
    ntp_configure
    ntp_validate
    freeipa_authenticate_admin
    if [[ "$IPA_DNS_MODE" == external ]]; then
        dns_provider_load
        dns_provider_call check
    else
        dns_integrated_reverse_zone_configure
    fi
    freeipa_ensure_ca
    freeipa_install_kra
    freeipa_configure_directory_defaults
    freeipa_configure_server_mkhomedir
    if [[ "$IPA_DNS_MODE" == integrated || "$DNS_BACKEND" == bind9_webmin || "$DNS_BACKEND" == technitium ]]; then
        DNS_FIREWALL_REQUIRED=true
    fi
    firewall_configure
    run_full_validation
    print_installation_summary "already configured"
    exit 0
fi

state_init

state_set FREEIPA_PREEXISTING "$FREEIPA_PREEXISTING"
if [[ "$DNS_BACKEND" == bind9_webmin ]] && { package_is_installed bind || [[ -f "$DNS_BIND_CONFIG_FILE" ]] || (command_exists systemctl && systemctl is-enabled --quiet named 2>/dev/null); }; then
    BIND_PREEXISTING=present
else
    BIND_PREEXISTING=absent
fi
if package_is_installed webmin || command_exists webmin; then
    WEBMIN_PREEXISTING=present
else
    WEBMIN_PREEXISTING=absent
fi
state_set BIND_PREEXISTING "$BIND_PREEXISTING"
state_set WEBMIN_PREEXISTING "$WEBMIN_PREEXISTING"

log_stage base-packages
base_packages=(bind-utils curl ca-certificates)
if [[ -n "$NTP_SERVERS" ]]; then
    base_packages+=(chrony)
fi
if [[ "$CONFIGURE_SERVER_MKHOMEDIR" == true ]]; then
    base_packages+=(authselect oddjob oddjob-mkhomedir)
fi
package_install "${base_packages[@]}"

preflight_runtime
preflight_fail_if_errors
configure_requested_hostname
ntp_configure
ntp_validate

if [[ "$IPA_DNS_MODE" == external ]]; then
    dns_provider_load
    dns_provider_call check
    dns_provider_call install
    dns_provider_call configure_forwarders
    dns_provider_call create_forward_zone
    dns_provider_call create_reverse_zone
    dns_prerequisite_records
    if [[ "${DNS_SERVER_ROLE:-primary}" == primary ]]; then
        for record in "${DNS_PREREQUISITE_RECORDS[@]}"; do
            dns_provider_call create_record "$record"
        done
    else
        log_info "DNS secondary mode leaves all authoritative record changes on the primary; no slave zone file will be edited"
    fi
    dns_provider_call configure
    if [[ "$DNS_BACKEND" == bind9_webmin || "$DNS_BACKEND" == technitium ]]; then
        # Open DNS before validating a secondary's actual AXFR/IXFR path.
        # The selected managed provider owns its service validation.
        DNS_FIREWALL_REQUIRED=true
        firewall_configure
    fi
    dns_provider_call validate_prerequisites
    validate_hostname_and_network true
    preflight_fail_if_errors
else
    DNS_FIREWALL_REQUIRED=true
fi

if [[ "$IPA_DNS_MODE" == integrated ]]; then
    DNS_FIREWALL_REQUIRED=true
    firewall_configure
fi

log_stage freeipa-packages
freeipa_packages=(ipa-server)
if [[ "$IPA_DNS_MODE" == integrated ]]; then
    freeipa_packages+=(ipa-server-dns)
fi
package_install "${freeipa_packages[@]}"

freeipa_validate_replica_source
freeipa_validate_installer_options
freeipa_install_with_retry

freeipa_authenticate_admin
freeipa_ensure_ca
if [[ "$IPA_DNS_MODE" == integrated ]]; then
    dns_integrated_reverse_zone_configure
else
    installer_records=$(freeipa_find_installer_record_file)
    if [[ -z "$installer_records" ]]; then
        installer_records=$(freeipa_generate_external_dns_records)
    fi
    [[ -n "$installer_records" ]] || {
        log_error "external DNS mode requires the installed FreeIPA DNS record output"
        exit 1
    }
    dns_provider_call sync_freeipa_records "$installer_records"
fi
freeipa_install_kra
freeipa_configure_directory_defaults
freeipa_configure_server_mkhomedir
run_full_validation
print_installation_summary installed

