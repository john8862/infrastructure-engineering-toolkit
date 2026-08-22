#!/usr/bin/env bash

: "${SCRIPT_DIR:?SCRIPT_DIR must be set before sourcing env.sh}"
: "${ENV_FILE:=$SCRIPT_DIR/.env}"

DOTENV_ERRORS=()

dotenv_trim() {
    local value=${1:-}
    value="${value#${value%%[![:space:]]*}}"
    value="${value%${value##*[![:space:]]}}"
    printf '%s' "$value"
}

dotenv_unquote() {
    local value=${1:-}
    if [[ "$value" == \"*\" && "$value" == *\" ]]; then
        value=${value:1:${#value}-2}
        value=${value//\\\"/\"}
        value=${value//\\\\/\\}
    elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
        value=${value:1:${#value}-2}
    fi
    printf '%s' "$value"
}

load_dotenv_without_overriding_environment() {
    local path=${1:?dotenv path required}
    local line key value
    [[ -f "$path" ]] || return 0
    while IFS= read -r line || [[ -n "$line" ]]; do
        line=$(dotenv_trim "$line")
        [[ -z "$line" || "$line" == \#* ]] && continue
        [[ "$line" == export\ * ]] && line=${line#export }
        if [[ "$line" =~ ^([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
            key=${BASH_REMATCH[1]}
            value=$(dotenv_trim "${BASH_REMATCH[2]}")
            if [[ -v "$key" ]]; then
                continue
            fi
            value=$(dotenv_unquote "$value")
            printf -v "$key" '%s' "$value"
            export "$key"
        else
            DOTENV_ERRORS+=("malformed .env line was ignored")
            log_warn "ignoring malformed .env line for safety"
        fi
    done < "$path"
}

load_environment() {
    load_dotenv_without_overriding_environment "$ENV_FILE"

    local backend_explicit=false
    local hostname_explicit=false
    local server_fqdn_explicit=false
    local manage_hostname_explicit=false
    local tsig_enabled_explicit=false
    local transfer_security_explicit=false
    [[ -v DNS_BACKEND ]] && backend_explicit=true
    [[ -v IPA_HOSTNAME ]] && hostname_explicit=true
    [[ -v SERVER_FQDN ]] && server_fqdn_explicit=true
    [[ -v MANAGE_HOSTNAME ]] && manage_hostname_explicit=true
    [[ -v DNS_TSIG_ENABLED ]] && tsig_enabled_explicit=true
    [[ -v DNS_TRANSFER_SECURITY ]] && transfer_security_explicit=true
    IPA_HOSTNAME_LEGACY=''

    : "${IPA_DOMAIN:=example.invalid}"
    : "${IPA_REALM:=${IPA_DOMAIN^^}}"
    : "${IPA_HOSTNAME:=ipa01.${IPA_DOMAIN}}"
    : "${SERVER_FQDN:=$IPA_HOSTNAME}"
    if [[ "$server_fqdn_explicit" == true ]]; then
        [[ "$hostname_explicit" == true ]] && IPA_HOSTNAME_LEGACY=$IPA_HOSTNAME
        IPA_HOSTNAME=$SERVER_FQDN
    else
        SERVER_FQDN=$IPA_HOSTNAME
    fi
    : "${IPA_IP_ADDRESS:=192.0.2.10}"
    IPA_REVERSE_ZONE=$(reverse_zone_for_ipv4 "$IPA_IP_ADDRESS" 2>/dev/null || printf '')
    IPA_REVERSE_RECORD=$(reverse_record_for_ipv4 "$IPA_IP_ADDRESS" 2>/dev/null || printf '')
    : "${IPA_SERVER_ROLE:=primary}"
    : "${IPA_REPLICA_SOURCE:=}"
    : "${IPA_REPLICA_PRINCIPAL:=admin}"
    : "${IPA_REPLICA_SETUP_CA:=true}"
    : "${IPA_SETUP_CA:=true}"
    : "${IPA_SETUP_KRA:=false}"
    : "${IPA_SSH_TRUST_DNS:=false}"
    : "${IPA_SETUP_SUBID:=false}"
    : "${IPA_DIRSRV_CERT_FILES:=}"
    : "${IPA_HTTP_CERT_FILES:=}"
    : "${IPA_CA_CERT_FILES:=}"
    : "${IPA_DIRSRV_CERT_PIN:=}"
    : "${IPA_HTTP_CERT_PIN:=}"
    : "${IPA_PKINIT_CERT_FILES:=}"
    : "${IPA_PKINIT_CERT_PIN:=}"
    : "${IPA_DEFAULT_SHELL:=/bin/bash}"
    : "${IPA_HOME_ROOT:=/home}"
    : "${CONFIGURE_HOSTNAME:=false}"
    : "${MANAGE_HOSTNAME:=$CONFIGURE_HOSTNAME}"
    CONFIGURE_HOSTNAME=$MANAGE_HOSTNAME
    : "${CONFIGURE_SERVER_MKHOMEDIR:=false}"
    : "${NTP_SERVERS:=}"
    : "${IPA_INSTALL_MAX_ATTEMPTS:=2}"
    if [[ "$backend_explicit" == true ]]; then
        case "${DNS_BACKEND,,}" in
            integrated)
                DNS_BACKEND=integrated
                IPA_DNS_MODE=integrated
                DNS_PROVIDER=''
                ;;
            bind9_webmin|bind9-webmin)
                DNS_BACKEND=bind9_webmin
                IPA_DNS_MODE=external
                DNS_PROVIDER=bind9-webmin
                ;;
            technitium)
                DNS_BACKEND=technitium
                IPA_DNS_MODE=external
                DNS_PROVIDER=technitium
                ;;
            existing)
                DNS_BACKEND=existing
                IPA_DNS_MODE=external
                DNS_PROVIDER=existing
                ;;
        esac
    else
        : "${IPA_DNS_MODE:=external}"
        : "${DNS_PROVIDER:=bind9-webmin}"
        if [[ "$IPA_DNS_MODE" == integrated ]]; then
            DNS_BACKEND=integrated
        else
            case "$DNS_PROVIDER" in
                bind9-webmin) DNS_BACKEND=bind9_webmin ;;
                technitium) DNS_BACKEND=technitium ;;
                existing) DNS_BACKEND=existing ;;
                *) DNS_BACKEND='' ;;
            esac
        fi
    fi
    if [[ ! -v DNS_FORWARDERS ]]; then
        DNS_FORWARDERS='192.0.2.53 192.0.2.54'
    fi
    : "${DNS_RECURSION_NETWORKS:=127.0.0.0/8}"
    : "${DNS_VALIDATION_SERVER:=}"
    : "${DNS_TTL:=86400}"
    : "${DNS_BIND_CONFIG_FILE:=/etc/named.conf}"
    : "${DNS_BIND_INCLUDE_FILE:=/etc/named/freeipa-bootstrap.conf}"
    : "${DNS_BIND_ZONE_DIR:=/var/named/freeipa-bootstrap}"
    : "${DNS_BIND_SLAVE_DIR:=/var/named/slaves}"
    : "${BIND_CONFIG_MODE:=managed_include}"
    : "${BIND_ZONE_FILE_MODE:=custom}"
    : "${BIND_NATIVE_ZONE_CONFIG_FILE:=}"
    : "${BIND_NATIVE_ZONE_DIR:=/var/named}"
    : "${BIND_ACL_NAME:=trusted_networks}"
    : "${BIND_ACL_NETWORKS:=127.0.0.0/8}"
    : "${BIND_ALLOW_QUERY_ACL:=}"
    : "${BIND_ALLOW_RECURSION_ACL:=}"
    : "${BIND_ALLOW_UPDATE_ACL:=}"
    : "${BIND_ALLOW_TRANSFER_ACL:=}"
    : "${BIND_ALLOW_NOTIFY_ACL:=}"
    : "${BIND_ALLOW_UPDATE_FORWARDING_ACL:=}"
    : "${DNS_SERVER_ROLE:=primary}"
    : "${DNS_PRIMARY_SERVER:=$IPA_HOSTNAME}"
    : "${DNS_PRIMARY_IP:=$IPA_IP_ADDRESS}"
    : "${DNS_SECONDARY_SERVER:=}"
    : "${DNS_SECONDARY_IP:=}"
    : "${DNS_ADDITIONAL_NODES:=}"
    : "${DNS_AUTHORITATIVE_REVERSE_ZONES:=}"
    : "${DNS_TRANSFER_SECURITY:=tsig}"
    : "${DNS_TRANSFER_KEY_NAME:=freeipa-bootstrap-transfer}"
    : "${DNS_TRANSFER_KEY_FILE:=/etc/named/freeipa-bootstrap-transfer.key}"
    : "${DNS_TRANSFER_KEY_SECRET:=}"
    if [[ "$tsig_enabled_explicit" == true ]]; then
        if [[ "$DNS_TSIG_ENABLED" == true ]]; then
            DNS_TRANSFER_SECURITY=tsig
        else
            DNS_TRANSFER_SECURITY=none
        fi
    elif [[ "$transfer_security_explicit" == false ]]; then
        DNS_TRANSFER_SECURITY=tsig
    fi
    : "${DNS_TSIG_ENABLED:=$([[ "$DNS_TRANSFER_SECURITY" == tsig ]] && printf true || printf false)}"
    : "${DNS_TSIG_KEY_NAME:=$DNS_TRANSFER_KEY_NAME}"
    : "${DNS_TSIG_KEY_FILE:=$DNS_TRANSFER_KEY_FILE}"
    DNS_TRANSFER_KEY_NAME=$DNS_TSIG_KEY_NAME
    DNS_TRANSFER_KEY_FILE=$DNS_TSIG_KEY_FILE
    : "${DNS_TSIG_PROVISION:=manual}"
    : "${DNS_TSIG_SSH_USER:=root}"
    : "${DNS_TSIG_SSH_KEY_FILE:=}"
    : "${DNS_TSIG_SSH_PORT:=22}"
    : "${DNS_NOTIFY_ENABLED:=true}"
    : "${DNS_DYNAMIC_UPDATE_MODE:=disabled}"
    : "${DNS_DYNAMIC_UPDATE_NETWORKS:=}"
    : "${DNS_TRANSFER_WAIT_SECONDS:=90}"
    : "${DNS_TRANSFER_POLL_SECONDS:=3}"
    : "${WEBMIN_PORT:=10000}"
    : "${WEBMIN_CONFIG_FILE:=/etc/webmin/miniserv.conf}"
    : "${WEBMIN_SETUP_REPO_SHA256:=}"
    : "${WEBMIN_PEER_SERVER:=}"
    : "${WEBMIN_PEER_IP:=}"
    : "${WEBMIN_PEER_PORT:=$WEBMIN_PORT}"
    : "${WEBMIN_PEER_USERNAME:=}"
    : "${WEBMIN_PEER_PASSWORD:=}"
    : "${TECHNITIUM_API_URL:=https://127.0.0.1:53443}"
    : "${TECHNITIUM_API_TOKEN:=}"
    : "${TECHNITIUM_API_TOKEN_FILE:=}"
    : "${TECHNITIUM_API_USERNAME:=admin}"
    : "${TECHNITIUM_API_PASSWORD:=}"
    : "${TECHNITIUM_API_CA_FILE:=}"
    : "${TECHNITIUM_API_TLS_VERIFY:=true}"
    : "${TECHNITIUM_INSTALLER_URL:=https://download.technitium.com/dns/install.sh}"
    : "${TECHNITIUM_INSTALLER_SHA256:=}"
    : "${TECHNITIUM_INSTALL_DIR:=/opt/technitium/dns}"
    : "${TECHNITIUM_CONFIG_DIR:=/etc/dns}"
    : "${TECHNITIUM_LOG_DIR:=/var/log/technitium/dns}"
    : "${TECHNITIUM_SERVICE_NAME:=dns.service}"
    : "${TECHNITIUM_ZONE_TRANSFER_PROTOCOL:=Tcp}"
    : "${TECHNITIUM_VALIDATE_ZONE:=false}"
    : "${TECHNITIUM_UPDATE_NETWORKS:=$DNS_DYNAMIC_UPDATE_NETWORKS}"
    : "${TECHNITIUM_DNS_CLIENT_NETWORKS:=}"
    : "${IPA_MIN_VCPU:=2}"
    : "${IPA_MIN_MEMORY_MB:=4096}"
    : "${IPA_MIN_FREE_DISK_MB:=10240}"
    : "${IPA_STATE_DIR:=/var/lib/freeipa-bootstrap}"
    : "${IPA_LOG_DIR:=/var/log/freeipa-bootstrap}"
    : "${IPA_GENERATED_DIR:=$SCRIPT_DIR/generated}"
    : "${NTP_CHRONY_CONFIG_FILE:=/etc/chrony.conf}"
    if [[ "$IPA_GENERATED_DIR" != /* ]]; then
        IPA_GENERATED_DIR="$SCRIPT_DIR/${IPA_GENERATED_DIR#./}"
    fi

    export IPA_DOMAIN IPA_REALM IPA_HOSTNAME SERVER_FQDN IPA_IP_ADDRESS IPA_SERVER_ROLE IPA_REPLICA_SOURCE
    export IPA_REPLICA_PRINCIPAL IPA_REPLICA_SETUP_CA IPA_SETUP_CA IPA_SETUP_KRA
    export IPA_SSH_TRUST_DNS IPA_SETUP_SUBID
    export IPA_DIRSRV_CERT_FILES IPA_HTTP_CERT_FILES IPA_CA_CERT_FILES IPA_PKINIT_CERT_FILES
    export IPA_REVERSE_ZONE IPA_REVERSE_RECORD
    export IPA_DEFAULT_SHELL IPA_HOME_ROOT CONFIGURE_HOSTNAME MANAGE_HOSTNAME
    export CONFIGURE_SERVER_MKHOMEDIR NTP_SERVERS IPA_INSTALL_MAX_ATTEMPTS
    export IPA_DNS_MODE DNS_PROVIDER DNS_BACKEND DNS_FORWARDERS DNS_RECURSION_NETWORKS
    export DNS_VALIDATION_SERVER DNS_TTL DNS_BIND_CONFIG_FILE
    export DNS_BIND_INCLUDE_FILE DNS_BIND_ZONE_DIR DNS_BIND_SLAVE_DIR BIND_CONFIG_MODE BIND_ZONE_FILE_MODE
    export BIND_NATIVE_ZONE_CONFIG_FILE BIND_NATIVE_ZONE_DIR BIND_ACL_NAME BIND_ACL_NETWORKS
    export BIND_ALLOW_QUERY_ACL BIND_ALLOW_RECURSION_ACL BIND_ALLOW_UPDATE_ACL BIND_ALLOW_TRANSFER_ACL
    export BIND_ALLOW_NOTIFY_ACL BIND_ALLOW_UPDATE_FORWARDING_ACL DNS_SERVER_ROLE
    export DNS_PRIMARY_SERVER DNS_PRIMARY_IP DNS_SECONDARY_SERVER DNS_SECONDARY_IP DNS_ADDITIONAL_NODES
    export DNS_AUTHORITATIVE_REVERSE_ZONES DNS_TRANSFER_SECURITY DNS_TRANSFER_KEY_NAME DNS_TRANSFER_KEY_FILE DNS_TRANSFER_KEY_SECRET
    export DNS_TSIG_ENABLED DNS_TSIG_KEY_NAME DNS_TSIG_KEY_FILE DNS_TSIG_PROVISION DNS_TSIG_SSH_USER DNS_TSIG_SSH_KEY_FILE DNS_TSIG_SSH_PORT
    export DNS_NOTIFY_ENABLED DNS_DYNAMIC_UPDATE_MODE DNS_DYNAMIC_UPDATE_NETWORKS
    export DNS_TRANSFER_WAIT_SECONDS DNS_TRANSFER_POLL_SECONDS
    export WEBMIN_PORT WEBMIN_CONFIG_FILE WEBMIN_SETUP_REPO_SHA256
    export WEBMIN_PEER_SERVER WEBMIN_PEER_IP WEBMIN_PEER_PORT WEBMIN_PEER_USERNAME WEBMIN_PEER_PASSWORD
    export TECHNITIUM_API_URL TECHNITIUM_API_TOKEN TECHNITIUM_API_TOKEN_FILE TECHNITIUM_API_USERNAME TECHNITIUM_API_PASSWORD
    export TECHNITIUM_API_CA_FILE TECHNITIUM_API_TLS_VERIFY TECHNITIUM_INSTALLER_URL TECHNITIUM_INSTALLER_SHA256
    export TECHNITIUM_INSTALL_DIR TECHNITIUM_CONFIG_DIR TECHNITIUM_LOG_DIR TECHNITIUM_SERVICE_NAME
    export TECHNITIUM_ZONE_TRANSFER_PROTOCOL TECHNITIUM_VALIDATE_ZONE TECHNITIUM_UPDATE_NETWORKS TECHNITIUM_DNS_CLIENT_NETWORKS
    export IPA_MIN_VCPU IPA_MIN_MEMORY_MB IPA_MIN_FREE_DISK_MB IPA_STATE_DIR
    export IPA_LOG_DIR IPA_GENERATED_DIR NTP_CHRONY_CONFIG_FILE
}

prompt_for_secret() {
    local variable=$1
    local prompt=$2
    local value=''
    if [[ ! -t 0 ]]; then
        log_error "$variable is not set and stdin is not interactive; set it in the environment or a 0600 .env file"
        return 1
    fi
    printf '%s: ' "$prompt" >&2
    IFS= read -r -s value
    printf '\n' >&2
    [[ -n "$value" ]] || {
        log_error "$variable must not be empty"
        return 1
    }
    printf -v "$variable" '%s' "$value"
    export "$variable"
}

load_required_secrets() {
    if [[ "${IPA_SERVER_ROLE:-primary}" == primary || "${IPA_SETUP_KRA:-false}" == true ]]; then
        if [[ -z "${IPA_DIRECTORY_MANAGER_PASSWORD:-}" ]]; then
            prompt_for_secret IPA_DIRECTORY_MANAGER_PASSWORD 'Directory Manager password' || return 1
        fi
    fi
    if [[ -z "${IPA_ADMIN_PASSWORD:-}" ]]; then
        prompt_for_secret IPA_ADMIN_PASSWORD 'IPA admin password' || return 1
    fi
}

validate_env_file_permissions() {
    if [[ ! -e "$ENV_FILE" ]]; then
        return 0
    fi
    if [[ ! -f "$ENV_FILE" || -L "$ENV_FILE" ]]; then
        preflight_error ".env must be a regular file, not a symlink: $ENV_FILE"
        return 0
    fi
    if ! file_has_restrictive_mode "$ENV_FILE"; then
        preflight_error ".env has group/other permissions; run chmod 600 '$ENV_FILE'"
    fi
    if [[ "$(id -u)" -eq 0 ]] && [[ "$(file_owner_uid "$ENV_FILE")" != 0 ]]; then
        preflight_error ".env must be root-owned when the bootstrap runs as root: $ENV_FILE"
    fi
}

validate_ca_less_file_list() {
    local variable=$1
    local path
    parse_space_list "${!variable}"
    for path in "${PARSED_WORDS[@]}"; do
        if [[ "$path" != /* || "$path" == *[[:space:]]* ]]; then
            preflight_error "$variable entries must be absolute paths without whitespace: $path"
        elif [[ ! -f "$path" || ! -r "$path" ]]; then
            preflight_error "$variable entry is not a readable regular file: $path"
        fi
    done
}

validate_network_list() {
    local variable=$1
    local value=${2:-}
    local network
    value=${value//,/ }
    parse_space_list "$value"
    for network in "${PARSED_WORDS[@]}"; do
        validate_ipv4_cidr "$network" || {
            preflight_error "$variable must contain only IPv4 CIDRs: $network"
            continue
        }
        [[ "$network" != 0.0.0.0/0 ]] || preflight_error "$variable must not allow unrestricted IPv4 access: $network"
    done
}

validate_bind_acl_reference() {
    local variable=$1
    local value=${2:-}
    [[ -z "$value" ]] && return 0
    [[ "$value" =~ ^[A-Za-z0-9_.-]+$ ]] || preflight_error "$variable must be a BIND ACL name or a built-in ACL token"
    [[ "$value" != any && "$value" != 0.0.0.0/0 ]] || preflight_error "$variable must not grant unrestricted access"
}

validate_env_configuration() {
    validate_env_file_permissions

    local dotenv_error
    for dotenv_error in "${DOTENV_ERRORS[@]}"; do
        preflight_error "$dotenv_error; correct $ENV_FILE before continuing"
    done

    validate_fqdn "$IPA_DOMAIN" || preflight_error "IPA_DOMAIN is not a valid DNS domain: $IPA_DOMAIN"
    validate_fqdn "$IPA_HOSTNAME" || preflight_error "IPA_HOSTNAME is not a valid FQDN: $IPA_HOSTNAME"
    [[ "$IPA_HOSTNAME" == "${IPA_HOSTNAME,,}" ]] || preflight_error "IPA_HOSTNAME must use lowercase DNS labels: $IPA_HOSTNAME"
    validate_ipv4 "$IPA_IP_ADDRESS" || preflight_error "IPA_IP_ADDRESS must be a valid IPv4 address: $IPA_IP_ADDRESS"
    validate_realm "$IPA_REALM" || preflight_error "IPA_REALM must be uppercase and DNS-realm compatible: $IPA_REALM"
    [[ "${IPA_HOSTNAME,,}" == *."${IPA_DOMAIN,,}" ]] || preflight_error "IPA_HOSTNAME must be below IPA_DOMAIN"

    for variable in IPA_SETUP_CA IPA_REPLICA_SETUP_CA IPA_SETUP_KRA IPA_SSH_TRUST_DNS IPA_SETUP_SUBID CONFIGURE_HOSTNAME MANAGE_HOSTNAME CONFIGURE_SERVER_MKHOMEDIR; do
        validate_bool "${!variable}" || preflight_error "$variable must be true or false"
    done
    if [[ -n "${IPA_HOSTNAME_LEGACY:-}" && "$SERVER_FQDN" != "$IPA_HOSTNAME_LEGACY" ]]; then
        preflight_error "SERVER_FQDN and legacy IPA_HOSTNAME must identify the same host when both are set"
    fi
    [[ "$IPA_SERVER_ROLE" == primary || "$IPA_SERVER_ROLE" == replica ]] || preflight_error "IPA_SERVER_ROLE must be primary or replica"
    if [[ "$IPA_SERVER_ROLE" == replica ]]; then
        validate_fqdn "$IPA_REPLICA_SOURCE" || preflight_error "IPA_REPLICA_SOURCE must be a valid source-server FQDN when IPA_SERVER_ROLE=replica"
        [[ "$IPA_REPLICA_SOURCE" != "$IPA_HOSTNAME" ]] || preflight_error "IPA_REPLICA_SOURCE must not equal IPA_HOSTNAME"
        [[ "$IPA_REPLICA_PRINCIPAL" =~ ^[A-Za-z0-9._/@-]+$ ]] || preflight_error "IPA_REPLICA_PRINCIPAL contains unsupported characters"
    fi
    local configured_ca=true
    local ca_setting_name=IPA_SETUP_CA
    if [[ "$IPA_SERVER_ROLE" == replica ]]; then
        configured_ca=$IPA_REPLICA_SETUP_CA
        ca_setting_name=IPA_REPLICA_SETUP_CA
    else
        configured_ca=$IPA_SETUP_CA
    fi
    if [[ "$configured_ca" == false ]]; then
        [[ -n "$IPA_DIRSRV_CERT_FILES" ]] || preflight_error "IPA_DIRSRV_CERT_FILES is required when $ca_setting_name=false"
        [[ -n "$IPA_HTTP_CERT_FILES" ]] || preflight_error "IPA_HTTP_CERT_FILES is required when $ca_setting_name=false"
        [[ "$IPA_SETUP_KRA" == false ]] || preflight_error "IPA_SETUP_KRA=true requires an integrated CA on the selected server; KRA cannot run in CA-less mode"
        validate_ca_less_file_list IPA_DIRSRV_CERT_FILES
        validate_ca_less_file_list IPA_HTTP_CERT_FILES
        validate_ca_less_file_list IPA_CA_CERT_FILES
        validate_ca_less_file_list IPA_PKINIT_CERT_FILES
        [[ -z "$IPA_DIRSRV_CERT_PIN" || -n "$IPA_DIRSRV_CERT_FILES" ]] || preflight_error "IPA_DIRSRV_CERT_PIN requires IPA_DIRSRV_CERT_FILES"
        [[ -z "$IPA_HTTP_CERT_PIN" || -n "$IPA_HTTP_CERT_FILES" ]] || preflight_error "IPA_HTTP_CERT_PIN requires IPA_HTTP_CERT_FILES"
        [[ -z "$IPA_PKINIT_CERT_PIN" || -n "$IPA_PKINIT_CERT_FILES" ]] || preflight_error "IPA_PKINIT_CERT_PIN requires IPA_PKINIT_CERT_FILES"
    else
        for variable in IPA_DIRSRV_CERT_FILES IPA_HTTP_CERT_FILES IPA_CA_CERT_FILES IPA_PKINIT_CERT_FILES IPA_DIRSRV_CERT_PIN IPA_HTTP_CERT_PIN IPA_PKINIT_CERT_PIN; do
            [[ -z "${!variable}" ]] || preflight_error "$variable is only valid when the selected server install is CA-less"
        done
    fi
    validate_positive_integer "$IPA_INSTALL_MAX_ATTEMPTS" || preflight_error "IPA_INSTALL_MAX_ATTEMPTS must be a positive integer"
    validate_positive_integer "$IPA_MIN_VCPU" || preflight_error "IPA_MIN_VCPU must be a positive integer"
    validate_positive_integer "$IPA_MIN_MEMORY_MB" || preflight_error "IPA_MIN_MEMORY_MB must be a positive integer"
    validate_positive_integer "$IPA_MIN_FREE_DISK_MB" || preflight_error "IPA_MIN_FREE_DISK_MB must be a positive integer"
    validate_positive_integer "$DNS_TTL" || preflight_error "DNS_TTL must be a positive integer"
    validate_positive_integer "$DNS_TRANSFER_WAIT_SECONDS" || preflight_error "DNS_TRANSFER_WAIT_SECONDS must be a positive integer"
    validate_positive_integer "$DNS_TRANSFER_POLL_SECONDS" || preflight_error "DNS_TRANSFER_POLL_SECONDS must be a positive integer"
    if [[ "$DNS_TRANSFER_WAIT_SECONDS" =~ ^[0-9]+$ && "$DNS_TRANSFER_POLL_SECONDS" =~ ^[0-9]+$ ]] && (( DNS_TRANSFER_WAIT_SECONDS < DNS_TRANSFER_POLL_SECONDS )); then
        preflight_error "DNS_TRANSFER_WAIT_SECONDS must be greater than or equal to DNS_TRANSFER_POLL_SECONDS"
    fi
    validate_tcp_port "$WEBMIN_PORT" || preflight_error "WEBMIN_PORT must be an integer from 1 through 65535"

    [[ "$IPA_DEFAULT_SHELL" == /* && "$IPA_DEFAULT_SHELL" != *[[:space:]]* ]] || preflight_error "IPA_DEFAULT_SHELL must be an absolute path without whitespace"
    [[ "$IPA_HOME_ROOT" == /* && "$IPA_HOME_ROOT" != *[[:space:]]* ]] || preflight_error "IPA_HOME_ROOT must be an absolute path without whitespace"
    case "$DNS_BACKEND" in
        integrated)
            [[ "$IPA_DNS_MODE" == integrated ]] || preflight_error "DNS_BACKEND=integrated must use IPA_DNS_MODE=integrated"
            ;;
        bind9_webmin|technitium|existing)
            [[ "$IPA_DNS_MODE" == external ]] || preflight_error "DNS_BACKEND=$DNS_BACKEND must use IPA_DNS_MODE=external"
            ;;
        *)
            preflight_error "DNS_BACKEND must be integrated, bind9_webmin, technitium, or existing"
            ;;
    esac
    [[ "$IPA_DNS_MODE" == integrated || "$IPA_DNS_MODE" == external ]] || preflight_error "IPA_DNS_MODE must be integrated or external"
    if [[ "$IPA_DNS_MODE" == external && -z "$DNS_PROVIDER" ]]; then
        preflight_error "DNS_PROVIDER is required when IPA_DNS_MODE=external"
    fi
    if [[ "$IPA_DNS_MODE" == external ]]; then
        case "$DNS_PROVIDER" in
            bind9-webmin|existing|technitium) ;;
            *) preflight_error "unsupported DNS_PROVIDER '$DNS_PROVIDER'; choose bind9-webmin, existing, or technitium" ;;
        esac
    fi

    validate_bool "$DNS_NOTIFY_ENABLED" || preflight_error "DNS_NOTIFY_ENABLED must be true or false"
    validate_bool "$DNS_TSIG_ENABLED" || preflight_error "DNS_TSIG_ENABLED must be true or false"
    case "$DNS_DYNAMIC_UPDATE_MODE" in
        disabled|secure|insecure) ;;
        *) preflight_error "DNS_DYNAMIC_UPDATE_MODE must be disabled, secure, or insecure" ;;
    esac
    if [[ "$IPA_DNS_MODE" == integrated && "$DNS_DYNAMIC_UPDATE_MODE" == insecure ]]; then
        preflight_error "FreeIPA integrated DNS does not support the bootstrap's insecure DDNS mode; use secure IPA/Kerberos updates"
    fi
    if [[ -n "$DNS_DYNAMIC_UPDATE_NETWORKS" ]]; then
        validate_network_list DNS_DYNAMIC_UPDATE_NETWORKS "$DNS_DYNAMIC_UPDATE_NETWORKS"
    fi
    case "$DNS_BACKEND:$DNS_DYNAMIC_UPDATE_MODE" in
        bind9_webmin:insecure)
            [[ -n "$BIND_ALLOW_UPDATE_ACL" ]] || preflight_error "BIND_ALLOW_UPDATE_ACL is required for insecure BIND dynamic updates"
            ;;
        bind9_webmin:secure)
            # BIND update-policy authenticates with TSIG; no source-network
            # list is required for the secure policy.
            ;;
        technitium:insecure|technitium:secure)
            validate_network_list TECHNITIUM_UPDATE_NETWORKS "$TECHNITIUM_UPDATE_NETWORKS"
            [[ -n "$TECHNITIUM_UPDATE_NETWORKS" ]] || preflight_error "TECHNITIUM_UPDATE_NETWORKS (or DNS_DYNAMIC_UPDATE_NETWORKS) is required for Technitium $DNS_DYNAMIC_UPDATE_MODE dynamic updates"
            ;;
        existing:secure|existing:insecure)
            preflight_error "DNS_BACKEND=existing is read-only and cannot configure $DNS_DYNAMIC_UPDATE_MODE dynamic updates"
            ;;
    esac

    case "$BIND_CONFIG_MODE" in
        managed_include|native) ;;
        *) preflight_error "BIND_CONFIG_MODE must be managed_include or native" ;;
    esac
    case "$BIND_ZONE_FILE_MODE" in
        custom|native) ;;
        *) preflight_error "BIND_ZONE_FILE_MODE must be custom or native" ;;
    esac
    [[ "$BIND_NATIVE_ZONE_DIR" == /* && "$BIND_NATIVE_ZONE_DIR" != *[[:space:]]* ]] || preflight_error "BIND_NATIVE_ZONE_DIR must be an absolute path without whitespace"
    if [[ -n "$BIND_NATIVE_ZONE_CONFIG_FILE" ]]; then
        [[ "$BIND_NATIVE_ZONE_CONFIG_FILE" == /* && "$BIND_NATIVE_ZONE_CONFIG_FILE" != *[[:space:]]* ]] || preflight_error "BIND_NATIVE_ZONE_CONFIG_FILE must be an absolute path without whitespace"
    fi
    [[ "$BIND_ACL_NAME" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]] || preflight_error "BIND_ACL_NAME must be a safe BIND ACL identifier"
    [[ -n "$BIND_ACL_NETWORKS" ]] || preflight_error "BIND_ACL_NETWORKS must contain at least one trusted IPv4 CIDR"
    validate_network_list BIND_ACL_NETWORKS "$BIND_ACL_NETWORKS"
    for acl_variable in BIND_ALLOW_QUERY_ACL BIND_ALLOW_RECURSION_ACL BIND_ALLOW_UPDATE_ACL BIND_ALLOW_TRANSFER_ACL BIND_ALLOW_NOTIFY_ACL BIND_ALLOW_UPDATE_FORWARDING_ACL; do
        validate_bind_acl_reference "$acl_variable" "${!acl_variable}"
    done
    if [[ "$DNS_DYNAMIC_UPDATE_MODE" == secure && ( "$DNS_BACKEND" == bind9_webmin || "$DNS_BACKEND" == technitium ) ]]; then
        [[ "$DNS_TSIG_ENABLED" == true ]] || preflight_error "secure dynamic updates on the selected external backend require DNS_TSIG_ENABLED=true"
    fi

    [[ "$DNS_TSIG_PROVISION" == manual || "$DNS_TSIG_PROVISION" == ssh ]] || preflight_error "DNS_TSIG_PROVISION must be manual or ssh"
    validate_tcp_port "$DNS_TSIG_SSH_PORT" || preflight_error "DNS_TSIG_SSH_PORT must be an integer from 1 through 65535"
    if [[ -n "$DNS_TSIG_SSH_KEY_FILE" ]]; then
        [[ "$DNS_TSIG_SSH_KEY_FILE" == /* && "$DNS_TSIG_SSH_KEY_FILE" != *[[:space:]]* ]] || preflight_error "DNS_TSIG_SSH_KEY_FILE must be an absolute path without whitespace"
    fi

    parse_space_list "$DNS_FORWARDERS"
    for forwarder in "${PARSED_WORDS[@]}"; do
        validate_dns_server "$forwarder" || preflight_error "invalid DNS_FORWARDERS entry: $forwarder"
    done
    parse_space_list "$DNS_RECURSION_NETWORKS"
    for network in "${PARSED_WORDS[@]}"; do
        validate_ipv4_cidr "$network" || preflight_error "DNS_RECURSION_NETWORKS currently supports IPv4 CIDRs only: $network"
        [[ "$network" != 0.0.0.0/0 ]] || preflight_error "DNS_RECURSION_NETWORKS must not allow unrestricted IPv4 recursion: $network"
    done
    parse_space_list "$NTP_SERVERS"
    for ntp_server in "${PARSED_WORDS[@]}"; do
        validate_dns_server "$ntp_server" || preflight_error "invalid NTP_SERVERS entry: $ntp_server"
    done

    if [[ -n "$DNS_VALIDATION_SERVER" ]]; then
        validate_dns_server "$DNS_VALIDATION_SERVER" || preflight_error "DNS_VALIDATION_SERVER is not a valid IPv4, IPv6, or DNS name: $DNS_VALIDATION_SERVER"
    fi

    if [[ "$DNS_BACKEND" == technitium ]]; then
        [[ "$TECHNITIUM_API_URL" =~ ^https://[^[:space:]]+$ ]] || preflight_error "TECHNITIUM_API_URL must be an https:// URL without whitespace"
        validate_bool "$TECHNITIUM_API_TLS_VERIFY" || preflight_error "TECHNITIUM_API_TLS_VERIFY must be true or false"
        [[ "$TECHNITIUM_API_TLS_VERIFY" == true ]] || preflight_error "TECHNITIUM_API_TLS_VERIFY=false is not supported; provide a trusted CA instead"
        validate_bool "$TECHNITIUM_VALIDATE_ZONE" || preflight_error "TECHNITIUM_VALIDATE_ZONE must be true or false"
        [[ "$TECHNITIUM_INSTALLER_URL" =~ ^https://[^[:space:]]+$ ]] || preflight_error "TECHNITIUM_INSTALLER_URL must be an https:// URL without whitespace"
        if [[ -n "$TECHNITIUM_INSTALLER_SHA256" && ! "$TECHNITIUM_INSTALLER_SHA256" =~ ^[A-Fa-f0-9]{64}$ ]]; then
            preflight_error "TECHNITIUM_INSTALLER_SHA256 must be a 64-character SHA-256 value when set"
        fi
        validate_network_list TECHNITIUM_UPDATE_NETWORKS "$TECHNITIUM_UPDATE_NETWORKS"
        validate_network_list TECHNITIUM_DNS_CLIENT_NETWORKS "$TECHNITIUM_DNS_CLIENT_NETWORKS"
    fi

    local path_variable
    for path_variable in IPA_STATE_DIR IPA_LOG_DIR IPA_GENERATED_DIR DNS_BIND_CONFIG_FILE DNS_BIND_INCLUDE_FILE DNS_BIND_ZONE_DIR DNS_BIND_SLAVE_DIR DNS_TRANSFER_KEY_FILE WEBMIN_CONFIG_FILE NTP_CHRONY_CONFIG_FILE TECHNITIUM_INSTALL_DIR TECHNITIUM_CONFIG_DIR TECHNITIUM_LOG_DIR TECHNITIUM_API_TOKEN_FILE TECHNITIUM_API_CA_FILE; do
        [[ -z "${!path_variable}" ]] && continue
        if [[ "${!path_variable}" != /* || "${!path_variable}" == *[[:space:]]* ]]; then
            preflight_error "$path_variable must be an absolute path without whitespace"
        fi
    done

    if [[ -n "$WEBMIN_SETUP_REPO_SHA256" && ! "$WEBMIN_SETUP_REPO_SHA256" =~ ^[A-Fa-f0-9]{64}$ ]]; then
        preflight_error "WEBMIN_SETUP_REPO_SHA256 must be a 64-character SHA-256 value when set"
    fi

    if declare -F topology_validate_configuration >/dev/null 2>&1; then
        topology_validate_configuration
    fi
}
