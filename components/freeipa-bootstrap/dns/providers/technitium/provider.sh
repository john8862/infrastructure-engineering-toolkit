#!/usr/bin/env bash

# Technitium is managed through its documented HTTP API.  The provider never
# edits Technitium's internal database or configuration files.

technitium_transfer_is_configured() {
    [[ -n "$(topology_secondary_server 2>/dev/null || true)" && -n "$(topology_secondary_ip 2>/dev/null || true)" ]]
}

technitium_api_url() {
    printf '%s' "${TECHNITIUM_API_URL%/}"
}

technitium_json_status() {
    python3 -c 'import json,sys
try:
    value=json.load(sys.stdin)
    print(value.get("status", ""))
except Exception:
    print("")' <<< "$1"
}

technitium_json_message() {
    python3 -c 'import json,sys
try:
    value=json.load(sys.stdin)
    response=value.get("response") or {}
    print(response.get("message") or value.get("message") or value.get("errorMessage") or "unknown API error")
except Exception:
    print("invalid JSON response")' <<< "$1"
}

technitium_token_from_file() {
    local path=${TECHNITIUM_API_TOKEN_FILE:-}
    [[ -n "$path" ]] || return 1
    [[ -f "$path" && ! -L "$path" ]] || {
        log_error "TECHNITIUM_API_TOKEN_FILE must be a regular non-symlink file: $path"
        return 1
    }
    local mode
    mode=$(file_mode_octal "$path") || return 1
    [[ "${mode: -1}" == 0 ]] || {
        log_error "TECHNITIUM_API_TOKEN_FILE must not be readable by other users: $path"
        return 1
    }
    awk 'NF { print; exit }' "$path"
}

technitium_http_request() {
    local method=$1
    local path=$2
    local authenticated=${3:-true}
    shift 3
    local token url key value
    local -a args=(--fail --silent --show-error --location --connect-timeout 10 --max-time 30)
    url="$(technitium_api_url)$path"
    [[ "$url" == https://* ]] || {
        log_error 'Technitium API requests require an https:// URL'
        return 1
    }
    [[ "${TECHNITIUM_API_TLS_VERIFY:-true}" == true ]] || {
        log_error 'TECHNITIUM_API_TLS_VERIFY=false is not supported; provide a trusted CA with TECHNITIUM_API_CA_FILE instead'
        return 1
    }
    args+=(--tlsv1.2)
    if [[ -n "${TECHNITIUM_API_CA_FILE:-}" ]]; then
        [[ -f "$TECHNITIUM_API_CA_FILE" && ! -L "$TECHNITIUM_API_CA_FILE" ]] || {
            log_error "TECHNITIUM_API_CA_FILE must be a regular non-symlink file: $TECHNITIUM_API_CA_FILE"
            return 1
        }
        args+=(--cacert "$TECHNITIUM_API_CA_FILE")
    fi
    if [[ "$authenticated" == true ]]; then
        token=$(technitium_get_token) || return 1
        args+=(-H "Authorization: Bearer $token")
    fi
    if [[ "$method" == GET ]]; then
        args+=(--get)
    else
        args+=(-X "$method")
    fi
    for pair in "$@"; do
        key=${pair%%=*}
        value=${pair#*=}
        args+=(--data-urlencode "$key=$value")
    done
    curl "${args[@]}" "$url"
}

technitium_login() {
    local response token
    [[ -n "${TECHNITIUM_API_USERNAME:-}" ]] || {
        log_error 'TECHNITIUM_API_USERNAME is required when an API token is not supplied'
        return 1
    }
    if [[ -z "${TECHNITIUM_API_PASSWORD:-}" ]]; then
        prompt_for_secret TECHNITIUM_API_PASSWORD 'Technitium API password' || return 1
    fi
    response=$(technitium_http_request GET '/api/user/login' false \
        "user=$TECHNITIUM_API_USERNAME" "pass=$TECHNITIUM_API_PASSWORD" 'includeInfo=true') || {
        log_error 'Technitium API login failed'
        return 1
    }
token=$(python3 -c 'import json,sys
try:
    value=json.load(sys.stdin)
    print((value.get("response") or {}).get("token") or value.get("token") or "")
except Exception:
    print("")' <<< "$response")
    [[ -n "$token" ]] || {
        log_error "Technitium API login returned no token: $(technitium_json_message "$response")"
        return 1
    }
    printf '%s' "$token"
}

technitium_get_token() {
    if [[ -n "${TECHNITIUM_API_TOKEN:-}" ]]; then
        printf '%s' "$TECHNITIUM_API_TOKEN"
    elif [[ -n "${TECHNITIUM_API_TOKEN_FILE:-}" ]]; then
        technitium_token_from_file
    else
        technitium_login
    fi
}

technitium_api_call() {
    local method=$1
    local path=$2
    shift 2
    local response status
    response=$(technitium_http_request "$method" "$path" true "$@") || return 1
    status=$(technitium_json_status "$response")
    [[ "$status" == ok ]] || {
        log_error "Technitium API request $path failed: $(technitium_json_message "$response")"
        return 1
    }
    printf '%s' "$response"
}

technitium_api_prepare() {
    command_exists curl || {
        log_error 'Technitium provider requires curl'
        return 1
    }
    command_exists python3 || {
        log_error 'Technitium provider requires python3 for safe JSON parsing'
        return 1
    }
    [[ "$TECHNITIUM_API_URL" == https://* ]] || {
        log_error 'TECHNITIUM_API_URL must use https://; plaintext API connections are not supported'
        return 1
    }
    [[ "${TECHNITIUM_API_TLS_VERIFY:-true}" == true ]] || {
        log_error 'TECHNITIUM_API_TLS_VERIFY=false is not supported; provide a trusted CA with TECHNITIUM_API_CA_FILE instead'
        return 1
    }
}

technitium_zone_type() {
    local zone=$1 response
    response=$(technitium_api_call GET '/api/zones/list' "filterName=$zone") || return 1
    python3 -c 'import json,sys
zone=sys.argv[1].rstrip(".").lower()
value=json.load(sys.stdin)
for item in ((value.get("response") or {}).get("zones") or []):
    name=str(item.get("name") or item.get("zone") or "").rstrip(".").lower()
    if name == zone:
        print(item.get("type") or item.get("zoneType") or "")
        break' "$zone" <<< "$response"
}

technitium_tsig_secret_from_file() {
    local path=${DNS_TRANSFER_KEY_FILE:-}
    [[ -f "$path" && ! -L "$path" ]] || return 1
    awk -F'"' '/^[[:space:]]*secret[[:space:]]+"/ { print $2; exit }' "$path"
}

technitium_fetch_tsig_key_over_ssh() {
    [[ "${DNS_SERVER_ROLE:-primary}" == secondary && "${DNS_TSIG_PROVISION:-manual}" == ssh ]] || return 1
    command_exists ssh || { log_error 'DNS_TSIG_PROVISION=ssh requires ssh'; return 1; }
    [[ -n "${DNS_TSIG_SSH_KEY_FILE:-}" && -f "$DNS_TSIG_SSH_KEY_FILE" ]] || {
        log_error 'DNS_TSIG_SSH_KEY_FILE must point to an existing private key for SSH TSIG provisioning'
        return 1
    }
    local remote_path host temporary
    remote_path=$(printf '%q' "$DNS_TRANSFER_KEY_FILE")
    host="$DNS_TSIG_SSH_USER@$(topology_primary_server)"
    temporary=$(mktemp "$(dirname "$DNS_TRANSFER_KEY_FILE")/.technitium-key.XXXXXX")
    chmod 0600 "$temporary"
    if ! ssh -p "$DNS_TSIG_SSH_PORT" -i "$DNS_TSIG_SSH_KEY_FILE" -o BatchMode=yes -o PasswordAuthentication=no \
        "$host" "cat -- $remote_path" > "$temporary"; then
        rm -f -- "$temporary"
        log_error "could not retrieve the TSIG key from $host; copy it manually or repair SSH trust"
        return 1
    fi
    grep -Fq "key \"$DNS_TSIG_KEY_NAME\"" "$temporary" || {
        rm -f -- "$temporary"
        log_error 'retrieved TSIG key does not contain the configured key name'
        return 1
    }
    install -d -m 0750 -- "$(dirname "$DNS_TRANSFER_KEY_FILE")"
    atomic_replace_file "$temporary" "$DNS_TRANSFER_KEY_FILE"
    chmod 0640 "$DNS_TRANSFER_KEY_FILE"
}

technitium_ensure_tsig_file() {
    [[ "${DNS_TSIG_ENABLED:-true}" == true ]] || return 0
    technitium_transfer_is_configured || [[ "${DNS_DYNAMIC_UPDATE_MODE:-disabled}" == secure ]] || return 0
    if [[ -f "$DNS_TRANSFER_KEY_FILE" && ! -L "$DNS_TRANSFER_KEY_FILE" ]]; then
        return 0
    fi
    if [[ "${DNS_SERVER_ROLE:-primary}" == secondary ]]; then
        technitium_fetch_tsig_key_over_ssh && return 0
        [[ "${DNS_TSIG_PROVISION:-manual}" == manual ]] || return 1
        log_error "Technitium secondary has no TSIG key; copy the primary's $DNS_TRANSFER_KEY_FILE or set DNS_TSIG_PROVISION=ssh"
        return 1
    fi
    if is_dry_run || is_check; then
        plan "create or verify the protected TSIG key $DNS_TSIG_KEY_NAME for Technitium transfer/DDNS policy"
        return 0
    fi
    local temporary
    install -d -m 0750 -- "$(dirname "$DNS_TRANSFER_KEY_FILE")"
    temporary=$(mktemp "$(dirname "$DNS_TRANSFER_KEY_FILE")/.technitium-key.XXXXXX")
    chmod 0600 "$temporary"
    if [[ -n "${DNS_TRANSFER_KEY_SECRET:-}" ]]; then
        {
            printf 'key "%s" {\n' "$DNS_TSIG_KEY_NAME"
            printf '    algorithm hmac-sha256;\n    secret "%s";\n};\n' "$DNS_TRANSFER_KEY_SECRET"
        } > "$temporary"
    elif command_exists tsig-keygen; then
        tsig-keygen -a hmac-sha256 "$DNS_TSIG_KEY_NAME" > "$temporary" 2>/dev/null || {
            rm -f -- "$temporary"
            log_error 'tsig-keygen failed while creating the Technitium TSIG key'
            return 1
        }
    else
        rm -f -- "$temporary"
        log_error 'Technitium TSIG requires DNS_TRANSFER_KEY_SECRET or tsig-keygen'
        return 1
    fi
    atomic_replace_file "$temporary" "$DNS_TRANSFER_KEY_FILE"
    chmod 0640 "$DNS_TRANSFER_KEY_FILE"
}

technitium_configure_tsig() {
    technitium_ensure_tsig_file || return 1
    [[ "${DNS_TSIG_ENABLED:-true}" == true ]] || return 0
    technitium_transfer_is_configured || [[ "${DNS_DYNAMIC_UPDATE_MODE:-disabled}" == secure ]] || return 0
    local secret settings keys existing
    secret=$(technitium_tsig_secret_from_file)
    [[ -n "$secret" ]] || {
        log_error "TSIG key file has no readable secret: $DNS_TRANSFER_KEY_FILE"
        return 1
    }
    settings=$(technitium_api_call GET '/api/settings/get') || return 1
existing=$(python3 -c 'import json,sys
value=json.load(sys.stdin)
for item in ((value.get("response") or {}).get("tsigKeys") or []):
    name=item.get("keyName") or item.get("name") or ""
    secret=item.get("sharedSecret") or ""
    algorithm=item.get("algorithmName") or "hmac-sha256"
    if name and secret:
        print(f"{name}|{secret}|{algorithm}")' <<< "$settings")
    keys=''
    local entry name
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        name=${entry%%|*}
        [[ "$name" == "$DNS_TSIG_KEY_NAME" ]] && continue
        [[ -n "$keys" ]] && keys+='|'
        keys+="$entry"
    done <<< "$existing"
    [[ -n "$keys" ]] && keys+='|'
    keys+="$DNS_TSIG_KEY_NAME|$secret|hmac-sha256"
    technitium_api_call POST '/api/settings/set' "tsigKeys=$keys" >/dev/null
}

technitium_configure_forwarders_api() {
    [[ -n "$DNS_FORWARDERS" ]] || return 0
    local forwarders
    forwarders=$(printf '%s' "$DNS_FORWARDERS" | tr ' ' ',')
    technitium_api_call POST '/api/settings/set' "forwarders=$forwarders" >/dev/null
}

technitium_zone_options() {
    local zone=$1
    local -a args=("zone=$zone")
    if [[ "${DNS_SERVER_ROLE:-primary}" == secondary ]]; then
        args+=("primaryNameServerAddresses=$(topology_primary_ip)" "primaryZoneTransferProtocol=$TECHNITIUM_ZONE_TRANSFER_PROTOCOL")
        [[ "${DNS_TSIG_ENABLED:-true}" == true ]] && args+=("primaryZoneTransferTsigKeyName=$DNS_TSIG_KEY_NAME")
        args+=("validateZone=$TECHNITIUM_VALIDATE_ZONE" "update=Deny" "zoneTransfer=Deny" "zoneTransferTsigKeyNames=false" "notify=None")
    else
        if technitium_transfer_is_configured; then
            # Keep both the source-network restriction and the optional TSIG
            # restriction.  Using zoneTransfer=Allow would make the zone
            # transferable to arbitrary clients when TSIG is not enforced.
            args+=("zoneTransfer=UseSpecifiedNetworkACL" "zoneTransferNetworkACL=$(topology_secondary_ip)")
            if [[ "${DNS_TSIG_ENABLED:-true}" == true ]]; then
                args+=("zoneTransferTsigKeyNames=$DNS_TSIG_KEY_NAME")
            else
                args+=("zoneTransferTsigKeyNames=false")
            fi
            if [[ "${DNS_NOTIFY_ENABLED:-true}" == true ]]; then
                args+=("notify=SpecifiedNameServers" "notifyNameServers=$(topology_secondary_ip)")
            else
                args+=("notify=None")
            fi
        else
            args+=("zoneTransfer=Deny" "zoneTransferTsigKeyNames=false" "notify=None")
        fi
        case "${DNS_DYNAMIC_UPDATE_MODE:-disabled}" in
            disabled) args+=("update=Deny" "updateSecurityPolicies=false") ;;
            insecure) args+=("update=UseSpecifiedNetworkACL" "updateNetworkACL=$TECHNITIUM_UPDATE_NETWORKS" "updateSecurityPolicies=false") ;;
            secure)
                args+=("update=UseSpecifiedNetworkACL" "updateNetworkACL=$TECHNITIUM_UPDATE_NETWORKS" \
                    "updateSecurityPolicies=$DNS_TSIG_KEY_NAME|$zone|A,AAAA,CNAME,PTR,SRV,TXT,URI|$DNS_TSIG_KEY_NAME|*.$zone|A,AAAA,CNAME,PTR,SRV,TXT,URI")
                ;;
        esac
    fi
    technitium_api_call POST '/api/zones/options/set' "${args[@]}" >/dev/null
}

technitium_ensure_zone() {
    local zone=$1 desired_type=$2 current
    current=$(technitium_zone_type "$zone") || return 1
    if [[ -z "$current" ]]; then
        local -a args=("zone=$zone" "type=$desired_type")
        if [[ "$desired_type" == Secondary ]]; then
            args+=("primaryNameServerAddresses=$(topology_primary_ip)" "zoneTransferProtocol=$TECHNITIUM_ZONE_TRANSFER_PROTOCOL" "validateZone=$TECHNITIUM_VALIDATE_ZONE")
            [[ "${DNS_TSIG_ENABLED:-true}" == true ]] && args+=("tsigKeyName=$DNS_TSIG_KEY_NAME")
        fi
        technitium_api_call POST '/api/zones/create' "${args[@]}" >/dev/null || return 1
        log_info "created Technitium $desired_type zone $zone"
    elif [[ "$current" != "$desired_type" ]]; then
        log_error "Technitium zone $zone exists as $current, expected $desired_type; refusing conversion or deletion"
        return 1
    else
        log_info "reusing Technitium $current zone $zone"
    fi
    technitium_zone_options "$zone"
}

technitium_zone_for_name() {
    local name=${1%.} candidate
    local forward=${IPA_DOMAIN%.}
    if [[ "${name,,}" == "${forward,,}" || "${name,,}" == *."${forward,,}" ]]; then
        printf '%s' "$forward"
        return 0
    fi
    while IFS= read -r candidate; do
        candidate=${candidate%.}
        [[ "${name,,}" == "${candidate,,}" || "${name,,}" == *."${candidate,,}" ]] && {
            printf '%s' "$candidate"
            return 0
        }
    done < <(dns_reverse_zone_list)
    return 1
}

technitium_record_present() {
    local zone=$1 name=$2 type=$3 expected=$4 response
    response=$(technitium_api_call GET '/api/zones/records/get' "domain=${name%.}" "zone=${zone%.}" 'listZone=true') || return 1
    python3 -c 'import json,sys
zone_name=sys.argv[1].rstrip(".").lower()
rtype=sys.argv[2].upper()
expected=sys.argv[3]
value=json.load(sys.stdin)
for record in ((value.get("response") or {}).get("records") or []):
    if str(record.get("type") or "").upper() != rtype:
        continue
    name=str(record.get("name") or "").rstrip(".").lower()
    if name and name not in (zone_name, "@") and not name.endswith("."+zone_name):
        continue
    data=record.get("rData") or {}
    if rtype in ("A","AAAA") and str(data.get("ipAddress") or "") == expected:
        raise SystemExit(0)
    if rtype in ("CNAME","PTR") and str(data.get("cname") or data.get("ptrName") or "").rstrip(".").lower() == expected.rstrip(".").lower():
        raise SystemExit(0)
    if rtype == "TXT" and str(data.get("text") or "") == expected:
        raise SystemExit(0)
    if rtype == "URI" and str(data.get("uri") or "") == expected:
        raise SystemExit(0)
    if rtype == "SRV" and " ".join(str(data.get(k) or "") for k in ("priority","weight","port","target")) == expected:
        raise SystemExit(0)
raise SystemExit(1)' "$zone" "$type" "$expected" <<< "$response"
}

technitium_add_record_line() {
    local line=$1 name ttl class type data zone
    line=$(awk '{$1=$1; print}' <<< "$line")
    [[ -z "$line" || "$line" == \#* || "$line" == \;* ]] && return 0
    [[ "$line" != *';'* && "$line" != *'{'* && "$line" != *'}'* ]] || {
        log_error 'refusing unsafe FreeIPA DNS record line for Technitium'
        return 1
    }
    read -r name ttl class type data <<< "$line"
    [[ "$ttl" =~ ^[0-9]+$ && "$class" == IN ]] || return 0
    case "$type" in A|AAAA|CNAME|PTR|SRV|TXT|URI) ;; *) log_warn "ignoring unsupported Technitium record type: $type"; return 0 ;; esac
    zone=$(technitium_zone_for_name "$name") || {
        log_warn "ignoring FreeIPA record outside Technitium managed zones: $name"
        return 0
    }
    local expected=$data
    local -a args=("domain=${name%.}" "zone=${zone%.}" "type=$type" "ttl=$ttl" 'overwrite=false')
    case "$type" in
        A|AAAA) args+=("ipAddress=$data") ;;
        CNAME) args+=("cname=$data") ;;
        PTR) args+=("ptrName=$data") ;;
        TXT) args+=("text=$data");;
        URI) args+=("uri=$data");;
        SRV)
            local priority weight port target
            read -r priority weight port target <<< "$data"
            expected="$priority $weight $port $target"
            args+=("priority=$priority" "weight=$weight" "port=$port" "target=$target")
            ;;
    esac
    technitium_record_present "$zone" "${name%.}" "$type" "$expected" && return 0
    technitium_api_call POST '/api/zones/records/add' "${args[@]}" >/dev/null || return 1
}

technitium_validate_secondary_transfer_once() {
    [[ "${DNS_SERVER_ROLE:-primary}" == secondary ]] || return 0
    local zone primary_serial secondary_serial
    while IFS= read -r zone; do
        [[ -n "$zone" ]] || continue
        primary_serial=$(dig +time=5 +tries=1 +short "@$(topology_primary_ip)" "$zone" SOA 2>/dev/null | awk 'NF >= 3 { print $3; exit }')
        secondary_serial=$(dig +time=5 +tries=1 +short @127.0.0.1 "$zone" SOA 2>/dev/null | awk 'NF >= 3 { print $3; exit }')
        [[ "$primary_serial" =~ ^[0-9]+$ && "$primary_serial" == "$secondary_serial" ]] || return 1
    done < <(printf '%s\n' "$IPA_DOMAIN"; dns_reverse_zone_list)
}

technitium_validate_secondary_transfer() {
    [[ "${DNS_SERVER_ROLE:-primary}" == secondary ]] || return 0
    local deadline=$((SECONDS + DNS_TRANSFER_WAIT_SECONDS))
    while :; do
        technitium_validate_secondary_transfer_once && return 0
        (( SECONDS >= deadline )) && {
            log_error "Technitium secondary did not converge within ${DNS_TRANSFER_WAIT_SECONDS}s"
            return 1
        }
        sleep "$DNS_TRANSFER_POLL_SECONDS"
    done
}

technitium_install_service() {
    if [[ -f "$TECHNITIUM_INSTALL_DIR/DnsServerApp.dll" ]]; then
        log_info "reusing the existing Technitium installation at $TECHNITIUM_INSTALL_DIR"
    else
        if is_dry_run || is_check; then
            plan "download the official Technitium installer, verify its syntax and required SHA-256 pin, and install it under $TECHNITIUM_INSTALL_DIR"
            return 0
        fi
        [[ "${TECHNITIUM_INSTALLER_SHA256:-}" =~ ^[A-Fa-f0-9]{64}$ ]] || {
            log_error 'TECHNITIUM_INSTALLER_SHA256 must be a 64-character SHA-256 pin before executing the remote installer'
            return 1
        }
        [[ ! -L /etc/resolv.conf ]] || {
            log_error 'refusing a new Technitium installation while /etc/resolv.conf is a symlink; protect the host resolver and rerun after choosing a resolver-safe installation procedure'
            return 1
        }
        local temporary resolver_backup
        temporary=$(mktemp)
        resolver_backup=$(mktemp)
        if [[ -f /etc/resolv.conf ]]; then cp -p /etc/resolv.conf "$resolver_backup"; else rm -f -- "$resolver_backup"; fi
        if ! curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 "$TECHNITIUM_INSTALLER_URL" -o "$temporary"; then
            rm -f -- "$temporary" "$resolver_backup"
            return 1
        fi
        if ! printf '%s  %s\n' "$TECHNITIUM_INSTALLER_SHA256" "$temporary" | sha256sum -c - >/dev/null; then
            rm -f -- "$temporary" "$resolver_backup"
            log_error 'Technitium installer SHA-256 verification failed'
            return 1
        fi
        sh -n "$temporary" || { rm -f -- "$temporary" "$resolver_backup"; return 1; }
        run_command sh "$temporary" || { rm -f -- "$temporary" "$resolver_backup"; return 1; }
        rm -f -- "$temporary"
        if [[ -f "$resolver_backup" ]] && { [[ ! -f /etc/resolv.conf ]] || ! cmp -s "$resolver_backup" /etc/resolv.conf; }; then
            state_record_backup /etc/resolv.conf
            local restored
            restored=$(mktemp /etc/.resolv.conf.restore.XXXXXX)
            cp -p "$resolver_backup" "$restored"
            atomic_replace_file "$restored" /etc/resolv.conf
            log_info 'restored the pre-existing regular /etc/resolv.conf after Technitium installation'
        fi
        rm -f -- "$resolver_backup"
        state_mark_resource technitium-installation created-by-bootstrap
    fi
    command_exists systemctl || { log_error 'systemctl is required to manage Technitium'; return 1; }
    run_command systemctl enable --now "$TECHNITIUM_SERVICE_NAME"
}

dns_provider_check() {
    log_stage dns-technitium-check
    technitium_api_prepare || return 1
    if is_dry_run || is_check; then
        plan 'validate the Technitium API endpoint, service ownership of port 53, and the configured primary/secondary zone topology'
        return 0
    fi
    [[ -f "$TECHNITIUM_INSTALL_DIR/DnsServerApp.dll" ]] || {
        log_warn 'Technitium is not installed yet; the install stage will use the official installer'
        return 0
    }
    technitium_api_call GET '/api/zones/list' >/dev/null
}

dns_provider_install() {
    log_stage dns-technitium-install
    technitium_api_prepare || return 1
    package_install curl ca-certificates python3 bind-utils
    technitium_install_service
    if is_dry_run || is_check; then
        return 0
    fi
    # Register the shared key before zone creation so primary/secondary zone
    # options and RFC 2136 policies never reference an absent key.
    technitium_configure_tsig
}

dns_provider_configure_forwarders() {
    log_stage dns-technitium-forwarding
    if is_dry_run || is_check; then
        plan 'configure Technitium forwarders through /api/settings/set'
        return 0
    fi
    technitium_configure_forwarders_api
}

dns_provider_create_forward_zone() {
    log_stage dns-technitium-forward-zone
    local zone_type
    if [[ "${DNS_SERVER_ROLE:-primary}" == secondary ]]; then zone_type=Secondary; else zone_type=Primary; fi
    if is_dry_run || is_check; then
        plan "ensure Technitium $zone_type forward zone $IPA_DOMAIN"
        return 0
    fi
    technitium_ensure_zone "$IPA_DOMAIN" "$zone_type"
}

dns_provider_create_reverse_zone() {
    log_stage dns-technitium-reverse-zone
    local zone_type reverse_zone
    if [[ "${DNS_SERVER_ROLE:-primary}" == secondary ]]; then zone_type=Secondary; else zone_type=Primary; fi
    if is_dry_run || is_check; then
        plan "ensure the configured Technitium reverse zones as $zone_type zones"
        return 0
    fi
    while IFS= read -r reverse_zone; do
        [[ -n "$reverse_zone" ]] || continue
        technitium_ensure_zone "$reverse_zone" "$zone_type" || return 1
    done < <(dns_reverse_zone_list)
}

dns_provider_create_record() {
    if [[ "${DNS_SERVER_ROLE:-primary}" == secondary ]]; then
        log_info "Technitium secondary will not edit authoritative record: ${1:-<unspecified>}"
        return 0
    fi
    if is_dry_run || is_check; then
        plan "ensure Technitium record: ${1:-<unspecified>}"
        return 0
    fi
    technitium_add_record_line "$1"
}

dns_provider_configure() {
    log_stage dns-technitium-configure
    if is_dry_run || is_check; then
        plan 'configure Technitium TSIG, transfer policy, RFC 2136 update policy, and NOTIFY through the official API'
        return 0
    fi
    technitium_configure_tsig || return 1
    local zone
    technitium_zone_options "$IPA_DOMAIN" || return 1
    while IFS= read -r zone; do
        [[ -n "$zone" ]] || continue
        technitium_zone_options "$zone" || return 1
    done < <(dns_reverse_zone_list)
}

dns_provider_validate() {
    log_stage dns-technitium-validation
    if is_dry_run || is_check; then
        plan 'validate Technitium service state, API authentication, zone type/options, and DNS A/PTR/FreeIPA records'
        return 0
    fi
    command_exists systemctl && systemctl is-active --quiet "$TECHNITIUM_SERVICE_NAME" || {
        log_error "Technitium service $TECHNITIUM_SERVICE_NAME is not active"
        return 1
    }
    technitium_api_call GET '/api/zones/list' >/dev/null || return 1
    technitium_validate_secondary_transfer || return 1
    dns_validate_prerequisite_records 127.0.0.1 || return 1
    local generated
    generated=$(dns_find_generated_record_file)
    if [[ -n "$generated" ]]; then
        dns_validate_records_file "$generated" 127.0.0.1 || return 1
        EXTERNAL_DNS_STATUS=complete
    fi
}

dns_provider_validate_prerequisites() {
    if is_dry_run || is_check; then
        plan 'validate Technitium API/service and the server A/PTR prerequisites before FreeIPA installation'
        return 0
    fi
    technitium_api_call GET '/api/zones/list' >/dev/null || return 1
    dns_validate_prerequisite_records 127.0.0.1
}

dns_provider_sync_freeipa_records() {
    local path=${1:-}
    [[ -n "$path" && -f "$path" && ! -L "$path" ]] || {
        log_error 'FreeIPA DNS record output is missing or unsafe; cannot reconcile Technitium records'
        return 1
    }
    if is_dry_run || is_check; then
        plan "reconcile version-specific FreeIPA DNS records from $path through the Technitium API"
        return 0
    fi
    local destination line
    dns_prepare_generated_directory
    destination="$IPA_GENERATED_DIR/freeipa-dns-records-${RUN_ID}.db"
    [[ ! -e "$destination" && ! -L "$destination" ]] || {
        log_error "refusing to overwrite an existing generated DNS record file: $destination"
        return 1
    }
    cp -p -- "$path" "$destination"
    chmod 0640 "$destination"
    state_set EXTERNAL_RECORDS_FILE "$destination"
    if [[ "${DNS_SERVER_ROLE:-primary}" == secondary ]]; then
        EXTERNAL_DNS_STATUS=pending
        state_set EXTERNAL_DNS_STATUS pending
        log_warn 'captured FreeIPA records on a Technitium secondary; no secondary record was edited'
        if technitium_validate_secondary_transfer && dns_validate_records_file "$path" 127.0.0.1; then
            EXTERNAL_DNS_STATUS=complete
            state_set EXTERNAL_DNS_STATUS complete
        fi
        return 0
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        technitium_add_record_line "$line" || return 1
    done < "$path"
    dns_validate_records_file "$path" 127.0.0.1 || return 1
    EXTERNAL_DNS_STATUS=complete
    state_set EXTERNAL_DNS_STATUS complete
}

dns_provider_uninstall() {
    log_warn "Technitium uninstall is not run automatically. Remove only resources recorded as created-by-bootstrap after reviewing $STATE_FILE; existing zones and the service are out of scope"
}
