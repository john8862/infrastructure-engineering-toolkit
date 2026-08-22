#!/usr/bin/env bash

# Shared topology helpers.  These functions do not change the host by
# themselves; callers decide whether they are running in check, dry-run, or
# normal mode before invoking mutating provider functions.

: "${DNS_AUTHORITATIVE_REVERSE_ZONES:=}"
: "${DNS_PRIMARY_SERVER:=}"
: "${DNS_PRIMARY_IP:=}"
: "${DNS_SECONDARY_SERVER:=}"
: "${DNS_SECONDARY_IP:=}"
: "${DNS_ADDITIONAL_NODES:=}"
: "${DNS_TRANSFER_SECURITY:=tsig}"
: "${DNS_TRANSFER_KEY_NAME:=freeipa-bootstrap-transfer}"
: "${DNS_TRANSFER_KEY_FILE:=/etc/named/freeipa-bootstrap-transfer.key}"
: "${DNS_TRANSFER_KEY_SECRET:=}"
: "${DNS_TSIG_ENABLED:=$([[ "$DNS_TRANSFER_SECURITY" == tsig ]] && printf true || printf false)}"
: "${DNS_TSIG_KEY_NAME:=$DNS_TRANSFER_KEY_NAME}"
: "${DNS_TSIG_KEY_FILE:=$DNS_TRANSFER_KEY_FILE}"
: "${DNS_TRANSFER_WAIT_SECONDS:=90}"
: "${DNS_TRANSFER_POLL_SECONDS:=3}"
: "${DNS_BIND_SLAVE_DIR:=/var/named/slaves}"
: "${WEBMIN_PEER_SERVER:=}"
: "${WEBMIN_PEER_IP:=}"
: "${WEBMIN_PEER_PORT:=10000}"
: "${WEBMIN_PEER_USERNAME:=}"
: "${WEBMIN_PEER_PASSWORD:=}"

DNS_REVERSE_ZONES=()
DNS_NODES=()

topology_primary_server() {
    printf '%s' "${DNS_PRIMARY_SERVER:-${IPA_HOSTNAME}}"
}

topology_primary_ip() {
    printf '%s' "${DNS_PRIMARY_IP:-${IPA_IP_ADDRESS}}"
}

topology_secondary_server() {
    if [[ -n "${DNS_SECONDARY_SERVER:-}" ]]; then
        printf '%s' "$DNS_SECONDARY_SERVER"
    elif [[ "${DNS_SERVER_ROLE:-primary}" == secondary ]]; then
        printf '%s' "$IPA_HOSTNAME"
    fi
}

topology_secondary_ip() {
    if [[ -n "${DNS_SECONDARY_IP:-}" ]]; then
        printf '%s' "$DNS_SECONDARY_IP"
    elif [[ "${DNS_SERVER_ROLE:-primary}" == secondary ]]; then
        printf '%s' "$IPA_IP_ADDRESS"
    fi
}

topology_webmin_peer_server() {
    printf '%s' "${WEBMIN_PEER_SERVER:-$(topology_secondary_server)}"
}

topology_webmin_peer_ip() {
    printf '%s' "${WEBMIN_PEER_IP:-$(topology_secondary_ip)}"
}

topology_reverse_zones() {
    DNS_REVERSE_ZONES=()
    parse_space_list "${DNS_AUTHORITATIVE_REVERSE_ZONES:-}"
    if (( ${#PARSED_WORDS[@]} > 0 )); then
        local zone
        for zone in "${PARSED_WORDS[@]}"; do
            zone=${zone%.}
            validate_fqdn "$zone" || return 1
            [[ "${zone,,}" == *.in-addr.arpa || "${zone,,}" == *.ip6.arpa ]] || return 1
            DNS_REVERSE_ZONES+=("$zone")
        done
    elif [[ "${DNS_SERVER_ROLE:-primary}" == secondary ]]; then
        # A secondary must not guess which reverse zones are authoritative.
        # The primary may serve several disjoint networks, and a new subnet
        # must never be silently invented from the local address.
        return 1
    else
        DNS_REVERSE_ZONES+=("${IPA_REVERSE_ZONE%.}")
    fi
    printf '%s\n' "${DNS_REVERSE_ZONES[@]}"
}

topology_reverse_zone_for_ip() {
    local address=${1:-}
    local zone
    validate_ipv4 "$address" || return 1
    zone=$(reverse_zone_for_ipv4 "$address") || return 1
    topology_reverse_zones >/dev/null || return 1
    local configured
    for configured in "${DNS_REVERSE_ZONES[@]}"; do
        [[ "${configured,,}" == "${zone,,}" ]] && {
            printf '%s' "$configured"
            return 0
        }
    done
    return 1
}

topology_has_dns_secondary() {
    [[ -n "$(topology_secondary_server)" && -n "$(topology_secondary_ip)" ]]
}

topology_dns_nodes() {
    DNS_NODES=()
    local primary_server primary_ip secondary_server secondary_ip node name address entry
    primary_server=$(topology_primary_server)
    primary_ip=$(topology_primary_ip)
    validate_fqdn "$primary_server" || return 1
    validate_ipv4 "$primary_ip" || return 1
    DNS_NODES+=("$primary_server|$primary_ip")

    secondary_server=$(topology_secondary_server)
    secondary_ip=$(topology_secondary_ip)
    if [[ -n "$secondary_server" || -n "$secondary_ip" ]]; then
        validate_fqdn "$secondary_server" || return 1
        validate_ipv4 "$secondary_ip" || return 1
        DNS_NODES+=("$secondary_server|$secondary_ip")
    fi

    parse_space_list "${DNS_ADDITIONAL_NODES:-}"
    for node in "${PARSED_WORDS[@]}"; do
        [[ "$node" == *=* ]] || return 1
        name=${node%%=*}
        address=${node#*=}
        validate_fqdn "$name" || return 1
        validate_ipv4 "$address" || return 1
        for entry in "${DNS_NODES[@]}"; do
            [[ "${entry%%|*}" != "$name" && "${entry#*|}" != "$address" ]] || return 1
        done
        DNS_NODES+=("$name|$address")
    done
    printf '%s\n' "${DNS_NODES[@]}"
}

topology_dns_node_name() {
    printf '%s' "${1%%|*}"
}

topology_dns_node_ip() {
    printf '%s' "${1#*|}"
}

topology_key_name_is_safe() {
    [[ "${DNS_TSIG_KEY_NAME:-${DNS_TRANSFER_KEY_NAME:-}}" =~ ^[A-Za-z0-9_.-]+$ ]]
}

topology_external_dns_enabled() {
    [[ "${IPA_DNS_MODE:-external}" == external && "${DNS_BACKEND:-}" != integrated ]]
}

topology_validate_configuration() {
    local primary_server primary_ip secondary_server secondary_ip
    primary_server=$(topology_primary_server)
    primary_ip=$(topology_primary_ip)
    secondary_server=$(topology_secondary_server)
    secondary_ip=$(topology_secondary_ip)

    [[ "${IPA_SERVER_ROLE:-primary}" == primary || "${IPA_SERVER_ROLE:-primary}" == replica ]] || \
        preflight_error "IPA_SERVER_ROLE must be primary or replica"
    if [[ "${IPA_SERVER_ROLE:-primary}" == replica ]]; then
        validate_fqdn "${IPA_REPLICA_SOURCE:-}" || preflight_error "IPA_REPLICA_SOURCE must be a source-server FQDN when IPA_SERVER_ROLE=replica"
        [[ "${IPA_REPLICA_SOURCE:-}" != "${IPA_HOSTNAME:-}" ]] || preflight_error "IPA_REPLICA_SOURCE must not be the local replica hostname"
        validate_bool "${IPA_REPLICA_SETUP_CA:-true}" || preflight_error "IPA_REPLICA_SETUP_CA must be true or false"
    fi

    [[ "${DNS_SERVER_ROLE:-primary}" == primary || "${DNS_SERVER_ROLE:-primary}" == secondary ]] || \
        preflight_error "DNS_SERVER_ROLE must be primary or secondary"
    if topology_external_dns_enabled; then
        validate_fqdn "$primary_server" || preflight_error "DNS_PRIMARY_SERVER must be a valid FQDN"
        validate_ipv4 "$primary_ip" || preflight_error "DNS_PRIMARY_IP must be a valid IPv4 address"
        if [[ "${DNS_SERVER_ROLE:-primary}" == secondary ]]; then
            [[ -n "$secondary_server" && -n "$secondary_ip" ]] || preflight_error "secondary DNS requires DNS_SECONDARY_SERVER and DNS_SECONDARY_IP (or local defaults)"
            [[ "${DNS_PRIMARY_SERVER:-}" != "$IPA_HOSTNAME" || "$primary_ip" != "$IPA_IP_ADDRESS" ]] || \
                preflight_error "DNS secondary must identify the distinct DNS primary; do not point it at itself"
        elif [[ -n "${DNS_SECONDARY_SERVER:-}" || -n "${DNS_SECONDARY_IP:-}" ]]; then
            validate_fqdn "$secondary_server" || preflight_error "DNS_SECONDARY_SERVER must be a valid FQDN when configured"
            validate_ipv4 "$secondary_ip" || preflight_error "DNS_SECONDARY_IP must be a valid IPv4 address when configured"
        fi
        if [[ -n "$secondary_server" || -n "$secondary_ip" ]]; then
            [[ -n "$secondary_server" && -n "$secondary_ip" ]] || preflight_error "DNS_SECONDARY_SERVER and DNS_SECONDARY_IP must be configured together"
            [[ "${primary_ip,,}" != "${secondary_ip,,}" ]] || preflight_error "DNS_PRIMARY_IP and DNS_SECONDARY_IP must be different"
            [[ "${primary_server,,}" != "${secondary_server,,}" ]] || preflight_error "DNS_PRIMARY_SERVER and DNS_SECONDARY_SERVER must be different"
        fi
        if [[ -n "${DNS_ADDITIONAL_NODES:-}" ]]; then
            topology_dns_nodes >/dev/null || preflight_error "DNS_ADDITIONAL_NODES must contain unique FQDN=IPv4 entries and must not duplicate the primary or secondary"
        fi
        [[ "${DNS_TRANSFER_SECURITY:-tsig}" == tsig || "${DNS_TRANSFER_SECURITY:-tsig}" == none ]] || \
            preflight_error "DNS_TRANSFER_SECURITY must be tsig or none"
        topology_key_name_is_safe || preflight_error "DNS_TRANSFER_KEY_NAME contains characters unsafe for a BIND key identifier"
        [[ "${DNS_TRANSFER_KEY_FILE:-}" == /* && "${DNS_TRANSFER_KEY_FILE:-}" != *[[:space:]]* ]] || \
            preflight_error "DNS_TRANSFER_KEY_FILE must be an absolute path without whitespace"
        [[ "${DNS_TRANSFER_KEY_SECRET:-}" != *\"* && "${DNS_TRANSFER_KEY_SECRET:-}" != *\\* && "${DNS_TRANSFER_KEY_SECRET:-}" != *$'\n'* && "${DNS_TRANSFER_KEY_SECRET:-}" != *$'\r'* ]] || \
            preflight_error "DNS_TRANSFER_KEY_SECRET must not contain quotes, backslashes, or newlines"
        if [[ "${DNS_PROVIDER:-}" == technitium ]]; then
            [[ "${TECHNITIUM_ZONE_TRANSFER_PROTOCOL:-Tcp}" == Tcp || "${TECHNITIUM_ZONE_TRANSFER_PROTOCOL:-Tcp}" == Tls || "${TECHNITIUM_ZONE_TRANSFER_PROTOCOL:-Tcp}" == Quic ]] || \
                preflight_error "TECHNITIUM_ZONE_TRANSFER_PROTOCOL must be Tcp, Tls, or Quic"
        fi
    fi

    if [[ "${DNS_SERVER_ROLE:-primary}" == secondary ]]; then
        topology_reverse_zones >/dev/null || preflight_error "DNS_AUTHORITATIVE_REVERSE_ZONES is required on a DNS secondary; do not derive a new reverse zone from the local IP"
    else
        topology_reverse_zones >/dev/null || preflight_error "could not determine the authoritative reverse zone list"
    fi
    if [[ -n "${DNS_AUTHORITATIVE_REVERSE_ZONES:-}" ]]; then
        local address address_zone
        for address in "$IPA_IP_ADDRESS" "$primary_ip" "$secondary_ip"; do
            [[ -n "$address" ]] || continue
            address_zone=$(reverse_zone_for_ipv4 "$address" 2>/dev/null || true)
            [[ -n "$address_zone" ]] || continue
            topology_reverse_zone_for_ip "$address" >/dev/null || \
                preflight_error "DNS_AUTHORITATIVE_REVERSE_ZONES does not include the reverse zone for $address ($address_zone)"
        done
    elif [[ -n "$secondary_ip" ]]; then
        local secondary_reverse_zone
        secondary_reverse_zone=$(reverse_zone_for_ipv4 "$secondary_ip" 2>/dev/null || true)
        [[ "$secondary_reverse_zone" == "${IPA_REVERSE_ZONE%.}" ]] || \
            preflight_error "DNS_SECONDARY_IP uses a different reverse zone; set DNS_AUTHORITATIVE_REVERSE_ZONES explicitly"
    fi

    validate_tcp_port "${WEBMIN_PEER_PORT:-10000}" || preflight_error "WEBMIN_PEER_PORT must be an integer from 1 through 65535"
    if [[ -n "${WEBMIN_PEER_SERVER:-}" ]]; then
        validate_fqdn "$WEBMIN_PEER_SERVER" || preflight_error "WEBMIN_PEER_SERVER must be a valid FQDN"
    fi
    if [[ -n "${WEBMIN_PEER_IP:-}" ]]; then
        validate_ipv4 "$WEBMIN_PEER_IP" || preflight_error "WEBMIN_PEER_IP must be a valid IPv4 address"
    fi
}

