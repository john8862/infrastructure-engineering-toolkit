#!/usr/bin/env bash

set -Eeuo pipefail

ROOT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../components/freeipa-bootstrap" && pwd)
TEST_TMP=$(mktemp -d)
trap 'rm -rf -- "$TEST_TMP"' EXIT

MODE=check
SCRIPT_DIR=$ROOT_DIR
ENV_FILE="$TEST_TMP/.env"
export MODE SCRIPT_DIR ENV_FILE

# shellcheck disable=SC1091
source "$ROOT_DIR/lib/common.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/logging.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/env.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/topology.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/state.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/preflight.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/freeipa.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/hostname.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/packages.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/lib/firewall.sh"
# shellcheck disable=SC1091
source "$ROOT_DIR/dns/provider.sh"

pass=0
fail=0

assert_equal() {
    local expected=$1 actual=$2 label=$3
    if [[ "$expected" == "$actual" ]]; then
        printf 'ok - %s\n' "$label"
        pass=$((pass + 1))
    else
        printf 'not ok - %s (expected=%q actual=%q)\n' "$label" "$expected" "$actual" >&2
        fail=$((fail + 1))
    fi
}

assert_true() {
    local label=$1
    shift
    if "$@"; then
        printf 'ok - %s\n' "$label"
        pass=$((pass + 1))
    else
        printf 'not ok - %s\n' "$label" >&2
        fail=$((fail + 1))
    fi
}

assert_false() {
    local label=$1
    shift
    if "$@"; then
        printf 'not ok - %s\n' "$label" >&2
        fail=$((fail + 1))
    else
        printf 'ok - %s\n' "$label"
        pass=$((pass + 1))
    fi
}

assert_contains() {
    local needle=$1 haystack=$2 label=$3
    if grep -Fq -- "$needle" <<< "$haystack"; then
        printf 'ok - %s\n' "$label"
        pass=$((pass + 1))
    else
        printf 'not ok - %s (missing=%q in=%q)\n' "$label" "$needle" "$haystack" >&2
        fail=$((fail + 1))
    fi
}

printf '1. environment and pure helpers\n'
printf 'IPA_DOMAIN=example.invalid\nIPA_REALM=\nIPA_HOSTNAME=ipa01.example.invalid\nIPA_IP_ADDRESS=192.0.2.10\nDNS_FORWARDERS="192.0.2.53 192.0.2.54 192.0.2.53"\n' > "$ENV_FILE"
chmod 0600 "$ENV_FILE"
unset IPA_DOMAIN IPA_REALM IPA_HOSTNAME IPA_IP_ADDRESS IPA_SETUP_CA IPA_SETUP_KRA IPA_SSH_TRUST_DNS IPA_SETUP_SUBID IPA_DIRSRV_CERT_FILES IPA_HTTP_CERT_FILES IPA_CA_CERT_FILES IPA_PKINIT_CERT_FILES IPA_DIRSRV_CERT_PIN IPA_HTTP_CERT_PIN IPA_PKINIT_CERT_PIN DNS_FORWARDERS
load_environment
assert_equal EXAMPLE.INVALID "${IPA_REALM}" 'realm defaults to uppercase domain when empty'
assert_equal true "${IPA_SETUP_CA}" 'integrated CA is enabled by default'
assert_equal false "${IPA_SSH_TRUST_DNS}" 'SSH trust DNS is disabled by default'
assert_equal false "${IPA_SETUP_SUBID}" 'subid is disabled by default'
assert_equal 2.0.192.in-addr.arpa "$IPA_REVERSE_ZONE" 'IPv4 /24 reverse zone calculation'
assert_equal 10 "$IPA_REVERSE_RECORD" 'IPv4 reverse record owner calculation'
assert_true 'valid IPv4 accepted' validate_ipv4 192.0.2.10
assert_false 'invalid IPv4 rejected' validate_ipv4 192.0.2.500
assert_equal example.invalid "$(normalize_fqdn EXAMPLE.INVALID.)" 'FQDN normalization'
assert_equal 10000 "$WEBMIN_PORT" 'Webmin port defaults to TCP 10000'
assert_equal /etc/webmin/miniserv.conf "$WEBMIN_CONFIG_FILE" 'Webmin configuration path has a safe default'
assert_equal "$IPA_HOSTNAME" "$SERVER_FQDN" 'canonical SERVER_FQDN mirrors the legacy hostname when only the legacy variable is set'
assert_equal false "$MANAGE_HOSTNAME" 'hostname management remains disabled by default'
DNS_BACKEND=integrated
load_environment
assert_equal integrated "$DNS_BACKEND" 'canonical backend selects FreeIPA integrated DNS'
assert_equal integrated "$IPA_DNS_MODE" 'integrated backend maps to integrated FreeIPA DNS mode'
assert_equal '' "$DNS_PROVIDER" 'integrated backend does not load an external provider'
DNS_BACKEND=technitium
load_environment
assert_equal technitium "$DNS_BACKEND" 'canonical backend selects Technitium'
assert_equal technitium "$DNS_PROVIDER" 'Technitium backend maps to the Technitium provider'
DNS_BACKEND=bind9_webmin
load_environment
assert_equal bind9_webmin "$DNS_BACKEND" 'canonical backend selects BIND9/Webmin'
assert_equal bind9-webmin "$DNS_PROVIDER" 'BIND9/Webmin backend maps to the legacy provider name'
parse_space_list "$DNS_FORWARDERS"
assert_equal 3 "${#PARSED_WORDS[@]}" 'multiple DNS forwarders are parsed'
assert_equal 192.0.2.54 "${PARSED_WORDS[1]}" 'forwarder ordering is preserved'
NTP_SERVERS='192.0.2.11 192.0.2.12'
parse_space_list "$NTP_SERVERS"
assert_equal 2 "${#PARSED_WORDS[@]}" 'multiple NTP servers are parsed'
assert_equal 192.0.2.12 "${PARSED_WORDS[1]}" 'NTP server ordering is preserved'
DNS_FORWARDERS=''
NTP_SERVERS=''
load_environment
assert_equal '' "$DNS_FORWARDERS" 'explicitly empty DNS_FORWARDERS remains empty'
MODE=dry-run
MANAGE_HOSTNAME=false
hostname_disabled_plan=$(configure_requested_hostname 2>&1)
assert_contains 'hostname configuration disabled' "$hostname_disabled_plan" 'hostname management false preserves the existing hostname'
MANAGE_HOSTNAME=true
hostname_enabled_plan=$(configure_requested_hostname 2>&1)
assert_contains 'set hostname to ipa01.example.invalid' "$hostname_enabled_plan" 'hostname management true derives the requested FQDN'
MANAGE_HOSTNAME=false
DNS_BACKEND=integrated
load_environment
DNS_DYNAMIC_UPDATE_MODE=insecure
preflight_reset
validate_env_configuration
assert_true 'integrated insecure DDNS is rejected explicitly' test "${#PREFLIGHT_ERRORS[@]}" -gt 0
DNS_DYNAMIC_UPDATE_MODE=disabled
DNS_BACKEND=bind9_webmin
load_environment
DNS_DYNAMIC_UPDATE_NETWORKS=''
BIND_ALLOW_UPDATE_ACL=trusted_networks
DNS_DYNAMIC_UPDATE_MODE=insecure
preflight_reset
validate_env_configuration
assert_equal 0 "${#PREFLIGHT_ERRORS[@]}" 'BIND insecure DDNS can use a named ACL without an unrelated source-network list'
DNS_DYNAMIC_UPDATE_MODE=secure
preflight_reset
validate_env_configuration
assert_equal 0 "${#PREFLIGHT_ERRORS[@]}" 'BIND secure DDNS uses TSIG update-policy without requiring a source-network list'
DNS_DYNAMIC_UPDATE_MODE=disabled
MODE=check
dns_prerequisite_records
assert_equal 2 "${#DNS_PREREQUISITE_RECORDS[@]}" 'external DNS prerequisites contain only A and PTR'
dns_expected_records
assert_true 'integrated DNS fallback still has service records' test "${#DNS_EXPECTED_RECORDS[@]}" -gt 2

printf '\n2. configuration and security helpers\n'
preflight_reset
validate_env_configuration
assert_equal 0 "${#PREFLIGHT_ERRORS[@]}" 'valid environment passes validation'
DNS_BACKEND=technitium
DNS_PROVIDER=technitium
IPA_DNS_MODE=external
TECHNITIUM_API_URL='http://dns01.example.invalid:5380'
TECHNITIUM_API_TLS_VERIFY=true
preflight_reset
validate_env_configuration
assert_true 'Technitium rejects plaintext API URLs' test "${#PREFLIGHT_ERRORS[@]}" -gt 0
TECHNITIUM_API_URL='https://dns01.example.invalid:53443'
TECHNITIUM_API_TLS_VERIFY=false
preflight_reset
validate_env_configuration
assert_true 'Technitium rejects disabled TLS verification' test "${#PREFLIGHT_ERRORS[@]}" -gt 0
TECHNITIUM_API_TLS_VERIFY=true
DNS_BACKEND=bind9_webmin
DNS_PROVIDER=bind9-webmin
IPA_DNS_MODE=external
original_hostname=$IPA_HOSTNAME
IPA_HOSTNAME=${IPA_HOSTNAME^^}
preflight_reset
validate_env_configuration
assert_true 'uppercase IPA_HOSTNAME is rejected' test "${#PREFLIGHT_ERRORS[@]}" -gt 0
IPA_HOSTNAME=$original_hostname
DNS_RECURSION_NETWORKS='0.0.0.0/0'
preflight_reset
validate_env_configuration
assert_true 'unrestricted recursion network is rejected' test "${#PREFLIGHT_ERRORS[@]}" -gt 0
DNS_RECURSION_NETWORKS='127.0.0.0/8'
preflight_reset
validate_env_configuration
WEBMIN_PORT=65536
preflight_reset
validate_env_configuration
assert_true 'out-of-range Webmin port is rejected' test "${#PREFLIGHT_ERRORS[@]}" -gt 0
WEBMIN_PORT=10000
preflight_reset
validate_env_configuration
IPA_SSH_TRUST_DNS=true
IPA_SETUP_SUBID=true
preflight_reset
validate_env_configuration
assert_equal 0 "${#PREFLIGHT_ERRORS[@]}" 'SSH trust DNS and subid options pass boolean validation'
IPA_SSH_TRUST_DNS=false
IPA_SETUP_SUBID=false
CALESS_CERT_DIR="$TEST_TMP/ca-less"
mkdir -p -- "$CALESS_CERT_DIR"
: > "$CALESS_CERT_DIR/dirsrv.pem"
: > "$CALESS_CERT_DIR/http.pem"
: > "$CALESS_CERT_DIR/ca.pem"
IPA_SETUP_CA=false
IPA_SETUP_KRA=false
IPA_DIRSRV_CERT_FILES="$CALESS_CERT_DIR/dirsrv.pem"
IPA_HTTP_CERT_FILES="$CALESS_CERT_DIR/http.pem"
IPA_CA_CERT_FILES="$CALESS_CERT_DIR/ca.pem"
preflight_reset
validate_env_configuration
assert_equal 0 "${#PREFLIGHT_ERRORS[@]}" 'CA-less certificate configuration passes validation'
IPA_SETUP_KRA=true
preflight_reset
validate_env_configuration
assert_true 'KRA is rejected when CA-less mode is selected' test "${#PREFLIGHT_ERRORS[@]}" -gt 0
IPA_SETUP_CA=true
IPA_SETUP_KRA=false
IPA_DIRSRV_CERT_FILES=''
IPA_HTTP_CERT_FILES=''
IPA_CA_CERT_FILES=''
IPA_PKINIT_CERT_FILES=''
IPA_DIRSRV_CERT_PIN=''
IPA_HTTP_CERT_PIN=''
IPA_PKINIT_CERT_PIN=''
preflight_reset
validate_env_configuration
assert_equal 0 "${#PREFLIGHT_ERRORS[@]}" 'integrated CA configuration is restored after CA-less validation'
redacted=$(redact_args ipa-server-install --ds-password 'fixture-dm-value' --admin-password='fixture-admin-value' --realm EXAMPLE.INVALID)
assert_false 'redacted command does not contain the Directory Manager secret' grep -Fq fixture-dm-value <<< "$redacted"
assert_false 'redacted command does not contain the admin secret' grep -Fq fixture-admin-value <<< "$redacted"
redacted=$(redact_args ipa-server-install --dirsrv-pin 'fixture-directory-pin' --http-pin=fixture-http-pin)
assert_false 'redacted command does not contain a CA-less certificate PIN' grep -Fq fixture-directory-pin <<< "$redacted"
assert_true 'state ownership helper accepts current-run resource' resource_is_owned_by_current_run created-by-bootstrap
assert_false 'state ownership helper rejects pre-existing resource' resource_is_owned_by_current_run pre-existing
assert_true 'retry counter allows the configured second attempt' retry_attempt_is_allowed 1 2
assert_false 'retry counter blocks attempts beyond the configured maximum' retry_attempt_is_allowed 2 2
assert_true 'retry counter allows the second retry when three attempts are configured' retry_attempt_is_allowed 2 3
assert_false 'retry counter blocks the fourth attempt when three attempts are configured' retry_attempt_is_allowed 3 3
FREEIPA_PREEXISTING=partial
assert_false 'pre-existing partial FreeIPA cannot be auto-uninstalled' freeipa_uninstall_current_run_partial
FREEIPA_PREEXISTING=absent
MODE=dry-run
assert_true 'dry-run mode is detected' is_dry_run
freeipa_build_install_args
assert_contains --no-ntp "${IPA_INSTALL_ARGS[*]}" 'installer arguments preserve existing NTP configuration'
assert_false 'integrated CA uses the installer default instead of an unsupported --setup-ca option' grep -Fq -- --setup-ca <<< "${IPA_INSTALL_ARGS[*]}"
IPA_SSH_TRUST_DNS=true
IPA_SETUP_SUBID=true
freeipa_build_install_args
assert_contains --ssh-trust-dns "${IPA_INSTALL_ARGS[*]}" 'SSH trust DNS option is passed when enabled'
assert_contains --subid "${IPA_INSTALL_ARGS[*]}" 'subid option is passed when enabled'
IPA_SSH_TRUST_DNS=false
IPA_SETUP_SUBID=false
IPA_SETUP_CA=false
IPA_DIRSRV_CERT_FILES="$CALESS_CERT_DIR/dirsrv.pem"
IPA_HTTP_CERT_FILES="$CALESS_CERT_DIR/http.pem"
IPA_CA_CERT_FILES="$CALESS_CERT_DIR/ca.pem"
freeipa_build_install_args
assert_contains --dirsrv-cert-file="$CALESS_CERT_DIR/dirsrv.pem" "${IPA_INSTALL_ARGS[*]}" 'CA-less mode passes the Directory Server certificate'
assert_contains --http-cert-file="$CALESS_CERT_DIR/http.pem" "${IPA_INSTALL_ARGS[*]}" 'CA-less mode passes the HTTP certificate'
assert_contains --ca-cert-file="$CALESS_CERT_DIR/ca.pem" "${IPA_INSTALL_ARGS[*]}" 'CA-less mode passes the optional CA chain'
IPA_SETUP_CA=true
IPA_DIRSRV_CERT_FILES=''
IPA_HTTP_CERT_FILES=''
IPA_CA_CERT_FILES=''
MODE=check
assert_true 'check mode is detected' is_check
ipactl() {
    [[ "${1:-}" == status ]]
}
FREEIPA_PREEXISTING=unknown
freeipa_detect_state
assert_equal healthy "$FREEIPA_STATE" 'healthy FreeIPA is detected from a successful ipactl status'
unset -f ipactl
FREEIPA_PREEXISTING=absent
IPA_LOCK_FILE="$TEST_TMP/bootstrap.lock"
rm -f -- "$IPA_LOCK_FILE"
if command -v flock >/dev/null 2>&1; then
    acquire_install_lock
    assert_false 'check mode does not create an execution lock' test -e "$IPA_LOCK_FILE"
    MODE=install
    acquire_install_lock
    assert_true 'normal mode creates an execution lock' test -e "$IPA_LOCK_FILE"
    release_install_lock
else
    printf 'ok - execution lock runtime test skipped because flock is unavailable on this development host\n'
fi
MODE=check

MODE=install
IPA_CREDENTIALS_DIR=''
freeipa_prepare_credentials
assert_true 'credential preparation creates the Kerberos cache file' test -f "$IPA_KRB_CACHE"
assert_equal 600 "$(file_mode_octal "$IPA_KRB_CACHE")" 'Kerberos cache is owner-only'
rm -rf -- "$IPA_CREDENTIALS_DIR"
IPA_CREDENTIALS_DIR=''
MODE=check

MODE=install
IPA_DEFAULT_SHELL=/bin/bash
IPA_HOME_ROOT=/home
IPA_CONFIG_MOD_CALLS=0
ipa() {
    if [[ "${1:-}" == config-show ]]; then
        printf '%s\n' '  Default shell: /bin/bash' '  Home directory base: /home'
        return 0
    fi
    if [[ "${1:-}" == config-mod ]]; then
        IPA_CONFIG_MOD_CALLS=$((IPA_CONFIG_MOD_CALLS + 1))
        return 0
    fi
    return 1
}
STATE_FILE=''
assert_true 'matching FreeIPA directory defaults are treated as converged' freeipa_configure_directory_defaults
assert_equal 0 "$IPA_CONFIG_MOD_CALLS" 'matching FreeIPA directory defaults do not call ipa config-mod'
ipa() {
    if [[ "${1:-}" == config-show ]]; then
        printf '%s\n' '  Default shell: /bin/zsh' '  Home directory base: /home'
        return 0
    fi
    if [[ "${1:-}" == config-mod ]]; then
        IPA_CONFIG_MOD_CALLS=$((IPA_CONFIG_MOD_CALLS + 1))
        return 0
    fi
    return 1
}
assert_true 'different FreeIPA directory defaults are corrected' freeipa_configure_directory_defaults
assert_equal 1 "$IPA_CONFIG_MOD_CALLS" 'different FreeIPA directory defaults call ipa config-mod once'
unset -f ipa
MODE=check

MODE=install
IPA_SETUP_CA=true
IPA_SETUP_KRA=true
FREEIPA_PREEXISTING=healthy
CA_STATUS=not-requested
KRA_STATUS=not-requested
KRA_INSTALL_CALLS=0
ipa() {
    if [[ "${1:-}" == ca-show || "${1:-}" == vaultconfig-show ]]; then
        return 0
    fi
    return 1
}
ipa-kra-install() {
    KRA_INSTALL_CALLS=$((KRA_INSTALL_CALLS + 1))
    return 1
}
assert_true 'existing CA is detected before installation' freeipa_ensure_ca
assert_equal installed "$CA_STATUS" 'existing CA is marked installed'
assert_true 'existing KRA is detected before ipa-kra-install' freeipa_install_kra
assert_equal installed "$KRA_STATUS" 'existing KRA is marked installed'
assert_equal 0 "$KRA_INSTALL_CALLS" 'existing KRA does not invoke ipa-kra-install'
IPA_SETUP_CA=false
assert_true 'CA-less rerun preserves an existing CA without removing it' freeipa_ensure_ca
assert_equal preserved "$CA_STATUS" 'existing CA is marked preserved when CA setup is disabled'
unset -f ipa ipa-kra-install
IPA_SETUP_CA=true
IPA_SETUP_KRA=false
MODE=check

printf '\n2b. multi-server FreeIPA and DNS topology helpers\n'
MODE=dry-run
IPA_SERVER_ROLE=replica
IPA_REPLICA_SOURCE=ipa01.example.invalid
IPA_REPLICA_PRINCIPAL=admin
IPA_REPLICA_SETUP_CA=true
IPA_ADMIN_PASSWORD='fixture-replica-admin'
freeipa_build_install_args
assert_equal ipa-replica-install "${IPA_INSTALL_ARGS[0]}" 'replica role selects ipa-replica-install'
assert_contains '--server=ipa01.example.invalid' "${IPA_INSTALL_ARGS[*]}" 'replica installer points to the configured source server'
assert_contains '--principal=admin' "${IPA_INSTALL_ARGS[*]}" 'replica installer uses the configured supported principal'
assert_contains '--admin-password=fixture-replica-admin' "${IPA_INSTALL_ARGS[*]}" 'replica installer receives the admin password in the argv array'
assert_contains '--setup-ca' "${IPA_INSTALL_ARGS[*]}" 'CA replica explicitly requests --setup-ca'
assert_false 'replica installer arguments do not fall back to ipa-server-install' grep -Fq ipa-server-install <<< "${IPA_INSTALL_ARGS[*]}"
IPA_SERVER_ROLE=primary
IPA_REPLICA_SOURCE=''
IPA_ADMIN_PASSWORD=''
saved_hostname=$IPA_HOSTNAME
saved_ip=$IPA_IP_ADDRESS
saved_reverse_zone=$IPA_REVERSE_ZONE
saved_reverse_record=$IPA_REVERSE_RECORD
IPA_HOSTNAME=ipa02.example.invalid
IPA_IP_ADDRESS=192.0.2.11
IPA_REVERSE_ZONE=2.0.192.in-addr.arpa
IPA_REVERSE_RECORD=11
DNS_SERVER_ROLE=secondary
DNS_PRIMARY_SERVER=ipa01.example.invalid
DNS_PRIMARY_IP=192.0.2.10
DNS_SECONDARY_SERVER=ipa02.example.invalid
DNS_SECONDARY_IP=192.0.2.11
DNS_AUTHORITATIVE_REVERSE_ZONES=2.0.192.in-addr.arpa
preflight_reset
topology_validate_configuration
assert_equal 0 "${#PREFLIGHT_ERRORS[@]}" 'secondary topology requires and accepts an explicit reverse-zone list'
DNS_AUTHORITATIVE_REVERSE_ZONES=''
preflight_reset
topology_validate_configuration
assert_true 'secondary topology rejects an implicit reverse-zone list' test "${#PREFLIGHT_ERRORS[@]}" -gt 0
IPA_HOSTNAME=$saved_hostname
IPA_IP_ADDRESS=$saved_ip
IPA_REVERSE_ZONE=$saved_reverse_zone
IPA_REVERSE_RECORD=$saved_reverse_record
DNS_SERVER_ROLE=primary
DNS_PRIMARY_SERVER=$IPA_HOSTNAME
DNS_PRIMARY_IP=$IPA_IP_ADDRESS
DNS_SECONDARY_SERVER=''
DNS_SECONDARY_IP=''
DNS_AUTHORITATIVE_REVERSE_ZONES=''
MODE=check

printf '\n3. streaming command execution\n'
MODE=install
CURRENT_STAGE=command-tests
LOG_FILE="$TEST_TMP/command.log"
: > "$LOG_FILE"
RUN_COMMAND_EXTRA_LOG_FILE=''

command_console="$TEST_TMP/command.console"
if run_command bash -c 'printf "out-%s\\n" 1; printf "err-%s\\n" 2 >&2' > "$command_console" 2>&1; then
    command_rc=0
else
    command_rc=$?
fi
assert_equal 0 "$command_rc" 'streaming command preserves a successful exit code'
command_console_contents=$(<"$command_console")
command_log_contents=$(<"$LOG_FILE")
assert_contains 'out-1' "$command_console_contents" 'child stdout is visible on the console'
assert_contains 'err-2' "$command_console_contents" 'child stderr is visible on the console'
assert_contains 'out-1' "$command_log_contents" 'child stdout is preserved in the bootstrap log'
assert_contains 'err-2' "$command_log_contents" 'child stderr is preserved in the bootstrap log'

single_line_console="$TEST_TMP/single-line.console"
run_command bash -c 'printf "single-%s\\n" 1' > "$single_line_console" 2>&1
single_line_count=$(grep -Exc 'single-1' "$single_line_console" || true)
assert_equal 1 "$single_line_count" 'streamed child output is not double-printed'

failure_console="$TEST_TMP/failure.console"
if run_command bash -c 'printf "native-failure-%s\\n" 1 >&2; exit 1' > "$failure_console" 2>&1; then
    failure_rc=0
else
    failure_rc=$?
fi
failure_console_contents=$(<"$failure_console")
assert_equal 1 "$failure_rc" 'streaming command preserves exit code 1'
assert_contains 'native-failure-1' "$failure_console_contents" 'native failure output is visible before structured failure'
assert_contains 'command failed with exit code 1' "$failure_console_contents" 'structured failure follows native output'

if run_command bash -c 'exit 2' > /dev/null 2>&1; then
    failure_rc=0
else
    failure_rc=$?
fi
assert_equal 2 "$failure_rc" 'streaming command preserves exit code 2'

if run_command bash -c 'kill -TERM "$$"' > /dev/null 2>&1; then
    signal_rc=0
else
    signal_rc=$?
fi
assert_equal 143 "$signal_rc" 'streaming command preserves a signal-derived exit code'

gradual_console="$TEST_TMP/gradual.console"
run_command bash -c 'printf "stream-first\\n"; sleep 0.5; printf "stream-second\\n"' > "$gradual_console" 2>&1 &
gradual_pid=$!
stream_seen=false
for (( wait_step=0; wait_step<10; wait_step++ )); do
    if grep -Fq 'stream-first' "$gradual_console" 2>/dev/null; then
        stream_seen=true
        break
    fi
    sleep 0.1
done
wait "$gradual_pid"
assert_true 'operational output is streamed before the child exits' test "$stream_seen" = true

secret='fixture-redaction-value'
secret_console="$TEST_TMP/secret.console"
if run_command true --admin-password "$secret" > "$secret_console" 2>&1; then
    secret_rc=0
else
    secret_rc=$?
fi
secret_console_contents=$(<"$secret_console")
secret_log_contents=$(<"$LOG_FILE")
assert_equal 0 "$secret_rc" 'redaction test command succeeds'
assert_false 'secret is absent from displayed command' grep -Fq -- "$secret" <<< "$secret_console_contents"
assert_false 'secret is absent from bootstrap log' grep -Fq -- "$secret" <<< "$secret_log_contents"
assert_contains 'REDACTED' "$secret_log_contents" 'redacted command marker is retained in the log'

MODE=dry-run
dry_run_marker="$TEST_TMP/dry-run-marker"
run_command sh -c 'touch "$1"' _ "$dry_run_marker" > /dev/null 2>&1
assert_false 'dry-run does not execute operational commands' test -e "$dry_run_marker"
MODE=check
check_marker="$TEST_TMP/check-marker"
run_command sh -c 'touch "$1"' _ "$check_marker" > /dev/null 2>&1
assert_false 'check mode does not execute operational commands' test -e "$check_marker"
MODE=install
run_command_with_umask 022 bash -c 'umask' > "$TEST_TMP/umask.console" 2>&1
umask_contents=$(<"$TEST_TMP/umask.console")
assert_contains 0022 "$umask_contents" 'FreeIPA child command uses the required 0022 umask'
LOG_FILE=''

printf '\n4. platform and provider selection\n'
MODE=install
PACKAGE_MANAGER=false
package_is_installed() {
    [[ "${1:-}" == installed ]]
}
assert_true 'installed package set is skipped without invoking the package manager' package_install installed
assert_false 'missing package installation propagates the package-manager failure' package_install missing
package_is_installed() {
    return 2
}
assert_false 'package query failures are not treated as absent packages' package_install unknown-state
source "$ROOT_DIR/lib/packages.sh"
MODE=check
assert_true 'Rocky Linux 9 x86_64 is an explicitly supported identity' supported_os_identity rocky 9.5 x86_64
assert_true 'AlmaLinux 10 aarch64 is an explicitly supported identity' supported_os_identity almalinux 10.0 aarch64
assert_false 'Debian is rejected by OS-family logic' supported_os_identity debian 12 x86_64
assert_false 'unsupported RHEL-family major version is rejected' supported_os_identity rhel 7.9 x86_64
IPA_DNS_MODE=external
DNS_PROVIDER=existing
assert_true 'existing DNS provider module loads' dns_provider_load
IPA_GENERATED_DIR="$TEST_TMP/generated"
dns_provider_check
assert_false 'existing provider check mode does not write generated files' test -e "$IPA_GENERATED_DIR/freeipa-dns-records.txt"
DNS_PROVIDER=unsupported-example
assert_false 'unknown DNS provider is rejected' dns_provider_load
DNS_PROVIDER=technitium
dns_provider_load
assert_true 'Technitium provider loads and supports read-only check planning' dns_provider_check

printf '\n5. external DNS post-install state\n'
MODE=install
IPA_DNS_MODE=external
IPA_GENERATED_DIR="$TEST_TMP/generated"
RUN_ID=regression
mkdir -p -- "$IPA_GENERATED_DIR"

DNS_PROVIDER=bind9-webmin
DNS_BIND_ZONE_DIR="$TEST_TMP/bind"
mkdir -p -- "$DNS_BIND_ZONE_DIR"
dns_provider_load

printf '%s\n' 'port=10000' 'listen=10000' > "$TEST_TMP/miniserv.conf"
WEBMIN_CONFIG_FILE="$TEST_TMP/miniserv.conf"
WEBMIN_PORT=10000
package_is_installed() {
    [[ "${1:-}" == webmin ]]
}
systemctl() {
    [[ "${1:-}" == is-active && "${2:-}" == --quiet && "${3:-}" == webmin ]]
}
ss() {
    printf '%s\n' 'LISTEN 0 128 0.0.0.0:10000 0.0.0.0:*'
}
assert_true 'Webmin validation accepts the configured active listener' bind_validate_webmin
printf '%s\n' 'port=10001' 'listen=10001' > "$TEST_TMP/miniserv.conf"
assert_false 'Webmin validation rejects a listener that differs from WEBMIN_PORT' bind_validate_webmin
printf '%s\n' 'port=10000' 'listen=10000' > "$TEST_TMP/miniserv.conf"
unset -f systemctl ss
source "$ROOT_DIR/lib/packages.sh"

DNS_BIND_CONFIG_FILE="$TEST_TMP/named.conf"
DNS_BIND_ZONE_DIR="$TEST_TMP/bind-options"
mkdir -p -- "$DNS_BIND_ZONE_DIR"
printf '%s\n' 'options {' '    recursion yes;' '};' > "$DNS_BIND_CONFIG_FILE"
DNS_FORWARDERS='192.0.2.53 192.0.2.54'
DNS_RECURSION_NETWORKS='127.0.0.0/8'
STATE_FILE=''
bind_configure_options
named_config_contents=$(<"$DNS_BIND_CONFIG_FILE")
recursion_count=$(grep -Ec '^[[:space:]]*recursion[[:space:]]+yes[[:space:]]*;' <<< "$named_config_contents" || true)
allow_recursion_count=$(grep -Ec '^[[:space:]]*allow-recursion[[:space:]]*\{' <<< "$named_config_contents" || true)
assert_equal 1 "$recursion_count" 'managed BIND preserves an existing recursion directive without duplicating it'
assert_equal 1 "$allow_recursion_count" 'managed BIND adds a restricted allow-recursion policy'

printf '%s\n' 'options {' '    recursion no;' '};' > "$DNS_BIND_CONFIG_FILE"
assert_false 'managed BIND rejects an existing disabled recursion policy' bind_configure_options

DNS_BIND_ZONE_DIR="$TEST_TMP/bind"
bind_write_zone_file "$IPA_DOMAIN" "$(bind_zone_file "$IPA_DOMAIN")" false
bind_write_zone_file "$IPA_REVERSE_ZONE" "$(bind_zone_file "$IPA_REVERSE_ZONE")" true
forward_zone_contents=$(<"$(bind_zone_file "$IPA_DOMAIN")")
reverse_zone_contents=$(<"$(bind_zone_file "$IPA_REVERSE_ZONE")")
assert_contains "$IPA_IP_ADDRESS" "$forward_zone_contents" 'managed BIND forward zone contains only the server prerequisite address'
assert_false 'managed BIND forward zone does not pre-create SRV records' grep -Fq '_kerberos' <<< "$forward_zone_contents"
assert_contains 'PTR' "$reverse_zone_contents" 'managed BIND reverse zone contains the server PTR prerequisite'
assert_false 'managed BIND reverse zone does not pre-create unrelated records' grep -Fq '_ldap' <<< "$reverse_zone_contents"

DNS_PROVIDER=existing
record_file="$TEST_TMP/ipa.system.records.test.db"
printf '%s\n' "${IPA_HOSTNAME%.}. $DNS_TTL IN A $IPA_IP_ADDRESS" > "$record_file"
printf '%s\n' "_ldap._tcp.${IPA_DOMAIN%.}. $DNS_TTL IN SRV 0 100 389 ${IPA_HOSTNAME%.}." >> "$record_file"
printf '%s\n' "_kerberos.${IPA_DOMAIN%.}. $DNS_TTL IN TXT \"${IPA_REALM}\"" >> "$record_file"
STATE_FILE=''
EXTERNAL_DNS_STATUS=not-applicable
dns_provider_load
dns_provider_sync_freeipa_records "$record_file"
assert_equal pending "$EXTERNAL_DNS_STATUS" 'existing DNS provider reports pending manual publication'
assert_true 'existing provider preserves the generated record file' test -f "$IPA_GENERATED_DIR/freeipa-dns-records-regression.db"
assert_equal "$IPA_GENERATED_DIR/freeipa-dns-records-regression.db" "$(dns_find_generated_record_file)" 'generated record discovery selects the captured file'
assert_true 'captured authoritative record file preserves SRV and TXT records' grep -Fq '_ldap._tcp' "$IPA_GENERATED_DIR/freeipa-dns-records-regression.db"

record_capture_dir="$TEST_TMP/record-capture"
mkdir -p -- "$record_capture_dir"
STATE_RUN_DIR="$record_capture_dir"
RUN_ID=nsupdate-regression
ipa() {
    local output=''
    while (( $# > 0 )); do
        if [[ "${1:-}" == --out ]]; then
            output=${2:-}
            shift 2
        else
            shift
        fi
    done
    [[ -n "$output" ]] || return 2
    printf '%s\n' \
        'server 192.0.2.10' \
        'zone example.invalid.' \
        '; IPA DNS records' \
        'update delete _kerberos._tcp.example.invalid. SRV' \
        'update add _kerberos._tcp.example.invalid. 86400 IN SRV 0 100 88 ipa01.example.invalid.' \
        'update add _kerberos.example.invalid. 86400 IN TXT "EXAMPLE.INVALID"' > "$output"
}
normalized_records=$(freeipa_generate_external_dns_records)
assert_true 'supported FreeIPA nsupdate output is normalized to a provider record file' test -s "$normalized_records"
assert_contains '_kerberos._tcp.example.invalid. 86400 IN SRV' "$(<"$normalized_records")" 'normalized external DNS output keeps SRV additions'
assert_contains '_kerberos.example.invalid. 86400 IN TXT' "$(<"$normalized_records")" 'normalized external DNS output keeps TXT additions'
assert_false 'normalized external DNS output does not pass nsupdate delete directives to BIND' grep -Fq 'update delete' "$normalized_records"
unset -f ipa

printf '\n5b. BIND primary/secondary transfer topology\n'
MODE=install
DNS_PROVIDER=bind9-webmin
DNS_SERVER_ROLE=primary
DNS_PRIMARY_SERVER=ipa01.example.invalid
DNS_PRIMARY_IP=192.0.2.10
DNS_SECONDARY_SERVER=ipa02.example.invalid
DNS_SECONDARY_IP=192.0.2.11
DNS_AUTHORITATIVE_REVERSE_ZONES=2.0.192.in-addr.arpa
DNS_TRANSFER_SECURITY=tsig
DNS_TRANSFER_KEY_NAME=freeipa-bootstrap-transfer
DNS_TRANSFER_KEY_FILE="$TEST_TMP/topology-transfer.key"
DNS_TRANSFER_KEY_SECRET='fixture-transfer-key'
topology_primary_root="$TEST_TMP/topology-primary"
mkdir -p -- "$topology_primary_root"
DNS_BIND_CONFIG_FILE="$topology_primary_root/named.conf"
DNS_BIND_INCLUDE_FILE="$topology_primary_root/freeipa-bootstrap.conf"
DNS_BIND_ZONE_DIR="$topology_primary_root/zones"
DNS_BIND_SLAVE_DIR="$topology_primary_root/slaves"
printf '%s\n' 'options {' '    recursion yes;' '};' > "$DNS_BIND_CONFIG_FILE"
dns_provider_load
bind_write_zone_file "$IPA_DOMAIN" "$(bind_zone_file "$IPA_DOMAIN")" false
bind_write_zone_file "$IPA_REVERSE_ZONE" "$(bind_zone_file "$IPA_REVERSE_ZONE")" true
bind_write_include_file
primary_include_contents=$(<"$DNS_BIND_INCLUDE_FILE")
primary_forward_contents=$(<"$(bind_zone_file "$IPA_DOMAIN")")
assert_contains 'type master;' "$primary_include_contents" 'DNS primary declares master zones'
assert_contains 'allow-transfer { key freeipa-bootstrap-transfer; };' "$primary_include_contents" 'DNS primary restricts transfers to the TSIG key'
assert_contains 'also-notify { 192.0.2.11; };' "$primary_include_contents" 'DNS primary configures NOTIFY for the secondary'
assert_contains '@ IN NS ipa01.example.invalid.' "$primary_forward_contents" 'primary forward zone publishes the primary NS'
assert_contains '@ IN NS ipa02.example.invalid.' "$primary_forward_contents" 'primary forward zone publishes the secondary NS'
key_mode=$(file_mode_octal "$DNS_TRANSFER_KEY_FILE")
assert_true 'primary transfer key is owner-only' test "$key_mode" = 640 -o "$key_mode" = 600

topology_secondary_root="$TEST_TMP/topology-secondary"
mkdir -p -- "$topology_secondary_root"
DNS_SERVER_ROLE=secondary
DNS_PRIMARY_SERVER=ipa01.example.invalid
DNS_PRIMARY_IP=192.0.2.10
DNS_SECONDARY_SERVER=ipa02.example.invalid
DNS_SECONDARY_IP=192.0.2.11
DNS_BIND_CONFIG_FILE="$topology_secondary_root/named.conf"
DNS_BIND_INCLUDE_FILE="$topology_secondary_root/freeipa-bootstrap.conf"
DNS_BIND_ZONE_DIR="$topology_secondary_root/unused-primary-zones"
DNS_BIND_SLAVE_DIR="$topology_secondary_root/slaves"
printf '%s\n' 'options {' '    recursion yes;' '};' > "$DNS_BIND_CONFIG_FILE"
bind_write_include_file
secondary_include_contents=$(<"$DNS_BIND_INCLUDE_FILE")
assert_contains 'type slave;' "$secondary_include_contents" 'DNS secondary declares slave zones'
assert_contains "file \"$DNS_BIND_SLAVE_DIR/example.invalid.zone\";" "$secondary_include_contents" 'DNS secondary stores transferred forward data under the slave directory'
assert_contains 'masters { 192.0.2.10 key freeipa-bootstrap-transfer; };' "$secondary_include_contents" 'DNS secondary authenticates transfers with the configured TSIG key'
assert_contains 'allow-transfer { none; };' "$secondary_include_contents" 'DNS secondary does not serve zone transfers onward'
assert_false 'DNS secondary never creates a local transferred forward zone file' test -e "$(bind_zone_file "$IPA_DOMAIN")"
assert_false 'DNS secondary refuses local FreeIPA record edits' bind_import_record_line "${IPA_HOSTNAME%.}. 86400 IN A 192.0.2.10"
assert_true 'IP update utility is executable' test -x "$ROOT_DIR/update-server-ip.sh"
update_help=$("$ROOT_DIR/update-server-ip.sh" --help)
assert_contains '--new-ip' "$update_help" 'IP update utility documents the required new address'
assert_contains '--check' "$update_help" 'IP update utility exposes a read-only consistency mode'
update_technitium_body=$(sed -n '/^update_technitium_apply()/,/^}/p' "$ROOT_DIR/update-server-ip.sh")
assert_contains 'firewall_configure || return 1' "$update_technitium_body" 'Technitium IP updates reconcile active managed firewall peer rules'
install_help=$("$ROOT_DIR/install.sh" --help)
assert_contains '--sync-freeipa-records' "$install_help" 'installer exposes primary-side external record reconciliation'
project_version=$(<"$ROOT_DIR/VERSION")
assert_true 'canonical project version is Semantic Versioning' grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' <<< "$project_version"
install_version=$($ROOT_DIR/install.sh --version)
assert_equal "FreeIPA Infrastructure Installer $project_version" "$install_version" 'installer displays the canonical project version without installation'
assert_contains '--version' "$install_help" 'installer help documents project version output'
assert_true 'primary environment template remains valid shell syntax' bash -n "$ROOT_DIR/../../examples/freeipa/primary.env.example"
assert_true 'secondary environment template remains valid shell syntax' bash -n "$ROOT_DIR/../../examples/freeipa/secondary.env.example"
DNS_SERVER_ROLE=primary
DNS_PRIMARY_SERVER=$IPA_HOSTNAME
DNS_PRIMARY_IP=$IPA_IP_ADDRESS
DNS_SECONDARY_SERVER=''
DNS_SECONDARY_IP=''
DNS_AUTHORITATIVE_REVERSE_ZONES=''
DNS_TRANSFER_KEY_SECRET=''
MODE=check

printf '\n5c. native BIND, ACL, DDNS policy, TSIG reuse, and Technitium API contracts\n'
MODE=install
native_root="$TEST_TMP/native-bind"
mkdir -p -- "$native_root"
DNS_PROVIDER=bind9-webmin
DNS_BACKEND=bind9_webmin
IPA_DNS_MODE=external
DNS_SERVER_ROLE=primary
DNS_PRIMARY_SERVER=$IPA_HOSTNAME
DNS_PRIMARY_IP=$IPA_IP_ADDRESS
DNS_SECONDARY_SERVER=ipa02.example.invalid
DNS_SECONDARY_IP=192.0.2.11
DNS_AUTHORITATIVE_REVERSE_ZONES="$IPA_REVERSE_ZONE"
DNS_BIND_CONFIG_FILE="$native_root/named.conf"
DNS_BIND_INCLUDE_FILE="$native_root/legacy/freeipa-bootstrap.conf"
DNS_BIND_ZONE_DIR="$native_root/legacy/zones"
DNS_BIND_SLAVE_DIR="$native_root/var/named/slaves"
BIND_CONFIG_MODE=native
BIND_ZONE_FILE_MODE=native
BIND_NATIVE_ZONE_CONFIG_FILE="$native_root/named.conf.local"
BIND_NATIVE_ZONE_DIR="$native_root/var/named"
BIND_ACL_NAME=trusted_networks
BIND_ACL_NETWORKS='127.0.0.0/8 192.0.2.0/24'
BIND_ALLOW_QUERY_ACL=trusted_networks
BIND_ALLOW_RECURSION_ACL=trusted_networks
BIND_ALLOW_UPDATE_ACL=trusted_networks
BIND_ALLOW_TRANSFER_ACL=trusted_networks
BIND_ALLOW_NOTIFY_ACL=trusted_networks
BIND_ALLOW_UPDATE_FORWARDING_ACL=trusted_networks
DNS_FORWARDERS=''
DNS_RECURSION_NETWORKS='127.0.0.0/8'
DNS_TSIG_ENABLED=true
DNS_TSIG_KEY_NAME=native-primary-secondary
DNS_TRANSFER_KEY_NAME=native-primary-secondary
DNS_TSIG_KEY_FILE="$native_root/tsig.key"
DNS_TRANSFER_KEY_FILE="$native_root/tsig.key"
DNS_TRANSFER_KEY_SECRET='fixture-native-shared-value'
DNS_TSIG_PROVISION=manual
DNS_DYNAMIC_UPDATE_MODE=disabled
DNS_NOTIFY_ENABLED=true
STATE_FILE=''
printf '%s\n' 'options {' '    recursion yes;' '};' > "$DNS_BIND_CONFIG_FILE"
printf '%s\n' 'zone "unrelated.example" { type master; file "/var/named/unrelated.zone"; };' > "$BIND_NATIVE_ZONE_CONFIG_FILE"
bind_configure_options
bind_write_include_file
native_named_contents=$(<"$DNS_BIND_CONFIG_FILE")
native_zone_config_contents=$(<"$BIND_NATIVE_ZONE_CONFIG_FILE")
assert_contains 'acl "trusted_networks" {' "$native_named_contents" 'native BIND configuration creates the named ACL'
assert_contains '192.0.2.0/24;' "$native_named_contents" 'native BIND ACL contains the configured network'
assert_contains 'allow-query { trusted_networks; };' "$native_named_contents" 'BIND query ACL use is explicit and configurable'
assert_contains 'allow-recursion { trusted_networks; };' "$native_named_contents" 'BIND recursion ACL use is explicit and configurable'
assert_contains "include \"$BIND_NATIVE_ZONE_CONFIG_FILE\";" "$native_named_contents" 'native BIND main configuration includes the native zone file'
assert_contains 'zone "unrelated.example"' "$native_zone_config_contents" 'native BIND preserves an unrelated pre-existing zone'
assert_contains 'zone "example.invalid"' "$native_zone_config_contents" 'native BIND adds the managed forward zone to the native zone file'
assert_contains "file \"$BIND_NATIVE_ZONE_DIR/example.invalid.zone\";" "$native_zone_config_contents" 'native BIND uses the configured native zone-file directory'
assert_contains 'also-notify { 192.0.2.11; };' "$native_zone_config_contents" 'native BIND emits also-notify for the configured secondary'
bind_write_include_file
native_notify_count=$(grep -Ec '^[[:space:]]*also-notify[[:space:]]*\{' "$BIND_NATIVE_ZONE_CONFIG_FILE" || true)
assert_equal 2 "$native_notify_count" 'native BIND rerun does not duplicate also-notify across forward and reverse zones'

DNS_DYNAMIC_UPDATE_MODE=disabled
disabled_policy=$(bind_dynamic_update_options)
assert_contains 'allow-update { none; };' "$disabled_policy" 'BIND disabled DDNS emits an explicit deny policy'
DNS_DYNAMIC_UPDATE_MODE=insecure
insecure_policy=$(bind_dynamic_update_options)
assert_contains 'allow-update { trusted_networks; };' "$insecure_policy" 'BIND insecure DDNS uses only the configured ACL'
DNS_DYNAMIC_UPDATE_MODE=secure
secure_policy=$(bind_dynamic_update_options)
assert_contains 'update-policy { grant native-primary-secondary zonesub ANY; };' "$secure_policy" 'BIND secure DDNS uses update-policy'
assert_false 'BIND secure DDNS never emits allow-update alongside update-policy' grep -Fq 'allow-update' <<< "$secure_policy"

key_digest_before=$(sha256sum "$DNS_TRANSFER_KEY_FILE" | awk '{print $1}')
DNS_TRANSFER_KEY_SECRET='fixture-other-shared-value'
bind_write_transfer_key_file
key_digest_after=$(sha256sum "$DNS_TRANSFER_KEY_FILE" | awk '{print $1}')
assert_equal "$key_digest_before" "$key_digest_after" 'BIND TSIG generation reuses an existing key on rerun'

DNS_BACKEND=technitium
DNS_PROVIDER=technitium
TECHNITIUM_UPDATE_NETWORKS='192.0.2.0/24'
DNS_DYNAMIC_UPDATE_NETWORKS='192.0.2.0/24'
DNS_TSIG_KEY_NAME=native-primary-secondary
DNS_SERVER_ROLE=primary
assert_equal ok "$(technitium_json_status '{"status":"ok"}')" 'Technitium parser accepts the documented top-level status field'
assert_equal denied "$(technitium_json_message '{"status":"error","errorMessage":"denied"}')" 'Technitium parser reads the documented top-level errorMessage field'
assert_equal example.invalid "$(technitium_zone_for_name "$IPA_HOSTNAME")" 'Technitium forward zone selection uses the configured IPA domain'
assert_equal "$IPA_REVERSE_ZONE" "$(technitium_zone_for_name "$(reverse_record_for_ipv4 "$IPA_IP_ADDRESS").$IPA_REVERSE_ZONE")" 'Technitium reverse zone selection uses the configured reverse zone'

technitium_api_call() {
    TECH_API_LAST_ARGS="$*"
    case "${2:-}" in
        /api/settings/get)
            printf '%s' '{"status":"ok","response":{"tsigKeys":[{"keyName":"existing-key","sharedSecret":"fixture-existing-shared-value","algorithmName":"hmac-sha256"}]}}'
            ;;
        *)
            printf '%s' '{"status":"ok"}'
            ;;
    esac
}
DNS_DYNAMIC_UPDATE_MODE=secure
DNS_SERVER_ROLE=primary
DNS_SECONDARY_SERVER=ipa02.example.invalid
DNS_SECONDARY_IP=192.0.2.11
technitium_zone_options "$IPA_DOMAIN"
assert_contains 'zoneTransfer=UseSpecifiedNetworkACL' "$TECH_API_LAST_ARGS" 'Technitium transfer policy restricts the secondary source network'
assert_contains 'zoneTransferTsigKeyNames=native-primary-secondary' "$TECH_API_LAST_ARGS" 'Technitium transfer policy includes the configured TSIG key'
assert_contains 'notify=SpecifiedNameServers' "$TECH_API_LAST_ARGS" 'Technitium primary configures explicit NOTIFY targets'
assert_contains 'updateSecurityPolicies=native-primary-secondary|example.invalid|A,AAAA,CNAME,PTR,SRV,TXT,URI|native-primary-secondary|*.example.invalid|A,AAAA,CNAME,PTR,SRV,TXT,URI' "$TECH_API_LAST_ARGS" 'Technitium secure DDNS covers the zone apex and subdomains'
DNS_SERVER_ROLE=secondary
technitium_zone_options "$IPA_DOMAIN"
assert_contains 'primaryZoneTransferProtocol=Tcp' "$TECH_API_LAST_ARGS" 'Technitium secondary points at the primary transfer protocol'
assert_contains 'primaryZoneTransferTsigKeyName=native-primary-secondary' "$TECH_API_LAST_ARGS" 'Technitium secondary references the shared TSIG key'
assert_contains 'update=Deny' "$TECH_API_LAST_ARGS" 'Technitium secondary does not accept local dynamic updates'
assert_contains 'validateZone=false' "$TECH_API_LAST_ARGS" 'Technitium secondary passes the configured zone validation policy'
DNS_SERVER_ROLE=primary
technitium_configure_tsig
assert_contains 'existing-key|fixture-existing-shared-value|hmac-sha256' "$TECH_API_LAST_ARGS" 'Technitium TSIG settings preserve an existing key from the documented keyName field'
assert_contains 'native-primary-secondary|fixture-native-shared-value|hmac-sha256' "$TECH_API_LAST_ARGS" 'Technitium TSIG settings add the configured shared key'
unset -f technitium_api_call
# Reload the provider module to restore the real API implementation without
# evaluating function source text.
# shellcheck disable=SC1091
source "$ROOT_DIR/dns/providers/technitium/provider.sh"

DNS_BACKEND=bind9_webmin
DNS_PROVIDER=bind9-webmin
IPA_DNS_MODE=external
DNS_SERVER_ROLE=primary
DNS_PRIMARY_SERVER=$IPA_HOSTNAME
DNS_PRIMARY_IP=$IPA_IP_ADDRESS
DNS_SECONDARY_SERVER=''
DNS_SECONDARY_IP=''
DNS_AUTHORITATIVE_REVERSE_ZONES=''
DNS_TRANSFER_KEY_SECRET=''
DNS_DYNAMIC_UPDATE_MODE=disabled
BIND_CONFIG_MODE=managed_include
BIND_ZONE_FILE_MODE=custom
MODE=check

printf '\n6. URI DNS validation and firewall convergence\n'
MODE=install
dig() {
    printf '%s\n' '0 100 "kr5srv:m:udp:ipa01.example.invalid."' '0 100 "krb5srv:m:tcp:ipa01.example.invalid."'
}
uri_record='_kpasswd.example.invalid. 3600 IN URI 0 100 "krb5srv:m:tcp:ipa01.example.invalid."'
assert_true 'URI validation accepts one matching value among multiple URI answers' dns_validate_record_line "$uri_record" 127.0.0.1
uri_mismatch='_kpasswd.example.invalid. 3600 IN URI 0 100 "krb5srv:m:tcp:wrong-host.example.invalid."'
assert_false 'URI validation rejects a mismatching value' dns_validate_record_line "$uri_mismatch" 127.0.0.1
unset -f dig

FIREWALL_TEST_STATE="$TEST_TMP/firewall-state"
: > "$FIREWALL_TEST_STATE"
FIREWALL_TEST_RELOADS=0
firewall-cmd() {
    local args="$*"
    local port scope
    if [[ "$args" == *'--get-active-zones'* ]]; then
        printf '%s\n' public '  interfaces: eth0'
        return 0
    fi
    if [[ "$args" == *'--get-services'* ]]; then
        printf '%s\n' freeipa-ldap freeipa-ldaps kerberos http https dns ntp
        return 0
    fi
    if [[ "$args" == *'--reload'* ]]; then
        FIREWALL_TEST_RELOADS=$((FIREWALL_TEST_RELOADS + 1))
        return 0
    fi
    if [[ "$args" == *'--query-port='* ]]; then
        port=${args#*--query-port=}
        port=${port%% *}
        scope=runtime
        [[ "$args" == *' --permanent'* ]] && scope=permanent
        grep -Fxq "$scope:$port" "$FIREWALL_TEST_STATE"
        return $?
    fi
    if [[ "$args" == *'--query-rich-rule='* ]]; then
        local rule
        rule=${args#*--query-rich-rule=}
        rule=${rule% --permanent}
        scope=runtime
        [[ "$args" == *' --permanent'* ]] && scope=permanent
        grep -Fxq "$scope-rich:$rule" "$FIREWALL_TEST_STATE"
        return $?
    fi
    if [[ "$args" == *'--add-port='* ]]; then
        port=${args#*--add-port=}
        port=${port%% *}
        scope=runtime
        [[ "$args" == *' --permanent'* ]] && scope=permanent
        printf '%s\n' "$scope:$port" >> "$FIREWALL_TEST_STATE"
        return 0
    fi
    if [[ "$args" == *'--add-rich-rule='* ]]; then
        local rule
        rule=${args#*--add-rich-rule=}
        rule=${rule% --permanent}
        scope=runtime
        [[ "$args" == *' --permanent'* ]] && scope=permanent
        printf '%s\n' "$scope-rich:$rule" >> "$FIREWALL_TEST_STATE"
        return 0
    fi
    if [[ "$args" == *'--remove-rich-rule='* ]]; then
        local rule temporary
        rule=${args#*--remove-rich-rule=}
        rule=${rule% --permanent}
        scope=runtime
        [[ "$args" == *' --permanent'* ]] && scope=permanent
        temporary="$FIREWALL_TEST_STATE.tmp"
        awk -v target="$scope-rich:$rule" '$0 != target { print }' "$FIREWALL_TEST_STATE" > "$temporary"
        mv -f -- "$temporary" "$FIREWALL_TEST_STATE"
        return 0
    fi
    if [[ "$args" == *'--query-service='* ]]; then
        return 0
    fi
    return 0
}
dns_provider_validate_webmin() {
    return 0
}
FIREWALL_STATE=active
FIREWALL_ZONES=()
IPA_DNS_MODE=external
DNS_PROVIDER=bind9-webmin
DNS_FIREWALL_REQUIRED=true
WEBMIN_PORT=10000
STATE_FILE=''
firewall_configure
assert_true 'firewall convergence adds the Webmin port permanently' grep -Fxq 'permanent:10000/tcp' "$FIREWALL_TEST_STATE"
assert_true 'firewall convergence adds the Webmin port at runtime' grep -Fxq 'runtime:10000/tcp' "$FIREWALL_TEST_STATE"
assert_equal 1 "$FIREWALL_TEST_RELOADS" 'firewall convergence reloads after the first change'
firewall_rule_count=$(wc -l < "$FIREWALL_TEST_STATE" | tr -d ' ')
firewall_configure
assert_equal "$firewall_rule_count" "$(wc -l < "$FIREWALL_TEST_STATE" | tr -d ' ')" 'firewall rerun does not duplicate rules'
assert_equal 1 "$FIREWALL_TEST_RELOADS" 'firewall rerun does not reload when already converged'
FIREWALL_STATE=inactive
firewall_configure
assert_equal 1 "$FIREWALL_TEST_RELOADS" 'inactive firewalld is left untouched'
FIREWALL_STATE=active
IPA_DNS_MODE=integrated
firewall_configure
assert_equal 1 "$FIREWALL_TEST_RELOADS" 'integrated DNS mode does not open the external Webmin port'

FIREWALL_TEST_STATE="$TEST_TMP/firewalld-technitium-state"
: > "$FIREWALL_TEST_STATE"
FIREWALL_TEST_RELOADS=0
IPA_STATE_DIR="$TEST_TMP/firewalld-technitium-state-dir"
FIREWALL_STATE=active
FIREWALL_BACKEND=firewalld
IPA_DNS_MODE=external
DNS_BACKEND=technitium
DNS_PROVIDER=technitium
DNS_SERVER_ROLE=primary
DNS_PRIMARY_SERVER=ipa01.example.invalid
DNS_PRIMARY_IP=192.0.2.10
DNS_SECONDARY_SERVER=ipa02.example.invalid
DNS_SECONDARY_IP=192.0.2.11
DNS_ADDITIONAL_NODES=''
TECHNITIUM_DNS_CLIENT_NETWORKS='192.0.2.0/24'
TECHNITIUM_ZONE_TRANSFER_PROTOCOL=Tcp
TECHNITIUM_SETTINGS_JSON='{"status":"ok","response":{"webServiceLocalAddresses":["0.0.0.0"],"webServiceHttpPort":55380,"webServiceEnableTls":true,"webServiceTlsPort":55443,"enableDnsOverTls":false}}'
TECHNITIUM_DHCP_SCOPES_JSON='{"status":"ok","response":{"scopes":[]}}'
firewall_configure
assert_true 'firewalld adds the configured Technitium Web port' grep -Fxq 'permanent:55380/tcp' "$FIREWALL_TEST_STATE"
assert_true 'firewalld adds the primary source rich rule' grep -Fq 'permanent-rich:rule family="ipv4" source address="192.0.2.10" port port="53" protocol="tcp" accept' "$FIREWALL_TEST_STATE"
firewall_rule_count=$(wc -l < "$FIREWALL_TEST_STATE" | tr -d ' ')
firewall_configure
assert_equal "$firewall_rule_count" "$(wc -l < "$FIREWALL_TEST_STATE" | tr -d ' ')" 'firewalld Technitium rerun is idempotent'
assert_equal 1 "$FIREWALL_TEST_RELOADS" 'firewalld Technitium rerun does not reload'

FIREWALL_BACKEND=none
detect_firewall_state
assert_equal active "$FIREWALL_STATE" 'active firewalld is detected by runtime state'
assert_equal firewalld "$FIREWALL_BACKEND" 'active firewalld is selected as the backend'
unset -f firewall-cmd dns_provider_validate_webmin

UFW_TEST_STATE="$TEST_TMP/ufw-state"
: > "$UFW_TEST_STATE"
UFW_TEST_ACTIVE=true
ufw() {
    local action=${1:-} spec source port protocol tag temporary
    case "$action" in
        status)
            if [[ "$UFW_TEST_ACTIVE" == true ]]; then
                printf '%s\n' 'Status: active'
            else
                printf '%s\n' 'Status: inactive'
            fi
            cat "$UFW_TEST_STATE"
            ;;
        allow)
            if [[ "${2:-}" == from ]]; then
                source=${3:-}
                port=${7:-}
                protocol=${9:-}
                printf '%s ALLOW %s # freeipa-bootstrap-technitium\n' "$port/$protocol" "$source" >> "$UFW_TEST_STATE"
            else
                spec=${2:-}
                tag=${4:-freeipa-bootstrap}
                printf '%s ALLOW Anywhere # %s\n' "$spec" "$tag" >> "$UFW_TEST_STATE"
            fi
            ;;
        delete)
            source=${4:-}
            port=${8:-}
            protocol=${10:-}
            temporary="$UFW_TEST_STATE.tmp"
            awk -v spec="$port/$protocol" -v source="$source" '! (index($0, spec) && index($0, source)) { print }' \
                "$UFW_TEST_STATE" > "$temporary"
            mv -f -- "$temporary" "$UFW_TEST_STATE"
            ;;
    esac
}

FIREWALL_BACKEND=none
detect_firewall_state
assert_equal active "$FIREWALL_STATE" 'active UFW is detected from ufw status'
assert_equal ufw "$FIREWALL_BACKEND" 'active UFW is selected as the backend'
UFW_TEST_ACTIVE=false
detect_firewall_state
assert_equal inactive "$FIREWALL_STATE" 'inactive UFW is not treated as active'
assert_equal none "$FIREWALL_BACKEND" 'inactive UFW does not select a firewall backend'
DNS_BACKEND=technitium
TECHNITIUM_REQUIRED_PORTS=('53/tcp|Technitium DNS TCP' '53/udp|Technitium DNS UDP')
TECHNITIUM_SOURCE_RULES=()
firewall_rule_count=$(wc -l < "$UFW_TEST_STATE" | tr -d ' ')
firewall_configure
assert_equal "$firewall_rule_count" "$(wc -l < "$UFW_TEST_STATE" | tr -d ' ')" 'Technitium with no active firewall makes no firewall changes'
UFW_TEST_ACTIVE=true

MODE=install
DNS_BACKEND=technitium
DNS_PROVIDER=technitium
IPA_DNS_MODE=external
DNS_SERVER_ROLE=primary
DNS_PRIMARY_SERVER=ipa01.example.invalid
DNS_PRIMARY_IP=192.0.2.10
DNS_SECONDARY_SERVER=ipa02.example.invalid
DNS_SECONDARY_IP=192.0.2.11
DNS_ADDITIONAL_NODES='ipa03.example.invalid=192.0.2.12'
TECHNITIUM_DNS_CLIENT_NETWORKS='192.0.2.0/24'
TECHNITIUM_ZONE_TRANSFER_PROTOCOL=Tcp
TECHNITIUM_SETTINGS_JSON='{"status":"ok","response":{"webServiceLocalAddresses":["0.0.0.0"],"webServiceHttpPort":55380,"webServiceEnableTls":true,"webServiceTlsPort":55443,"webServiceEnableHttp3":true,"enableDnsOverHttp":true,"dnsOverHttpPort":8080,"enableDnsOverTls":true,"dnsOverTlsPort":8853,"enableDnsOverHttps":true,"dnsOverHttpsPort":8443,"enableDnsOverHttp3":true,"enableDnsOverQuic":true,"dnsOverQuicPort":8853}}'
TECHNITIUM_DHCP_SCOPES_JSON='{"status":"ok","response":{"scopes":[{"name":"lab","enabled":true}]}}'
firewall_technitium_collect_ports
tech_ports=$(printf '%s\n' "${TECHNITIUM_REQUIRED_PORTS[@]}")
assert_contains '53/tcp' "$tech_ports" 'Technitium firewall includes DNS TCP 53'
assert_contains '53/udp' "$tech_ports" 'Technitium firewall includes DNS UDP 53'
assert_contains '55380/tcp' "$tech_ports" 'Technitium firewall uses the configured remote Web HTTP port'
assert_contains '55443/tcp' "$tech_ports" 'Technitium firewall uses the configured Web HTTPS port'
assert_contains '55443/udp' "$tech_ports" 'Technitium firewall includes configured Web HTTP/3'
assert_contains '8853/tcp' "$tech_ports" 'Technitium firewall uses the configured DoT port'
assert_contains '8853/udp' "$tech_ports" 'Technitium firewall uses the configured DoQ port'
assert_contains '8443/tcp' "$tech_ports" 'Technitium firewall uses the configured DoH port'
assert_contains '8443/udp' "$tech_ports" 'Technitium firewall uses the configured DoH HTTP/3 port'
assert_contains '8080/tcp' "$tech_ports" 'Technitium firewall includes enabled DNS-over-HTTP'
assert_contains '67/udp' "$tech_ports" 'Technitium firewall includes DHCP only when a scope is enabled'

TECHNITIUM_SETTINGS_JSON='{"status":"ok","response":{"webServiceLocalAddresses":["127.0.0.1"],"webServiceHttpPort":5380,"webServiceEnableTls":true,"webServiceTlsPort":53443,"enableDnsOverTls":false,"enableDnsOverQuic":false,"enableDnsOverHttps":false,"enableDnsOverHttp":false}}'
TECHNITIUM_DHCP_SCOPES_JSON='{"status":"ok","response":{"scopes":[{"name":"lab","enabled":false}]}}'
TECHNITIUM_ZONE_TRANSFER_PROTOCOL=Tcp
TECHNITIUM_DNS_CLIENT_NETWORKS=''
firewall_technitium_collect_ports
tech_ports=$(printf '%s\n' "${TECHNITIUM_REQUIRED_PORTS[@]}")
assert_false 'localhost-only Technitium Web Console is not opened' grep -Fq '5380/tcp' <<< "$tech_ports"
assert_false 'localhost-only Technitium Web HTTPS is not opened' grep -Fq '53443/tcp' <<< "$tech_ports"
assert_false 'disabled DoT is not opened' grep -Fq '853/tcp' <<< "$tech_ports"
assert_false 'disabled DoQ is not opened' grep -Fq '853/udp' <<< "$tech_ports"
assert_false 'disabled DHCP is not opened' grep -Fq '67/udp' <<< "$tech_ports"

TECHNITIUM_SETTINGS_JSON='{"status":"ok","response":{"webServiceLocalAddresses":["127.0.0.1"],"enableDnsOverTls":false}}'
TECHNITIUM_DHCP_SCOPES_JSON='{"status":"ok","response":{"scopes":[]}}'
TECHNITIUM_DNS_CLIENT_NETWORKS='192.0.2.0/24'
DNS_ADDITIONAL_NODES='ipa03.example.invalid=192.0.2.12'
firewall_technitium_collect_ports
tech_sources=$(printf '%s\n' "${TECHNITIUM_SOURCE_RULES[@]}")
assert_contains '192.0.2.0/24|53/tcp' "$tech_sources" 'configured DNS client network receives TCP 53'
assert_contains '192.0.2.0/24|53/udp' "$tech_sources" 'configured DNS client network receives UDP 53'
assert_contains '192.0.2.10|53/tcp' "$tech_sources" 'primary DNS node is included in source rules'
assert_contains '192.0.2.11|53/udp' "$tech_sources" 'secondary DNS node is included in source rules'
assert_contains '192.0.2.12|53/tcp' "$tech_sources" 'third DNS node is included in source rules'
TECHNITIUM_ZONE_TRANSFER_PROTOCOL=Tls
TECHNITIUM_SETTINGS_JSON='{"status":"ok","response":{"webServiceLocalAddresses":["127.0.0.1"],"enableDnsOverTls":false,"dnsOverTlsPort":8853}}'
firewall_technitium_collect_ports
tech_sources=$(printf '%s\n' "${TECHNITIUM_SOURCE_RULES[@]}")
assert_contains '192.0.2.10|8853/tcp' "$tech_sources" 'XFR-over-TLS uses the configured transfer port and topology peers'
assert_false 'XFR-over-TLS is not opened globally when only node transfer uses it' grep -Fq '8853/tcp' <<< "$(printf '%s\n' "${TECHNITIUM_REQUIRED_PORTS[@]}")"
TECHNITIUM_ZONE_TRANSFER_PROTOCOL=Tcp

FIREWALL_BACKEND=ufw
FIREWALL_STATE=active
FIREWALL_STATUS=''
IPA_STATE_DIR="$TEST_TMP/technitium-firewall-state"
STATE_FILE=''
printf '%s\n' '22/tcp ALLOW Anywhere # administrator-rule' >> "$UFW_TEST_STATE"
firewall_configure
assert_true 'UFW preserves an unrelated administrator rule' grep -Fq 'administrator-rule' "$UFW_TEST_STATE"
assert_true 'UFW creates the managed primary peer rule' grep -Fq '53/tcp ALLOW 192.0.2.10 # freeipa-bootstrap-technitium' "$UFW_TEST_STATE"
assert_true 'UFW creates the managed third-node peer rule' grep -Fq '53/udp ALLOW 192.0.2.12 # freeipa-bootstrap-technitium' "$UFW_TEST_STATE"
ufw_rule_count=$(grep -c 'freeipa-bootstrap-technitium' "$UFW_TEST_STATE")
firewall_configure
assert_equal "$ufw_rule_count" "$(grep -c 'freeipa-bootstrap-technitium' "$UFW_TEST_STATE")" 'UFW rerun does not duplicate managed rules'

DNS_ADDITIONAL_NODES='ipa03.example.invalid=192.0.2.13'
firewall_configure
assert_false 'UFW removes the old managed peer IP after topology change' grep -Fq '192.0.2.12' "$UFW_TEST_STATE"
assert_true 'UFW adds the new managed peer IP after topology change' grep -Fq '53/tcp ALLOW 192.0.2.13 # freeipa-bootstrap-technitium' "$UFW_TEST_STATE"
assert_true 'UFW metadata records managed source rules' test -s "$IPA_STATE_DIR/technitium-firewall.rules"

unset -f ufw
MODE=check

printf '\nSummary: %d passed, %d failed\n' "$pass" "$fail"
(( fail == 0 ))
