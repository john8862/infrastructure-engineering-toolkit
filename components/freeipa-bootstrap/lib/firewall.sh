#!/usr/bin/env bash

FIREWALL_ZONES=()
FIREWALL_CHANGED=false
FIREWALL_BACKEND=${FIREWALL_BACKEND:-unknown}
TECHNITIUM_REQUIRED_PORTS=()
TECHNITIUM_INTERNAL_PORTS=()
TECHNITIUM_SOURCE_RULES=()
TECHNITIUM_MANAGED_SOURCE_RULES=()
TECHNITIUM_PREVIOUS_SOURCE_RULES=()
: "${TECHNITIUM_SETTINGS_JSON:=}"
: "${TECHNITIUM_DHCP_SCOPES_JSON:=}"

firewall_webmin_required() {
    [[ "${DNS_BACKEND:-}" == bind9_webmin ]]
}

firewall_discover_active_zones() {
    FIREWALL_ZONES=()
    [[ "${FIREWALL_STATE:-}" == active ]] || return 0

    local zone
    while IFS= read -r zone; do
        [[ -n "$zone" ]] || continue
        FIREWALL_ZONES+=("$zone")
    done < <(firewall-cmd --get-active-zones 2>/dev/null | awk 'NF == 1 { print $1 }')

    if (( ${#FIREWALL_ZONES[@]} == 0 )); then
        zone=$(firewall-cmd --get-default-zone 2>/dev/null || true)
        [[ -n "$zone" ]] || {
            log_error "firewalld is active but no active or default zone could be determined"
            return 1
        }
        FIREWALL_ZONES+=("$zone")
    fi
}

firewall_service_exists() {
    local service=$1
    firewall-cmd --get-services 2>/dev/null | tr -s '[:space:]' '\n' | grep -Fxq "$service"
}

firewall_add_service_if_needed() {
    local zone=$1
    local service=$2
    local permanent=false
    local runtime=false

    if firewall-cmd --zone="$zone" --query-service="$service" --permanent >/dev/null 2>&1; then
        permanent=true
    fi
    if firewall-cmd --zone="$zone" --query-service="$service" >/dev/null 2>&1; then
        runtime=true
    fi
    if [[ "$permanent" != true ]]; then
        run_command firewall-cmd --zone="$zone" --add-service="$service" --permanent || return $?
        FIREWALL_CHANGED=true
    fi
    if [[ "$runtime" != true ]]; then
        run_command firewall-cmd --zone="$zone" --add-service="$service" || return $?
        FIREWALL_CHANGED=true
    fi
}

firewall_add_port_if_needed() {
    local zone=$1
    local port=$2
    local permanent=false
    local runtime=false

    if ! firewall-cmd --zone="$zone" --query-port="$port" --permanent >/dev/null 2>&1; then
        permanent=false
    else
        permanent=true
    fi
    if firewall-cmd --zone="$zone" --query-port="$port" >/dev/null 2>&1; then
        runtime=true
    fi
    if [[ "$permanent" != true ]]; then
        run_command firewall-cmd --zone="$zone" --add-port="$port" --permanent || return $?
        FIREWALL_CHANGED=true
    fi
    if [[ "$runtime" != true ]]; then
        run_command firewall-cmd --zone="$zone" --add-port="$port" || return $?
        FIREWALL_CHANGED=true
    fi
}

firewall_plan_port() {
    local zone=$1
    local port=$2
    local permanent=false
    local runtime=false

    if firewall-cmd --zone="$zone" --query-port="$port" --permanent >/dev/null 2>&1; then
        permanent=true
    fi
    if firewall-cmd --zone="$zone" --query-port="$port" >/dev/null 2>&1; then
        runtime=true
    fi
    if [[ "$permanent" != true ]]; then
        plan "add $port permanently to active firewalld zone $zone"
    fi
    if [[ "$runtime" != true ]]; then
        plan "add $port at runtime to active firewalld zone $zone"
    fi
    if [[ "$permanent" == true && "$runtime" == true ]]; then
        log_info "firewalld zone $zone already allows $port permanently and at runtime"
    fi
}

firewall_service_enabled_in_zone() {
    local zone=$1
    local service=$2
    firewall-cmd --zone="$zone" --query-service="$service" --permanent >/dev/null 2>&1 || return 1
    firewall-cmd --zone="$zone" --query-service="$service" >/dev/null 2>&1
}

firewall_plan_service() {
    local zone=$1
    local service=$2
    firewall_service_enabled_in_zone "$zone" "$service" || plan "add $service to active firewalld zone $zone permanently and at runtime"
}

firewall_effective_backend() {
    if [[ "${FIREWALL_BACKEND:-unknown}" == firewalld || "${FIREWALL_BACKEND:-unknown}" == ufw ]]; then
        printf '%s' "$FIREWALL_BACKEND"
        return 0
    fi
    if [[ "${FIREWALL_STATE:-}" == active ]]; then
        if command_exists firewall-cmd && firewall-cmd --state >/dev/null 2>&1; then
            FIREWALL_BACKEND=firewalld
        elif command_exists ufw && grep -Eiq '^Status:[[:space:]]*active([[:space:]]|$)' < <(ufw status 2>/dev/null || true); then
            FIREWALL_BACKEND=ufw
        fi
    fi
    printf '%s' "${FIREWALL_BACKEND:-unknown}"
}

firewall_technitium_dns_restricted() {
    [[ -n "${TECHNITIUM_DNS_CLIENT_NETWORKS:-}" ]]
}

firewall_technitium_add_port() {
    local spec=$1
    local description=$2
    local existing
    [[ "$spec" =~ ^[1-9][0-9]{0,4}/(tcp|udp)$ ]] || return 1
    for existing in "${TECHNITIUM_REQUIRED_PORTS[@]}"; do
        [[ "${existing%%|*}" != "$spec" ]] || return 0
    done
    TECHNITIUM_REQUIRED_PORTS+=("$spec|$description")
}

firewall_technitium_add_source_rule() {
    local source=$1
    local spec=$2
    local existing
    for existing in "${TECHNITIUM_SOURCE_RULES[@]}"; do
        [[ "$existing" != "$source|$spec" ]] || return 0
    done
    TECHNITIUM_SOURCE_RULES+=("$source|$spec")
}

firewall_technitium_add_internal_port() {
    local spec=$1
    local description=$2
    local existing
    [[ "$spec" =~ ^[1-9][0-9]{0,4}/(tcp|udp)$ ]] || return 1
    for existing in "${TECHNITIUM_INTERNAL_PORTS[@]}"; do
        [[ "${existing%%|*}" != "$spec" ]] || return 0
    done
    TECHNITIUM_INTERNAL_PORTS+=("$spec|$description")
}

firewall_technitium_listener_is_external() {
    local spec=$1
    local port=${spec%/*}
    local protocol=${spec#*/}
    local output='' command_status=0
    command_exists ss || return 0
    case "$protocol" in
        tcp) output=$(ss -H -lnt 2>/dev/null) || command_status=$? ;;
        udp) output=$(ss -H -lnu 2>/dev/null) || command_status=$? ;;
        *) return 1 ;;
    esac
    (( command_status == 0 )) || return 0
    [[ -n "$output" ]] || return 1
    awk -v port="$port" '
        function loopback(endpoint) {
            return endpoint ~ /^127\./ || endpoint ~ /^\[?::1\]?([:%]|$)/ || endpoint ~ /^localhost/
        }
        $4 ~ (":" port "$") && !loopback($4) { found=1 }
        END { exit(found ? 0 : 1) }
    ' <<< "$output"
}

firewall_technitium_configured_port() {
    local field=$1
    local default=$2
    local value=''
    if command_exists python3 && [[ -n "${TECHNITIUM_SETTINGS_JSON:-}" ]]; then
        value=$(python3 -c '
import json, sys
try:
    settings = (json.load(sys.stdin).get("response") or {})
    number = int(settings.get(sys.argv[1], sys.argv[2]))
    if 1 <= number <= 65535:
        print(number)
except (ValueError, TypeError, KeyError, json.JSONDecodeError):
    pass
' "$field" "$default" <<< "$TECHNITIUM_SETTINGS_JSON" 2>/dev/null || true)
    fi
    if [[ "$value" =~ ^[1-9][0-9]{0,4}$ ]]; then
        printf '%s' "$value"
    else
        printf '%s' "$default"
    fi
}

firewall_technitium_add_listener_port() {
    local spec=$1
    local description=$2
    if firewall_technitium_listener_is_external "$spec"; then
        firewall_technitium_add_port "$spec" "$description"
    else
        log_warn "Technitium reports $description on $spec, but no external listener was observed; skipping that firewall port"
    fi
    return 0
}

firewall_technitium_collect_api_features() {
    local parsed feature port enabled
    command_exists python3 || return 0
    [[ -n "${TECHNITIUM_SETTINGS_JSON:-}" ]] || return 0
    parsed=$(python3 -c '
import json, sys
try:
    value = json.load(sys.stdin)
    settings = value.get("response") or {}
except Exception:
    raise SystemExit(0)

def boolean(name, default=False):
    value = settings.get(name, default)
    return value is True or str(value).lower() == "true"

def port(name, default):
    value = settings.get(name, default)
    try:
        number = int(value)
    except (TypeError, ValueError):
        number = default
    return number if 1 <= number <= 65535 else default

def external(addresses):
    if not isinstance(addresses, list):
        return False
    for address in addresses:
        text = str(address).strip().lower().strip("[]")
        if text in ("", "0.0.0.0", "::", "*"):
            return True
        if text.startswith("127.") or text in ("::1", "localhost"):
            continue
        return True
    return False

web_external = external(settings.get("webServiceLocalAddresses") or [])
http_port = port("webServiceHttpPort", 5380)
tls_port = port("webServiceTlsPort", 53443)
if web_external:
    print("web-http|%d|1" % http_port)
    if boolean("webServiceEnableTls") or boolean("clusterInitialized"):
        print("web-https|%d|1" % tls_port)
    if boolean("webServiceEnableHttp3"):
        print("web-http3|%d|1" % tls_port)
if boolean("enableDnsOverHttp") and not boolean("enableDnsOverHttpUnixSocket"):
    print("doh-http|%d|1" % port("dnsOverHttpPort", 80))
if boolean("enableDnsOverTls"):
    print("dot|%d|1" % port("dnsOverTlsPort", 853))
if boolean("enableDnsOverHttps") and not boolean("enableDnsOverHttpsUnixSocket"):
    print("doh|%d|1" % port("dnsOverHttpsPort", 443))
if boolean("enableDnsOverHttp3"):
    print("doh3|%d|1" % port("dnsOverHttpsPort", 443))
if boolean("enableDnsOverQuic"):
    print("doq|%d|1" % port("dnsOverQuicPort", 853))
if boolean("clusterInitialized"):
    print("cluster|%d|1" % tls_port)
' <<< "$TECHNITIUM_SETTINGS_JSON" 2>/dev/null || true)
    while IFS='|' read -r feature port enabled; do
        [[ "$enabled" == 1 && "$port" =~ ^[1-9][0-9]{0,4}$ ]] || continue
        case "$feature" in
            web-http) firewall_technitium_add_listener_port "$port/tcp" 'Technitium Web Console HTTP' ;;
            web-https) firewall_technitium_add_listener_port "$port/tcp" 'Technitium Web Console HTTPS' ;;
            web-http3) firewall_technitium_add_listener_port "$port/udp" 'Technitium Web Console HTTP/3' ;;
            doh-http) firewall_technitium_add_listener_port "$port/tcp" 'Technitium DNS-over-HTTP' ;;
            dot) firewall_technitium_add_listener_port "$port/tcp" 'Technitium DNS-over-TLS' ;;
            doh) firewall_technitium_add_listener_port "$port/tcp" 'Technitium DNS-over-HTTPS' ;;
            doh3) firewall_technitium_add_listener_port "$port/udp" 'Technitium DNS-over-HTTPS HTTP/3' ;;
            doq) firewall_technitium_add_listener_port "$port/udp" 'Technitium DNS-over-QUIC' ;;
            cluster) firewall_technitium_add_internal_port "$port/tcp" 'Technitium cluster Web HTTPS' ;;
        esac
    done <<< "$parsed"
}

firewall_technitium_collect_dhcp() {
    local parsed
    command_exists python3 || return 0
    [[ -n "${TECHNITIUM_DHCP_SCOPES_JSON:-}" ]] || return 0
    parsed=$(python3 -c '
import json, sys
try:
    value = json.load(sys.stdin)
    scopes = (value.get("response") or {}).get("scopes") or []
except Exception:
    scopes = []
print("true" if any(item.get("enabled") is True for item in scopes if isinstance(item, dict)) else "false")
' <<< "$TECHNITIUM_DHCP_SCOPES_JSON" 2>/dev/null || true)
    if [[ "$parsed" == true ]]; then
        firewall_technitium_add_port '67/udp' 'Technitium DHCP'
    fi
    return 0
}

firewall_technitium_collect_ports() {
    local transfer_port
    TECHNITIUM_REQUIRED_PORTS=()
    TECHNITIUM_INTERNAL_PORTS=()
    TECHNITIUM_SOURCE_RULES=()
    if [[ -z "${TECHNITIUM_SETTINGS_JSON:-}" ]] && ! is_dry_run && declare -F technitium_api_call >/dev/null 2>&1; then
        TECHNITIUM_SETTINGS_JSON=$(technitium_api_call GET '/api/settings/get' 2>/dev/null || true)
    fi
    if [[ -z "${TECHNITIUM_DHCP_SCOPES_JSON:-}" ]] && ! is_dry_run && declare -F technitium_api_call >/dev/null 2>&1; then
        TECHNITIUM_DHCP_SCOPES_JSON=$(technitium_api_call GET '/api/dhcp/scopes/list' 2>/dev/null || true)
    fi
    if ! firewall_technitium_dns_restricted; then
        firewall_technitium_add_port '53/tcp' 'Technitium DNS TCP'
        firewall_technitium_add_port '53/udp' 'Technitium DNS UDP'
    fi
    case "${TECHNITIUM_ZONE_TRANSFER_PROTOCOL:-Tcp}" in
        Tls)
            transfer_port=$(firewall_technitium_configured_port dnsOverTlsPort 853)
            firewall_technitium_add_internal_port "$transfer_port/tcp" 'Technitium XFR-over-TLS'
            ;;
        Quic)
            transfer_port=$(firewall_technitium_configured_port dnsOverQuicPort 853)
            firewall_technitium_add_internal_port "$transfer_port/udp" 'Technitium XFR-over-QUIC'
            ;;
        Tcp) ;;
        *) log_warn "unknown Technitium transfer protocol '${TECHNITIUM_ZONE_TRANSFER_PROTOCOL:-}' while planning firewall ports" ;;
    esac
    firewall_technitium_collect_api_features
    firewall_technitium_collect_dhcp

    if firewall_technitium_dns_restricted || (( ${#TECHNITIUM_INTERNAL_PORTS[@]} > 0 )); then
        local network entry ip internal
        if ! declare -F topology_dns_nodes >/dev/null 2>&1 || ! topology_dns_nodes >/dev/null 2>&1; then
            log_error 'could not build the configured DNS_NODES[] topology for Technitium firewall source rules'
            return 1
        fi
        for entry in "${DNS_NODES[@]}"; do
            ip=$(topology_dns_node_ip "$entry")
            if firewall_technitium_dns_restricted; then
                firewall_technitium_add_source_rule "$ip" '53/tcp'
                firewall_technitium_add_source_rule "$ip" '53/udp'
            fi
            for internal in "${TECHNITIUM_INTERNAL_PORTS[@]}"; do
                firewall_technitium_add_source_rule "$ip" "${internal%%|*}"
            done
        done
        parse_space_list "${TECHNITIUM_DNS_CLIENT_NETWORKS//,/ }"
        for network in "${PARSED_WORDS[@]}"; do
            firewall_technitium_add_source_rule "$network" '53/tcp'
            firewall_technitium_add_source_rule "$network" '53/udp'
        done
    fi
    return 0
}

firewall_source_rule_key() {
    local backend=$1 zone=$2 source=$3 spec=$4
    printf '%s|%s|%s|%s' "$backend" "$zone" "$source" "$spec"
}

firewall_metadata_file() {
    printf '%s/technitium-firewall.rules' "${IPA_STATE_DIR:-/var/lib/freeipa-bootstrap}"
}

firewall_load_managed_source_rules() {
    TECHNITIUM_PREVIOUS_SOURCE_RULES=()
    local path=${1:-$(firewall_metadata_file)} line
    [[ -f "$path" && ! -L "$path" ]] || return 0
    while IFS= read -r line; do
        [[ "$line" == *'|'* ]] || continue
        TECHNITIUM_PREVIOUS_SOURCE_RULES+=("$line")
    done < "$path"
}

firewall_record_managed_source_rule() {
    local key=$1 existing
    for existing in "${TECHNITIUM_MANAGED_SOURCE_RULES[@]}"; do
        [[ "$existing" != "$key" ]] || return 0
    done
    TECHNITIUM_MANAGED_SOURCE_RULES+=("$key")
}

firewall_managed_source_rule_recorded() {
    local key=$1 existing
    for existing in "${TECHNITIUM_MANAGED_SOURCE_RULES[@]}"; do
        [[ "$existing" == "$key" ]] && return 0
    done
    return 1
}

firewall_metadata_write() {
    if is_dry_run || is_check; then
        return 0
    fi
    local path=${1:-$(firewall_metadata_file)} temporary line
    install -d -m 0750 -- "$(dirname "$path")"
    temporary=$(mktemp "${path}.XXXXXX")
    chmod 0600 "$temporary"
    for line in "${TECHNITIUM_MANAGED_SOURCE_RULES[@]}"; do
        printf '%s\n' "$line" >> "$temporary"
    done
    atomic_replace_file "$temporary" "$path"
    chmod 0640 "$path"
}

firewall_ufw_status() {
    ufw status 2>/dev/null || true
}

firewall_ufw_line_matches_spec() {
    local spec=$1
    local line=$2
    [[ "$line" == "$spec" || "$line" == "$spec "* || "$line" == "$spec ("* ]]
}

firewall_ufw_rule_exists() {
    local spec=$1 source=${2:-} line output
    output=$(firewall_ufw_status)
    while IFS= read -r line; do
        firewall_ufw_line_matches_spec "$spec" "$line" && [[ "$line" == *ALLOW* ]] || continue
        if [[ -n "$source" ]]; then
            [[ "$line" == *"$source"* ]] && return 0
        elif [[ "$line" == *Anywhere* ]]; then
            return 0
        fi
    done <<< "$output"
    return 1
}

firewall_ufw_managed_rule_exists() {
    local spec=$1 source=$2 line output
    output=$(firewall_ufw_status)
    while IFS= read -r line; do
        firewall_ufw_line_matches_spec "$spec" "$line" && [[ "$line" == *"$source"* && "$line" == *freeipa-bootstrap-technitium* && "$line" == *ALLOW* ]] && return 0
    done <<< "$output"
    return 1
}

firewall_ufw_add_global_if_needed() {
    local spec=$1 tag=${FIREWALL_RULE_TAG:-freeipa-bootstrap}
    firewall_ufw_rule_exists "$spec" || {
        run_command ufw allow "$spec" comment "$tag" || return $?
        FIREWALL_CHANGED=true
    }
}

firewall_ufw_add_source_if_needed() {
    local source=$1 spec=$2 port=${2%/*} protocol=${2#*/} key
    key=$(firewall_source_rule_key ufw - "$source" "$spec")
    if firewall_ufw_rule_exists "$spec" "$source"; then
        if firewall_ufw_managed_rule_exists "$spec" "$source" || printf '%s\n' "${TECHNITIUM_PREVIOUS_SOURCE_RULES[@]}" | grep -Fqx "$key"; then
            firewall_record_managed_source_rule "$key"
        fi
        return 0
    fi
    run_command ufw allow from "$source" to any port "$port" proto "$protocol" comment freeipa-bootstrap-technitium || return $?
    firewall_record_managed_source_rule "$key"
    FIREWALL_CHANGED=true
}

firewall_ufw_remove_managed_source() {
    local source=$1 spec=$2 port=${2%/*} protocol=${2#*/}
    firewall_ufw_managed_rule_exists "$spec" "$source" || return 0
    run_command ufw delete allow from "$source" to any port "$port" proto "$protocol" comment freeipa-bootstrap-technitium || return $?
    FIREWALL_CHANGED=true
}

firewall_reconcile_source_rule_metadata() {
    local backend=$1 zone=$2 old rest old_backend old_zone old_source old_spec key
    for old in "${TECHNITIUM_PREVIOUS_SOURCE_RULES[@]}"; do
        old_backend=${old%%|*}
        rest=${old#*|}; old_zone=${rest%%|*}
        rest=${rest#*|}; old_source=${rest%%|*}
        old_spec=${rest#*|}
        [[ "$old_backend" == "$backend" && "$old_zone" == "$zone" ]] || continue
        key=$(firewall_source_rule_key "$backend" "$zone" "$old_source" "$old_spec")
        firewall_managed_source_rule_recorded "$key" && continue
        if [[ "$backend" == ufw ]]; then
            firewall_ufw_remove_managed_source "$old_source" "$old_spec" || {
                log_warn "could not remove stale installer-managed UFW rule $old_source $old_spec; keeping metadata"
                firewall_record_managed_source_rule "$key"
            }
        else
            local port=${old_spec%/*} protocol=${old_spec#*/}
            local rule="rule family=\"ipv4\" source address=\"$old_source\" port port=\"$port\" protocol=\"$protocol\" accept"
            if firewall-cmd --zone="$old_zone" --query-rich-rule="$rule" --permanent >/dev/null 2>&1; then
                run_command firewall-cmd --zone="$old_zone" --remove-rich-rule="$rule" --permanent || {
                    firewall_record_managed_source_rule "$key"
                    continue
                }
                FIREWALL_CHANGED=true
            fi
            if firewall-cmd --zone="$old_zone" --query-rich-rule="$rule" >/dev/null 2>&1; then
                run_command firewall-cmd --zone="$old_zone" --remove-rich-rule="$rule" || {
                    firewall_record_managed_source_rule "$key"
                    continue
                }
                FIREWALL_CHANGED=true
            fi
        fi
    done
}

firewall_standard_ports() {
    local -a ports=(389/tcp 636/tcp 88/tcp 88/udp 464/tcp 464/udp 80/tcp 443/tcp 123/udp)
    if [[ "$IPA_DNS_MODE" == integrated || "$DNS_BACKEND" == bind9_webmin || "$DNS_BACKEND" == technitium ]]; then
        if [[ "$DNS_BACKEND" != technitium ]] || ! firewall_technitium_dns_restricted; then
            ports+=(53/tcp 53/udp)
        fi
    fi
    printf '%s\n' "${ports[@]}"
}

firewall_add_rich_rule_if_needed() {
    local zone=$1
    local rule=$2
    local permanent=false runtime=false
    firewall-cmd --zone="$zone" --query-rich-rule="$rule" --permanent >/dev/null 2>&1 && permanent=true
    firewall-cmd --zone="$zone" --query-rich-rule="$rule" >/dev/null 2>&1 && runtime=true
    if [[ "$permanent" != true ]]; then
        run_command firewall-cmd --zone="$zone" --add-rich-rule="$rule" --permanent || return $?
        FIREWALL_CHANGED=true
    fi
    if [[ "$runtime" != true ]]; then
        run_command firewall-cmd --zone="$zone" --add-rich-rule="$rule" || return $?
        FIREWALL_CHANGED=true
    fi
}

firewall_plan_rich_rule() {
    local zone=$1 rule=$2
    firewall-cmd --zone="$zone" --query-rich-rule="$rule" --permanent >/dev/null 2>&1 || plan "add managed source rule permanently to firewalld zone $zone: $rule"
    firewall-cmd --zone="$zone" --query-rich-rule="$rule" >/dev/null 2>&1 || plan "add managed source rule at runtime to firewalld zone $zone: $rule"
}

firewall_configure_ufw() {
    local -a required_ports=()
    local port spec source source_address
    while IFS= read -r port; do
        [[ -n "$port" ]] && required_ports+=("$port")
    done < <(firewall_standard_ports)
    firewall_webmin_required && required_ports+=("${WEBMIN_PORT}/tcp")
    if [[ "$DNS_BACKEND" == technitium ]]; then
        for spec in "${TECHNITIUM_REQUIRED_PORTS[@]}"; do
            required_ports+=("${spec%%|*}")
        done
    fi

    if is_dry_run || is_check; then
        for spec in "${required_ports[@]}"; do
            is_dry_run && { firewall_ufw_rule_exists "$spec" || plan "allow $spec in active UFW with a bootstrap description"; }
            if is_check && ! firewall_ufw_rule_exists "$spec"; then
                log_error "active UFW is missing required rule $spec"
                return 1
            fi
        done
        if [[ "$DNS_BACKEND" == technitium ]]; then
            for source in "${TECHNITIUM_SOURCE_RULES[@]}"; do
                source_address=${source%%|*}
                spec=${source#*|}
                is_dry_run && { firewall_ufw_rule_exists "$spec" "$source_address" || plan "allow $spec from $source_address in active UFW"; }
                if is_check && ! firewall_ufw_rule_exists "$spec" "$source_address"; then
                    log_error "active UFW is missing required Technitium source rule $source_address $spec"
                    return 1
                fi
            done
        fi
        FIREWALL_STATUS=planned
        return 0
    fi

    FIREWALL_CHANGED=false
    FIREWALL_RULE_TAG=freeipa-bootstrap
    for spec in "${required_ports[@]}"; do
        firewall_ufw_add_global_if_needed "$spec" || return 1
    done
    if [[ "$DNS_BACKEND" == technitium ]]; then
        firewall_load_managed_source_rules
        TECHNITIUM_MANAGED_SOURCE_RULES=()
        FIREWALL_RULE_TAG=freeipa-bootstrap-technitium
        for source in "${TECHNITIUM_SOURCE_RULES[@]}"; do
            source_address=${source%%|*}
            spec=${source#*|}
            firewall_ufw_add_source_if_needed "$source_address" "$spec" || return 1
        done
        firewall_reconcile_source_rule_metadata ufw -
        firewall_metadata_write
    fi
    if [[ "$FIREWALL_CHANGED" == true ]]; then
        FIREWALL_STATUS=active-configured
        state_mark_resource ufw modified-by-bootstrap
        log_info 'UFW configured without resetting rules, changing default policies, or enabling/disabling the firewall'
    else
        FIREWALL_STATUS=active-validated
        log_info 'UFW already contains the required FreeIPA/Technitium rules; no changes were needed'
    fi
}

firewall_configure_firewalld() {
    firewall_discover_active_zones || return 1
    local restricted=false
    [[ "$DNS_BACKEND" == technitium ]] && firewall_technitium_dns_restricted && restricted=true

    if is_dry_run || is_check; then
        local zone spec port source source_address source_port source_protocol rule missing=false
        if firewall_webmin_required; then
            for zone in "${FIREWALL_ZONES[@]}"; do
                is_dry_run && firewall_plan_port "$zone" "${WEBMIN_PORT}/tcp"
                if is_check && { ! firewall-cmd --zone="$zone" --query-port="${WEBMIN_PORT}/tcp" --permanent >/dev/null 2>&1 || ! firewall-cmd --zone="$zone" --query-port="${WEBMIN_PORT}/tcp" >/dev/null 2>&1; }; then
                    missing=true
                fi
            done
        fi
        for zone in "${FIREWALL_ZONES[@]}"; do
            if [[ "$DNS_BACKEND" == technitium ]]; then
                for spec in "${TECHNITIUM_REQUIRED_PORTS[@]}"; do
                    port=${spec%%|*}
                    if [[ "$port" == 53/tcp || "$port" == 53/udp ]] && firewall_service_exists dns; then
                        if is_dry_run; then
                            firewall_plan_service "$zone" dns
                        elif is_check && ! firewall_service_enabled_in_zone "$zone" dns; then
                            missing=true
                        fi
                        continue
                    fi
                    is_dry_run && firewall_plan_port "$zone" "$port"
                    if is_check && { ! firewall-cmd --zone="$zone" --query-port="$port" --permanent >/dev/null 2>&1 || ! firewall-cmd --zone="$zone" --query-port="$port" >/dev/null 2>&1; }; then
                        missing=true
                    fi
                done
                for source in "${TECHNITIUM_SOURCE_RULES[@]}"; do
                    source_address=${source%%|*}
                    spec=${source#*|}
                    source_port=${spec%/*}
                    source_protocol=${spec#*/}
                    rule="rule family=\"ipv4\" source address=\"$source_address\" port port=\"$source_port\" protocol=\"$source_protocol\" accept"
                    is_dry_run && firewall_plan_rich_rule "$zone" "$rule"
                    if is_check && { ! firewall-cmd --zone="$zone" --query-rich-rule="$rule" --permanent >/dev/null 2>&1 || ! firewall-cmd --zone="$zone" --query-rich-rule="$rule" >/dev/null 2>&1; }; then
                        missing=true
                    fi
                done
            fi
        done
        if is_dry_run; then
            plan "configure active firewalld zone(s) ${FIREWALL_ZONES[*]} for FreeIPA${DNS_FIREWALL_REQUIRED:+ and DNS}"
            FIREWALL_STATUS=planned
            return 0
        fi
        if [[ "$missing" == true ]]; then
            FIREWALL_STATUS=active-missing
            log_error 'active firewalld is missing one or more required rules; rerun normal mode to add only missing rules'
            return 1
        fi
        FIREWALL_STATUS=active-validated
        return 0
    fi

    FIREWALL_CHANGED=false
    local -a services=(freeipa-ldap freeipa-ldaps kerberos http https)
    if [[ "$IPA_DNS_MODE" == integrated || "$DNS_BACKEND" == bind9_webmin || ( "$DNS_BACKEND" == technitium && "$restricted" != true ) ]]; then
        services+=(dns)
    fi
    services+=(ntp)
    local zone service missing_standard port spec source source_address source_port source_protocol rule key had_rule
    if [[ "$DNS_BACKEND" == technitium ]]; then
        firewall_load_managed_source_rules
        TECHNITIUM_MANAGED_SOURCE_RULES=()
    fi
    for zone in "${FIREWALL_ZONES[@]}"; do
        missing_standard=false
        for service in "${services[@]}"; do
            if firewall_service_exists "$service"; then
                firewall_add_service_if_needed "$zone" "$service" || return 1
            else
                missing_standard=true
            fi
        done
        if [[ "$missing_standard" == true ]]; then
            while IFS= read -r port; do
                [[ -n "$port" ]] || continue
                firewall_add_port_if_needed "$zone" "$port" || return 1
            done < <(firewall_standard_ports)
        fi
        if firewall_webmin_required; then
            firewall_add_port_if_needed "$zone" "${WEBMIN_PORT}/tcp" || return 1
        fi
        if [[ "$DNS_BACKEND" == technitium ]]; then
            for spec in "${TECHNITIUM_REQUIRED_PORTS[@]}"; do
                port=${spec%%|*}
                [[ "$port" == 53/tcp || "$port" == 53/udp ]] && firewall_service_exists dns && continue
                firewall_add_port_if_needed "$zone" "$port" || return 1
            done
            for source in "${TECHNITIUM_SOURCE_RULES[@]}"; do
                source_address=${source%%|*}
                spec=${source#*|}
                source_port=${spec%/*}
                source_protocol=${spec#*/}
                rule="rule family=\"ipv4\" source address=\"$source_address\" port port=\"$source_port\" protocol=\"$source_protocol\" accept"
                had_rule=false
                firewall-cmd --zone="$zone" --query-rich-rule="$rule" --permanent >/dev/null 2>&1 && had_rule=true
                firewall-cmd --zone="$zone" --query-rich-rule="$rule" >/dev/null 2>&1 && had_rule=true
                firewall_add_rich_rule_if_needed "$zone" "$rule" || return 1
                key=$(firewall_source_rule_key firewalld "$zone" "$source_address" "$spec")
                if [[ "$had_rule" == false ]] || printf '%s\n' "${TECHNITIUM_PREVIOUS_SOURCE_RULES[@]}" | grep -Fqx "$key"; then
                    firewall_record_managed_source_rule "$key"
                fi
            done
        fi
    done
    if [[ "$DNS_BACKEND" == technitium ]]; then
        for zone in "${FIREWALL_ZONES[@]}"; do
            firewall_reconcile_source_rule_metadata firewalld "$zone"
        done
        firewall_metadata_write
    fi
    if [[ "$FIREWALL_CHANGED" == true ]]; then
        run_command firewall-cmd --reload || return $?
        FIREWALL_STATUS=active-configured
        state_mark_resource firewalld modified-by-bootstrap
        log_info 'firewalld configured without enabling a previously inactive firewall or modifying unrelated zones'
    else
        FIREWALL_STATUS=active-validated
        log_info 'firewalld already contains the required FreeIPA/Technitium rules; no reload was needed'
    fi
}

firewall_configure() {
    log_stage firewall
    if [[ "${FIREWALL_STATE:-}" != active ]]; then
        log_info 'firewall is not active; no firewall changes will be made'
        FIREWALL_STATUS=${FIREWALL_STATE:-unavailable}
        return 0
    fi
    local backend
    backend=$(firewall_effective_backend)
    [[ "$backend" == firewalld || "$backend" == ufw ]] || {
        log_info 'no supported active firewall backend was detected; no firewall changes will be made'
        FIREWALL_STATUS=unavailable
        return 0
    }
    if firewall_webmin_required && declare -F dns_provider_validate_webmin >/dev/null 2>&1; then
        dns_provider_validate_webmin || return 1
    fi
    if [[ "$DNS_BACKEND" == technitium ]]; then
        firewall_technitium_collect_ports || return 1
    else
        TECHNITIUM_REQUIRED_PORTS=()
        TECHNITIUM_INTERNAL_PORTS=()
        TECHNITIUM_SOURCE_RULES=()
    fi
    if [[ "$backend" == ufw ]]; then
        firewall_configure_ufw
    else
        firewall_configure_firewalld
    fi
}

