#!/usr/bin/env bash

BIND_OPTIONS_BEGIN='/* BEGIN FREEIPA-BOOTSTRAP OPTIONS */'
BIND_OPTIONS_END='/* END FREEIPA-BOOTSTRAP OPTIONS */'
BIND_INCLUDE_BEGIN='// BEGIN FREEIPA-BOOTSTRAP ZONES'
BIND_INCLUDE_END='// END FREEIPA-BOOTSTRAP ZONES'
BIND_ZONE_MARKER='; Managed by freeipa-bootstrap. Do not edit outside the marked file.'
BIND_ZONE_RECORDS_BEGIN='; BEGIN FREEIPA-BOOTSTRAP RECORDS'
BIND_ZONE_RECORDS_END='; END FREEIPA-BOOTSTRAP RECORDS'
BIND_ZONE_AUTHORITY_BEGIN='; BEGIN FREEIPA-BOOTSTRAP AUTHORITY'
BIND_ZONE_AUTHORITY_END='; END FREEIPA-BOOTSTRAP AUTHORITY'
BIND_ACL_BEGIN='// BEGIN FREEIPA-BOOTSTRAP ACL'
BIND_ACL_END='// END FREEIPA-BOOTSTRAP ACL'

bind_zone_directory() {
    local directory=${DNS_BIND_ZONE_DIR:-/var/named/freeipa-bootstrap}
    if [[ "${BIND_ZONE_FILE_MODE:-custom}" == native ]]; then
        directory=${BIND_NATIVE_ZONE_DIR:-/var/named}
    fi
    if [[ "${DNS_SERVER_ROLE:-primary}" == secondary ]]; then
        directory=${DNS_BIND_SLAVE_DIR:-${directory%/}/slaves}
    fi
    printf '%s' "$directory"
}

bind_zone_config_file() {
    if [[ "${BIND_CONFIG_MODE:-managed_include}" != native ]]; then
        printf '%s' "${DNS_BIND_INCLUDE_FILE:-/etc/named/freeipa-bootstrap.conf}"
        return 0
    fi
    if [[ -n "${BIND_NATIVE_ZONE_CONFIG_FILE:-}" ]]; then
        printf '%s' "$BIND_NATIVE_ZONE_CONFIG_FILE"
    elif [[ -f /etc/named.rfc1912.zones || ! -e /etc/bind/named.conf.local ]]; then
        printf '%s' /etc/named.rfc1912.zones
    else
        printf '%s' /etc/bind/named.conf.local
    fi
}

bind_declared_zone_file() {
    local config=$1 zone=$2 candidate
    [[ -f "$config" && ! -L "$config" ]] || return 1
    candidate=$(awk -v zone="${zone%.}" '
        BEGIN { inside=0 }
        /^[[:space:]]*zone[[:space:]]+"/ && index($0, "zone \"" zone "\"") {
            inside=1
        }
        inside && /file[[:space:]]+"/ {
            value=$0
            sub(/^.*file[[:space:]]+"/, "", value)
            sub(/".*$/, "", value)
            print value
            exit
        }
        inside && /}/ { inside=0 }
    ' "$config")
    [[ "$candidate" == /* && "$candidate" != *[[:space:]]* ]] || return 1
    printf '%s' "$candidate"
}

bind_existing_zone_file() {
    local zone=$1 config candidate
    for config in "$(bind_zone_config_file)" "$DNS_BIND_CONFIG_FILE"; do
        candidate=$(bind_declared_zone_file "$config" "$zone" 2>/dev/null || true)
        [[ -n "$candidate" ]] && {
            printf '%s' "$candidate"
            return 0
        }
    done
    return 1
}

bind_unmanaged_zone_declaration_exists() {
    local config=$1 zone=$2
    [[ -f "$config" && ! -L "$config" ]] || return 1
    awk -v zone="${zone%.}" -v begin="$BIND_INCLUDE_BEGIN" -v end="$BIND_INCLUDE_END" '
        $0 == begin { managed=1; next }
        $0 == end { managed=0; next }
        !managed && /^[[:space:]]*zone[[:space:]]+"/ && index($0, "zone \"" zone "\"") { found=1 }
        END { exit(found ? 0 : 1) }
    ' "$config"
}

bind_key_required() {
    [[ "${DNS_TSIG_ENABLED:-true}" == true ]] || return 1
    bind_transfer_is_configured || [[ "${DNS_DYNAMIC_UPDATE_MODE:-disabled}" == secure ]]
}

bind_zone_file() {
    local zone=$1 existing
    if [[ "${BIND_ZONE_FILE_MODE:-custom}" == native ]]; then
        existing=$(bind_existing_zone_file "$zone" 2>/dev/null || true)
        [[ -n "$existing" ]] && {
            printf '%s' "$existing"
            return 0
        }
    fi
    printf '%s/%s.zone' "$(bind_zone_directory)" "$zone"
}

bind_named_group() {
    if command_exists getent && getent group named >/dev/null 2>&1; then
        printf '%s' named
    else
        printf '%s' root
    fi
}

bind_set_zone_permissions() {
    local path=$1
    chmod 0640 "$path"
    if [[ "$(id -u)" -eq 0 ]]; then
        chown "root:$(bind_named_group)" "$path"
    fi
    if command_exists restorecon; then
        restorecon "$path" >/dev/null 2>&1 || true
    fi
}

bind_prepare_zone_directory() {
    local directory
    directory=$(bind_zone_directory)
    [[ ! -L "$directory" ]] || {
        log_error "BIND zone directory must not be a symlink: $directory"
        return 1
    }
    if [[ -e "$directory" && ! -d "$directory" ]]; then
        log_error "BIND zone path is not a directory: $directory"
        return 1
    fi
    install -d -m 0750 -- "$directory"
    # named normally runs as the named user.  This directory is the provider's
    # dedicated scope, so make the required traversal permission explicit while
    # leaving unrelated /var/named content untouched.
    chmod 0750 "$directory"
    if getent group named >/dev/null 2>&1; then
        chown "root:named" "$directory"
    fi
    if command_exists restorecon; then
        restorecon "$directory" >/dev/null 2>&1 || true
    fi
}

bind_zone_serial() {
    local path=$1
    local serial
    serial=$(awk '/; serial$/ { print $1; exit }' "$path" 2>/dev/null || true)
    if [[ "$serial" =~ ^[0-9]+$ ]]; then
        printf '%s' "$serial"
    else
        date -u '+%Y%m%d%H'
    fi
}

bind_next_serial() {
    local current=$1
    if [[ "$current" =~ ^[0-9]+$ ]]; then
        printf '%s' "$((current + 1))"
    else
        date -u '+%Y%m%d%H'
    fi
}

bind_check_managed_zone_target() {
    local path=$1
    [[ ! -L "$path" ]] || {
        log_error "refusing to manage a symlinked BIND zone file: $path"
        return 1
    }
    if [[ ! -e "$path" ]]; then
        return 0
    fi
    grep -Fq "$BIND_ZONE_MARKER" "$path" || {
        log_error "refusing to overwrite pre-existing unmanaged BIND zone file: $path"
        return 1
    }
}

bind_zone_records_lines() {
    local reverse=${1:-false}
    local current_zone=${2:-${IPA_REVERSE_ZONE}}
    local record name ttl class type data normalized_name forward_zone reverse_zone
    local primary_server primary_ip secondary_server secondary_ip
    local -a emitted=()
    forward_zone=${IPA_DOMAIN,,}
    forward_zone=${forward_zone%.}
    primary_server=${DNS_PRIMARY_SERVER:-$IPA_HOSTNAME}
    primary_ip=${DNS_PRIMARY_IP:-$IPA_IP_ADDRESS}
    secondary_server=${DNS_SECONDARY_SERVER:-}
    secondary_ip=${DNS_SECONDARY_IP:-}
    if [[ -z "$secondary_server" && "${DNS_SERVER_ROLE:-primary}" == secondary ]]; then
        secondary_server=$IPA_HOSTNAME
    fi
    if [[ -z "$secondary_ip" && "${DNS_SERVER_ROLE:-primary}" == secondary ]]; then
        secondary_ip=$IPA_IP_ADDRESS
    fi
    dns_prerequisite_records
    for record in "${DNS_PREREQUISITE_RECORDS[@]}"; do
        read -r name ttl class type data <<< "$record"
        normalized_name=${name,,}
        if [[ "$reverse" == true ]]; then
            reverse_zone=${current_zone,,}
            reverse_zone=${reverse_zone%.}
            [[ "$normalized_name" == *"$reverse_zone." ]] || continue
        else
            [[ "$normalized_name" == *"$forward_zone." ]] || continue
        fi
        if ! printf '%s\n' "${emitted[@]}" | grep -Fqx -- "$record" 2>/dev/null; then
            printf '%s\n' "$record"
            emitted+=("$record")
        fi
    done

    local host fqdn zone
    if [[ "$reverse" != true ]]; then
        if [[ "${primary_server,,}" == *."$forward_zone" || "${primary_server,,}" == "$forward_zone" ]]; then
            fqdn="${primary_server%.}."
            record="$fqdn $DNS_TTL IN A $primary_ip"
            if ! printf '%s\n' "${emitted[@]}" | grep -Fqx -- "$record" 2>/dev/null; then
                printf '%s\n' "$record"
                emitted+=("$record")
            fi
        fi
        if [[ -n "$secondary_server" && -n "$secondary_ip" && ( "${secondary_server,,}" == *."$forward_zone" || "${secondary_server,,}" == "$forward_zone" ) ]]; then
            fqdn="${secondary_server%.}."
            record="$fqdn $DNS_TTL IN A $secondary_ip"
            if ! printf '%s\n' "${emitted[@]}" | grep -Fqx -- "$record" 2>/dev/null; then
                printf '%s\n' "$record"
                emitted+=("$record")
            fi
        fi
        return 0
    fi

    # Reverse records for configured DNS servers are emitted only when their
    # addresses belong to the reverse zone currently being written.
    reverse_zone=${current_zone,,}
    reverse_zone=${reverse_zone%.}
    for host in "$primary_server $primary_ip" "$secondary_server $secondary_ip"; do
        read -r fqdn zone <<< "$host"
        [[ -n "$fqdn" && -n "$zone" ]] || continue
        local host_reverse
        host_reverse=$(reverse_zone_for_ipv4 "$zone" 2>/dev/null || true)
        [[ "${host_reverse,,}" == "${reverse_zone,,}" ]] || continue
        record="$(reverse_record_for_ipv4 "$zone") $DNS_TTL IN PTR ${fqdn%.}."
        if ! printf '%s\n' "${emitted[@]}" | grep -Fqx -- "$record" 2>/dev/null; then
            printf '%s\n' "$record"
            emitted+=("$record")
        fi
    done
}

bind_zone_authority_lines() {
    local primary_server=${DNS_PRIMARY_SERVER:-$IPA_HOSTNAME}
    local secondary_server=${DNS_SECONDARY_SERVER:-}
    if [[ -z "$secondary_server" && "${DNS_SERVER_ROLE:-primary}" == secondary ]]; then
        secondary_server=$IPA_HOSTNAME
    fi
    printf '@ IN NS %s.\n' "${primary_server%.}"
    if [[ -n "$secondary_server" ]]; then
        printf '@ IN NS %s.\n' "${secondary_server%.}"
    fi
}

bind_zone_authority_block() {
    printf '%s\n' "$BIND_ZONE_AUTHORITY_BEGIN"
    bind_zone_authority_lines
    printf '%s\n' "$BIND_ZONE_AUTHORITY_END"
}

bind_ensure_zone_authority_records() {
    local path=$1
    local temporary authority_file work_dir
    work_dir=$(dirname "$path")
    authority_file=$(mktemp "$work_dir/.authority.XXXXXX")
    chmod 0600 "$authority_file"
    bind_zone_authority_block > "$authority_file"
    temporary=$(mktemp "$work_dir/.zone-authority.XXXXXX")
    chmod 0600 "$temporary"
    awk -v begin="$BIND_ZONE_AUTHORITY_BEGIN" -v end="$BIND_ZONE_AUTHORITY_END" \
        -v records_begin="$BIND_ZONE_RECORDS_BEGIN" -v authority="$authority_file" \
        -v legacy="@ IN NS ${IPA_HOSTNAME%.}." '
        function emit_authority(line) {
            while ((getline line < authority) > 0) print line
            close(authority)
        }
        $0 == begin { skipping=1; emit_authority(); inserted=1; next }
        $0 == end { skipping=0; next }
        skipping { next }
        !inserted && $0 == legacy { next }
        !inserted && $0 == records_begin { emit_authority(); inserted=1 }
        { print }
        END { if (!inserted) { print ""; emit_authority() } }
    ' "$path" > "$temporary"
    rm -f -- "$authority_file"
    atomic_replace_file "$temporary" "$path"
}

bind_zone_records_block() {
    local reverse=${1:-false}
    local zone=${2:-${IPA_REVERSE_ZONE}}
    printf '%s\n' "$BIND_ZONE_RECORDS_BEGIN"
    bind_zone_records_lines "$reverse" "$zone"
    printf '%s\n' "$BIND_ZONE_RECORDS_END"
}

bind_write_zone_file() {
    local zone=$1
    local path=$2
    local reverse=${3:-false}
    local temporary serial existed=false records_block legacy_records filtered work_dir
    work_dir=$(dirname "$path")
    bind_check_managed_zone_target "$path" || return 1
    bind_prepare_zone_directory || return 1
    records_block=$(mktemp "$work_dir/.records.XXXXXX")
    chmod 0600 "$records_block"
    bind_zone_records_block "$reverse" "$zone" > "$records_block"
    if [[ -e "$path" ]]; then
        existed=true
        state_record_backup "$path"
        serial=$(bind_next_serial "$(bind_zone_serial "$path")")
        temporary=$(mktemp "$work_dir/.zone.XXXXXX")
        chmod 0600 "$temporary"
        if grep -Fq "$BIND_ZONE_RECORDS_BEGIN" "$path" && grep -Fq "$BIND_ZONE_RECORDS_END" "$path"; then
            awk -v begin="$BIND_ZONE_RECORDS_BEGIN" -v end="$BIND_ZONE_RECORDS_END" -v block="$records_block" '
                function emit_block(line) {
                    while ((getline line < block) > 0) print line
                    close(block)
                }
                $0 == begin { skip=1; emit_block(); found=1; next }
                $0 == end { skip=0; next }
                !skip { print }
                END { if (!found) { print ""; emit_block() } }
            ' "$path" > "$temporary"
        else
            # Migrate an older bootstrap-managed zone without deleting any
            # non-bootstrap records that an administrator may have added.
            legacy_records=$(mktemp "$work_dir/.legacy-records.XXXXXX")
            chmod 0600 "$legacy_records"
            bind_zone_records_lines "$reverse" "$zone" > "$legacy_records"
            filtered=$(mktemp "$work_dir/.filtered-zone.XXXXXX")
            chmod 0600 "$filtered"
            awk -v record_file="$legacy_records" '
                BEGIN {
                    while ((getline line < record_file) > 0) {
                        split(line, fields, /[[:space:]]+/)
                        remove[fields[1] SUBSEP fields[4]]=1
                    }
                    close(record_file)
                }
                NF >= 4 && (($1 SUBSEP $4) in remove) { next }
                { print }
            ' "$path" > "$filtered"
            cat "$filtered" > "$temporary"
            printf '\n' >> "$temporary"
            cat "$records_block" >> "$temporary"
            rm -f -- "$legacy_records" "$filtered"
        fi
        rm -f -- "$records_block"
        atomic_replace_file "$temporary" "$path"
        bind_ensure_zone_authority_records "$path"
        bind_increment_zone_serial "$path"
    else
        serial=$(date -u '+%Y%m%d%H')
        temporary=$(mktemp "$work_dir/.zone.XXXXXX")
        chmod 0600 "$temporary"
        {
            printf '%s\n' "$BIND_ZONE_MARKER"
            printf '$TTL %s\n' "$DNS_TTL"
            printf '$ORIGIN %s.\n\n' "${zone%.}"
            printf '@ IN SOA %s. hostmaster.%s. (\n' "${IPA_HOSTNAME%.}" "${IPA_DOMAIN%.}"
            printf '    %s ; serial\n    3600 ; refresh\n    900 ; retry\n    604800 ; expire\n    86400 ; minimum\n)\n' "$serial"
            bind_zone_authority_block
            cat "$records_block"
        } > "$temporary"
        rm -f -- "$records_block"
        atomic_replace_file "$temporary" "$path"
    fi
    bind_set_zone_permissions "$path"
    if [[ "$existed" == true ]]; then
        state_mark_resource "dns-zone-$zone" modified-by-bootstrap
    else
        state_mark_resource "dns-zone-$zone" created-by-bootstrap
    fi
}

bind_increment_zone_serial() {
    local path=$1
    local current next temporary work_dir
    work_dir=$(dirname "$path")
    current=$(bind_zone_serial "$path")
    next=$(bind_next_serial "$current")
    temporary=$(mktemp "$work_dir/.serial.XXXXXX")
    chmod 0600 "$temporary"
    if ! awk -v old="$current" -v new="$next" '
        !changed && $0 ~ "^[[:space:]]*" old "[[:space:]]*; serial$" {
            sub(old, new)
            changed=1
        }
        { print }
        END { exit(changed == 1 ? 0 : 1) }
    ' "$path" > "$temporary"
    then
        rm -f -- "$temporary"
        log_error "managed BIND zone has no unique SOA serial marker: $path"
        return 1
    fi
    atomic_replace_file "$temporary" "$path"
    bind_set_zone_permissions "$path"
}

bind_import_record_line() {
    if [[ "${DNS_SERVER_ROLE:-primary}" == secondary ]]; then
        log_error "refusing to edit a BIND secondary zone locally; publish FreeIPA records on the DNS primary"
        return 1
    fi
    local line=$1
    local name ttl class type data zone path
    line=$(awk '{$1=$1; print}' <<< "$line")
    [[ -z "$line" || "$line" == \#* || "$line" == \;* ]] && return 0
    [[ "$line" != *';'* && "$line" != *'{'* && "$line" != *'}'* ]] || {
        log_error "refusing unsafe external DNS record line"
        return 1
    }
    read -r name ttl class type data <<< "$line"
    [[ "$ttl" =~ ^[0-9]+$ && "$class" == IN ]] || {
        log_warn "ignoring non-standard FreeIPA DNS record line: $line"
        return 0
    }
    case "$type" in
        A|AAAA|CNAME|PTR|SRV|TXT|URI) ;;
        *) log_warn "ignoring unsupported record type from FreeIPA output: $type"; return 0 ;;
    esac
    local normalized_name=${name,,}
    local forward_zone=${IPA_DOMAIN,,}
    forward_zone=${forward_zone%.}
    if [[ "$normalized_name" == "$forward_zone." || "$normalized_name" == *".$forward_zone." ]]; then
        zone=$IPA_DOMAIN
    else
        local reverse_zone
        while IFS= read -r reverse_zone; do
            reverse_zone=${reverse_zone%.}
            if [[ "$normalized_name" == "$reverse_zone." || "$normalized_name" == *".$reverse_zone." ]]; then
                zone=$reverse_zone
                break
            fi
        done < <(dns_reverse_zone_list)
        if [[ -z "$zone" ]]; then
            log_warn "ignoring FreeIPA record outside managed forward/reverse zones: $name"
            return 0
        fi
    fi
    path=$(bind_zone_file "$zone")
    [[ -f "$path" ]] || {
        log_error "managed zone file is missing while importing FreeIPA record: $path"
        return 1
    }
    if grep -Fqx "$line" "$path"; then
        return 0
    fi
    case "$type" in
        A|AAAA|CNAME|PTR)
            if awk -v owner="${normalized_name,,}" -v record_type="$type" \
                '$1 != ";" && NF >= 5 && tolower($1) == owner && $3 == "IN" && $4 == record_type { found=1 } END { exit(found ? 0 : 1) }' "$path"; then
                log_error "refusing to add a conflicting $type record for $name; reconcile the managed zone before importing FreeIPA output"
                return 1
            fi
            ;;
    esac
    state_record_backup "$path"
    printf '\n%s\n' "$line" >> "$path"
    bind_increment_zone_serial "$path"
    bind_set_zone_permissions "$path"
}

bind_configure_acl() {
    if is_dry_run || is_check; then
        plan "configure the named BIND ACL $BIND_ACL_NAME in $DNS_BIND_CONFIG_FILE"
        return 0
    fi
    [[ -f "$DNS_BIND_CONFIG_FILE" && ! -L "$DNS_BIND_CONFIG_FILE" ]] || {
        log_error "BIND configuration file is missing or symlinked: $DNS_BIND_CONFIG_FILE"
        return 1
    }
    if grep -Eq "^[[:space:]]*acl[[:space:]]+\\\"$BIND_ACL_NAME\\\"[[:space:]]*\\{" "$DNS_BIND_CONFIG_FILE" && ! grep -Fq "$BIND_ACL_BEGIN" "$DNS_BIND_CONFIG_FILE"; then
        log_error "BIND ACL $BIND_ACL_NAME already exists outside the bootstrap marker; refusing to overwrite it"
        return 1
    fi
    local block_file temporary network
    block_file=$(mktemp "$(dirname "$DNS_BIND_CONFIG_FILE")/.acl.XXXXXX")
    chmod 0600 "$block_file"
    {
        printf '%s\n' "$BIND_ACL_BEGIN"
        printf 'acl "%s" {\n' "$BIND_ACL_NAME"
        parse_space_list "${BIND_ACL_NETWORKS//,/ }"
        for network in "${PARSED_WORDS[@]}"; do
            printf '    %s;\n' "$network"
        done
        printf '};\n%s\n' "$BIND_ACL_END"
    } > "$block_file"
    state_record_backup "$DNS_BIND_CONFIG_FILE"
    temporary=$(mktemp "$(dirname "$DNS_BIND_CONFIG_FILE")/.named-acl.XXXXXX")
    chmod 0600 "$temporary"
    awk -v begin="$BIND_ACL_BEGIN" -v end="$BIND_ACL_END" -v block="$block_file" '
        function emit_block(line) {
            while ((getline line < block) > 0) print line
            close(block)
        }
        $0 == begin { skipping=1; emit_block(); inserted=1; next }
        $0 == end { skipping=0; next }
        skipping { next }
        !inserted && $0 ~ /^[[:space:]]*options[[:space:]]*\{/ { emit_block(); inserted=1 }
        { print }
        END { if (!inserted) emit_block() }
    ' "$DNS_BIND_CONFIG_FILE" > "$temporary"
    rm -f -- "$block_file"
    atomic_replace_file "$temporary" "$DNS_BIND_CONFIG_FILE"
    state_mark_resource named-acl modified-by-bootstrap
}

bind_configure_options() {
    bind_configure_acl || return 1
    if is_dry_run || is_check; then
        plan "configure BIND forwarding and restricted recursion in $DNS_BIND_CONFIG_FILE using $BIND_CONFIG_MODE mode"
        return 0
    fi
    [[ -f "$DNS_BIND_CONFIG_FILE" && ! -L "$DNS_BIND_CONFIG_FILE" ]] || {
        log_error "BIND configuration file is missing or symlinked: $DNS_BIND_CONFIG_FILE"
        return 1
    }
    local existing_forwarders=false existing_recursion=false existing_query=false existing_update_forwarding=false managed_options=false
    if grep -Eq '^[[:space:]]*forwarders[[:space:]]*\{' "$DNS_BIND_CONFIG_FILE"; then
        existing_forwarders=true
    fi
    if grep -Eq '^[[:space:]]*allow-recursion[[:space:]]*\{' "$DNS_BIND_CONFIG_FILE"; then
        existing_recursion=true
    fi
    if grep -Eq '^[[:space:]]*allow-query[[:space:]]*\{' "$DNS_BIND_CONFIG_FILE"; then
        existing_query=true
    fi
    if grep -Eq '^[[:space:]]*allow-update-forwarding[[:space:]]*\{' "$DNS_BIND_CONFIG_FILE"; then
        existing_update_forwarding=true
    fi
    grep -Fq "$BIND_OPTIONS_BEGIN" "$DNS_BIND_CONFIG_FILE" && managed_options=true
    local existing_recursion_setting=''
    existing_recursion_setting=$(
        awk -v begin="$BIND_OPTIONS_BEGIN" -v end="$BIND_OPTIONS_END" '
            $0 == begin { managed=1; next }
            $0 == end { managed=0; next }
            managed { next }
            /^[[:space:]]*recursion[[:space:]]+(yes|no)[[:space:]]*;/ {
                value=$0
                sub(/^[[:space:]]*recursion[[:space:]]+/, "", value)
                sub(/[[:space:]]*;.*$/, "", value)
                print value
                exit
            }
        ' "$DNS_BIND_CONFIG_FILE"
    )
    if [[ "$existing_forwarders" == true && "$managed_options" == false ]]; then
        log_error "pre-existing unmanaged BIND forwarders were found; refusing to overwrite or silently retain them. Reconcile them manually or use a clean managed include"
        return 1
    fi
    if [[ "$existing_query" == true && "$managed_options" == false && -n "$BIND_ALLOW_QUERY_ACL" ]]; then
        log_error "pre-existing unmanaged BIND allow-query policy was found; refusing to add a second policy. Reconcile it manually or leave BIND_ALLOW_QUERY_ACL empty"
        return 1
    fi
    if [[ "$existing_update_forwarding" == true && "$managed_options" == false && -n "$BIND_ALLOW_UPDATE_FORWARDING_ACL" ]]; then
        log_error "pre-existing unmanaged BIND allow-update-forwarding policy was found; refusing to add a second policy. Reconcile it manually or leave BIND_ALLOW_UPDATE_FORWARDING_ACL empty"
        return 1
    fi
    if [[ "$existing_recursion" == true && "$managed_options" == false ]] && awk '
        /^[[:space:]]*allow-recursion[[:space:]]*\{/ { inside=1 }
        inside && /(^|[[:space:];])(any|0\.0\.0\.0\/0|::\/0)([[:space:];]|$)/ { found=1 }
        inside && /}/ { inside=0 }
        END { exit !found }
    ' "$DNS_BIND_CONFIG_FILE"; then
        log_error "pre-existing BIND configuration permits unrestricted recursion; refusing to proceed"
        return 1
    fi
    if [[ "$existing_recursion_setting" == no ]]; then
        log_error "pre-existing BIND configuration disables recursion; refusing to proceed with managed DNS forwarding. Reconcile the recursion policy first"
        return 1
    fi
    if [[ "$managed_options" == true ]]; then
        existing_forwarders=false
        existing_recursion=false
    fi

    state_record_backup "$DNS_BIND_CONFIG_FILE"
    local block_file new_file has_options
    if grep -Eq '^[[:space:]]*options[[:space:]]*\{' "$DNS_BIND_CONFIG_FILE"; then
        has_options=1
    else
        has_options=0
    fi
    block_file=$(mktemp "$(dirname "$DNS_BIND_CONFIG_FILE")/.options.XXXXXX")
    chmod 0600 "$block_file"
    {
        if [[ "$has_options" == 0 ]]; then
            printf 'options {\n'
        fi
        printf '%s\n' "$BIND_OPTIONS_BEGIN"
        if [[ -n "$DNS_FORWARDERS" ]]; then
            printf 'forwarders {'
            parse_space_list "$DNS_FORWARDERS"
            local forwarder
            for forwarder in "${PARSED_WORDS[@]}"; do
                printf ' %s;' "$forwarder"
            done
            printf ' };\nforward only;\n'
        fi
        if [[ -n "$BIND_ALLOW_QUERY_ACL" ]]; then
            printf 'allow-query { %s; };\n' "$BIND_ALLOW_QUERY_ACL"
        fi
        if [[ "$existing_recursion" == false ]]; then
            if [[ -z "$existing_recursion_setting" ]]; then
                printf 'recursion yes;\n'
            fi
            if [[ -n "$BIND_ALLOW_RECURSION_ACL" ]]; then
                printf 'allow-recursion { %s; };\n' "$BIND_ALLOW_RECURSION_ACL"
            else
                printf 'allow-recursion {'
                parse_space_list "$DNS_RECURSION_NETWORKS"
                local network
                for network in "${PARSED_WORDS[@]}"; do
                    printf ' %s;' "$network"
                done
                printf ' };\n'
            fi
        fi
        if [[ -n "$BIND_ALLOW_UPDATE_FORWARDING_ACL" ]]; then
            printf 'allow-update-forwarding { %s; };\n' "$BIND_ALLOW_UPDATE_FORWARDING_ACL"
        fi
        printf '%s\n' "$BIND_OPTIONS_END"
        if [[ "$has_options" == 0 ]]; then
            printf '};\n'
        fi
    } > "$block_file"
    new_file=$(mktemp "$(dirname "$DNS_BIND_CONFIG_FILE")/.named.XXXXXX")
    chmod 0600 "$new_file"
    awk -v begin="$BIND_OPTIONS_BEGIN" -v end="$BIND_OPTIONS_END" \
        -v block="$block_file" -v has_options="$has_options" '
        function emit_block( line ) {
            while ((getline line < block) > 0) print line
            close(block)
        }
        $0 == begin { skip=1; next }
        $0 == end { skip=0; next }
        skip { next }
        !inserted && has_options == 1 && $0 ~ /^[[:space:]]*options[[:space:]]*\{/ {
            print
            emit_block()
            inserted=1
            next
        }
        { print }
        END {
            if (!inserted) emit_block()
        }
    ' "$DNS_BIND_CONFIG_FILE" > "$new_file"
    atomic_replace_file "$new_file" "$DNS_BIND_CONFIG_FILE"
    state_mark_resource named-config modified-by-bootstrap
}

bind_transfer_is_configured() {
    [[ -n "$(topology_secondary_server 2>/dev/null || true)" && -n "$(topology_secondary_ip 2>/dev/null || true)" ]]
}

bind_fetch_transfer_key_over_ssh() {
    [[ "${DNS_SERVER_ROLE:-primary}" == secondary ]] || return 1
    [[ "${DNS_TSIG_PROVISION:-manual}" == ssh ]] || return 1
    command_exists ssh || {
        log_error "DNS_TSIG_PROVISION=ssh requires the ssh client"
        return 1
    }
    [[ -n "${DNS_TSIG_SSH_USER:-}" ]] || {
        log_error "DNS_TSIG_SSH_USER is required for SSH TSIG provisioning"
        return 1
    }
    [[ -n "${DNS_TSIG_SSH_KEY_FILE:-}" ]] || {
        log_error "DNS_TSIG_SSH_KEY_FILE is required for SSH TSIG provisioning"
        return 1
    }
    [[ -f "$DNS_TSIG_SSH_KEY_FILE" && ! -L "$DNS_TSIG_SSH_KEY_FILE" ]] || {
        log_error "DNS_TSIG_SSH_KEY_FILE is not a readable regular file: $DNS_TSIG_SSH_KEY_FILE"
        return 1
    }
    local primary host remote_path temporary
    primary=$(topology_primary_server)
    host="$DNS_TSIG_SSH_USER@$primary"
    remote_path=$(printf '%q' "$DNS_TRANSFER_KEY_FILE")
    if is_dry_run || is_check; then
        plan "retrieve the existing TSIG key file from $host over verified SSH; no key material will be logged"
        return 0
    fi
    install -d -m 0750 -- "$(dirname "$DNS_TRANSFER_KEY_FILE")"
    temporary=$(mktemp "$(dirname "$DNS_TRANSFER_KEY_FILE")/.transfer-key-fetch.XXXXXX")
    chmod 0600 "$temporary"
    local -a ssh_args=(-p "$DNS_TSIG_SSH_PORT" -i "$DNS_TSIG_SSH_KEY_FILE" -o BatchMode=yes -o PasswordAuthentication=no)
    if ! ssh "${ssh_args[@]}" "$host" "cat -- $remote_path" > "$temporary"; then
        rm -f -- "$temporary"
        log_error "could not retrieve the TSIG key from $host; copy it manually or repair SSH trust"
        return 1
    fi
    grep -Fq "key \"$DNS_TRANSFER_KEY_NAME\"" "$temporary" || {
        rm -f -- "$temporary"
        log_error "retrieved TSIG key file does not contain the configured key name"
        return 1
    }
    atomic_replace_file "$temporary" "$DNS_TRANSFER_KEY_FILE"
    bind_set_zone_permissions "$DNS_TRANSFER_KEY_FILE"
    log_info "retrieved the configured TSIG key from the DNS primary over SSH"
}

bind_write_transfer_key_file() {
    bind_key_required || return 0
    local key_file=${DNS_TRANSFER_KEY_FILE:?DNS_TRANSFER_KEY_FILE is required}
    local key_dir temporary
    key_dir=$(dirname "$key_file")
    if [[ -e "$key_file" ]]; then
        [[ -f "$key_file" && ! -L "$key_file" ]] || {
            log_error "BIND transfer key must be a regular non-symlink file: $key_file"
            return 1
        }
        grep -Fq "key \"$DNS_TRANSFER_KEY_NAME\"" "$key_file" || {
            log_error "existing BIND transfer key file does not contain the configured key name: $key_file"
            return 1
        }
        grep -Eq '^[[:space:]]*secret[[:space:]]+\"[^\"]+\"[[:space:]]*;' "$key_file" || {
            log_error "existing BIND transfer key file does not contain a protected TSIG secret: $key_file"
            return 1
        }
        local key_mode
        key_mode=$(file_mode_octal "$key_file") || return 1
        [[ "${key_mode: -1}" == 0 ]] || {
            log_error "BIND transfer key file must not be readable by other users: $key_file"
            return 1
        }
        log_info "reusing the existing BIND TSIG key file: $key_file"
        return 0
    fi
    if is_dry_run || is_check; then
        plan "create or verify the protected BIND TSIG key $DNS_TRANSFER_KEY_NAME and share the same key with the DNS secondary"
        return 0
    fi
    if [[ "${DNS_SERVER_ROLE:-primary}" == secondary ]]; then
        if bind_fetch_transfer_key_over_ssh; then
            return 0
        fi
        if [[ "${DNS_TSIG_PROVISION:-manual}" == ssh ]]; then
            return 1
        fi
        log_error "BIND secondary has no TSIG key; copy the primary's protected $key_file to this host or set DNS_TSIG_PROVISION=ssh"
        return 1
    fi
    install -d -m 0750 -- "$key_dir"
    if [[ -n "${DNS_TRANSFER_KEY_SECRET:-}" ]]; then
        temporary=$(mktemp "$key_dir/.transfer-key.XXXXXX")
        chmod 0600 "$temporary"
        {
            printf 'key "%s" {\n' "$DNS_TRANSFER_KEY_NAME"
            printf '    algorithm hmac-sha256;\n'
            printf '    secret "%s";\n' "$DNS_TRANSFER_KEY_SECRET"
            printf '};\n'
        } > "$temporary"
    elif command_exists tsig-keygen; then
        temporary=$(mktemp "$key_dir/.transfer-key.XXXXXX")
        chmod 0600 "$temporary"
        # Do not send the generated key through run_command: tsig-keygen emits
        # the secret on stdout and would otherwise put it in the operator log.
        if ! tsig-keygen -a hmac-sha256 "$DNS_TRANSFER_KEY_NAME" > "$temporary" 2>/dev/null; then
            rm -f -- "$temporary"
            log_error "tsig-keygen failed while creating the BIND transfer key"
            return 1
        fi
    else
        log_error "DNS_TRANSFER_SECURITY=tsig requires DNS_TRANSFER_KEY_SECRET or the installed tsig-keygen utility"
        return 1
    fi
    state_record_backup "$key_file"
    atomic_replace_file "$temporary" "$key_file"
    bind_set_zone_permissions "$key_file"
    state_mark_resource named-transfer-key created-by-bootstrap
}

bind_ensure_transfer_key_include() {
    bind_key_required || return 0
    local include_line="include \"$DNS_TRANSFER_KEY_FILE\";"
    grep -Fqx "$include_line" "$DNS_BIND_CONFIG_FILE" && return 0
    if is_dry_run || is_check; then
        plan "include the protected BIND transfer key file in $DNS_BIND_CONFIG_FILE"
        return 0
    fi
    state_record_backup "$DNS_BIND_CONFIG_FILE"
    local temporary
    temporary=$(mktemp "$(dirname "$DNS_BIND_CONFIG_FILE")/.named-key-include.XXXXXX")
    chmod 0600 "$temporary"
    awk -v line="$include_line" '{ print } END { print line }' "$DNS_BIND_CONFIG_FILE" > "$temporary"
    atomic_replace_file "$temporary" "$DNS_BIND_CONFIG_FILE"
}

bind_dynamic_update_options() {
    if [[ "${DNS_SERVER_ROLE:-primary}" == secondary ]]; then
        printf 'allow-update { none; };\n'
        return 0
    fi
    case "${DNS_DYNAMIC_UPDATE_MODE:-disabled}" in
        disabled)
            printf 'allow-update { none; };\n'
            ;;
        insecure)
            printf 'allow-update { %s; };\n' "$BIND_ALLOW_UPDATE_ACL"
            ;;
        secure)
            # BIND rejects a zone that contains both allow-update and
            # update-policy.  Secure mode therefore emits update-policy only.
            printf 'update-policy { grant %s zonesub ANY; };\n' "$DNS_TSIG_KEY_NAME"
            ;;
    esac
}

bind_transfer_zone_options() {
    local secondary_server secondary_ip primary_ip notify_acl transfer_acl
    primary_ip=$(topology_primary_ip)
    secondary_server=$(topology_secondary_server)
    secondary_ip=$(topology_secondary_ip)
    notify_acl=${BIND_ALLOW_NOTIFY_ACL:-$primary_ip}
    transfer_acl=${BIND_ALLOW_TRANSFER_ACL:-$secondary_ip}
    if [[ "${DNS_SERVER_ROLE:-primary}" == secondary ]]; then
        printf 'type slave;\n'
        printf 'file "%s";\n' "$(bind_zone_file "$1")"
        printf 'allow-transfer { none; };\n'
        printf 'allow-notify { %s; };\n' "$notify_acl"
        if [[ "${DNS_TRANSFER_SECURITY:-tsig}" == tsig ]]; then
            printf 'masters { %s key %s; };\n' "$primary_ip" "$DNS_TSIG_KEY_NAME"
        else
            printf 'masters { %s; };\n' "$primary_ip"
        fi
        bind_dynamic_update_options
    else
        printf 'type master;\n'
        printf 'file "%s";\n' "$(bind_zone_file "$1")"
        if [[ -n "$secondary_server" && -n "$secondary_ip" ]]; then
            if [[ "${DNS_TRANSFER_SECURITY:-tsig}" == tsig ]]; then
                printf 'allow-transfer { key %s; };\n' "$DNS_TSIG_KEY_NAME"
            else
                printf 'allow-transfer { %s; };\n' "$transfer_acl"
            fi
            if [[ "${DNS_NOTIFY_ENABLED:-true}" == true ]]; then
                printf 'also-notify { %s; };\n' "$secondary_ip"
                printf 'notify yes;\n'
            else
                printf 'notify no;\n'
            fi
        else
            printf 'allow-transfer { none; };\n'
        fi
        bind_dynamic_update_options
    fi
}

bind_write_include_file() {
    local zone_config_file
    zone_config_file=$(bind_zone_config_file)
    if is_dry_run || is_check; then
        plan "declare BIND zones in $zone_config_file using $BIND_CONFIG_MODE mode"
        return 0
    fi
    install -d -m 0750 -- "$(dirname "$zone_config_file")"
    bind_prepare_zone_directory
    bind_write_transfer_key_file
    [[ ! -L "$zone_config_file" ]] || {
        log_error "refusing to replace a symlinked BIND zone configuration file: $zone_config_file"
        return 1
    }
    if [[ "${BIND_CONFIG_MODE:-managed_include}" == native ]]; then
        local existing_zone
        for existing_zone in "$IPA_DOMAIN"; do
            if bind_unmanaged_zone_declaration_exists "$zone_config_file" "$existing_zone" || {
                [[ "$zone_config_file" != "$DNS_BIND_CONFIG_FILE" ]] && bind_unmanaged_zone_declaration_exists "$DNS_BIND_CONFIG_FILE" "$existing_zone"
            }; then
                log_error "BIND zone $existing_zone already has an unmanaged native declaration; refusing to create a duplicate. Set the native paths to the active declaration and reconcile it manually before rerunning"
                return 1
            fi
        done
        while IFS= read -r existing_zone; do
            [[ -n "$existing_zone" ]] || continue
            if bind_unmanaged_zone_declaration_exists "$zone_config_file" "$existing_zone" || {
                [[ "$zone_config_file" != "$DNS_BIND_CONFIG_FILE" ]] && bind_unmanaged_zone_declaration_exists "$DNS_BIND_CONFIG_FILE" "$existing_zone"
            }; then
                log_error "BIND reverse zone $existing_zone already has an unmanaged native declaration; refusing to create a duplicate. Set the native paths to the active declaration and reconcile it manually before rerunning"
                return 1
            fi
        done < <(dns_reverse_zone_list)
    fi
    if [[ "${BIND_CONFIG_MODE:-managed_include}" != native && -e "$zone_config_file" ]] && ! grep -Fq "$BIND_INCLUDE_BEGIN" "$zone_config_file"; then
        log_error "refusing to overwrite unmanaged BIND include file: $zone_config_file"
        return 1
    fi
    local zone_config_preexisting=false
    if [[ -e "$zone_config_file" ]]; then
        zone_config_preexisting=true
        state_record_backup "$zone_config_file"
    fi
    local temporary
    local block_file
    block_file=$(mktemp "$(dirname "$zone_config_file")/.freeipa-zone-block.XXXXXX")
    chmod 0600 "$block_file"
    {
        printf '%s\n' "$BIND_INCLUDE_BEGIN"
        printf 'zone "%s" {\n' "${IPA_DOMAIN%.}"
        bind_transfer_zone_options "$IPA_DOMAIN" | sed 's/^/    /'
        printf '} ;\n'
        while IFS= read -r reverse_zone; do
            [[ -n "$reverse_zone" ]] || continue
            printf 'zone "%s" {\n' "${reverse_zone%.}"
            bind_transfer_zone_options "$reverse_zone" | sed 's/^/    /'
            printf '} ;\n'
        done < <(dns_reverse_zone_list)
        printf '%s\n' "$BIND_INCLUDE_END"
    } > "$block_file"
    temporary=$(mktemp "$(dirname "$zone_config_file")/.freeipa-include.XXXXXX")
    chmod 0600 "$temporary"
    if [[ -e "$zone_config_file" ]]; then
        awk -v begin="$BIND_INCLUDE_BEGIN" -v end="$BIND_INCLUDE_END" -v block="$block_file" '
            function emit_block(line) {
                while ((getline line < block) > 0) print line
                close(block)
            }
            $0 == begin { skipping=1; emit_block(); inserted=1; next }
            $0 == end { skipping=0; next }
            skipping { next }
            { print }
            END { if (!inserted) { print ""; emit_block() } }
        ' "$zone_config_file" > "$temporary"
    else
        cat "$block_file" > "$temporary"
    fi
    rm -f -- "$block_file"
    atomic_replace_file "$temporary" "$zone_config_file"
    if [[ "${BIND_CONFIG_MODE:-managed_include}" != native ]]; then
        bind_set_zone_permissions "$zone_config_file"
    elif [[ "$zone_config_preexisting" == false ]]; then
        # A newly created native zone declaration file has no prior metadata
        # to preserve.  Keep it root-readable and compatible with named while
        # leaving an existing distribution/Webmin file untouched.
        chmod 0640 "$zone_config_file"
        if [[ "$(id -u)" -eq 0 ]]; then
            chown "root:$(bind_named_group)" "$zone_config_file" 2>/dev/null || true
        fi
    fi

    if [[ "$zone_config_file" != "$DNS_BIND_CONFIG_FILE" ]] && ! grep -Fq "include \"$zone_config_file\";" "$DNS_BIND_CONFIG_FILE"; then
        [[ -f "$DNS_BIND_CONFIG_FILE" && ! -L "$DNS_BIND_CONFIG_FILE" ]] || {
            log_error "BIND main configuration file is missing or symlinked: $DNS_BIND_CONFIG_FILE"
            return 1
        }
        state_record_backup "$DNS_BIND_CONFIG_FILE"
        temporary=$(mktemp "$(dirname "$DNS_BIND_CONFIG_FILE")/.named-include.XXXXXX")
        chmod 0600 "$temporary"
        awk -v path="$zone_config_file" '{ print } END { print "include \"" path "\";" }' "$DNS_BIND_CONFIG_FILE" > "$temporary"
        atomic_replace_file "$temporary" "$DNS_BIND_CONFIG_FILE"
    fi
    bind_ensure_transfer_key_include
    state_mark_resource named-zone-include created-by-bootstrap
}

bind_run_validation_command() {
    local description=$1
    shift
    if run_command "$@"; then
        return 0
    else
        local rc=$?
        log_error "$description failed with exit code $rc"
        return "$rc"
    fi
}

bind_validate_configuration() {
    if ! command_exists named-checkconf; then
        log_error "named-checkconf is required for BIND validation"
        return 1
    fi
    bind_run_validation_command named-checkconf named-checkconf "$DNS_BIND_CONFIG_FILE" || return 1
    if [[ "${DNS_SERVER_ROLE:-primary}" == secondary ]]; then
        log_info "BIND secondary configuration validated with named-checkconf; transferred slave files are never edited locally"
        return 0
    fi
    command_exists named-checkzone || {
        log_error "named-checkzone is required for BIND primary zone validation"
        return 1
    }
    bind_run_validation_command "named-checkzone ${IPA_DOMAIN%.}" named-checkzone "${IPA_DOMAIN%.}" "$(bind_zone_file "$IPA_DOMAIN")" || return 1
    while IFS= read -r reverse_zone; do
        [[ -n "$reverse_zone" ]] || continue
        bind_run_validation_command "named-checkzone ${reverse_zone%.}" named-checkzone "${reverse_zone%.}" "$(bind_zone_file "$reverse_zone")" || return 1
    done < <(dns_reverse_zone_list)
}

bind_zone_soa_serial() {
    local server=$1
    local zone=$2
    dig +time=5 +tries=1 +short "@$server" "$zone" SOA 2>/dev/null | awk 'NF >= 3 { print $3; exit }'
}

bind_validate_zone_axfr() {
    local primary_ip=$1
    local zone=$2
    local transfer_file
    local -a transfer_args=(+tcp +time=5 +tries=1)
    if [[ "${DNS_TRANSFER_SECURITY:-tsig}" == tsig ]]; then
        local key_file=${DNS_TRANSFER_KEY_FILE:?DNS_TRANSFER_KEY_FILE is required}
        [[ -f "$key_file" && ! -L "$key_file" ]] || {
            log_error "TSIG key file is required for the secondary AXFR validation: $key_file"
            return 1
        }
        local key_mode
        key_mode=$(file_mode_octal "$key_file") || return 1
        [[ "${key_mode: -1}" == 0 ]] || {
            log_error "TSIG key file is readable by other users; refusing AXFR validation: $key_file"
            return 1
        }
        transfer_args+=(-k "$key_file")
    fi
    transfer_args+=("@$primary_ip" "$zone" AXFR)
    transfer_file=$(mktemp "${TMPDIR:-/tmp}/freeipa-axfr.XXXXXX")
    if ! dig "${transfer_args[@]}" > "$transfer_file" 2>&1; then
        rm -f -- "$transfer_file"
        log_error "authenticated AXFR request for $zone from $primary_ip failed"
        return 1
    fi
    local soa_count
    soa_count=$(awk '$4 == "SOA" { count++ } END { print count + 0 }' "$transfer_file")
    rm -f -- "$transfer_file"
    [[ "$soa_count" =~ ^[0-9]+$ && "$soa_count" -ge 2 ]] || {
        log_error "AXFR response for $zone from $primary_ip did not contain a complete SOA-bounded zone transfer"
        return 1
    }
    log_info "validated actual ${DNS_TRANSFER_SECURITY:-none}-protected AXFR for $zone from $primary_ip"
}

bind_validate_secondary_transfer_once() {
    [[ "${DNS_SERVER_ROLE:-primary}" == secondary ]] || return 0
    command_exists dig || {
        log_error "dig is required to validate BIND secondary convergence"
        return 1
    }
    local primary_ip
    primary_ip=$(topology_primary_ip)
    local zone primary_serial secondary_serial
    while IFS= read -r zone; do
        [[ -n "$zone" ]] || continue
        primary_serial=$(bind_zone_soa_serial "$primary_ip" "$zone")
        secondary_serial=$(bind_zone_soa_serial 127.0.0.1 "$zone")
        [[ "$primary_serial" =~ ^[0-9]+$ && "$secondary_serial" =~ ^[0-9]+$ ]] || {
            log_error "could not read SOA serials for $zone from primary $primary_ip and local secondary"
            return 1
        }
        [[ "$primary_serial" == "$secondary_serial" ]] || {
            log_error "BIND secondary SOA serial for $zone ($secondary_serial) does not converge with primary ($primary_serial)"
            return 1
        }
        bind_validate_zone_axfr "$primary_ip" "$zone" || return 1
        log_info "BIND secondary SOA serial converged for $zone: $secondary_serial"
        local ns_answer
        ns_answer=$(dig +time=5 +tries=1 +short @127.0.0.1 "$zone" NS 2>/dev/null || true)
        grep -Fqi "$(topology_primary_server)" <<< "$ns_answer" || {
            log_error "BIND secondary NS answer for $zone does not contain the configured DNS primary"
            return 1
        }
        if [[ -n "$(topology_secondary_server)" ]]; then
            grep -Fqi "$(topology_secondary_server)" <<< "$ns_answer" || {
                log_error "BIND secondary NS answer for $zone does not contain the configured DNS secondary"
                return 1
            }
        fi
    done < <(printf '%s\n' "$IPA_DOMAIN"; dns_reverse_zone_list)
}

bind_validate_secondary_transfer() {
    [[ "${DNS_SERVER_ROLE:-primary}" == secondary ]] || return 0
    local wait_seconds=${DNS_TRANSFER_WAIT_SECONDS:-90}
    local poll_seconds=${DNS_TRANSFER_POLL_SECONDS:-3}
    local deadline=$((SECONDS + wait_seconds))
    local first_attempt=true
    while :; do
        if bind_validate_secondary_transfer_once; then
            return 0
        fi
        if (( SECONDS >= deadline )); then
            log_error "BIND secondary did not converge within ${wait_seconds}s; inspect named logs and the primary/secondary transfer policy"
            return 1
        fi
        if [[ "$first_attempt" == true ]]; then
            log_warn "BIND secondary transfer is not converged yet; waiting up to ${wait_seconds}s for NOTIFY/AXFR/IXFR"
            first_attempt=false
        fi
        sleep "$poll_seconds"
    done
}

bind_validate_authoritative_nameservers() {
    [[ "${DNS_SERVER_ROLE:-primary}" == primary ]] || return 0
    command_exists dig || return 1
    local zone ns_answer primary secondary
    primary=$(topology_primary_server)
    secondary=$(topology_secondary_server)
    while IFS= read -r zone; do
        [[ -n "$zone" ]] || continue
        ns_answer=$(dig +time=5 +tries=1 +short @127.0.0.1 "$zone" NS 2>/dev/null || true)
        grep -Fqi "$primary" <<< "$ns_answer" || {
            log_error "authoritative BIND zone $zone is missing NS $primary"
            return 1
        }
        if [[ -n "$secondary" ]]; then
            grep -Fqi "$secondary" <<< "$ns_answer" || {
                log_error "authoritative BIND zone $zone is missing NS $secondary"
                return 1
            }
        fi
    done < <(printf '%s\n' "$IPA_DOMAIN"; dns_reverse_zone_list)
}

bind_activate_service() {
    command_exists systemctl || {
        log_error "systemctl is required to activate named"
        return 1
    }
    if systemctl is-active --quiet named; then
        run_command systemctl reload named
    else
        run_command systemctl enable --now named
    fi
}

bind_webmin_installed() {
    if command_exists webmin; then
        return 0
    fi
    package_is_installed webmin
}

bind_webmin_configured_port() {
    local config=${WEBMIN_CONFIG_FILE:-/etc/webmin/miniserv.conf}
    [[ -f "$config" && ! -L "$config" ]] || {
        log_error "Webmin configuration file is missing or symlinked: $config"
        return 1
    }
    local port listen
    port=$(awk -F= '$1 == "port" { value=$2; gsub(/[[:space:]]/, "", value); print value; exit }' "$config")
    listen=$(awk -F= '$1 == "listen" { value=$2; gsub(/[[:space:]]/, "", value); print value; exit }' "$config")
    validate_tcp_port "$port" || {
        log_error "Webmin configuration has an invalid port in $config: ${port:-<unset>}"
        return 1
    }
    if [[ -n "$listen" && "$listen" != "$port" ]]; then
        log_error "Webmin listen value '$listen' does not match port '$port' in $config"
        return 1
    fi
    printf '%s' "$port"
}

bind_webmin_is_listening() {
    local port=$1
    command_exists ss || {
        log_error "ss is required to validate the Webmin listener on TCP $port"
        return 1
    }
    ss -lntH 2>/dev/null | awk -v port="$port" '$4 ~ (":" port "$ ") || $4 ~ (":" port "$") { found=1 } END { exit(found ? 0 : 1) }'
}

bind_validate_webmin_peer_configuration() {
    local peer peer_ip
    peer=$(topology_webmin_peer_server 2>/dev/null || true)
    peer_ip=$(topology_webmin_peer_ip 2>/dev/null || true)
    [[ -n "$peer" ]] || return 0
    validate_fqdn "$peer" || {
        log_error "configured Webmin peer is not a valid FQDN: $peer"
        return 1
    }
    if [[ -n "$peer_ip" ]]; then
        validate_ipv4 "$peer_ip" || {
            log_error "configured Webmin peer IP is not a valid IPv4 address: $peer_ip"
            return 1
        }
    fi
    log_info "Webmin peer is parameterized as $peer:${WEBMIN_PEER_PORT:-$WEBMIN_PORT}; Webmin cluster registration remains an administration-plane action"
    if [[ -z "${WEBMIN_PEER_USERNAME:-}" || -z "${WEBMIN_PEER_PASSWORD:-}" ]]; then
        log_warn "Webmin peer credentials are not complete; register the peer manually in Webmin Servers Index/Cluster Webmin Servers"
    else
        log_info "Webmin peer credentials are present in the protected environment; no internal Webmin files or undocumented API are modified by this bootstrap"
    fi
}

bind_validate_webmin() {
    local query_rc
    if bind_webmin_installed; then
        :
    else
        query_rc=$?
        if (( query_rc != 1 )); then
            log_error "could not determine whether the Webmin package is installed (rpm query exit code $query_rc)"
            return "$query_rc"
        fi
        if is_dry_run; then
            plan "validate the installed Webmin configuration and active TCP ${WEBMIN_PORT} listener after package installation"
            return 0
        fi
        log_error "Webmin is not installed; bind9-webmin mode cannot validate its management listener"
        return 1
    fi

    local actual_port
    actual_port=$(bind_webmin_configured_port) || return 1
    [[ "$actual_port" == "$WEBMIN_PORT" ]] || {
        log_error "Webmin is configured for TCP $actual_port, but WEBMIN_PORT=$WEBMIN_PORT"
        return 1
    }
    command_exists systemctl || {
        log_error "systemctl is required to validate the Webmin service"
        return 1
    }
    systemctl is-active --quiet webmin || {
        log_error "Webmin service is not active"
        return 1
    }
    bind_webmin_is_listening "$actual_port" || {
        log_error "Webmin service is active but is not listening on TCP $actual_port"
        return 1
    }
    bind_validate_webmin_peer_configuration || return 1
    log_info "Webmin is installed, active, and listening on TCP $actual_port"
}

dns_provider_validate_webmin() {
    bind_validate_webmin
}

bind_install_webmin() {
    if command_exists webmin; then
        log_info "Webmin is already installed; preserving it and validating its configuration and listener"
        bind_validate_webmin
        return $?
    fi
    local query_rc
    if package_is_installed webmin; then
        log_info "Webmin package is already installed; preserving it and validating its configuration and listener"
        bind_validate_webmin
        return $?
    else
        query_rc=$?
        if (( query_rc != 1 )); then
            log_error "could not determine whether the Webmin package is installed (rpm query exit code $query_rc)"
            return "$query_rc"
        fi
    fi
    if is_dry_run || is_check; then
        plan "download the official Webmin repository setup script, verify syntax and required SHA-256 pin, configure the signed repository, and install webmin"
        return 0
    fi
    command_exists curl || {
        log_error "curl is required to install the official Webmin repository"
        return 1
    }
    [[ "${WEBMIN_SETUP_REPO_SHA256:-}" =~ ^[A-Fa-f0-9]{64}$ ]] || {
        log_error 'WEBMIN_SETUP_REPO_SHA256 must be a 64-character SHA-256 pin before executing the remote repository installer'
        return 1
    }
    local temporary
    umask 077
    temporary=$(mktemp)
    if ! run_command curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        'https://raw.githubusercontent.com/webmin/webmin/master/webmin-setup-repo.sh' -o "$temporary"; then
        rm -f -- "$temporary"
        return 1
    fi
    if ! printf '%s  %s\n' "$WEBMIN_SETUP_REPO_SHA256" "$temporary" | sha256sum -c - >/dev/null; then
        rm -f -- "$temporary"
        log_error 'Webmin repository script SHA-256 verification failed'
        return 1
    fi
    if ! sh -n "$temporary"; then
        rm -f -- "$temporary"
        return 1
    fi
    if ! run_command sh "$temporary" --force --stable; then
        rm -f -- "$temporary"
        return 1
    fi
    rm -f -- "$temporary"
    package_install webmin || return $?
    state_mark_resource webmin-package created-by-bootstrap
    bind_validate_webmin
}

dns_provider_check() {
    log_stage dns-bind-check
    command_exists dig || {
        if is_dry_run; then
            plan "install bind-utils for DNS validation"
        else
            log_error "bind9-webmin provider requires dig from bind-utils"
            return 1
        fi
    }
    if is_dry_run; then
        plan "check BIND package, named configuration ownership, recursion networks, and official Webmin repository prerequisites"
    fi
}

dns_provider_install() {
    log_stage dns-bind-install
    package_install bind bind-utils curl ca-certificates
    bind_install_webmin
}

dns_provider_configure_forwarders() {
    log_stage dns-bind-forwarding
    bind_configure_options
}

dns_provider_create_forward_zone() {
    log_stage dns-bind-forward-zone
    if is_dry_run || is_check; then
        if [[ "${DNS_SERVER_ROLE:-primary}" == secondary ]]; then
            plan "declare BIND forward zone $IPA_DOMAIN as a read-only slave of $(topology_primary_server)"
        else
            plan "create/manage BIND forward zone $IPA_DOMAIN with the configured DNS NS/A prerequisites; post-install system records come from ipa-replica-install or ipa-server-install"
        fi
        return 0
    fi
    if [[ "${DNS_SERVER_ROLE:-primary}" == secondary ]]; then
        bind_prepare_zone_directory
        log_info "BIND secondary will never create or edit the transferred forward zone file"
        return 0
    fi
    bind_prepare_zone_directory
    bind_write_zone_file "$IPA_DOMAIN" "$(bind_zone_file "$IPA_DOMAIN")" false
}

dns_provider_create_reverse_zone() {
    log_stage dns-bind-reverse-zone
    if is_dry_run || is_check; then
        if [[ "${DNS_SERVER_ROLE:-primary}" == secondary ]]; then
            plan "declare each configured BIND reverse zone as a read-only slave; no reverse zone will be guessed from the local IP"
        else
            plan "create/manage the configured authoritative BIND reverse zone list and DNS server PTR prerequisites"
        fi
        return 0
    fi
    if [[ "${DNS_SERVER_ROLE:-primary}" == secondary ]]; then
        bind_prepare_zone_directory
        log_info "BIND secondary will never create or edit transferred reverse zone files"
        return 0
    fi
    bind_prepare_zone_directory
    while IFS= read -r reverse_zone; do
        [[ -n "$reverse_zone" ]] || continue
        bind_write_zone_file "$reverse_zone" "$(bind_zone_file "$reverse_zone")" true
    done < <(dns_reverse_zone_list)
}

dns_provider_create_record() {
    local line=${1:-}
    if is_dry_run || is_check; then
        plan "ensure BIND record: $line"
        return 0
    fi
    bind_import_record_line "$line"
}

dns_provider_configure() {
    log_stage dns-bind-configure
    bind_write_include_file
    if is_dry_run || is_check; then
        return 0
    fi
    bind_validate_configuration || return 1
    bind_activate_service
}

dns_provider_validate() {
    log_stage dns-bind-validation
    if is_dry_run; then
        plan "run named-checkconf${DNS_SERVER_ROLE:+ and the ${DNS_SERVER_ROLE} zone validation}, Webmin listener, and DNS validation against 127.0.0.1"
        return 0
    fi
    bind_validate_webmin || return 1
    bind_validate_configuration || return 1
    systemctl is-active --quiet named || {
        log_error "named is not active after BIND configuration"
        return 1
    }
    if [[ "${DNS_SERVER_ROLE:-primary}" == secondary ]]; then
        bind_validate_secondary_transfer || return 1
    else
        bind_validate_authoritative_nameservers || return 1
    fi
    local generated
    if ! dns_validate_prerequisite_records 127.0.0.1; then
        return 1
    fi
    generated=$(dns_find_generated_record_file)
    if [[ -n "$generated" ]]; then
        if ! dns_validate_records_file "$generated" 127.0.0.1; then
            return 1
        fi
        EXTERNAL_DNS_STATUS=complete
    else
        log_warn "no captured FreeIPA system-record file is available; validating only the server A/PTR prerequisites"
    fi
}

dns_provider_validate_prerequisites() {
    log_stage dns-bind-prerequisites
    if is_dry_run; then
        plan "validate BIND configuration, Webmin listener, and the server A/PTR prerequisites before FreeIPA installation"
        return 0
    fi
    bind_validate_configuration || return 1
    systemctl is-active --quiet named || {
        log_error "named is not active while validating BIND prerequisites"
        return 1
    }
    bind_validate_webmin || return 1
    dns_validate_prerequisite_records 127.0.0.1 || return 1
    if [[ "${DNS_SERVER_ROLE:-primary}" == secondary ]]; then
        bind_validate_secondary_transfer
    fi
}

dns_provider_sync_freeipa_records() {
    local path=${1:-}
    [[ -n "$path" && -f "$path" && ! -L "$path" ]] || {
        log_error "FreeIPA DNS record output is missing or unsafe; cannot reconcile the installed-version DNS record set"
        return 1
    }
    if is_dry_run || is_check; then
        plan "reconcile version-specific FreeIPA DNS records from $path into the managed BIND zones"
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
    if [[ "${DNS_SERVER_ROLE:-primary}" == secondary ]]; then
        EXTERNAL_DNS_STATUS=pending
        state_set EXTERNAL_DNS_STATUS pending
        log_warn "captured FreeIPA records on a DNS secondary; no slave zone file was edited"
        log_warn "publish $destination on the configured DNS primary, then rerun ./install.sh --check"
        if bind_validate_secondary_transfer && dns_validate_records_file "$path" 127.0.0.1; then
            EXTERNAL_DNS_STATUS=complete
            state_set EXTERNAL_DNS_STATUS complete
            log_info "the DNS secondary already converged with the primary and the captured FreeIPA records validate"
        fi
        return 0
    fi
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
        bind_import_record_line "$line"
    done < "$path"
    bind_validate_configuration
    bind_activate_service
    dns_validate_records_file "$path" 127.0.0.1
    EXTERNAL_DNS_STATUS=complete
    state_set EXTERNAL_DNS_STATUS complete
}

dns_provider_uninstall() {
    log_warn "BIND/Webmin uninstall is not run automatically. Remove only resources recorded as created-by-bootstrap after reviewing $STATE_FILE; pre-existing BIND/Webmin and unrelated zones are out of scope"
}
