#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
export SCRIPT_DIR
MODE=install
RUN_ID=''
NEW_IP=''
REQUESTED_OLD_IP=''
ENV_IP_OVERRIDDEN=false
UPDATE_IN_TRANSACTION=false
CURRENT_IP=''
OLD_IP=''
OLD_REVERSE_ZONE=''
NEW_REVERSE_ZONE=''
FORWARD_ZONE_FILE=''
OLD_REVERSE_ZONE_FILE=''
NEW_REVERSE_ZONE_FILE=''
UPDATE_CHANGED=false
TOPOLOGY_IP_CHANGED=false

if [[ -v IPA_IP_ADDRESS ]]; then
    ENV_IP_OVERRIDDEN=true
fi

usage() {
    cat <<'EOF'
Usage: ./update-server-ip.sh --new-ip IPv4 [--old-ip IPv4] [--check|--dry-run]

  --new-ip IPv4  New address for the existing IPA host A/PTR mapping.
  --old-ip IPv4  Optional explicit old address when the local interface has
                 already changed but the authoritative managed record has not.
  --check        Read-only consistency validation; no files, DNS, services, or
                 network settings are changed.
  --dry-run      Validate the proposed change and print the transaction plan.
  -h, --help     Show this help.

This utility updates records through the selected DNS backend.  BIND edits only
marked zone records; FreeIPA integrated DNS uses the supported IPA CLI; and
Technitium uses its documented records API.  It does not change the operating-
system interface, the server hostname, IPA LDAP internals, or Kerberos topology.
Hostname changes are not supported.
EOF
}

while (( $# > 0 )); do
    case "$1" in
        --new-ip)
            (( $# >= 2 )) || { printf '%s\n' '--new-ip requires an IPv4 address' >&2; exit 2; }
            NEW_IP=$2
            shift 2
            ;;
        --old-ip)
            (( $# >= 2 )) || { printf '%s\n' '--old-ip requires an IPv4 address' >&2; exit 2; }
            REQUESTED_OLD_IP=$2
            shift 2
            ;;
        --check) MODE=check; shift ;;
        --dry-run) MODE=dry-run; shift ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'Unknown option: %s\n\n' "$1" >&2; usage >&2; exit 2 ;;
    esac
done

[[ -n "$NEW_IP" ]] || { usage >&2; exit 2; }
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
source "$SCRIPT_DIR/lib/firewall.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/dns/provider.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/freeipa.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/validation.sh"

on_error() {
    local rc=$?
    if [[ "$UPDATE_IN_TRANSACTION" == true ]]; then
        log_error "update transaction stopped unexpectedly; attempting to restore its managed backups"
        update_backend_rollback || log_error 'DNS backend rollback failed during unexpected termination'
        if state_restore_current_run_backups; then
            if [[ "${DNS_BACKEND:-}" == bind9_webmin ]] && command_exists systemctl && systemctl is-active --quiet named 2>/dev/null; then
                systemctl reload named >/dev/null 2>&1 || true
            fi
        fi
        UPDATE_IN_TRANSACTION=false
    fi
    log_error "IP update utility stopped at stage '${CURRENT_STAGE:-unknown}' with exit code $rc"
    exit "$rc"
}

cleanup_update() {
    if [[ -n "${IPA_CREDENTIALS_DIR:-}" && -d "$IPA_CREDENTIALS_DIR" ]]; then
        rm -rf -- "$IPA_CREDENTIALS_DIR"
    fi
    release_install_lock
}

trap on_error ERR
trap cleanup_update EXIT

log_readonly_command() {
    log_info "read-only command: $(redact_args "$@")"
    "$@"
}

ip_is_assigned_locally() {
    local address=$1
    command_exists ip || return 1
    ip -o -4 addr show 2>/dev/null | awk -v expected="$address" 'index($4, expected "/") == 1 { found=1 } END { exit !found }'
}

discover_current_ip() {
    if [[ -n "$REQUESTED_OLD_IP" ]]; then
        validate_ipv4 "$REQUESTED_OLD_IP" || {
            log_error "--old-ip must be a valid IPv4 address"
            return 1
        }
        CURRENT_IP=$REQUESTED_OLD_IP
        return 0
    fi
    if validate_ipv4 "$IPA_IP_ADDRESS" && ip_is_assigned_locally "$IPA_IP_ADDRESS"; then
        CURRENT_IP=$IPA_IP_ADDRESS
        return 0
    fi
    command_exists ip || {
        log_error "ip is required to discover the current local address; provide --old-ip only when the DNS primary is being operated remotely"
        return 1
    }
    local -a addresses=()
    local address
    while IFS= read -r address; do
        [[ "$address" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || continue
        if ! printf '%s\n' "${addresses[@]}" | grep -Fqx -- "$address" 2>/dev/null; then
            addresses+=("$address")
        fi
    done < <(ip -o -4 addr show scope global 2>/dev/null | awk '{ split($4, value, "/"); print value[1] }')
    if (( ${#addresses[@]} == 1 )); then
        CURRENT_IP=${addresses[0]}
        log_warn "IPA_IP_ADDRESS=$IPA_IP_ADDRESS is not assigned locally; using the only discovered global IPv4 $CURRENT_IP as the current address"
        return 0
    fi
    log_error "could not unambiguously discover the current local IPv4 address; use --old-ip to identify the authoritative old address"
    return 1
}

current_hostname_is_immutable() {
    local current_host
    current_host=$(hostname --fqdn 2>/dev/null || hostname 2>/dev/null || true)
    [[ "${current_host,,}" == "${IPA_HOSTNAME,,}" ]] || {
        log_error "hostname is '$current_host', but the installed IPA hostname is '$IPA_HOSTNAME'; hostname changes are not supported by update-server-ip.sh"
        return 1
    }
    [[ "${MANAGE_HOSTNAME:-${CONFIGURE_HOSTNAME:-false}}" == false ]] || {
        log_error "MANAGE_HOSTNAME=true is incompatible with an IP-only update; this utility will not change the hostname"
        return 1
    }
}

zone_file_is_managed() {
    local path=$1
    [[ -f "$path" && ! -L "$path" ]] || {
        log_error "managed BIND zone file is missing or symlinked: $path"
        return 1
    }
    grep -Fq "$BIND_ZONE_MARKER" "$path" || {
        log_error "refusing to edit an unmanaged BIND zone file: $path"
        return 1
    }
}

managed_record_stats() {
    local path=$1
    local owner=$2
    local type=$3
    local value=${4:-}
    awk -v begin="$BIND_ZONE_RECORDS_BEGIN" -v end="$BIND_ZONE_RECORDS_END" \
        -v owner="${owner,,}" -v type="$type" -v value="$value" '
        $0 == begin { inside=1; next }
        $0 == end { inside=0; next }
        inside && NF >= 5 && tolower($1) == owner && $3 == "IN" && $4 == type {
            count++
            if (value == "" || $5 == value) matching++
        }
        END { printf "%d %d\n", count + 0, matching + 0 }
    ' "$path"
}

forward_record_conflicts() {
    local path=$1
    local address=$2
    local owner=${3,,}
    awk -v begin="$BIND_ZONE_RECORDS_BEGIN" -v end="$BIND_ZONE_RECORDS_END" \
        -v address="$address" -v owner="$owner" '
        $0 == begin { inside=1; next }
        $0 == end { inside=0; next }
        inside && NF >= 5 && $3 == "IN" && $4 == "A" && $5 == address && tolower($1) != owner { count++ }
        END { exit(count ? 0 : 1) }
    ' "$path"
}

reverse_zone_is_explicit() {
    local zone=$1
    [[ -n "${DNS_AUTHORITATIVE_REVERSE_ZONES:-}" ]] || return 1
    local candidate
    while IFS= read -r candidate; do
        [[ "${candidate,,}" == "${zone,,}" ]] && return 0
    done < <(topology_reverse_zones)
    return 1
}

validate_reverse_zone_selection() {
    OLD_REVERSE_ZONE=$(reverse_zone_for_ipv4 "$OLD_IP")
    NEW_REVERSE_ZONE=$(reverse_zone_for_ipv4 "$NEW_IP")
    if [[ "$OLD_REVERSE_ZONE" != "$NEW_REVERSE_ZONE" && -z "${DNS_AUTHORITATIVE_REVERSE_ZONES:-}" ]]; then
        log_error "new IP $NEW_IP is in $NEW_REVERSE_ZONE, but no explicit DNS_AUTHORITATIVE_REVERSE_ZONES is configured; refusing to invent a reverse zone"
        return 1
    fi
    if [[ -n "${DNS_AUTHORITATIVE_REVERSE_ZONES:-}" ]]; then
        reverse_zone_is_explicit "$OLD_REVERSE_ZONE" || {
            log_error "current reverse zone $OLD_REVERSE_ZONE is not in DNS_AUTHORITATIVE_REVERSE_ZONES"
            return 1
        }
        reverse_zone_is_explicit "$NEW_REVERSE_ZONE" || {
            log_error "new reverse zone $NEW_REVERSE_ZONE is not in DNS_AUTHORITATIVE_REVERSE_ZONES"
            return 1
        }
    fi
    if [[ "${DNS_BACKEND:-}" == bind9_webmin ]]; then
        OLD_REVERSE_ZONE_FILE=$(bind_zone_file "$OLD_REVERSE_ZONE")
        NEW_REVERSE_ZONE_FILE=$(bind_zone_file "$NEW_REVERSE_ZONE")
    else
        OLD_REVERSE_ZONE_FILE=''
        NEW_REVERSE_ZONE_FILE=''
    fi
}

validate_zone_record_state() {
    local host_owner="${IPA_HOSTNAME%.}."
    local old_owner="$(reverse_record_for_ipv4 "$OLD_IP").${OLD_REVERSE_ZONE%.}."
    local new_owner="$(reverse_record_for_ipv4 "$NEW_IP").${NEW_REVERSE_ZONE%.}."
    zone_file_is_managed "$FORWARD_ZONE_FILE"
    zone_file_is_managed "$OLD_REVERSE_ZONE_FILE"
    if [[ "$NEW_REVERSE_ZONE_FILE" != "$OLD_REVERSE_ZONE_FILE" ]]; then
        zone_file_is_managed "$NEW_REVERSE_ZONE_FILE"
    fi

    local stats count matching
    stats=$(managed_record_stats "$FORWARD_ZONE_FILE" "$host_owner" A "$OLD_IP")
    read -r count matching <<< "$stats"
    if [[ "$OLD_IP" == "$NEW_IP" ]]; then
        stats=$(managed_record_stats "$FORWARD_ZONE_FILE" "$host_owner" A "$NEW_IP")
        read -r count matching <<< "$stats"
        [[ "$count" == 1 && "$matching" == 1 ]] || {
            log_error "managed forward zone does not contain exactly one converged A record for $host_owner -> $NEW_IP"
            return 1
        }
    else
        [[ "$count" == 1 && "$matching" == 1 ]] || {
            log_error "managed forward zone must contain exactly one current A record for $host_owner -> $OLD_IP"
            return 1
        }
        stats=$(managed_record_stats "$FORWARD_ZONE_FILE" "$host_owner" A)
        read -r count matching <<< "$stats"
        [[ "$count" == 1 ]] || {
            log_error "managed forward zone contains duplicate or conflicting A records for $host_owner"
            return 1
        }
        if forward_record_conflicts "$FORWARD_ZONE_FILE" "$NEW_IP" "$host_owner"; then
            log_error "new address $NEW_IP is already assigned to another managed forward-zone owner"
            return 1
        fi
    fi

    stats=$(managed_record_stats "$OLD_REVERSE_ZONE_FILE" "$old_owner" PTR "${IPA_HOSTNAME%.}.")
    read -r count matching <<< "$stats"
    if [[ "$OLD_IP" == "$NEW_IP" ]]; then
        [[ "$count" == 1 && "$matching" == 1 ]] || {
            log_error "managed reverse zone does not contain exactly one converged PTR for $old_owner"
            return 1
        }
    elif [[ "$OLD_REVERSE_ZONE" == "$NEW_REVERSE_ZONE" ]]; then
        [[ "$count" == 1 && "$matching" == 1 ]] || {
            log_error "managed reverse zone must contain exactly one current PTR for $old_owner"
            return 1
        }
        stats=$(managed_record_stats "$OLD_REVERSE_ZONE_FILE" "$new_owner" PTR)
        read -r count matching <<< "$stats"
        [[ "$count" == 0 ]] || {
            log_error "new reverse owner $new_owner already exists; refusing to overwrite a conflicting PTR"
            return 1
        }
    else
        [[ "$count" == 1 && "$matching" == 1 ]] || {
            log_error "managed old reverse zone must contain exactly one current PTR for $old_owner"
            return 1
        }
        stats=$(managed_record_stats "$NEW_REVERSE_ZONE_FILE" "$new_owner" PTR)
        read -r count matching <<< "$stats"
        [[ "$count" == 0 ]] || {
            log_error "managed new reverse zone already contains $new_owner; refusing to overwrite a conflicting PTR"
            return 1
        }
    fi
}

validate_dns_current_answers() {
    command_exists dig || {
        log_error "dig is required for IP update consistency validation"
        return 1
    }
    local answer
    answer=$(dig +time=3 +tries=1 +short @127.0.0.1 "${IPA_HOSTNAME%.}." A 2>/dev/null || true)
    if [[ "$OLD_IP" != "$NEW_IP" ]]; then
        grep -Fxq "$OLD_IP" <<< "$answer" || log_warn "local named did not answer the old A record $IPA_HOSTNAME -> $OLD_IP; the managed zone file remains the authoritative preflight source"
    fi
    answer=$(dig +time=3 +tries=1 +short @127.0.0.1 -x "$OLD_IP" 2>/dev/null || true)
    if [[ "$OLD_IP" != "$NEW_IP" && -n "$answer" ]]; then
        grep -Fqi "${IPA_HOSTNAME%.}" <<< "$answer" || {
            log_error "old PTR $OLD_IP currently resolves to an unrelated hostname: $answer"
            return 1
        }
    fi
}

validate_named_readonly() {
    if is_dry_run; then
        plan "run named-checkconf and named-checkzone for the managed forward and reverse zones"
        return 0
    fi
    command_exists named-checkconf || { log_error "named-checkconf is required"; return 1; }
    command_exists named-checkzone || { log_error "named-checkzone is required"; return 1; }
    log_readonly_command named-checkconf "$DNS_BIND_CONFIG_FILE"
    log_readonly_command named-checkzone "${IPA_DOMAIN%.}" "$FORWARD_ZONE_FILE"
    log_readonly_command named-checkzone "${OLD_REVERSE_ZONE%.}" "$OLD_REVERSE_ZONE_FILE"
    if [[ "$NEW_REVERSE_ZONE_FILE" != "$OLD_REVERSE_ZONE_FILE" ]]; then
        log_readonly_command named-checkzone "${NEW_REVERSE_ZONE%.}" "$NEW_REVERSE_ZONE_FILE"
    fi
}

IPA_HOST_A_UPDATED=false
IPA_CA_A_UPDATED=false
IPA_PTR_UPDATED=false
TECHNITIUM_HOST_A_UPDATED=false
TECHNITIUM_CA_A_UPDATED=false

ipa_dns_record_name() {
    local name=${1%.}
    local domain=${IPA_DOMAIN%.}
    if [[ "${name,,}" == "${domain,,}" ]]; then
        printf '@'
    elif [[ "${name,,}" == *."${domain,,}" ]]; then
        printf '%s' "${name%.$domain}"
    else
        printf '%s' "$name"
    fi
}

ipa_dns_a_record_exists() {
    local fqdn=$1
    ipa dnsrecord-show "$IPA_DOMAIN" "$(ipa_dns_record_name "$fqdn")" >/dev/null 2>&1
}

ipa_dns_reverse_record_exists() {
    local zone=$1 owner=$2
    ipa dnsrecord-show "$zone" "$owner" >/dev/null 2>&1
}

validate_integrated_ip_update_records() {
    [[ "$DNS_BACKEND" == integrated ]] || return 0
    if is_dry_run || is_check; then
        plan "validate the FreeIPA integrated DNS A/PTR records and reverse zones through the IPA CLI"
        return 0
    fi
    command_exists ipa || { log_error 'ipa is required for integrated DNS IP updates'; return 1; }
    ipa dnszone-show "$OLD_REVERSE_ZONE" >/dev/null 2>&1 || {
        log_error "FreeIPA integrated reverse zone is missing: $OLD_REVERSE_ZONE"
        return 1
    }
    ipa dnszone-show "$NEW_REVERSE_ZONE" >/dev/null 2>&1 || {
        log_error "FreeIPA integrated reverse zone is missing: $NEW_REVERSE_ZONE"
        return 1
    }
    local host_name="$(ipa_dns_record_name "$IPA_HOSTNAME")"
    ipa_dns_a_record_exists "$IPA_HOSTNAME" || {
        log_error "FreeIPA integrated DNS has no host A record for $IPA_HOSTNAME"
        return 1
    }
    local old_owner new_owner
    old_owner=$(reverse_record_for_ipv4 "$OLD_IP")
    new_owner=$(reverse_record_for_ipv4 "$NEW_IP")
    ipa_dns_reverse_record_exists "$OLD_REVERSE_ZONE" "$old_owner" || {
        log_error "FreeIPA integrated DNS has no PTR record for $OLD_IP in $OLD_REVERSE_ZONE"
        return 1
    }
    if [[ "$OLD_IP" != "$NEW_IP" ]] && ipa_dns_reverse_record_exists "$NEW_REVERSE_ZONE" "$new_owner"; then
        log_error "FreeIPA integrated DNS already has a record at the new reverse owner $new_owner.$NEW_REVERSE_ZONE"
        return 1
    fi
    log_info "validated FreeIPA integrated A/PTR records for $host_name"
}

ipa_update_a_record() {
    local fqdn=$1 old_address=$2 new_address=$3
    [[ "$old_address" == "$new_address" ]] && return 0
    run_command ipa dnsrecord-mod "$IPA_DOMAIN" "$(ipa_dns_record_name "$fqdn")" \
        "--a-rec=$old_address" "--a-ip-address=$new_address"
}

ipa_update_ptr_record() {
    local old_zone=$1 old_owner=$2 new_zone=$3 new_owner=$4 host=$5
    [[ "$OLD_IP" == "$NEW_IP" ]] && return 0
    run_command ipa dnsrecord-del "$old_zone" "$old_owner" "--ptr-rec=${host%.}."
    run_command ipa dnsrecord-add "$new_zone" "$new_owner" "--ptr-rec=${host%.}."
}

update_integrated_dns_apply() {
    [[ "$OLD_IP" == "$NEW_IP" ]] && return 0
    log_stage ip-update-integrated-dns
    local old_owner new_owner
    old_owner=$(reverse_record_for_ipv4 "$OLD_IP")
    new_owner=$(reverse_record_for_ipv4 "$NEW_IP")
    ipa_update_a_record "$IPA_HOSTNAME" "$OLD_IP" "$NEW_IP"
    IPA_HOST_A_UPDATED=true
    if ipa_dns_a_record_exists 'ipa-ca'; then
        ipa_update_a_record 'ipa-ca' "$OLD_IP" "$NEW_IP"
        IPA_CA_A_UPDATED=true
    fi
    ipa_update_ptr_record "$OLD_REVERSE_ZONE" "$old_owner" "$NEW_REVERSE_ZONE" "$new_owner" "$IPA_HOSTNAME"
    IPA_PTR_UPDATED=true
    update_env_assignment IPA_IP_ADDRESS "$NEW_IP"
    if [[ "${DNS_PRIMARY_IP:-}" == "$OLD_IP" && "${DNS_PRIMARY_SERVER:-}" == "$IPA_HOSTNAME" ]]; then
        DNS_PRIMARY_IP=$NEW_IP
        export DNS_PRIMARY_IP
        update_env_assignment DNS_PRIMARY_IP "$DNS_PRIMARY_IP"
        TOPOLOGY_IP_CHANGED=true
    fi
    IPA_IP_ADDRESS=$NEW_IP
    IPA_REVERSE_ZONE=$NEW_REVERSE_ZONE
    IPA_REVERSE_RECORD=$(reverse_record_for_ipv4 "$NEW_IP")
    export IPA_IP_ADDRESS IPA_REVERSE_ZONE IPA_REVERSE_RECORD
    DNS_FIREWALL_REQUIRED=true
    firewall_configure || return 1
    UPDATE_CHANGED=true
}

update_integrated_dns_rollback() {
    [[ "$DNS_BACKEND" == integrated ]] || return 0
    [[ "$UPDATE_CHANGED" == true || "$IPA_HOST_A_UPDATED" == true || "$IPA_PTR_UPDATED" == true ]] || return 0
    local old_owner new_owner
    old_owner=$(reverse_record_for_ipv4 "$OLD_IP")
    new_owner=$(reverse_record_for_ipv4 "$NEW_IP")
    if [[ "$IPA_PTR_UPDATED" == true ]]; then
        ipa dnsrecord-del "$NEW_REVERSE_ZONE" "$new_owner" "--ptr-rec=${IPA_HOSTNAME%.}." >/dev/null 2>&1 || true
        ipa dnsrecord-add "$OLD_REVERSE_ZONE" "$old_owner" "--ptr-rec=${IPA_HOSTNAME%.}." >/dev/null 2>&1 || true
    fi
    if [[ "$IPA_CA_A_UPDATED" == true ]]; then
        ipa dnsrecord-mod "$IPA_DOMAIN" "$(ipa_dns_record_name 'ipa-ca')" \
            "--a-rec=$NEW_IP" "--a-ip-address=$OLD_IP" >/dev/null 2>&1 || true
    fi
    if [[ "$IPA_HOST_A_UPDATED" == true ]]; then
        ipa dnsrecord-mod "$IPA_DOMAIN" "$(ipa_dns_record_name "$IPA_HOSTNAME")" \
            "--a-rec=$NEW_IP" "--a-ip-address=$OLD_IP" >/dev/null 2>&1 || true
    fi
}

validate_technitium_ip_update_records() {
    [[ "$DNS_BACKEND" == technitium ]] || return 0
    [[ "${DNS_SERVER_ROLE:-primary}" == primary ]] || {
        log_error 'Technitium IP updates must run on the authoritative primary; a secondary only receives transfers'
        return 1
    }
    [[ "$(topology_primary_server)" == "$IPA_HOSTNAME" ]] || {
        log_error 'the local Technitium host must be the configured DNS primary for an IP update'
        return 1
    }
    [[ "$(topology_primary_ip)" == "$IPA_IP_ADDRESS" ]] || {
        log_error 'DNS_PRIMARY_IP must match IPA_IP_ADDRESS before a local Technitium IP update'
        return 1
    }
    if is_dry_run || is_check; then
        plan 'validate Technitium A/PTR records through the authenticated API before the IP transaction'
        return 0
    fi
    technitium_api_call GET '/api/zones/list' 'filterName=.' >/dev/null || return 1
    local host_zone old_owner
    host_zone=$(technitium_zone_for_name "$IPA_HOSTNAME") || return 1
    technitium_record_present "$host_zone" "$IPA_HOSTNAME" A "$OLD_IP" || {
        log_error "Technitium has no current A record for $IPA_HOSTNAME -> $OLD_IP"
        return 1
    }
    old_owner="$(reverse_record_for_ipv4 "$OLD_IP").${OLD_REVERSE_ZONE%.}"
    technitium_record_present "$OLD_REVERSE_ZONE" "$old_owner" PTR "${IPA_HOSTNAME%.}." || {
        log_error "Technitium has no current PTR record for $OLD_IP"
        return 1
    }
}

technitium_update_a_record() {
    local fqdn=$1 old_address=$2 new_address=$3 zone
    [[ "$old_address" == "$new_address" ]] && return 0
    zone=$(technitium_zone_for_name "$fqdn") || return 1
    technitium_api_call POST '/api/zones/records/update' \
        "domain=${fqdn%.}" "zone=${zone%.}" type=A "ipAddress=$old_address" \
        "newIpAddress=$new_address" ptr=true createPtrZone=false >/dev/null
}

update_technitium_apply() {
    [[ "$OLD_IP" == "$NEW_IP" ]] && return 0
    log_stage ip-update-technitium
    technitium_update_a_record "$IPA_HOSTNAME" "$OLD_IP" "$NEW_IP"
    TECHNITIUM_HOST_A_UPDATED=true
    if technitium_record_present "$IPA_DOMAIN" 'ipa-ca' A "$OLD_IP"; then
        technitium_update_a_record 'ipa-ca' "$OLD_IP" "$NEW_IP"
        TECHNITIUM_CA_A_UPDATED=true
    fi
    update_env_assignment IPA_IP_ADDRESS "$NEW_IP"
    if [[ "${DNS_PRIMARY_IP:-}" == "$OLD_IP" && "${DNS_PRIMARY_SERVER:-}" == "$IPA_HOSTNAME" ]]; then
        DNS_PRIMARY_IP=$NEW_IP
        export DNS_PRIMARY_IP
        update_env_assignment DNS_PRIMARY_IP "$DNS_PRIMARY_IP"
        TOPOLOGY_IP_CHANGED=true
    fi
    IPA_IP_ADDRESS=$NEW_IP
    IPA_REVERSE_ZONE=$NEW_REVERSE_ZONE
    IPA_REVERSE_RECORD=$(reverse_record_for_ipv4 "$NEW_IP")
    export IPA_IP_ADDRESS IPA_REVERSE_ZONE IPA_REVERSE_RECORD
    if [[ "$DNS_BACKEND" == technitium && "${FIREWALL_STATE:-}" == active && ( "${FIREWALL_BACKEND:-}" == firewalld || "${FIREWALL_BACKEND:-}" == ufw ) ]]; then
        DNS_FIREWALL_REQUIRED=true
        firewall_configure || return 1
    fi
    UPDATE_CHANGED=true
}

update_technitium_rollback() {
    [[ "$DNS_BACKEND" == technitium ]] || return 0
    [[ "$TECHNITIUM_HOST_A_UPDATED" == true ]] || return 0
    technitium_update_a_record "$IPA_HOSTNAME" "$NEW_IP" "$OLD_IP" >/dev/null 2>&1 || true
    if [[ "$TECHNITIUM_CA_A_UPDATED" == true ]]; then
        technitium_update_a_record 'ipa-ca' "$NEW_IP" "$OLD_IP" >/dev/null 2>&1 || true
    fi
    if [[ "${FIREWALL_STATE:-}" == active && ( "${FIREWALL_BACKEND:-}" == firewalld || "${FIREWALL_BACKEND:-}" == ufw ) ]]; then
        local current_ipa_ip=$IPA_IP_ADDRESS current_primary_ip=${DNS_PRIMARY_IP:-}
        IPA_IP_ADDRESS=$OLD_IP
        if [[ "${DNS_PRIMARY_SERVER:-}" == "$IPA_HOSTNAME" ]]; then
            DNS_PRIMARY_IP=$OLD_IP
        fi
        export IPA_IP_ADDRESS DNS_PRIMARY_IP
        DNS_FIREWALL_REQUIRED=true
        firewall_configure || log_error 'Technitium firewall rollback could not restore the previous managed peer rules'
        IPA_IP_ADDRESS=$current_ipa_ip
        DNS_PRIMARY_IP=$current_primary_ip
        export IPA_IP_ADDRESS DNS_PRIMARY_IP
    fi
}

update_backend_rollback() {
    case "${DNS_BACKEND:-}" in
        integrated) update_integrated_dns_rollback ;;
        technitium) update_technitium_rollback ;;
    esac
}

validate_update_preflight() {
    log_stage ip-update-preflight
    validate_ipv4 "$NEW_IP" || { log_error "--new-ip must be a valid IPv4 address"; return 1; }
    [[ "$NEW_IP" != 0.0.0.0 ]] || { log_error "new IP must not be 0.0.0.0"; return 1; }
    current_hostname_is_immutable
    freeipa_detect_state
    [[ "$FREEIPA_STATE" == healthy ]] || {
        log_error "a healthy installed FreeIPA server is required; the utility will not update a partial or absent deployment"
        return 1
    }
    case "$DNS_BACKEND" in
        integrated)
            if ! is_dry_run && ! is_check; then
                load_required_secrets
                freeipa_prepare_credentials
                freeipa_authenticate_admin
            fi
            ;;
        bind9_webmin|technitium)
            [[ "${DNS_SERVER_ROLE:-primary}" == primary ]] || {
                log_error "this host is configured as a DNS secondary; it will not edit transferred records. Run the authoritative update on the DNS primary"
                return 1
            }
            [[ "$(topology_primary_server)" == "$IPA_HOSTNAME" ]] || {
                log_error "the local authoritative DNS primary must be the installed IPA host; remote DNS-primary edits are intentionally not inferred"
                return 1
            }
            [[ "$(topology_primary_ip)" == "$IPA_IP_ADDRESS" ]] || {
                log_error "DNS_PRIMARY_IP must match IPA_IP_ADDRESS before an address-only update; reconcile the shared configuration first"
                return 1
            }
            ;;
        existing)
            log_error 'update-server-ip.sh cannot safely write an existing external DNS service; use that provider'
            return 1
            ;;
        *)
            log_error "unsupported DNS backend for IP update: $DNS_BACKEND"
            return 1
            ;;
    esac
    discover_current_ip
    OLD_IP=${REQUESTED_OLD_IP:-$IPA_IP_ADDRESS}
    if [[ "$DNS_BACKEND" == bind9_webmin && "$REQUESTED_OLD_IP" == '' && "$IPA_IP_ADDRESS" != "$CURRENT_IP" && -f "$(bind_zone_file "$IPA_DOMAIN")" ]]; then
        local configured_stats
        configured_stats=$(managed_record_stats "$(bind_zone_file "$IPA_DOMAIN")" "${IPA_HOSTNAME%.}." A "$IPA_IP_ADDRESS" 2>/dev/null || true)
        if [[ "$configured_stats" == '1 1' ]]; then
            OLD_IP=$IPA_IP_ADDRESS
        else
            OLD_IP=$CURRENT_IP
        fi
    fi
    validate_ipv4 "$OLD_IP" || { log_error "could not determine a valid current/old IPv4 address"; return 1; }
    OLD_IP=$(printf '%s' "$OLD_IP")
    if [[ "$DNS_BACKEND" == bind9_webmin ]]; then
        FORWARD_ZONE_FILE=$(bind_zone_file "$IPA_DOMAIN")
    fi
    validate_reverse_zone_selection
    case "$DNS_BACKEND" in
        bind9_webmin)
            validate_zone_record_state
            validate_dns_current_answers
            validate_named_readonly
            ;;
        integrated)
            validate_integrated_ip_update_records
            ;;
        technitium)
            validate_technitium_ip_update_records
            ;;
    esac
    if ip_is_assigned_locally "$NEW_IP" && [[ "$NEW_IP" != "$CURRENT_IP" ]]; then
        log_error "new IP $NEW_IP is already assigned locally to a different current address; resolve the interface conflict first"
        return 1
    fi
    if [[ "$OLD_IP" == "$NEW_IP" ]]; then
        log_info "the managed DNS mapping is already converged on $NEW_IP; no changes are required"
    fi
}

update_replace_managed_a() {
    local path=$1
    local owner=$2
    local old_address=$3
    local new_address=$4
    local temporary
    state_record_backup "$path"
    temporary=$(mktemp "$(dirname "$path")/.ip-update.XXXXXX")
    chmod 0600 "$temporary"
    if ! awk -v begin="$BIND_ZONE_RECORDS_BEGIN" -v end="$BIND_ZONE_RECORDS_END" \
        -v owner="${owner,,}" -v old="$old_address" -v new="$new_address" '
        $0 == begin { inside=1; print; next }
        $0 == end { inside=0; print; next }
        inside && NF >= 5 && tolower($1) == owner && $3 == "IN" && $4 == "A" && $5 == old {
            printf "%s %s IN A %s\n", $1, $2, new
            changed++
            next
        }
        { print }
        END { exit(changed == 1 ? 0 : 1) }
    ' "$path" > "$temporary"; then
        rm -f -- "$temporary"
        log_error "could not replace exactly one managed A record for $owner"
        return 1
    fi
    atomic_replace_file "$temporary" "$path"
    bind_increment_zone_serial "$path"
    UPDATE_CHANGED=true
}

update_replace_managed_ptr_same_zone() {
    local path=$1
    local old_owner=$2
    local new_owner=$3
    local target=$4
    local temporary
    state_record_backup "$path"
    temporary=$(mktemp "$(dirname "$path")/.ip-update.XXXXXX")
    chmod 0600 "$temporary"
    if ! awk -v begin="$BIND_ZONE_RECORDS_BEGIN" -v end="$BIND_ZONE_RECORDS_END" \
        -v old_owner="${old_owner,,}" -v new_owner="${new_owner,,}" -v target="${target,,}" '
        $0 == begin { inside=1; print; next }
        $0 == end { inside=0; print; next }
        inside && NF >= 5 && tolower($1) == old_owner && $3 == "IN" && $4 == "PTR" && tolower($5) == target {
            printf "%s %s IN PTR %s\n", new_owner, $2, $5
            changed++
            next
        }
        { print }
        END { exit(changed == 1 ? 0 : 1) }
    ' "$path" > "$temporary"; then
        rm -f -- "$temporary"
        log_error "could not replace exactly one managed PTR record for $old_owner"
        return 1
    fi
    atomic_replace_file "$temporary" "$path"
    bind_increment_zone_serial "$path"
    UPDATE_CHANGED=true
}

update_remove_managed_ptr() {
    local path=$1
    local owner=$2
    local target=$3
    local temporary
    state_record_backup "$path"
    temporary=$(mktemp "$(dirname "$path")/.ip-update-remove.XXXXXX")
    chmod 0600 "$temporary"
    if ! awk -v begin="$BIND_ZONE_RECORDS_BEGIN" -v end="$BIND_ZONE_RECORDS_END" \
        -v owner="${owner,,}" -v target="${target,,}" '
        $0 == begin { inside=1; print; next }
        $0 == end { inside=0; print; next }
        inside && NF >= 5 && tolower($1) == owner && $3 == "IN" && $4 == "PTR" && tolower($5) == target { removed++; next }
        { print }
        END { exit(removed == 1 ? 0 : 1) }
    ' "$path" > "$temporary"; then
        rm -f -- "$temporary"
        log_error "could not remove exactly one managed PTR record for $owner"
        return 1
    fi
    atomic_replace_file "$temporary" "$path"
    bind_increment_zone_serial "$path"
    UPDATE_CHANGED=true
}

update_add_managed_ptr() {
    local path=$1
    local owner=$2
    local target=$3
    local temporary
    state_record_backup "$path"
    temporary=$(mktemp "$(dirname "$path")/.ip-update-add.XXXXXX")
    chmod 0600 "$temporary"
    if ! awk -v begin="$BIND_ZONE_RECORDS_BEGIN" -v end="$BIND_ZONE_RECORDS_END" \
        -v line="$owner ${DNS_TTL} IN PTR ${target}" '
        $0 == begin { inside=1; print; next }
        $0 == end && !added { print line; added=1; inside=0; print; next }
        { print }
        END { exit(added == 1 ? 0 : 1) }
    ' "$path" > "$temporary"; then
        rm -f -- "$temporary"
        log_error "could not add the new managed PTR record to $path"
        return 1
    fi
    atomic_replace_file "$temporary" "$path"
    bind_increment_zone_serial "$path"
    UPDATE_CHANGED=true
}

update_env_assignment() {
    local variable=$1
    local value=$2
    [[ "$ENV_IP_OVERRIDDEN" == true ]] && return 0
    [[ -f "$ENV_FILE" && ! -L "$ENV_FILE" ]] || {
        log_error "$ENV_FILE is not a regular file; the shared configuration must be updated before this transaction can complete"
        return 1
    }
    local temporary
    state_record_backup "$ENV_FILE"
    temporary=$(mktemp "$(dirname "$ENV_FILE")/.env-ip-update.XXXXXX")
    chmod 0600 "$temporary"
    awk -v variable="$variable" -v value="$value" '
        $0 ~ "^[[:space:]]*(export[[:space:]]+)?" variable "=" {
            sub(/=.*/, "=" value)
            changed++
        }
        { print }
        END {
            if (changed == 0) print variable "=" value
            exit((changed == 0 || changed == 1) ? 0 : 1)
        }
    ' "$ENV_FILE" > "$temporary" || {
        rm -f -- "$temporary"
        log_error "did not rewrite $variable in $ENV_FILE because it has multiple assignments; the shared configuration must be repaired before retrying"
        return 1
    }
    atomic_replace_file "$temporary" "$ENV_FILE"
}

update_apply_transaction() {
    [[ "$OLD_IP" == "$NEW_IP" ]] && return 0
    case "$DNS_BACKEND" in
        integrated)
            UPDATE_IN_TRANSACTION=true
            update_integrated_dns_apply
            local integrated_rc=$?
            UPDATE_IN_TRANSACTION=false
            return "$integrated_rc"
            ;;
        technitium)
            UPDATE_IN_TRANSACTION=true
            update_technitium_apply
            local technitium_rc=$?
            UPDATE_IN_TRANSACTION=false
            return "$technitium_rc"
            ;;
    esac
    UPDATE_IN_TRANSACTION=true
    log_stage ip-update-transaction
    local host_owner="${IPA_HOSTNAME%.}."
    local old_owner="$(reverse_record_for_ipv4 "$OLD_IP").${OLD_REVERSE_ZONE%.}."
    local new_owner="$(reverse_record_for_ipv4 "$NEW_IP").${NEW_REVERSE_ZONE%.}."

    update_replace_managed_a "$FORWARD_ZONE_FILE" "$host_owner" "$OLD_IP" "$NEW_IP"
    if [[ "$OLD_REVERSE_ZONE" == "$NEW_REVERSE_ZONE" ]]; then
        update_replace_managed_ptr_same_zone "$OLD_REVERSE_ZONE_FILE" "$old_owner" "$new_owner" "${IPA_HOSTNAME%.}."
    else
        update_remove_managed_ptr "$OLD_REVERSE_ZONE_FILE" "$old_owner" "${IPA_HOSTNAME%.}."
        update_add_managed_ptr "$NEW_REVERSE_ZONE_FILE" "$new_owner" "${IPA_HOSTNAME%.}."
    fi

    if [[ "${DNS_PRIMARY_IP:-}" == "$OLD_IP" && "${DNS_PRIMARY_SERVER:-}" == "$IPA_HOSTNAME" ]]; then
        DNS_PRIMARY_IP=$NEW_IP
        export DNS_PRIMARY_IP
        TOPOLOGY_IP_CHANGED=true
    fi
    if [[ "$TOPOLOGY_IP_CHANGED" == true ]]; then
        bind_write_include_file
    fi

    update_env_assignment IPA_IP_ADDRESS "$NEW_IP"
    if [[ "$TOPOLOGY_IP_CHANGED" == true ]]; then
        update_env_assignment DNS_PRIMARY_IP "$DNS_PRIMARY_IP"
    fi

    IPA_IP_ADDRESS=$NEW_IP
    IPA_REVERSE_ZONE=$NEW_REVERSE_ZONE
    IPA_REVERSE_RECORD=$(reverse_record_for_ipv4 "$NEW_IP")
    export IPA_IP_ADDRESS IPA_REVERSE_ZONE IPA_REVERSE_RECORD

    bind_validate_configuration
    bind_activate_service
    UPDATE_IN_TRANSACTION=false
}

validate_update_post_state() {
    log_stage ip-update-post-validation
    if [[ "$DNS_BACKEND" != bind9_webmin ]]; then
        dns_prerequisite_records
        dns_validate_prerequisite_records 127.0.0.1 || return 1
        if [[ "$OLD_IP" != "$NEW_IP" ]]; then
            local old_ptr
            old_ptr=$(dig +time=3 +tries=1 +short @127.0.0.1 -x "$OLD_IP" 2>/dev/null || true)
            [[ -z "$old_ptr" ]] || {
                log_error "old PTR $OLD_IP still exists after the $DNS_BACKEND update: $old_ptr"
                return 1
            }
        fi
        if ! validate_freeipa_services; then
            log_warn 'FreeIPA service status could not be confirmed after the DNS update; the utility does not change IPA LDAP or the OS network interface'
        fi
        if ! validate_freeipa_cli; then
            log_warn 'FreeIPA CLI ping could not be confirmed after the DNS update; verify Kerberos/IPA health after the operating-system IP migration'
        fi
        return 0
    fi
    local target
    dns_prerequisite_records
    dns_validate_prerequisite_records 127.0.0.1 || return 1
    if [[ -n "$(topology_secondary_ip 2>/dev/null || true)" ]]; then
        target=$(topology_secondary_ip)
        dns_validate_prerequisite_records "$target" || {
            log_error "DNS secondary $target has not converged to the new A/PTR records"
            return 1
        }
    fi
    if [[ "$OLD_IP" != "$NEW_IP" ]]; then
        local old_ptr
        old_ptr=$(dig +time=3 +tries=1 +short @127.0.0.1 -x "$OLD_IP" 2>/dev/null || true)
        [[ -z "$old_ptr" ]] || {
            log_error "old PTR $OLD_IP still exists after reload: $old_ptr"
            return 1
        }
    fi
    if ! validate_freeipa_services; then
        log_warn "FreeIPA service status could not be confirmed after the DNS update; the utility does not change IPA LDAP or the OS network interface"
    fi
    if ! validate_freeipa_cli; then
        log_warn "FreeIPA CLI ping could not be confirmed after the DNS update; verify Kerberos/IPA health after the operating-system IP migration"
    fi
}

print_update_summary() {
    printf '\nFreeIPA server IP update summary\n'
    printf '%s\n' '--------------------------------'
    printf 'hostname:               %s\n' "$IPA_HOSTNAME"
    printf 'old IP:                 %s\n' "$OLD_IP"
    printf 'new IP:                 %s\n' "$NEW_IP"
    printf 'DNS backend:            %s\n' "$DNS_BACKEND"
    printf 'forward zone:           %s%s\n' "$IPA_DOMAIN" "${FORWARD_ZONE_FILE:+ ($FORWARD_ZONE_FILE)}"
    printf 'old reverse zone:       %s\n' "$OLD_REVERSE_ZONE"
    printf 'new reverse zone:       %s\n' "$NEW_REVERSE_ZONE"
    printf 'DNS topology:           %s primary\n' "$(topology_primary_server)"
    if [[ -n "$(topology_secondary_server 2>/dev/null || true)" ]]; then
        printf 'DNS secondary:          %s (%s)\n' "$(topology_secondary_server)" "$(topology_secondary_ip)"
    fi
    printf 'hostname change:        refused/unsupported\n'
    printf 'IPA LDAP/network move:  not performed; use the supported OS/FreeIPA migration procedure\n'
    if [[ "$UPDATE_CHANGED" == true ]]; then
        printf 'transaction:             %s records changed; validation completed\n' "$DNS_BACKEND"
    else
        printf 'transaction:             no managed $DNS_BACKEND changes required; validation completed\n'
    fi
    printf '\n'
}

load_environment
validate_env_configuration
preflight_fail_if_errors
detect_firewall_state

if [[ "$IPA_DNS_MODE" == external ]]; then
    dns_provider_load
fi

validate_update_preflight

if is_check; then
    if [[ "$DNS_BACKEND" == technitium ]]; then
        DNS_FIREWALL_REQUIRED=true
        firewall_configure
    fi
    print_update_summary
    printf 'Read-only IP update consistency checks passed. No files, DNS records, services, network settings, or FreeIPA state was changed.\n'
    exit 0
fi

if is_dry_run; then
    case "$DNS_BACKEND" in
        bind9_webmin)
            plan "replace ${IPA_HOSTNAME%.}. A $OLD_IP with $NEW_IP and increment the forward-zone SOA serial"
            if [[ "$OLD_REVERSE_ZONE" == "$NEW_REVERSE_ZONE" ]]; then
                plan "replace the managed PTR owner for $OLD_IP with the owner for $NEW_IP and increment the reverse-zone SOA serial"
            else
                plan "remove the managed PTR from $OLD_REVERSE_ZONE, add it to the existing explicit $NEW_REVERSE_ZONE, and increment both SOA serials"
            fi
            plan 'validate named-checkconf/named-checkzone, reload named only after validation, query A/PTR and wait for secondary SOA convergence'
            ;;
        integrated)
            plan "use ipa dnsrecord-mod to update ${IPA_HOSTNAME%.}. A $OLD_IP -> $NEW_IP and ipa dnsrecord-del/add for the PTR; FreeIPA replication publishes the change"
            ;;
        technitium)
            plan "use the authenticated Technitium records/update API to update ${IPA_HOSTNAME%.}. A $OLD_IP -> $NEW_IP and its existing PTR"
            DNS_FIREWALL_REQUIRED=true
            firewall_configure
            ;;
    esac
    print_update_summary
    exit 0
fi

RUN_ID="$(date -u '+%Y%m%dT%H%M%SZ')-$$"
export RUN_ID
acquire_install_lock
log_init
state_init
state_set UPDATE_OLD_IP "$OLD_IP"
state_set UPDATE_NEW_IP "$NEW_IP"
state_set UPDATE_BACKEND "$DNS_BACKEND"
state_set UPDATE_FORWARD_ZONE_FILE "$FORWARD_ZONE_FILE"
state_set UPDATE_OLD_REVERSE_ZONE "$OLD_REVERSE_ZONE"
state_set UPDATE_NEW_REVERSE_ZONE "$NEW_REVERSE_ZONE"

if ! update_apply_transaction; then
    UPDATE_IN_TRANSACTION=false
    update_backend_rollback || log_error "DNS backend rollback failed; inspect the authoritative service before retrying"
    state_restore_current_run_backups || log_error "automatic rollback failed; inspect the current-run backups under $STATE_RUN_DIR"
    if command_exists systemctl && systemctl is-active --quiet named 2>/dev/null; then
        systemctl reload named >/dev/null 2>&1 || true
    fi
    exit 1
fi

if ! validate_update_post_state; then
    UPDATE_IN_TRANSACTION=true
    update_backend_rollback || log_error "DNS backend rollback failed after post-validation; inspect the authoritative service before retrying"
    state_restore_current_run_backups || log_error "automatic rollback failed; inspect the current-run backups under $STATE_RUN_DIR"
    UPDATE_IN_TRANSACTION=false
    if command_exists systemctl && systemctl is-active --quiet named 2>/dev/null; then
        systemctl reload named >/dev/null 2>&1 || true
    fi
    exit 1
fi

state_set UPDATE_STATUS complete
state_mark_resource "dns-ip-update-${IPA_HOSTNAME}" modified-by-bootstrap
UPDATE_CHANGED=true
print_update_summary
printf 'IP-only DNS update completed. Update the operating-system network configuration separately, keep the hostname unchanged, then run ./install.sh --check and the documented FreeIPA/Kerberos health checks.\n'

