#!/usr/bin/env bash

: "${OS_RELEASE_FILE:=/etc/os-release}"
: "${OS_SUPPORTED:=false}"
: "${PACKAGE_MANAGER:=}"
: "${OS_ID:=}"
: "${OS_VERSION_ID:=}"
: "${OS_MAJOR:=}"
: "${ARCHITECTURE:=}"
: "${FIREWALL_STATE:=unknown}"
: "${FIREWALL_BACKEND:=unknown}"
: "${SELINUX_STATE:=unknown}"

supported_os_identity() {
    local id=${1:-}
    local version=${2:-}
    local arch=${3:-}
    local major=${version%%.*}
    case "$id" in
        rhel|rocky|almalinux|centos|ol) ;;
        *) return 1 ;;
    esac
    [[ "$major" == 8 || "$major" == 9 || "$major" == 10 ]] || return 1
    [[ "$arch" == x86_64 || "$arch" == aarch64 ]]
}

preflight_reset() {
    PREFLIGHT_ERRORS=()
    PREFLIGHT_WARNINGS=()
}

detect_supported_os() {
    local id_like=''
    if [[ ! -r "$OS_RELEASE_FILE" ]]; then
        preflight_error "cannot read $OS_RELEASE_FILE; only RHEL-family Linux targets are supported"
        return 0
    fi
    # os-release is a system-owned shell assignment file on the target.  It is
    # used instead of parsing distro-specific command output.
    # shellcheck disable=SC1090
    . "$OS_RELEASE_FILE"
    OS_ID=${ID:-}
    OS_VERSION_ID=${VERSION_ID:-}
    id_like=${ID_LIKE:-}
    OS_MAJOR=${OS_VERSION_ID%%.*}
    ARCHITECTURE=$(uname -m 2>/dev/null || printf 'unknown')
    OS_SUPPORTED=false

    case "$OS_ID" in
        rhel|rocky|almalinux|centos|ol)
            if [[ "$OS_MAJOR" == 8 || "$OS_MAJOR" == 9 || "$OS_MAJOR" == 10 ]]; then
                OS_SUPPORTED=true
            else
                preflight_error "unsupported $OS_ID major version '$OS_MAJOR'; supported versions are 8, 9, and 10"
            fi
            ;;
        *)
            if [[ "$id_like" == *rhel* || "$id_like" == *centos* ]]; then
                preflight_error "OS '$OS_ID' is RHEL-like but is not in the explicit support allowlist (rhel, rocky, almalinux, centos, ol)"
            else
                preflight_error "unsupported operating system '$OS_ID'; this bootstrap does not implement Debian/Ubuntu or other non-RHEL paths"
            fi
            ;;
    esac

    if [[ "$OS_SUPPORTED" == true ]]; then
        if ! supported_os_identity "$OS_ID" "$OS_VERSION_ID" "$ARCHITECTURE"; then
            if [[ "$ARCHITECTURE" != x86_64 && "$ARCHITECTURE" != aarch64 ]]; then
                preflight_error "unsupported CPU architecture '$ARCHITECTURE'; supported architectures are x86_64 and aarch64"
            else
                preflight_error "unsupported $OS_ID major version '$OS_MAJOR'; supported versions are 8, 9, and 10"
            fi
            OS_SUPPORTED=false
            return 0
        fi
        if command_exists dnf; then
            PACKAGE_MANAGER=dnf
        elif command_exists yum; then
            PACKAGE_MANAGER=yum
        else
            preflight_error "neither dnf nor yum is available"
        fi
        command_exists rpm || preflight_error "rpm is required to inspect installed packages"
    fi
}

validate_package_repositories() {
    [[ -n "$PACKAGE_MANAGER" ]] || return 0
    if is_dry_run; then
        plan "verify that enabled $PACKAGE_MANAGER repositories can provide the supported FreeIPA, DNS, time, and validation packages"
        return 0
    fi
    if is_check; then
        log_info "skipping package repository refresh in --check to preserve read-only semantics"
        return 0
    fi
    if "$PACKAGE_MANAGER" -q repolist >/dev/null 2>&1; then
        log_info "package repositories are reachable through $PACKAGE_MANAGER"
    else
        preflight_error "enabled $PACKAGE_MANAGER repositories could not be queried; verify repository configuration before installing FreeIPA"
    fi
}

require_root_privilege() {
    if [[ "$(id -u)" -ne 0 ]]; then
        preflight_error "run the bootstrap as root (for example: sudo ./install.sh); it does not attempt partial sudo escalation"
    fi
}

validate_resources() {
    local cpu_count memory_kb free_kb minimum_kb
    if ! command_exists nproc; then
        if is_dry_run; then
            plan "check at least $IPA_MIN_VCPU vCPU(s)"
        else
            preflight_error "nproc is required to validate CPU resources"
        fi
    else
        cpu_count=$(nproc)
        (( cpu_count >= IPA_MIN_VCPU )) || preflight_error "at least $IPA_MIN_VCPU vCPU(s) required; detected $cpu_count"
    fi

    if [[ -r /proc/meminfo ]]; then
        memory_kb=$(awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo)
        minimum_kb=$((IPA_MIN_MEMORY_MB * 1024))
        (( memory_kb >= minimum_kb )) || preflight_error "at least ${IPA_MIN_MEMORY_MB} MiB RAM required; detected $((memory_kb / 1024)) MiB"
    elif is_dry_run; then
        plan "check at least ${IPA_MIN_MEMORY_MB} MiB RAM"
    else
        preflight_error "cannot read /proc/meminfo to validate memory"
    fi

    if command_exists df; then
        free_kb=$(df -Pk /var | awk 'NR == 2 { print $4; exit }')
        minimum_kb=$((IPA_MIN_FREE_DISK_MB * 1024))
        if [[ "$free_kb" =~ ^[0-9]+$ ]]; then
            (( free_kb >= minimum_kb )) || preflight_error "at least ${IPA_MIN_FREE_DISK_MB} MiB free on /var required; detected $((free_kb / 1024)) MiB"
        else
            preflight_error "could not determine free space on /var"
        fi
    else
        preflight_error "df is required to validate disk space"
    fi
}

hostname_in_local_hosts() {
    local expected=$1
    local address name alias
    [[ -r /etc/hosts ]] || return 1
    while read -r address name alias; do
        [[ -n "${address:-}" && "$address" != \#* ]] || continue
        for candidate in "$name" "$alias"; do
            if [[ "${candidate,,}" == "${expected,,}" ]]; then
                printf '%s' "$address"
                return 0
            fi
        done
    done < <(awk '!/^[[:space:]]*#/ && NF >= 2 { print $1, $2, $3 }' /etc/hosts)
    return 1
}

hostname_resolves_to_expected_ip() {
    local hostname=$1
    local expected=$2
    local output line
    if command_exists getent; then
        output=$(getent ahostsv4 "$hostname" 2>/dev/null || true)
        while read -r line; do
            [[ -n "$line" ]] || continue
            [[ "${line%% *}" == "$expected" ]] && return 0
        done <<< "$output"
    fi
    if command_exists host; then
        output=$(host -t A "$hostname" 2>/dev/null || true)
        grep -Eq " has address $expected([[:space:]]|$)" <<< "$output" && return 0
    fi
    return 1
}

validate_hostname_and_network() {
    local strict_dns=${1:-false}
    local current_host local_host_entry
    if [[ "${MANAGE_HOSTNAME:-$CONFIGURE_HOSTNAME}" == false ]]; then
        current_host=$(hostname --fqdn 2>/dev/null || hostname 2>/dev/null || true)
        if [[ "${current_host,,}" != "${IPA_HOSTNAME,,}" ]]; then
            preflight_error "current hostname is '$current_host', expected '$IPA_HOSTNAME'; set MANAGE_HOSTNAME=true or fix the host first"
        fi
    elif ! command_exists hostnamectl && ! is_dry_run; then
        preflight_error "MANAGE_HOSTNAME=true requires hostnamectl on a supported RHEL-family system"
    fi

    if command_exists ip; then
        if ! ip -o -4 addr show | awk -v expected="$IPA_IP_ADDRESS" 'index($4, expected "/") == 1 { found=1 } END { exit !found }'; then
            if [[ "${MANAGE_HOSTNAME:-$CONFIGURE_HOSTNAME}" == true ]] && is_dry_run; then
                plan "validate that $IPA_IP_ADDRESS is assigned to a local interface"
            else
                preflight_error "IPA_IP_ADDRESS '$IPA_IP_ADDRESS' is not assigned to a local IPv4 interface"
            fi
        fi
    elif is_dry_run; then
        plan "validate local IPv4 interface assignment for $IPA_IP_ADDRESS"
    else
        preflight_error "ip is required to validate local IPv4 assignment"
    fi

    local_host_entry=$(hostname_in_local_hosts "$IPA_HOSTNAME" || true)
    if [[ -n "$local_host_entry" && "$local_host_entry" != "$IPA_IP_ADDRESS" ]]; then
        preflight_error "/etc/hosts maps $IPA_HOSTNAME to '$local_host_entry', expected '$IPA_IP_ADDRESS'"
    fi
    if ! hostname_resolves_to_expected_ip "$IPA_HOSTNAME" "$IPA_IP_ADDRESS"; then
        if [[ -n "$local_host_entry" && "$local_host_entry" == "$IPA_IP_ADDRESS" ]]; then
            :
        elif [[ "$IPA_DNS_MODE" == integrated || "$DNS_BACKEND" == bind9_webmin || "$DNS_BACKEND" == technitium ]]; then
            if [[ "$strict_dns" == true ]]; then
                preflight_error "$IPA_HOSTNAME does not resolve to $IPA_IP_ADDRESS through the system resolver; configure /etc/hosts or the system DNS resolver before ipa-server-install"
            else
                preflight_warning "$IPA_HOSTNAME does not resolve yet; the selected managed DNS path must create the prerequisite record before ipa-server-install"
            fi
        elif [[ "$IPA_DNS_MODE" == external && "$DNS_BACKEND" == existing ]]; then
            if [[ "$strict_dns" == true ]]; then
                preflight_error "$IPA_HOSTNAME does not resolve to $IPA_IP_ADDRESS through the system resolver; publish the server A record in existing DNS before ipa-server-install"
            else
                preflight_warning "$IPA_HOSTNAME does not resolve yet; the existing-DNS provider must publish the prerequisite A record before ipa-server-install"
            fi
        elif is_dry_run; then
            plan "validate forward DNS for $IPA_HOSTNAME -> $IPA_IP_ADDRESS"
        else
            preflight_error "forward DNS for $IPA_HOSTNAME does not resolve to $IPA_IP_ADDRESS"
        fi
    fi
}

validate_resolver_configuration() {
    if [[ ! -r /etc/resolv.conf ]]; then
        preflight_error "/etc/resolv.conf is not readable"
        return 0
    fi
    if ! awk '$1 == "nameserver" && $2 != "" { found=1 } END { exit !found }' /etc/resolv.conf; then
        preflight_error "/etc/resolv.conf does not contain a nameserver"
    fi
}

detect_firewall_state() {
    FIREWALL_STATE=unavailable
    FIREWALL_BACKEND=none
    local firewalld_active=false ufw_active=false firewalld_present=false ufw_present=false ufw_status

    if command_exists firewall-cmd; then
        firewalld_present=true
        if firewall-cmd --state >/dev/null 2>&1; then
            firewalld_active=true
        fi
    fi

    if command_exists ufw; then
        ufw_present=true
        ufw_status=$(ufw status 2>/dev/null || true)
        if grep -Eiq '^Status:[[:space:]]*active([[:space:]]|$)' <<< "$ufw_status"; then
            ufw_active=true
        fi
    fi

    if [[ "$firewalld_active" == true ]]; then
        FIREWALL_STATE=active
        FIREWALL_BACKEND=firewalld
        if [[ "$ufw_active" == true ]]; then
            log_warn 'firewall: both firewalld and UFW report active; firewalld will be used and UFW will not be changed'
        else
            log_info "firewall: firewalld is active; required services will be configured"
        fi
    elif [[ "$ufw_active" == true ]]; then
        FIREWALL_STATE=active
        FIREWALL_BACKEND=ufw
        log_info 'firewall: UFW is active; required rules will be configured'
    elif [[ "$firewalld_present" == true || "$ufw_present" == true ]]; then
        FIREWALL_STATE=inactive
        if [[ "$firewalld_present" == true && "$ufw_present" == true ]]; then
            log_info 'firewall: firewalld and UFW are installed but inactive; neither will be enabled by this bootstrap'
        elif [[ "$firewalld_present" == true ]]; then
            log_info 'firewall: firewalld is installed but inactive; it will not be enabled by this bootstrap'
        else
            log_info 'firewall: UFW is installed but inactive; it will not be enabled by this bootstrap'
        fi
    else
        log_info 'firewall: no supported active firewall detected; no firewall changes will be made'
    fi
}

detect_selinux_state() {
    SELINUX_STATE=unavailable
    if ! command_exists getenforce; then
        log_warn "SELinux state could not be queried because getenforce is unavailable"
        return 0
    fi
    SELINUX_STATE=$(getenforce 2>/dev/null || printf 'unknown')
    case "$SELINUX_STATE" in
        Enforcing) log_info "SELinux: enforcing; no policy weakening will be attempted" ;;
        Permissive) preflight_warning "SELinux is permissive; this bootstrap will not change it, but production operation should use enforcing mode" ;;
        Disabled) preflight_error "SELinux is disabled; enable it through the platform baseline before installing FreeIPA; this bootstrap will not enable or disable SELinux" ;;
        *) preflight_warning "SELinux state is '$SELINUX_STATE'" ;;
    esac
}

detect_existing_services() {
    if command_exists systemctl; then
        if systemctl is-active --quiet slapd 2>/dev/null || systemctl is-active --quiet dirsrv 2>/dev/null; then
            preflight_error "an existing standalone Directory Server service is active; do not install FreeIPA over it"
        fi
        if [[ "${FREEIPA_STATE:-absent}" != healthy && "$IPA_DNS_MODE" == integrated ]] && systemctl is-active --quiet named 2>/dev/null; then
            preflight_error "named is already active while integrated DNS was requested; review the existing DNS service before proceeding"
        fi
        if [[ "${FREEIPA_STATE:-absent}" != healthy && "$DNS_BACKEND" == technitium ]] && systemctl is-active --quiet named 2>/dev/null; then
            preflight_error "named is already active while Technitium DNS was requested; port 53 must be available to Technitium"
        fi
        if [[ "${FREEIPA_STATE:-absent}" != healthy && "$IPA_DNS_MODE" == integrated ]] && systemctl is-active --quiet unbound 2>/dev/null; then
            preflight_error "unbound is already active while integrated DNS was requested; port 53 must be available to FreeIPA DNS"
        fi
    fi
}

validate_required_ports() {
    if [[ "${FREEIPA_STATE:-absent}" == healthy ]]; then
        return 0
    fi
    if ! command_exists ss; then
        if is_dry_run; then
            plan "check that FreeIPA ports are available before installation"
        else
            preflight_error "ss is required to inspect required FreeIPA ports"
        fi
        return 0
    fi
    local ports=(389 636 88 464 80 443)
    if [[ "$IPA_DNS_MODE" == integrated || "$DNS_BACKEND" == bind9_webmin || "$DNS_BACKEND" == technitium ]]; then
        ports+=(53)
    fi
    local port listeners
    for port in "${ports[@]}"; do
        listeners=$(ss -H -lntup "sport = :$port" 2>/dev/null || true)
        if [[ -n "$listeners" ]]; then
            if [[ "$port" == 53 && "$DNS_BACKEND" == bind9_webmin && "$listeners" == *'"named"'* ]]; then
                log_info "port 53 is already owned by named; the selected BIND provider will validate and reload it safely"
                continue
            fi
            if [[ "$port" == 53 && "$DNS_BACKEND" == technitium && "$listeners" == *'"dns"'* ]]; then
                log_info "port 53 is already owned by Technitium; the selected provider will validate it safely"
                continue
            fi
            if is_dry_run; then
                plan "verify port $port is free or owned by the selected FreeIPA/DNS service"
            else
                preflight_error "required port $port is already listening; inspect with ss -lntup and remove the conflict before installation"
            fi
        fi
    done
}

validate_replica_source_reachability() {
    [[ "${IPA_SERVER_ROLE:-primary}" == replica ]] || return 0
    local source=${IPA_REPLICA_SOURCE:-}
    validate_fqdn "$source" || return 0
    local addresses
    if command_exists getent; then
        addresses=$(getent ahostsv4 "$source" 2>/dev/null || true)
        [[ -n "$addresses" ]] || preflight_error "IPA_REPLICA_SOURCE '$source' does not resolve to an IPv4 address"
    fi
    if command_exists dig; then
        if ! dig +time=3 +tries=1 +short A "$source" 2>/dev/null | grep -Eq '^[0-9]+(\.[0-9]+){3}$'; then
            preflight_error "IPA_REPLICA_SOURCE '$source' has no usable A record"
        fi
    fi
    if command_exists timeout; then
        local port
        for port in 443 389 636 88 464; do
            if ! timeout 4 bash -c ":</dev/tcp/$source/$port" >/dev/null 2>&1; then
                preflight_error "IPA_REPLICA_SOURCE '$source' is not reachable on required TCP port $port"
            fi
        done
    else
        preflight_warning "timeout is unavailable; the supported ipa-replica-conncheck and installer will perform the authoritative source connectivity check"
    fi
}

validate_runtime_tools() {
    local missing=()
    for tool in dig; do
        command_exists "$tool" || missing+=("$tool (bind-utils)")
    done
    if [[ "$DNS_BACKEND" == bind9_webmin || "$DNS_BACKEND" == technitium ]]; then
        for tool in rpm; do
            command_exists "$tool" || missing+=("$tool")
        done
    fi
    if [[ "$MODE" == dry-run ]]; then
        for tool in "${missing[@]}"; do
            plan "install/verify runtime tool $tool"
        done
    else
        for tool in "${missing[@]}"; do
            preflight_error "required runtime tool is unavailable: $tool"
        done
    fi
}

validate_runtime_dns() {
    if ! command_exists dig; then
        return 0
    fi
    local result
    result=$(dig +time=3 +tries=1 +short . NS 2>/dev/null || true)
    [[ -n "$result" ]] || preflight_warning "configured DNS resolver did not return the root NS query; verify resolver reachability"

    if [[ "$DNS_BACKEND" == existing ]]; then
        # The existing provider performs the strict record validation later.
        return 0
    fi
    local reverse_zone
    reverse_zone=$(reverse_zone_for_ipv4 "$IPA_IP_ADDRESS") || return 0
    if ! dig +time=3 +tries=1 +short -x "$IPA_IP_ADDRESS" 2>/dev/null | grep -qi "${IPA_HOSTNAME%.}"; then
        if [[ "$IPA_DNS_MODE" == integrated || "$DNS_BACKEND" == bind9_webmin || "$DNS_BACKEND" == technitium ]]; then
            preflight_warning "reverse DNS for $IPA_IP_ADDRESS is not present yet; the selected managed DNS path will create only $reverse_zone"
        else
            preflight_error "reverse DNS for $IPA_IP_ADDRESS does not resolve to $IPA_HOSTNAME"
        fi
    fi
}

validate_runtime_time() {
    if command_exists chronyc && chronyc tracking >/dev/null 2>&1; then
        return 0
    fi
    if command_exists timedatectl && [[ "$(timedatectl show -p NTPSynchronized --value 2>/dev/null || true)" == yes ]]; then
        return 0
    fi
    if is_dry_run; then
        plan "validate chrony or the existing system time-synchronization service"
    else
        preflight_error "time synchronization is not healthy; verify chronyd/ntpd and correct the system clock before FreeIPA installation"
    fi
}

preflight_initial() {
    preflight_reset
    log_stage preflight
    require_root_privilege
    detect_supported_os
    [[ "$OS_SUPPORTED" == true ]] || return 0
    validate_package_repositories
    validate_resources
    validate_hostname_and_network
    validate_resolver_configuration
    detect_firewall_state
    detect_selinux_state
    detect_existing_services
    validate_required_ports
    validate_replica_source_reachability
}

preflight_runtime() {
    preflight_reset
    log_stage runtime-preflight
    [[ "$OS_SUPPORTED" == true ]] || return 0
    validate_runtime_tools
    validate_runtime_dns
    validate_replica_source_reachability
}

