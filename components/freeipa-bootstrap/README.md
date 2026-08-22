# FreeIPA Server Bootstrap

This repository contains a standalone Bash bootstrap for a FreeIPA/IdM primary or replica server on supported
RHEL-family Linux hosts. It installs the FreeIPA server, 389 Directory Server, MIT Kerberos, and Web UI/CLI, with an
integrated Dogtag CA enabled by default or a certificate-backed CA-less mode when explicitly selected. KRA installation
is optional when the IPA CA is enabled.

The bootstrap is infrastructure-only. It does not create users, groups, HBAC or sudo rules, host groups, service
principals, certificate policies, trust relationships, or application configuration.

Operational administrators should use the
[FreeIPA Server Bootstrap operational article](docs/FreeIPA_Server_Bootstrap.md). It describes prerequisites, deployment
scenarios, DNS records, validation, troubleshooting, recovery, and the completion checklist.

## Project information

The canonical project version is stored in [`VERSION`](VERSION). Display it
without loading configuration or starting installation:

```bash
./install.sh --version
```

The current release notes are in [`CHANGELOG.md`](CHANGELOG.md). Run
[`scripts/lint-docs.sh`](scripts/lint-docs.sh) to lint the complete maintained
Markdown documentation tree, including this README, the operational article,
and DNS provider documentation.

The project version identifies this bootstrap's configuration and interface
baseline. It is not the installed version of FreeIPA, BIND, Webmin, or
Technitium DNS Server. FreeIPA and BIND packages are resolved from the native
repositories of the supported RHEL-family host. Webmin uses its official
repository setup, and Technitium uses the official installer URL in
`TECHNITIUM_INSTALLER_URL`; neither component is pinned to a project version.
`WEBMIN_SETUP_REPO_SHA256` and `TECHNITIUM_INSTALLER_SHA256` are required
integrity pins before a remote installer script is executed; they do not
select component release versions.

## Supported targets

The implementation explicitly supports RHEL, Rocky Linux, AlmaLinux, CentOS Stream, and Oracle Linux major versions 8,
9, and 10 on `x86_64` or `aarch64`, when the installed distribution repositories provide the required FreeIPA packages.
It uses the native `dnf` or `yum` package manager and does not add third-party FreeIPA repositories.

Ubuntu, Debian, Fedora, SUSE, and other non-allowlisted systems are rejected before package or system changes.

## Repository layout

```text
VERSION                            Canonical project version
CHANGELOG.md                       Release notes and current baseline
install.sh                         Entry point and orchestration
update-server-ip.sh                Transactional managed DNS A/PTR IP update utility
../../examples/freeipa/             Safe configuration templates
lib/                               Shared configuration, topology, preflight, system, and validation code
dns/provider.sh                    Provider contract and DNS record helpers
dns/providers/bind9-webmin/        Managed local BIND plus official Webmin repository provider
dns/providers/existing/            Read-only external DNS provider
dns/providers/technitium/          Technitium API/installer provider
docs/FreeIPA_Server_Bootstrap.md   Confluence-compatible operational article
scripts/lint-docs.sh               Complete Markdown documentation lint entry point
generated/.gitkeep                 Location for generated external-DNS record output
../../tests/freeipa-bootstrap/      Dependency-free pure-function test suite
```

## Quick start

Copy the example configuration and keep the real file private:

```bash
cp ../../examples/freeipa/freeipa.env.example .env
chmod 600 .env
chown root:root .env
vi .env
./install.sh --check
./install.sh --dry-run
./install.sh
```

Run these commands on the target server as root, or with `sudo` as appropriate. The development workstation is not a
FreeIPA test host; the installer is intentionally not run as part of repository development.

Configuration precedence is:

1. already-exported environment variables
2. the local `.env` file
3. secure interactive prompts for the two required FreeIPA passwords when normal execution has an interactive terminal

Passwords are not written to state or logs. The FreeIPA installer itself requires password arguments for unattended
installation; the bootstrap uses Bash arrays, never logs the complete command, and documents the resulting short-lived
process-list exposure in the operational article.

## Execution modes

- `./install.sh --check` performs read-only preflight and provider validation. It does not install packages or write
  files.
- `./install.sh --dry-run` validates the configuration and prints the planned packages, files, services, DNS
  zones/records, firewall behavior, and FreeIPA mode without changing the system.
- `./install.sh` performs the installation, optional DNS orchestration, post-install validation, and a concise summary.

The normal run tracks ownership in `/var/lib/freeipa-bootstrap/` and writes structured logs to
`/var/log/freeipa-bootstrap/`. Operational child-command output (including package installation, BIND validation,
service operations, Webmin setup, and the selected `ipa-server-install`/`ipa-replica-install`) is shown live in the same
console and retained in the per-run log. Displayed commands redact known credential arguments. A healthy existing
FreeIPA server is reported as `already configured` and is validated without reinstalling it. A partial FreeIPA
installation that existed before the current run aborts; automatic uninstall/retry is only allowed for a partial
installation created by that same run.

## DNS model

`IPA_DNS_MODE=integrated` passes repeated `--forwarder` options to the supported `ipa-server-install --setup-dns` path
and explicitly creates only the server IPv4 `/24` reverse zone after installation.

`IPA_DNS_MODE=external` selects exactly one provider through `dns/provider.sh`:

- `bind9-webmin` is implemented. It installs native BIND packages, creates only the managed IPA forward and explicitly
  configured reverse zones, supports independent `DNS_SERVER_ROLE=primary|secondary` operation, restricts transfers with
  a protected TSIG key by default, configures NOTIFY/also-notify, validates with `named-checkconf`, `named-checkzone`,
  SOA/NS queries, and `dig`, and installs or validates Webmin using the official repository setup script. A secondary
  declares `type slave` zones under `DNS_BIND_SLAVE_DIR` and never edits transferred slave files. When firewalld is
  active, TCP/UDP 53 and the configured `WEBMIN_PORT` are converged while preserving Webmin TCP 10000 semantics.
- `existing` is implemented and never changes external DNS. Before installation it writes
  `generated/freeipa-dns-prerequisites.txt` and validates only the server A/PTR prerequisites. After a successful
  FreeIPA installation it preserves the installer-generated system-record file as
  `generated/freeipa-dns-records-<run-id>.db`; if those records still need to be published, the run completes with an
  explicit pending-DNS status and `./install.sh --check` can be used after publication.
- `technitium` is implemented through the official HTTP API and installer. It supports Primary/Secondary forward and
  reverse zones, native AXFR/IXFR/NOTIFY, TSIG transfer keys, RFC 2136 update policies, idempotent record
  reconciliation, and API-backed validation. Secure mode is TSIG policy plus an explicit source-network ACL; it is not
  FreeIPA GSS-TSIG/Kerberos. When UFW or firewalld is already active, the bootstrap automatically converges
  feature-aware Technitium firewall rules, including configured Web/encrypted-DNS listeners and enabled DHCP only;
  inactive firewalls are left untouched.

The canonical selector is `DNS_BACKEND`:

```dotenv
DNS_BACKEND=integrated
# DNS_BACKEND=bind9_webmin
# DNS_BACKEND=technitium
# DNS_BACKEND=existing
```

Enable exactly one line. Existing `IPA_DNS_MODE` and `DNS_PROVIDER` values are
translated for backward compatibility. `SERVER_FQDN` and `MANAGE_HOSTNAME` are
the canonical hostname variables; `IPA_HOSTNAME` and `CONFIGURE_HOSTNAME`
remain accepted aliases.

| Backend | Primary/secondary model | Secure update model | Zone ownership |
| --- | --- | --- | --- |
| FreeIPA integrated | FreeIPA primary/replica replication; not a conventional AXFR secondary | FreeIPA CLI/Kerberos/GSS-TSIG path; insecure mode is rejected | FreeIPA LDAP-integrated DNS |
| BIND9 + Webmin | BIND master/slave with AXFR/IXFR and optional NOTIFY | TSIG `update-policy` or explicit ACL `allow-update` | Marked zones in native or managed-include configuration |
| Technitium | Native Primary/Secondary zones with API-configured transfers and NOTIFY | TSIG security policy plus explicit source ACL | Technitium HTTP API; no internal-file edits |
| Existing | External service is administered elsewhere | Controlled outside this project | Read-only validation |

The provider contract is the set of `check`, `install`, `configure`, `configure-forwarders`, `create-forward-zone`,
`create-reverse-zone`, `create-record`, `validate-prerequisites`, `validate`, `sync-freeipa-records`, and `uninstall`
operations. To add a provider, implement the same `dns_provider_<operation>` functions in a new module and add one
selection entry in `dns/provider.sh`; keep provider-specific behavior out of `lib/freeipa.sh`.

For `DNS_PROVIDER=existing`, publish each server A and configured authoritative reverse PTR before running the
installer. After FreeIPA succeeds, publish every record in the preserved `freeipa-dns-records-<run-id>.db` file and
rerun `./install.sh --check`. The bootstrap never writes or removes records in that provider.

### Multi-server topology and IP changes

Use `IPA_SERVER_ROLE=primary` for the first server and `IPA_SERVER_ROLE=replica` for every additional server. Replica
installation uses the supported `ipa-replica-install` path, validates the source FQDN/reachability/realm, and uses
`IPA_REPLICA_SOURCE`, `IPA_REPLICA_PRINCIPAL`, and `IPA_ADMIN_PASSWORD`; it never converts a healthy server in place.
Set `IPA_REPLICA_SETUP_CA=true` when the replica must host a CA replica, and validate the resulting topology with
`ipa server-show` and `ipa topologysegment-find`.

DNS has its own independent role. On the authoritative BIND host use `DNS_SERVER_ROLE=primary` and configure
`DNS_SECONDARY_SERVER`/`DNS_SECONDARY_IP`; on the redundant host use `DNS_SERVER_ROLE=secondary` plus the primary
address and an explicit `DNS_AUTHORITATIVE_REVERSE_ZONES` list. The primary publishes both NS/A/PTR prerequisites,
restricts AXFR/IXFR to the TSIG key, and sends NOTIFY. The secondary uses native `/etc/named.conf` and
`/var/named/slaves` layout, validates SOA serial convergence, and does not let Webmin initialize or replace BIND
configuration. Register a Webmin peer manually through Webmin Servers Index/Cluster Webmin Servers; the bootstrap does
not edit undocumented Webmin cluster files or APIs. For Technitium, `DNS_ADDITIONAL_NODES` extends the shared
`DNS_NODES[]` topology for source-restricted firewall rules, and `update-server-ip.sh` reconciles installer-managed peer
rules after a local primary IP change.

After the replica installation, treat its captured `freeipa-dns-records-<run-id>.db` as the version-specific source of
truth for the new server's records. Copy it through the approved channel to the BIND primary and run
`./install.sh --sync-freeipa-records /path/to/freeipa-dns-records-<run-id>.db`, then rerun the primary and secondary
`./install.sh --check` flows until the primary/secondary SOA serials and A/PTR/SRV/TXT answers converge. The secondary
deliberately reports pending when it has captured records but has not been given authority to edit the primary.

For an address-only DNS update, run `./update-server-ip.sh --check` first, then
`./update-server-ip.sh --dry-run --new-ip <new-address>`, and finally the normal command on the authoritative primary.
The utility dispatches by `DNS_BACKEND`: it edits only marked BIND A/PTR records, uses the supported FreeIPA DNS CLI for
integrated DNS, or uses Technitium's authenticated records API. It updates the shared `.env`, keeps the hostname and
FreeIPA LDAP/Kerberos state unchanged, validates before activation, waits for secondary convergence where applicable,
and attempts a backend-specific rollback on failure. For Technitium with an active UFW/firewalld, it also reconciles the
`DNS_NODES[]` peer source rules so a changed local primary IP does not leave a stale installer-managed rule. It refuses
to run on a DNS secondary or existing read-only DNS. The operating-system interface migration remains a separate,
supported change.

## Configuration reference

All variables in `../../examples/freeipa/freeipa.env.example` are documented in the
[operational configuration reference](docs/FreeIPA_Server_Bootstrap.md#configuration). The most important choices are:

```dotenv
# FreeIPA integrated DNS
IPA_DNS_MODE=integrated
DNS_FORWARDERS="192.0.2.53 192.0.2.54"

# Managed external BIND and Webmin
IPA_DNS_MODE=external
DNS_PROVIDER=bind9-webmin
DNS_FORWARDERS="192.0.2.53 192.0.2.54"
DNS_SERVER_ROLE=primary
DNS_PRIMARY_SERVER=ipa01.example.invalid
DNS_PRIMARY_IP=192.0.2.10
DNS_SECONDARY_SERVER=ipa02.example.invalid
DNS_SECONDARY_IP=192.0.2.11
DNS_AUTHORITATIVE_REVERSE_ZONES="2.0.192.in-addr.arpa"
DNS_TRANSFER_SECURITY=tsig
WEBMIN_PORT=10000
WEBMIN_CONFIG_FILE=/etc/webmin/miniserv.conf

# Existing external DNS; no external DNS writes
IPA_DNS_MODE=external
DNS_PROVIDER=existing

# Integrated Dogtag CA (default) and optional KRA
IPA_SETUP_CA=true
IPA_SETUP_KRA=false
IPA_SSH_TRUST_DNS=false
IPA_SETUP_SUBID=false

# CA-less mode for a new server; use absolute, whitespace-separated paths
IPA_SETUP_CA=false
IPA_DIRSRV_CERT_FILES="/etc/pki/ipa/dirsrv.p12"
IPA_HTTP_CERT_FILES="/etc/pki/ipa/http.p12"
IPA_CA_CERT_FILES="/etc/pki/ipa/issuer-chain.pem"
```

Set `DNS_FORWARDERS=""` when integrated DNS must use the installer's no-forwarders behavior or managed BIND must leave
forwarding unset. The bootstrap does not invent a replacement list for an explicitly empty value.

`IPA_REALM` is explicitly overridable; an empty value derives the uppercase form of `IPA_DOMAIN`. `IPA_SETUP_CA=true`
uses the platform's default integrated Dogtag CA. `IPA_SETUP_CA=false` selects a new CA-less primary installation and
requires external LDAP/HTTP server certificate files; an existing CA is never removed during a rerun. On replicas,
`IPA_REPLICA_SETUP_CA` controls whether `ipa-replica-install` creates the CA replica. `IPA_SETUP_KRA=false` leaves KRA
out, while `IPA_SETUP_KRA=true` first detects an existing healthy KRA and runs `ipa-kra-install` only when it is absent.
KRA requires the IPA CA. `IPA_SSH_TRUST_DNS=true` adds the supported SSH trust option and `IPA_SETUP_SUBID=true` adds
the supported subid option to a new primary or replica installer invocation; both default to false and are not
retroactively applied when a healthy existing FreeIPA server is detected. `CONFIGURE_SERVER_MKHOMEDIR` controls host
PAM/SSSD login behavior only and does not create or alter FreeIPA user entries. `WEBMIN_PORT` is validated against
Webmin's actual `miniserv.conf` listener and is opened only for the managed `bind9-webmin` design when firewalld is
already active.

## Tests and development

The test suite has no external testing dependency:

```bash
bash ../../tests/freeipa-bootstrap/test.sh
bash -n install.sh lib/*.sh dns/provider.sh dns/providers/*/*.sh ../../tests/freeipa-bootstrap/test.sh
```

It covers environment/default handling, CA-less certificate validation and argument construction, primary/replica
installer selection, SSH trust DNS/subid option construction, existing CA/KRA detection, IPv4 and reverse-zone helpers,
multiple forwarders and NTP servers, redaction, provider selection, legacy and nsupdate external-record capture, BIND
prerequisite zones, primary/secondary TSIG topology, URI DNS records, Webmin listener validation, package-query
idempotency, firewalld/UFW and feature-aware Technitium firewall convergence, three-node peer rules, IP-change
reconciliation, OS allowlisting, ownership, retry bounds, and execution-mode detection. ShellCheck is recommended in CI
when available; it was not present in the development environment used for this repository task.

Do not run the installer on a developer workstation. Runtime validation of `ipa-server-install`, `ipa-kra-install`,
BIND, firewalld, chrony, SELinux, Webmin, and systemd must be performed on a disposable supported RHEL-family host with
the required DNS and time prerequisites.

## Backup and lifecycle boundary

Backup scheduling is deliberately not automated. Administrators should establish and test the platform-supported
`ipa-backup` procedure and restore plan before production use. Uninstallation of FreeIPA, BIND, Webmin, and external DNS
is not part of the normal install flow; see the operational article for the supported manual recovery and safety
boundaries.
