# FreeIPA Server Bootstrap

## Document Purpose

This article is the operational guide for the FreeIPA Server Bootstrap package. It explains what the bootstrap changes,
how an infrastructure administrator prepares and installs a FreeIPA server, how DNS modes differ, how to validate the
result, and how to recover safely from common failures.

It is written to stand alone. It assumes that the package files are available but does not require reading the Bash
source code.

## Project version and component versions

The project version is the single value in [`../VERSION`](../VERSION). Read it
with `../install.sh --version`. The current release notes are in
[`../CHANGELOG.md`](../CHANGELOG.md), and the complete documentation lint
command is [`../scripts/lint-docs.sh`](../scripts/lint-docs.sh).

This project version describes the bootstrap's configuration and CLI contract.
It is separate from the versions of FreeIPA, BIND, Webmin, and Technitium DNS
Server installed on a target host.

- FreeIPA and BIND use the supported packages supplied by the host's native
  RHEL-family repositories. The bootstrap validates the installed
  `ipa-server-install` and `ipa-replica-install` option surfaces instead of
  hard-coding a component release.
- Webmin uses its official repository setup. `WEBMIN_SETUP_REPO_SHA256` is a
  required pin before the setup script can run, but it does not select a Webmin release.
- Technitium uses `TECHNITIUM_INSTALLER_URL`, which defaults to the official
  installer URL. `TECHNITIUM_INSTALLER_SHA256` is required before that script can run;
  there is no separate project-level Technitium version variable.

These policies support the supported RHEL-family major versions documented
below without claiming a component version range that the installer does not
actually enforce.

Version policy follows Semantic Versioning for the project interface:

- `MAJOR` is an incompatible configuration or CLI change.
- `MINOR` is a backward-compatible feature.
- `PATCH` is a backward-compatible fix or documentation correction.

The project is pre-1.0. During `0.x` development, a breaking change may still
require a minor release when the compatibility contract is revised.

## Scope

The bootstrap installs and validates a FreeIPA/IdM primary or replica server with:

- 389 Directory Server
- MIT Kerberos
- FreeIPA CLI and Web UI
- the integrated Dogtag FreeIPA CA when IPA_SETUP_CA=true, or a certificate-backed CA-less server when
  IPA_SETUP_CA=false
- optional KRA, enabled only when IPA_SETUP_KRA=true and an IPA CA is enabled
- either FreeIPA integrated DNS or one implemented external DNS provider

This is infrastructure bootstrap only. It does not configure users, groups, HBAC rules, sudo rules, host groups, service
definitions, certificate profiles, password policies, trusts, application principals, Webmin ACLs, or project-specific
identity policy.

> **Warning:** FreeIPA names, realm, hostname, and DNS design are foundational choices. Review them carefully before installation.
>
> They are not ordinary settings that can be changed casually after the realm is created.

## Supported Platforms

The implementation explicitly supports these RHEL-family identities when the installed distribution repositories provide
a supported FreeIPA/IdM server implementation:

- RHEL 8, 9, or 10
- Rocky Linux 8, 9, or 10
- AlmaLinux 8, 9, or 10
- CentOS Stream 8, 9, or 10
- Oracle Linux 8, 9, or 10

Only x86_64 and aarch64 are allowlisted. The bootstrap uses the native dnf or yum package manager. It does not install
Debian packages, create an Ubuntu/Debian FreeIPA path, or add arbitrary third-party FreeIPA repositories.

Ubuntu, Debian, Fedora, SUSE, and other non-allowlisted systems fail during preflight before package or service changes.

## Architecture Overview

The package has one FreeIPA orchestration layer and a DNS provider boundary. Provider-specific DNS actions are not
embedded in the FreeIPA installation functions. FreeIPA and DNS roles are independent: an IPA replica may be the DNS
primary, and a DNS secondary may be hosted on an IPA replica, but the common production topology is an IPA primary/BIND
primary plus an IPA replica/BIND secondary.

```text
                         +----------------------+       +----------------------+
                         | FreeIPA primary      |       | FreeIPA replica      |
                         | ipa-server-install   |       | ipa-replica-install  |
                         | Directory/Kerberos   |<----->| Directory/Kerberos   |
                         | Dogtag CA / KRA      |        | optional CA replica  |
                         +----------+-----------+        +----------+-----------+
                                    |                               |
                                    | DNS records / NS / NOTIFY     | AXFR/IXFR + SOA
                                    v                               v
                         +----------------------+       +----------------------+
                         | BIND primary        |======>| BIND secondary       |
                         | type master         | TSIG  | type slave           |
                         | native named.conf   |       | /var/named/slaves    |
                         | Webmin admin plane  |       | Webmin admin plane   |
                         +----------------------+       +----------------------+

                         Alternative: existing external DNS is read-only
```

The canonical DNS selector is `DNS_BACKEND=integrated|bind9_webmin|technitium|existing`. The legacy
`IPA_DNS_MODE`/`DNS_PROVIDER` pair remains accepted and is normalized to the canonical backend.
`SERVER_FQDN`/`MANAGE_HOSTNAME` are the canonical hostname variables; `IPA_HOSTNAME`/`CONFIGURE_HOSTNAME` remain
compatibility aliases.

### FreeIPA Components

The primary ipa-server-install invocation installs the directory server, Kerberos, and HTTP/API components. With
IPA_SETUP_CA=true (the default), the platform's default integrated Dogtag CA is used. With IPA_SETUP_CA=false, the
bootstrap passes externally issued LDAP and HTTP certificate files for a CA-less installation. The bootstrap checks the
installed command's help output before constructing version-sensitive arguments.

The CA choice applies to a new installation. A healthy existing integrated CA is detected and reported as already
configured; it is never installed a second time. Setting IPA_SETUP_CA=false on a host that already has a CA preserves
that CA and does not remove it. Converting an existing CA-less server to CA-full is outside this bootstrap's automatic
scope.

### PKI / Internal CA

IPA_SETUP_CA=true uses the FreeIPA-integrated Dogtag CA and validates it with ipa ca-show ipa. IPA_SETUP_CA=false
requires externally issued server certificates and skips the integrated-CA object check. IPA_SETUP_KRA is available only
with the IPA CA: false leaves KRA absent, while true first validates an existing KRA with ipa vaultconfig-show and runs
ipa-kra-install only when KRA is absent.

### FreeIPA Primary and Replica Roles

Set `IPA_SERVER_ROLE=primary` on the first server and `IPA_SERVER_ROLE=replica` on each additional server. A primary is
installed with the platform's `ipa-server-install`; a replica is installed only with the supported `ipa-replica-install`
flow. The bootstrap never uses `ipa-server-install` to create a replica and never converts a healthy server when the
requested role differs from the recorded role.

For a replica, set `IPA_REPLICA_SOURCE` to the source server's FQDN, keep `IPA_REPLICA_PRINCIPAL=admin` unless an
approved supported principal is required, and provide `IPA_ADMIN_PASSWORD`. The preflight resolves and probes the
source, then `ipa-replica-conncheck` validates the source, realm, hostname, and credentials before the installer is
invoked. Hostname, domain, realm, local address, time synchronization, and required network ports are validated
independently; the replica installer is passed `--no-ntp` so chrony remains under the bootstrap/platform policy.

Set `IPA_REPLICA_SETUP_CA=true` when the replica must contain the same FreeIPA CA topology as the source; this adds
`--setup-ca` and the post-install validation checks both server objects and topology segments. KRA is a separate
operation and is never implied by CA replication. For an explicitly supported CA-less replica, set
`IPA_REPLICA_SETUP_CA=false` and provide the certificate inputs required by the target release; do not reuse
`IPA_SETUP_CA` as a replica-role switch.

The bootstrap writes a root-only role marker under `IPA_STATE_DIR` after a successful new installation. If a healthy
pre-existing server has no marker and its role cannot be proven safely, a replica request stops rather than guessing. A
primary request preserves the server and warns; this keeps existing single-server reruns non-destructive.

### DNS Architecture

DNS is selected with `DNS_BACKEND`. Exactly one backend is enabled in the
environment file.

| Backend | Primary/secondary relationship | Dynamic update security | Configuration boundary |
| --- | --- | --- | --- |
| `integrated` | FreeIPA primary/replica replication; it is not a conventional AXFR secondary | FreeIPA CLI/Kerberos/GSS-TSIG; `insecure` is rejected | FreeIPA LDAP-integrated DNS |
| `bind9_webmin` | BIND master/slave with AXFR/IXFR and optional NOTIFY | `disabled`, explicit ACL `allow-update`, or TSIG `update-policy` | Native distribution zone file/config paths or marked managed include |
| `technitium` | Technitium Primary/Secondary zones, API-configured AXFR/IXFR/NOTIFY | TSIG security policy plus explicit source-network ACL; not GSS-TSIG | Official HTTP API and official installer |
| `existing` | External DNS is administered by another team/service | Outside this project | Read-only plan and validation |

The provider matrix is deliberately explicit: integrated DNS uses FreeIPA's
replication model; BIND and Technitium can run conventional authoritative
primary/secondary pairs; existing DNS is never mutated.

#### Integrated DNS

Integrated mode uses the supported ipa-server-install --setup-dns path. Each configured DNS_FORWARDERS value becomes its
own --forwarder argument. Reverse auto-discovery is disabled with --no-reverse; after installation, the bootstrap
creates only the reverse zone for the FreeIPA server's IPv4 /24 and adds its PTR record through the FreeIPA CLI.

#### External DNS

External mode installs FreeIPA without integrated DNS. Before installation, only the server FQDN A record and the
explicitly configured authoritative reverse-zone PTR are prerequisites. The bootstrap creates those records through BIND
or Technitium, or validates and reports them without writing when `DNS_BACKEND=existing`. The full SRV/TXT system-record
set is not required during this pre-install phase.

`DNS_SERVER_ROLE=primary` manages authoritative zones and may derive one reverse zone from the local address when no
explicit list is supplied. A redundant deployment should set `DNS_AUTHORITATIVE_REVERSE_ZONES` explicitly on both hosts;
a secondary is rejected unless every authoritative reverse zone is listed. The primary publishes NS records for both DNS
servers, A/PTR prerequisites for both servers when they belong to the managed zones, `type master` declarations,
restricted AXFR/IXFR, and `also-notify`. The secondary publishes no local authoritative data: it declares `type slave`,
stores transferred files under `DNS_BIND_SLAVE_DIR`, uses the configured primary and TSIG key in `masters`, and refuses
local record imports.

The FreeIPA installer may expose its system records in the legacy version-specific `/tmp/ipa.system.records.*.db` file.
On releases that use the supported external-DNS workflow instead, the bootstrap invokes
`ipa dns-update-system-records --dry-run --out <file>`, retains the captured nsupdate transaction in the current run
state, and normalizes only its `update add` statements into the provider record contract. Delete directives are not
replayed against unmanaged administrator records. This prevents a stale file from an earlier run being consumed and
keeps the record set derived from the installed FreeIPA version rather than a hardcoded list.

#### DNS Provider Model

Every external provider exposes these operations through dns/provider.sh:

1. check
2. install
3. configure
4. configure-forwarders
5. create-forward-zone
6. create-reverse-zone
7. create-record
8. validate-prerequisites
9. validate
10. sync-freeipa-records
11. uninstall

The main installer calls these operations through a single provider dispatch function. Provider selection is made once.
The Technitium module uses authenticated API calls, preserves unrelated settings, refuses zone-type conversion/deletion,
and treats a secondary as read-only for authoritative records.

## Deployment Scenarios

### Scenario 1 - FreeIPA Integrated DNS

Use this when the FreeIPA server should be authoritative for its own IPA domain.

```dotenv
IPA_DNS_MODE=integrated
DNS_FORWARDERS="192.0.2.53 192.0.2.54"
```

The installer creates the IPA forward zone through FreeIPA. It creates only the reverse zone for the server's own IPv4
/24; other reverse networks and IPv6 reverse zones remain outside scope.

### Scenario 2 - External BIND and Webmin

Use this when BIND should be the authoritative external DNS service on the same server and Webmin should be installed
for later administration.

```dotenv
IPA_DNS_MODE=external
DNS_PROVIDER=bind9-webmin
DNS_FORWARDERS="192.0.2.53 192.0.2.54"
DNS_RECURSION_NETWORKS="127.0.0.0/8 192.0.2.0/24"
WEBMIN_PORT=10000
```

The provider installs bind and bind-utils, configures forwarding and restricted recursion, validates the configuration,
and starts or reloads named. `BIND_CONFIG_MODE=native` writes zone declarations into the detected
distribution/Webmin-compatible native zone configuration file; `BIND_CONFIG_MODE=managed_include` preserves the existing
dedicated include behavior. `BIND_ZONE_FILE_MODE=native|custom` independently selects the normal `/var/named` data path
or the legacy dedicated path. Both modes use marked blocks and refuse unmanaged zone-file replacement. The provider
installs or preserves Webmin using the official Webmin repository setup script, then validates `WEBMIN_CONFIG_FILE`, the
active Webmin service, and the actual TCP listener. When firewalld is already active, the bootstrap adds `WEBMIN_PORT`
to both the permanent and runtime rules; it does not enable an inactive firewall or configure Webmin ACLs, TLS policy,
or accounts.

The target's system resolver must be able to use the authoritative DNS service before FreeIPA is installed. The
bootstrap does not rewrite arbitrary network interfaces or take ownership of /etc/resolv.conf.

`BIND_ACL_NAME` and `BIND_ACL_NETWORKS` create one marked top-level ACL. The
`BIND_ALLOW_*_ACL` variables are independent references; an ACL is not silently
reused for transfers, queries, recursion, NOTIFY, and updates. `DNS_NOTIFY_ENABLED`
controls `notify`/`also-notify`. `DNS_DYNAMIC_UPDATE_MODE=disabled` emits an
explicit deny; `insecure` requires `BIND_ALLOW_UPDATE_ACL`; `secure` emits only
TSIG `update-policy` and never both `allow-update` and `update-policy`.
For BIND secure DDNS, `DNS_DYNAMIC_UPDATE_NETWORKS` is not required because
the TSIG `update-policy` is the authorization boundary. For BIND insecure DDNS,
the named ACL reference is the authorization boundary. Technitium secure or
insecure DDNS uses its native source-network ACL, so `TECHNITIUM_UPDATE_NETWORKS`
(normally inherited from `DNS_DYNAMIC_UPDATE_NETWORKS`) must be set.

For a redundant BIND pair, install the primary configuration first, then install the secondary with the same
`DNS_TRANSFER_KEY_NAME` and key material. The primary uses `type master`, `allow-transfer { key ...; }`, `notify yes`,
and `also-notify`; the secondary uses `type slave`, `masters { <primary-ip> key <name>; }`, `allow-notify`,
`allow-transfer { none; }`, and files below `/var/named/slaves` (or the configured `DNS_BIND_SLAVE_DIR`). Transfer
completion is checked with primary/secondary SOA serial equality and NS answers. The provider keeps `/etc/named.conf`
and the distribution's native layout; it never invokes Webmin's BIND initialization action.

Webmin is an administration plane, not the DNS replication protocol. If both hosts need to be visible in Webmin,
register the peer manually under Webmin **Servers Index** / **Cluster Webmin Servers**, using `WEBMIN_PEER_SERVER`,
`WEBMIN_PEER_PORT`, and approved credentials as the operator's reference. The bootstrap validates the peer parameters
and records the manual action but does not write undocumented Webmin cluster files or call an unsafe internal API.

### Scenario 2b - Technitium DNS Server

Use this when Technitium should own the external authoritative zones and its
native API should be the management boundary.

```dotenv
DNS_BACKEND=technitium
TECHNITIUM_API_URL=https://dns01.example.invalid:53443
TECHNITIUM_API_TOKEN_FILE=/etc/freeipa-bootstrap/technitium.token
DNS_SERVER_ROLE=primary
DNS_PRIMARY_SERVER=dns01.example.invalid
DNS_PRIMARY_IP=192.0.2.10
DNS_SECONDARY_SERVER=dns02.example.invalid
DNS_SECONDARY_IP=192.0.2.11
DNS_TSIG_ENABLED=true
DNS_TSIG_KEY_NAME=primary-secondary
DNS_TSIG_KEY_FILE=/etc/named/freeipa-bootstrap-transfer.key
DNS_DYNAMIC_UPDATE_MODE=secure
DNS_DYNAMIC_UPDATE_NETWORKS="192.0.2.0/24"
```

The provider uses the official Linux installer only when the configured
installation is absent, then enables `dns.service` and calls the documented
HTTP API. It creates or reuses Primary/Secondary forward and reverse zones,
configures the primary address, transfer protocol, TSIG key, transfer policy,
NOTIFY, forwarders, and RFC 2136 update security policy. Existing zones with a
different type are rejected; they are never converted or deleted. Record
reconciliation is idempotent and a Technitium secondary never edits its
transferred records locally.

Technitium secure DDNS means a TSIG security policy plus an explicit source ACL
(`DNS_DYNAMIC_UPDATE_NETWORKS`); it is not FreeIPA GSS-TSIG/Kerberos. Do not
claim integrated-DNS secure-update parity for this backend. TLS verification is
enabled; use `TECHNITIUM_API_CA_FILE` for a private CA. Plain HTTP and
`TECHNITIUM_API_TLS_VERIFY=false` are rejected.

### Scenario 2a - FreeIPA Primary and Replica with Redundant External DNS

Primary/authoritative host example:

```dotenv
IPA_SERVER_ROLE=primary
IPA_DOMAIN=example.invalid
IPA_REALM=EXAMPLE.INVALID
IPA_HOSTNAME=ipa01.example.invalid
IPA_IP_ADDRESS=192.0.2.10
IPA_DNS_MODE=external
DNS_PROVIDER=bind9-webmin
DNS_SERVER_ROLE=primary
DNS_PRIMARY_SERVER=ipa01.example.invalid
DNS_PRIMARY_IP=192.0.2.10
DNS_SECONDARY_SERVER=ipa02.example.invalid
DNS_SECONDARY_IP=192.0.2.11
DNS_AUTHORITATIVE_REVERSE_ZONES="2.0.192.in-addr.arpa"
DNS_TRANSFER_SECURITY=tsig
DNS_TRANSFER_KEY_NAME=freeipa-bootstrap-transfer
DNS_TRANSFER_KEY_FILE=/etc/named/freeipa-bootstrap-transfer.key
```

Replica/secondary host example:

```dotenv
IPA_SERVER_ROLE=replica
IPA_REPLICA_SOURCE=ipa01.example.invalid
IPA_REPLICA_PRINCIPAL=admin
IPA_REPLICA_SETUP_CA=true
IPA_DOMAIN=example.invalid
IPA_REALM=EXAMPLE.INVALID
IPA_HOSTNAME=ipa02.example.invalid
IPA_IP_ADDRESS=192.0.2.11
IPA_DNS_MODE=external
DNS_PROVIDER=bind9-webmin
DNS_SERVER_ROLE=secondary
DNS_PRIMARY_SERVER=ipa01.example.invalid
DNS_PRIMARY_IP=192.0.2.10
DNS_SECONDARY_SERVER=ipa02.example.invalid
DNS_SECONDARY_IP=192.0.2.11
DNS_AUTHORITATIVE_REVERSE_ZONES="2.0.192.in-addr.arpa"
DNS_TRANSFER_SECURITY=tsig
DNS_TRANSFER_KEY_NAME=freeipa-bootstrap-transfer
DNS_TRANSFER_KEY_FILE=/etc/named/freeipa-bootstrap-transfer.key
```

Copy the protected TSIG key through the approved secret-distribution process before secondary validation, or set the
same `DNS_TRANSFER_KEY_SECRET` on both hosts before the first configuration. Do not place a production secret in this
article or `../../examples/freeipa/freeipa.env.example`.

After the replica installation, use its captured `freeipa-dns-records-<run-id>.db` as the version-specific record source
for the new server. Copy it through the approved channel to the BIND primary and run:

```bash
./install.sh --sync-freeipa-records /path/to/freeipa-dns-records-<run-id>.db
```

This primary-only operation imports the generated records into marked managed zones, validates/reloads named, and runs
the normal FreeIPA/DNS validation. Then rerun `./install.sh --check` on both hosts. The secondary intentionally reports
a pending external-record status when it has captured the output but has no authority to edit the primary or a
transferred slave file. Once the primary accepts the records, NOTIFY/AXFR/IXFR and the SOA/NS checks provide the
convergence evidence.

### Scenario 3 - Existing External DNS

Use this when another DNS team or service owns the authoritative zone.

```dotenv
IPA_DNS_MODE=external
DNS_PROVIDER=existing
DNS_VALIDATION_SERVER=""
```

The provider never writes to external DNS. Before installation it creates `generated/freeipa-dns-prerequisites.txt` and
validates only the server A/PTR prerequisites. After FreeIPA succeeds, the installer-generated system records are
preserved as `generated/freeipa-dns-records-<run-id>.db`. The bootstrap reports
`FreeIPA installed successfully / External DNS update required / Final DNS validation pending` when those records still
need to be published; it does not uninstall or retry because of that manual DNS step. Publish the file's records in the
external DNS service, then rerun `./install.sh --check`.

### Existing External DNS

`DNS_BACKEND=existing` remains read-only. It writes a prerequisite plan and
preserves the version-specific FreeIPA record file, but the DNS administrator
must publish the records and rerun `./install.sh --check`.

## What to Change for a New Environment

This is the first section to review when reusing the bootstrap for another environment.

| Change class | Variables | Guidance |
| --- | --- | --- |
| Must change | `IPA_DOMAIN`, `IPA_HOSTNAME`, `IPA_IP_ADDRESS` | Replace the documentation values with the real lowercase FQDN, domain, and statically assigned IPv4 address. |
| Must provide for installation | `IPA_ADMIN_PASSWORD` | Supply through the protected environment, a mode-0600 `.env`, or the hidden interactive prompt. A primary, or any run with `IPA_SETUP_KRA=true`, also needs `IPA_DIRECTORY_MANAGER_PASSWORD`; a normal replica does not. Never commit either secret. |
| Choose the FreeIPA role | `IPA_SERVER_ROLE`, `IPA_REPLICA_SOURCE`, `IPA_REPLICA_PRINCIPAL`, `IPA_REPLICA_SETUP_CA` | Use `primary` once. Every additional server uses `replica`, a source FQDN, a supported principal/password, and an explicit CA-replica choice. The role is not converted automatically on a healthy host. |
| Choose the DNS design | `DNS_BACKEND` (legacy `IPA_DNS_MODE`, `DNS_PROVIDER`) | Enable exactly one of `integrated`, `bind9_webmin`, `technitium`, or `existing`. The legacy pair is normalized for existing deployments. |
| Choose DNS roles | `DNS_SERVER_ROLE`, `DNS_PRIMARY_SERVER`, `DNS_PRIMARY_IP`, `DNS_SECONDARY_SERVER`, `DNS_SECONDARY_IP` | DNS role is independent from IPA role. On a secondary, explicitly identify the distinct primary and local secondary. On a primary, set the secondary pair to enable TSIG-protected AXFR/IXFR and NOTIFY. |
| List authoritative reverse zones | `DNS_AUTHORITATIVE_REVERSE_ZONES` | A primary may derive one local `/24`; a redundant pair should list every reverse zone explicitly. A secondary refuses to guess a zone. |
| Secure DNS transfers | `DNS_TSIG_ENABLED`, `DNS_TSIG_KEY_NAME`, `DNS_TSIG_KEY_FILE`, legacy `DNS_TRANSFER_*` | TSIG is the default for BIND/Technitium pairs. Distribute the protected key manually or set `DNS_TSIG_PROVISION=ssh` with verified SSH trust. Never commit or log the secret. |
| Dynamic updates | `DNS_DYNAMIC_UPDATE_MODE`, `DNS_DYNAMIC_UPDATE_NETWORKS`, `TECHNITIUM_UPDATE_NETWORKS`, `BIND_ALLOW_UPDATE_ACL` | `disabled` is safest. BIND secure uses TSIG `update-policy`; BIND insecure uses the named ACL reference; Technitium secure/insecure uses its native source ACL; integrated insecure mode is rejected. |
| BIND strategy | `BIND_CONFIG_MODE`, `BIND_ZONE_FILE_MODE`, `BIND_NATIVE_ZONE_CONFIG_FILE`, `BIND_NATIVE_ZONE_DIR` | Native mode uses the distribution/Webmin-compatible zone layout; managed-include preserves the legacy dedicated include. Zone data path is selected independently. |
| Technitium API | `TECHNITIUM_API_URL`, `TECHNITIUM_API_TOKEN[_FILE]`, `TECHNITIUM_API_CA_FILE`, installer variables | API calls require HTTPS, Bearer/login authentication, and TLS verification. The official installer is version-discovered and requires a SHA-256 pin. |
| Usually change | `DNS_FORWARDERS`, `DNS_RECURSION_NETWORKS`, `DNS_VALIDATION_SERVER` | Use the organisation's resolvers and trusted recursion networks. Set`DNS_FORWARDERS=""` when forwarding must remain unset. `DNS_VALIDATION_SERVER` is useful for an existing external DNS service. |
| Optional | `WEBMIN_PORT`, `WEBMIN_CONFIG_FILE`, `WEBMIN_PEER_*` | Validate the local listener and use the same port for firewalld. Peer values document the manual Webmin cluster registration; the bootstrap does not initialize Webmin or edit its internal cluster state. The default is TCP 10000. |
| Usually change | `NTP_SERVERS` | Set a whitespace-separated list of approved time sources, or leave it empty to preserve the host's current time configuration. |
| Choose CA mode | `IPA_SETUP_CA`, `IPA_DIRSRV_CERT_FILES`, `IPA_HTTP_CERT_FILES`, `IPA_CA_CERT_FILES`, `IPA_PKINIT_CERT_FILES` | `IPA_SETUP_CA=true` uses the integrated Dogtag CA. Set it to false only for a new CA-less server and provide the external LDAP/HTTP certificate files; the CA-file and PKINIT-file lists are optional when the supplied bundles already contain the required chain or PKINIT is not being supplied. |
| Optional | `IPA_REALM`, `IPA_SETUP_KRA`, `SERVER_FQDN`, `MANAGE_HOSTNAME`, `CONFIGURE_SERVER_MKHOMEDIR` | The realm defaults to uppercase `IPA_DOMAIN`; KRA and host login/hostname changes are opt-in. A healthy pre-existing FreeIPA server's hostname is never changed. Legacy hostname variables remain accepted. |
| Normally keep | `IPA_INSTALL_MAX_ATTEMPTS`, resource thresholds, state/log paths | Change only to match an approved platform standard. The retry value counts total install attempts, not retries after the first attempt. |

### Quick Deployment Path

1. Provision a clean supported RHEL-family host with a static IPv4 address, a permanent lowercase FQDN, working
   repositories, healthy time synchronization, and SELinux enabled.
2. Copy `../../examples/freeipa/freeipa.env.example` to `.env`, replace the environment-specific values, protect it
   with `chmod 600`, and choose the FreeIPA and DNS roles before the first installation. Use the primary example first;
   install the replica only after
   source DNS, time, firewall, and the protected transfer key are ready.
3. Run `./install.sh --check`, review the read-only result, then run `./install.sh --dry-run` and review the plan. For
   managed BIND/Webmin, confirm the intended `WEBMIN_PORT`, management-network policy, reverse-zone list, and TSIG
   distribution.
4. For `DNS_PROVIDER=existing`, publish the server A record and each required reverse PTR before installation. For
   managed BIND, confirm the local resolver can use the BIND service that the provider will configure.
5. Run `./install.sh` as root. The primary uses `ipa-server-install`; the replica uses `ipa-replica-install` and
   captures the installed version's external-DNS records.
6. Confirm BIND primary/secondary SOA and NS convergence, then register the Webmin peer manually if required. For
   existing external DNS, publish the captured records and rerun `./install.sh --check` to complete final validation.

## Prerequisites

### Operating System

Prepare a clean supported RHEL-family host with root access and enabled distribution repositories. Do not install
FreeIPA over a pre-existing customized DNS, Kerberos, HTTP, Directory Server, or partial FreeIPA configuration.

The package manager must be dnf or yum. The bootstrap installs direct dependencies through that manager and relies on
the distribution to resolve the remaining FreeIPA dependencies.

### Hostname

FreeIPA requires a permanent FQDN. Set the requested value in IPA_HOSTNAME.

With the default CONFIGURE_HOSTNAME=false, the current hostname must already match IPA_HOSTNAME; the bootstrap does not
change it. With CONFIGURE_HOSTNAME=true, hostnamectl set-hostname is used on a normal run, and the result is validated
before installation. Dry-run and check modes never change the hostname.

When a healthy FreeIPA installation is discovered before the run, the bootstrap never changes its hostname, even if
CONFIGURE_HOSTNAME=true. It validates the existing value and stops if it does not match the requested configuration.

The requested hostname must be below IPA_DOMAIN, and IPA_IP_ADDRESS must be assigned to a local IPv4 interface. Static
network interface configuration is outside this bootstrap.

### Network

IPv4 is required. The bootstrap validates the requested address, local interface assignment, local hostname resolution,
/etc/hosts consistency when an entry is present, resolver configuration, and required service ports.

Do not add a second IP address or reconfigure arbitrary interfaces as part of this task. If the host has multiple
interfaces, verify which address FreeIPA should advertise before running the installer.

For a replica, the source FQDN must resolve before the run and the source must be reachable for the
FreeIPA/LDAP/Kerberos/HTTPS checks used by `ipa-replica-conncheck` and the installer. Confirm TCP 443, 389, 636, 88, and
464 between the replica and source, plus the approved time sources. The installer also validates the configured domain
and realm; do not install a replica with a different DNS suffix or realm from the source.

### DNS

The resolver configuration must contain at least one nameserver. Before installing external-DNS mode, the host must be
able to use the server A record and the PTR in each authoritative reverse zone required by the selected provider. In
managed BIND mode, the primary creates and validates prerequisites locally and the secondary waits for transfers; the
target's resolver still needs to be designed so the FreeIPA installer can complete its own hostname checks. The
remaining FreeIPA SRV/TXT records are captured from the installer after installation.

For an existing DNS provider, create and delegate the IPA forward zone and every required reverse zone before the
install. Publish one A record for each server FQDN and one PTR mapping each server IP to its FQDN. Do not create a PTR
for ipa-ca; publish the remaining installer-generated records after FreeIPA succeeds.

### Time Synchronisation

Kerberos requires a healthy clock. By default, an empty NTP_SERVERS leaves the existing system time configuration
untouched and validates chrony, timedatectl, or ntpq status. When NTP_SERVERS contains values, the bootstrap installs
chrony if required, replaces only its own marked configuration block, enables chronyd, and validates sources and
synchronization. FreeIPA is always invoked with `--no-ntp` so the installer does not overwrite this decision.

Use multiple servers as a whitespace-separated list:

```dotenv
NTP_SERVERS="192.0.2.11 192.0.2.12"
```

### Firewall

If firewalld is installed and active, the bootstrap discovers the active firewalld zones and adds the FreeIPA services
and DNS service when DNS is integrated or managed by local BIND. It prefers distribution service definitions and falls
back to the documented FreeIPA/DNS ports when a service definition is unavailable. It does not enable an inactive
firewall.

If firewalld is installed but inactive, the bootstrap reports that state and skips firewall changes. It does not enable
or install a firewall. Webmin access is only converged in managed BIND/Webmin mode when firewalld is already active.

#### Technitium automatic firewall integration

Technitium firewall handling is mandatory and automatic; there is no separate
firewall enable/disable variable. When `DNS_BACKEND=technitium` is selected and
firewalld or UFW is actually active, the bootstrap inspects the current rules
and adds only missing rules. An installed-but-inactive firewall remains
inactive, and no unsupported or inactive firewall is enabled merely because
Technitium is selected.

The Technitium port plan is obtained from the installed server's documented
`/api/settings/get` response; DHCP exposure is derived from enabled scopes in
`/api/dhcp/scopes/list`. On Linux, optional Web and encrypted-DNS ports are
also compared with non-loopback listeners from `ss -lntup` when `ss` is
available. A localhost-only Web Console is therefore not exposed. The defaults
below are documentation defaults, not hard-coded assumptions: the configured
API port values are used.

| Function | Default port | Open condition |
| --- | --- | --- |
| DNS | UDP 53 | Technitium DNS is selected |
| DNS | TCP 53 | Technitium DNS is selected; also supports TCP DNS and AXFR/IXFR/NOTIFY |
| Web HTTP | TCP 5380 | Remote Web Console HTTP is configured and externally listening |
| Web HTTPS | TCP 53443 | Remote Web Console TLS is enabled, or cluster mode requires the Web HTTPS endpoint |
| Web HTTP/3 | UDP 53443 | Web Console HTTP/3 is enabled and externally listening |
| DoT | TCP 853 | DNS-over-TLS is enabled and externally listening |
| DoQ | UDP 853 | DNS-over-QUIC is enabled and externally listening |
| DoH | TCP 443 | DNS-over-HTTPS is enabled and not Unix-socket-only |
| DoH HTTP/3 | UDP 443 | DNS-over-HTTPS HTTP/3 is enabled and externally listening |
| DNS-over-HTTP | TCP 80 | DNS-over-HTTP is enabled and not Unix-socket-only |
| DHCP | UDP 67 | At least one Technitium DHCP scope is enabled |

DHCP is not opened merely because the package is installed. For primary,
secondary, and three-node DNS topologies, conventional zone transfer remains
the DNS protocol path: TCP/UDP 53 carries normal DNS and TCP-based
AXFR/IXFR/NOTIFY. `TECHNITIUM_ZONE_TRANSFER_PROTOCOL=Tls` adds the configured
XFR-over-TLS TCP port (normally 853), while `Quic` adds the configured
XFR-over-QUIC UDP port (normally 853); no arbitrary AXFR/IXFR/NOTIFY port is
invented. Technitium's zone/API ACL remains the transfer authorization
boundary.

Technitium v14+ cluster nodes use the supported Web HTTPS node URL. There is no
additional undocumented cluster port to open; when the API reports
`clusterInitialized=true`, the configured Web TLS port is included. If that
same port is deliberately exposed as a general Web administration endpoint,
the firewall cannot distinguish the two uses at the port level, so the existing
Web access policy remains authoritative.

Set `TECHNITIUM_DNS_CLIENT_NETWORKS` when client-facing DNS should be source
restricted. The bootstrap then creates UFW source rules or firewalld IPv4 rich
rules for the configured client networks and the `DNS_NODES[]` topology derived
from `DNS_PRIMARY_*`, `DNS_SECONDARY_*`, and `DNS_ADDITIONAL_NODES`. Leave it
empty to retain the existing firewall zone/interface policy for DNS. This is
the same topology used by the DNS provider; no separate hard-coded peer list is
created.

UFW source rules created by this project use the
`freeipa-bootstrap-technitium` comment. firewalld source rules are recorded in
`$IPA_STATE_DIR/technitium-firewall.rules`. Existing administrator rules are
preserved. On a rerun, only rules with that comment or recorded metadata are
eligible for removal when a feature or peer is no longer present. The IP update
utility invokes the same reconciliation for an active supported firewall after
the local Technitium primary address changes, so old peer-specific rules are
removed only when they were created and tracked by this bootstrap.

The implementation follows the
[official Technitium API documentation](https://raw.githubusercontent.com/TechnitiumSoftware/DnsServer/master/APIDOCS.md),
the [official Technitium README](https://raw.githubusercontent.com/TechnitiumSoftware/DnsServer/master/README.md),
and the [official Linux installer](https://github.com/TechnitiumSoftware/DnsServer/blob/master/DnsServerApp/install.sh).

### SELinux

SELinux is not disabled, set permissive, or otherwise weakened by the bootstrap. Enforcing is the expected production
state. A pre-existing permissive state is reported as a warning; a disabled state fails preflight so it can be corrected
through the platform baseline.

### Resource Requirements

Default preflight thresholds are:

- 2 vCPU
- 4096 MiB RAM
- 10240 MiB free on /var

These are configurable through IPA_MIN_VCPU, IPA_MIN_MEMORY_MB, and IPA_MIN_FREE_DISK_MB. Size production deployments
according to user count, replication, certificate workload, and backup retention; the bootstrap thresholds are not a
capacity plan.

## Package Contents / Repository Structure

```text
VERSION                            Canonical project version
CHANGELOG.md                       Release notes and current baseline
install.sh                         Entry point and orchestration
../../examples/freeipa/             Safe configuration examples
lib/common.sh                      Validation, redaction, and safe file helpers
lib/env.sh                         .env precedence and configuration validation
lib/topology.sh                    FreeIPA/DNS primary-secondary topology validation
lib/logging.sh                     Structured root-only logging
lib/state.sh                       Root-only run state and backup records
lib/packages.sh                    Native package-manager operations
lib/preflight.sh                   OS, host, resource, DNS, port, firewall, SELinux checks
lib/hostname.sh                    Optional hostname configuration
lib/ntp.sh                         Chrony block management and time validation
lib/firewall.sh                    Firewalld service/port configuration
lib/freeipa.sh                     Installer options, retry, CA/KRA detection, and defaults
lib/validation.sh                  Post-install validation and summary
dns/provider.sh                    DNS contract, records, and provider selection
dns/providers/bind9-webmin/        BIND/Webmin implementation
dns/providers/existing/            Read-only external DNS implementation
dns/providers/technitium/          Technitium API/installer implementation
update-server-ip.sh                Backend-aware transactional address update
scripts/lint-docs.sh               Complete Markdown documentation lint entry point
generated/                         Generated DNS output directory
../../tests/freeipa-bootstrap/      Dependency-free tests
```

## Configuration

### Configuration File

Copy `../../examples/freeipa/primary.env.example` or `../../examples/freeipa/secondary.env.example` to `.env` in the
package directory. The loader accepts simple
KEY=value, single-quoted, or double-quoted values and does not execute the file as shell code. Existing exported
environment variables win over .env values. The actual .env must be a regular non-symlink file with no group or other
permissions. `../../examples/freeipa/freeipa.env.example` remains a backward-compatible single-host template.

### Secret Handling

The normal primary secrets are `IPA_DIRECTORY_MANAGER_PASSWORD` and `IPA_ADMIN_PASSWORD`. A normal replica needs only
`IPA_ADMIN_PASSWORD`; Directory Manager credentials are requested only for a primary or an explicitly requested KRA.
Normal execution uses exported values first, then .env, then a hidden interactive prompt. Check and dry-run modes do not
prompt or need the passwords because they do not execute the installer; normal non-interactive execution fails if a
required secret is absent.

Passwords are not printed, stored in /var/lib/freeipa-bootstrap, written to generated DNS files, or included in
structured logs. The underlying FreeIPA commands require password arguments for unattended operation. Those arguments
are kept in Bash arrays, never reconstructed from shell text, and never printed. The values can still be visible to privileged
process inspection while the installer is running; run the bootstrap on a controlled host and document that exposure in
change records.

### Core FreeIPA Parameters

| Variable | Required | Default | Description | Example |
| --- | --- | --- | --- | --- |
| IPA_DOMAIN | Yes; replace example | example.invalid | LDAP/DNS domain for the new realm | example.invalid |
| IPA_REALM | No | Uppercase IPA_DOMAIN | Kerberos realm; explicit override is supported | EXAMPLE.INVALID |
| SERVER_FQDN | Yes; replace example | ipa01.example.invalid | Permanent FQDN of this server | ipa01.example.invalid |
| IPA_HOSTNAME | Legacy alias | SERVER_FQDN | Compatibility alias for SERVER_FQDN | ipa01.example.invalid |
| IPA_IP_ADDRESS | Yes; replace example | 192.0.2.10 | Local static IPv4 address | 192.0.2.10 |
| IPA_DIRECTORY_MANAGER_PASSWORD | Yes for install | Empty | Directory Manager password; never log or commit | prompted securely |
| IPA_ADMIN_PASSWORD | Yes for install | Empty | FreeIPA admin password; never log or commit | prompted securely |

The example address uses the documentation-only 192.0.2.0/24 range. It must be replaced with the real assigned address.

### FreeIPA Topology Parameters

| Variable | Required | Default | Description | Example |
| --- | --- | --- | --- | --- |
| IPA_SERVER_ROLE | No | primary | `primary` uses `ipa-server-install`; `replica` uses `ipa-replica-install` and never performs role conversion | replica |
| IPA_REPLICA_SOURCE | Replica | Empty | Source FreeIPA server FQDN; it must not equal the local hostname | ipa01.example.invalid |
| IPA_REPLICA_PRINCIPAL | Replica | admin | Supported source-authorized principal used by `ipa-replica-install` and post-install validation | admin |
| IPA_REPLICA_SETUP_CA | Replica when a CA copy is wanted | true | Adds `--setup-ca` so the replica has the source CA topology; KRA remains separate | true |

The normal replica needs `IPA_ADMIN_PASSWORD` and does not prompt for Directory Manager credentials. A primary, or a
replica run that explicitly installs KRA, needs `IPA_DIRECTORY_MANAGER_PASSWORD` as well. The role marker under
`IPA_STATE_DIR` is written only after a new installation has become healthy.

### DNS Parameters

| Variable | Required | Default | Description | Example |
| --- | --- | --- | --- | --- |
| DNS_BACKEND | No | bind9_webmin | Exactly one of integrated, bind9_webmin, technitium, existing | technitium |
| IPA_DNS_MODE/DNS_PROVIDER | Legacy | external/bind9-webmin | Compatibility pair normalized to DNS_BACKEND | external/bind9-webmin |
| DNS_FORWARDERS | No | 192.0.2.53 192.0.2.54 | Whitespace-separated forwarders for integrated/BIND/Technitium | 192.0.2.53 192.0.2.54 |
| DNS_RECURSION_NETWORKS | BIND provider | 127.0.0.0/8 | IPv4 CIDRs allowed to recurse; never use any | 127.0.0.0/8 192.0.2.0/24 |
| DNS_VALIDATION_SERVER | No | Empty | Resolver address for existing-DNS checks; empty uses system resolver | 192.0.2.53 |
| DNS_TTL | No | 86400 | TTL used in managed BIND zones and the pre-install prerequisite plan | 3600 |
| DNS_BIND_CONFIG_FILE | BIND provider | /etc/named.conf | Main BIND configuration file | /etc/named.conf |
| DNS_BIND_INCLUDE_FILE | BIND provider | /etc/named/freeipa-bootstrap.conf | Dedicated managed zone include | /etc/named/freeipa-bootstrap.conf |
| DNS_BIND_ZONE_DIR | BIND provider | /var/named/freeipa-bootstrap | Dedicated managed zone directory | /var/named/freeipa-bootstrap |
| DNS_BIND_SLAVE_DIR | BIND secondary | /var/named/slaves | Native BIND slave-file directory; secondary zone files are never locally edited | /var/named/slaves |
| DNS_SERVER_ROLE | BIND provider | primary | Independent DNS role: `primary` or `secondary` | secondary |
| DNS_PRIMARY_SERVER | BIND provider | local IPA FQDN | Authoritative DNS primary FQDN; required explicitly on a secondary | ipa01.example.invalid |
| DNS_PRIMARY_IP | BIND provider | local IPA IPv4 | Authoritative DNS primary IPv4 used for masters/NOTIFY | 192.0.2.10 |
| DNS_SECONDARY_SERVER | Optional pair | Empty | Redundant secondary FQDN; set together with DNS_SECONDARY_IP | ipa02.example.invalid |
| DNS_SECONDARY_IP | Optional pair | Empty | Redundant secondary IPv4 used for NOTIFY and transfer ACLs | 192.0.2.11 |
| DNS_ADDITIONAL_NODES | Optional multi-node | Empty | Whitespace-separated `fqdn=ipv4` entries used by Technitium source-restricted firewall rules | ipa03.example.invalid=192.0.2.12 |
| DNS_AUTHORITATIVE_REVERSE_ZONES | Required on secondary; recommended for pairs | Empty | Whitespace-separated authoritative `in-addr.arpa`/`ip6.arpa` zones; secondary never guesses | 2.0.192.in-addr.arpa |
| DNS_TRANSFER_SECURITY | BIND pair | tsig | `tsig` (recommended) or explicitly approved `none` | tsig |
| DNS_TRANSFER_KEY_NAME | BIND pair | freeipa-bootstrap-transfer | Safe BIND key identifier shared by primary/secondary | freeipa-bootstrap-transfer |
| DNS_TRANSFER_KEY_FILE | BIND pair | /etc/named/freeipa-bootstrap-transfer.key | Protected key include path; distribute the file securely to both hosts | /etc/named/freeipa-bootstrap-transfer.key |
| DNS_TRANSFER_KEY_SECRET | BIND pair | Empty | Optional secret used to create the key; never commit or log it | secret-in-protected-env |
| DNS_TRANSFER_WAIT_SECONDS | BIND secondary | 90 | Maximum wait for SOA/AXFR convergence during validation | 90 |
| DNS_TRANSFER_POLL_SECONDS | BIND secondary | 3 | Poll interval while waiting for NOTIFY/AXFR/IXFR | 3 |
| TECHNITIUM_ZONE_TRANSFER_PROTOCOL | Technitium pair | Tcp | `Tcp`, `Tls`, or `Quic`; selects the protocol used for Technitium zone transfers and its firewall port | Tls |
| TECHNITIUM_DNS_CLIENT_NETWORKS | Technitium firewall | Empty | Optional trusted IPv4 networks for source-restricted DNS 53 rules; topology DNS nodes are added automatically | 192.0.2.0/24 |
| WEBMIN_PORT | BIND/Webmin provider | 10000 | Webmin TCP listener and firewalld port when firewalld is active | 10000 |
| WEBMIN_CONFIG_FILE | BIND/Webmin provider | /etc/webmin/miniserv.conf | Webmin configuration file read for listener validation | /etc/webmin/miniserv.conf |
| WEBMIN_PEER_SERVER/IP | Optional pair | Empty | Peer values for manual Webmin Servers Index/Cluster registration | ipa02.example.invalid / 192.0.2.11 |
| WEBMIN_PEER_PORT | Optional pair | 10000 | Peer Webmin management port; no internal Webmin files are changed | 10000 |

For BIND, `BIND_CONFIG_MODE=native|managed_include` controls where marked zone
declarations are written, while `BIND_ZONE_FILE_MODE=native|custom` controls
the zone data directory. `BIND_ACL_NAME`/`BIND_ACL_NETWORKS` create a marked
named ACL; `BIND_ALLOW_QUERY_ACL`, `BIND_ALLOW_RECURSION_ACL`,
`BIND_ALLOW_UPDATE_ACL`, `BIND_ALLOW_TRANSFER_ACL`, `BIND_ALLOW_NOTIFY_ACL`,
and `BIND_ALLOW_UPDATE_FORWARDING_ACL` are independent optional references.
`DNS_NOTIFY_ENABLED` controls NOTIFY. `DNS_DYNAMIC_UPDATE_MODE` is
`disabled`, `secure`, or `insecure`; secure BIND emits only TSIG
`update-policy`, and insecure BIND requires an explicit update ACL.

For Technitium, use `TECHNITIUM_API_TOKEN` or a private 0600 token file. The
provider uses the documented login/Bearer API, preserves unrelated settings,
and keeps TLS certificate verification enabled.

The default forwarders are documentation-only addresses in 192.0.2.0/24. Replace them with approved resolver addresses
for a real environment. An empty list is accepted for integrated DNS and selects the installer's --no-forwarders
behavior; for BIND, an empty list leaves
forwarding unset and uses the existing/root-hints behavior.

### NTP Parameters

| Variable | Required | Default | Description | Example |
| --- | --- | --- | --- | --- |
| NTP_SERVERS | No | Empty | Whitespace-separated chrony servers; empty retains existing configuration | 192.0.2.11 192.0.2.12 |
| NTP_CHRONY_CONFIG_FILE | No | /etc/chrony.conf | Chrony file receiving the marked block when NTP_SERVERS is set | /etc/chrony.conf |

### PKI / KRA Parameters

| Variable | Required | Default | Description | Example |
| --- | --- | --- | --- | --- |
| IPA_SETUP_CA | No | true | Selects the default integrated Dogtag CA; false selects a new certificate-backed CA-less installation | false |
| IPA_REPLICA_SETUP_CA | Replica | true | Selects `ipa-replica-install --setup-ca`; it is independent from the primary's IPA_SETUP_CA variable | true |
| IPA_SETUP_KRA | No | false | Detects an existing KRA and runs ipa-kra-install only when KRA is absent; requires IPA_SETUP_CA=true | true |
| IPA_DIRSRV_CERT_FILES | When CA-less | Empty | Whitespace-separated absolute files passed as repeated --dirsrv-cert-file options; required when IPA_SETUP_CA=false | /etc/pki/ipa/dirsrv.p12 |
| IPA_HTTP_CERT_FILES | When CA-less | Empty | Whitespace-separated absolute files passed as repeated --http-cert-file options; required when IPA_SETUP_CA=false | /etc/pki/ipa/http.p12 |
| IPA_CA_CERT_FILES | No | Empty | Optional whitespace-separated external CA-chain files passed as repeated --ca-cert-file options | /etc/pki/ipa/issuer-chain.pem |
| IPA_DIRSRV_CERT_PIN | No | Empty | PIN for the Directory Server certificate bundle, redacted from logs | secret |
| IPA_HTTP_CERT_PIN | No | Empty | PIN for the HTTP certificate bundle, redacted from logs | secret |
| IPA_PKINIT_CERT_FILES | No | Empty | Optional whitespace-separated files passed as repeated --pkinit-cert-file options | /etc/pki/ipa/pkinit.p12 |
| IPA_PKINIT_CERT_PIN | No | Empty | PIN for the optional PKINIT certificate bundle, redacted from logs | secret |

### Optional Server Installer Features

| Variable | Required | Default | Description | Example |
| --- | --- | --- | --- | --- |
| IPA_SSH_TRUST_DNS | No | false | Adds --ssh-trust-dns to a new primary or replica installer invocation so OpenSSH trusts IPA DNS SSHFP records | true |
| IPA_SETUP_SUBID | No | false | Adds --subid to a new primary or replica installer invocation so SSSD uses IPA as the subordinate-ID data source | true |

These are first-install options. A healthy existing FreeIPA server is not re-run through ipa-server-install, so changing
either value later does not retroactively modify the server.

Enable IPA_SSH_TRUST_DNS only when the DNS service and its SSHFP records are trusted by the client environment.
IPA_SETUP_SUBID is supported on FreeIPA versions that advertise --subid; the bootstrap fails clearly instead of passing
an unsupported option.

### Login / Home Directory Parameters

| Variable | Required | Default | Description | Example |
| --- | --- | --- | --- | --- |
| IPA_DEFAULT_SHELL | No | /bin/bash | FreeIPA default shell for future user entries; does not create users | /bin/bash |
| IPA_HOME_ROOT | No | /home | FreeIPA home-directory root for future user entries | /home |
| CONFIGURE_SERVER_MKHOMEDIR | No | false | Enables host authselect/oddjobd automatic home creation for local IPA logins | true |

CONFIGURE_SERVER_MKHOMEDIR is host PAM/SSSD behavior. It is separate from IPA_HOME_ROOT, which is a FreeIPA default
attribute for future accounts. Neither setting creates an identity object.

### Retry / Bootstrap Parameters

| Variable | Required | Default | Description | Example |
| --- | --- | --- | --- | --- |
| MANAGE_HOSTNAME | No | false | Whether normal execution may call hostnamectl set-hostname | true |
| CONFIGURE_HOSTNAME | Legacy | MANAGE_HOSTNAME | Compatibility alias for MANAGE_HOSTNAME | true |
| IPA_INSTALL_MAX_ATTEMPTS | No | 2 | Initial FreeIPA install plus at most one retry by default | 2 |
| IPA_MIN_VCPU | No | 2 | Minimum vCPU preflight threshold | 2 |
| IPA_MIN_MEMORY_MB | No | 4096 | Minimum RAM preflight threshold | 4096 |
| IPA_MIN_FREE_DISK_MB | No | 10240 | Minimum free space on /var | 10240 |
| IPA_STATE_DIR | No | /var/lib/freeipa-bootstrap | Root-only run state and backups | /var/lib/freeipa-bootstrap |
| IPA_LOG_DIR | No | /var/log/freeipa-bootstrap | Root-only structured bootstrap logs | /var/log/freeipa-bootstrap |
| IPA_GENERATED_DIR | No | package-directory/generated | Generated external-DNS record output; the example uses ./generated | /var/lib/freeipa-bootstrap/generated |
| WEBMIN_SETUP_REPO_SHA256 | Required before a new Webmin install | Empty | SHA-256 pin for the official Webmin repository setup script | 64 hex characters |

The Webmin repository URL is intentionally fixed in the provider to the official Webmin source. A hash pin is required
before the script can be executed, including in controlled environments. The bootstrap does not rewrite an existing
Webmin listener to match
`WEBMIN_PORT`; a mismatch fails validation so an operator can review the management-plane design safely.

## Example Configuration

### Integrated DNS Example

```dotenv
IPA_DOMAIN=example.invalid
IPA_REALM=EXAMPLE.INVALID
IPA_HOSTNAME=ipa01.example.invalid
IPA_IP_ADDRESS=192.0.2.10
IPA_DIRECTORY_MANAGER_PASSWORD=
IPA_ADMIN_PASSWORD=
IPA_SETUP_CA=true
IPA_SETUP_KRA=false
IPA_DNS_MODE=integrated
DNS_FORWARDERS="192.0.2.53 192.0.2.54"
NTP_SERVERS="192.0.2.11 192.0.2.12"
```

The parent DNS environment must delegate or otherwise route the IPA domain to the new server as appropriate for the
organisation's DNS design.

### BIND and Webmin Example

```dotenv
IPA_DOMAIN=example.invalid
IPA_REALM=EXAMPLE.INVALID
IPA_HOSTNAME=ipa01.example.invalid
IPA_IP_ADDRESS=192.0.2.10
IPA_DIRECTORY_MANAGER_PASSWORD=
IPA_ADMIN_PASSWORD=
IPA_SETUP_CA=true
IPA_DNS_MODE=external
DNS_PROVIDER=bind9-webmin
DNS_FORWARDERS="192.0.2.53 192.0.2.54"
DNS_RECURSION_NETWORKS="127.0.0.0/8 192.0.2.0/24"
```

The recursion network example is documentation-only. Replace it with the actual trusted internal networks. Do not use
allow-recursion { any; };.

### Existing DNS Example

```dotenv
IPA_DOMAIN=example.invalid
IPA_REALM=EXAMPLE.INVALID
IPA_HOSTNAME=ipa01.example.invalid
IPA_IP_ADDRESS=192.0.2.10
IPA_DIRECTORY_MANAGER_PASSWORD=
IPA_ADMIN_PASSWORD=
IPA_DNS_MODE=external
DNS_PROVIDER=existing
DNS_VALIDATION_SERVER=192.0.2.53
```

Create the external zone, each server A record, and each configured authoritative reverse PTR before the install. The
provider produces a human-readable prerequisite plan and stops if the resolver does not return those values. After
installation, publish the preserved version-specific FreeIPA records and rerun `./install.sh --check`.

## Installation Procedure

### Step 1 - Prepare the Server

1. Provision a clean supported RHEL-family host with a static IPv4 address.
2. Set a permanent FQDN or decide that the bootstrap may set it with CONFIGURE_HOSTNAME=true.
3. Enable distribution repositories that contain ipa-server and, for integrated DNS, ipa-server-dns.
4. Confirm that no standalone 389 Directory Server, unbound, Kerberos, HTTP, or partial FreeIPA installation conflicts
   with the selected scenario. An existing named service is permitted only for the managed BIND provider and is still
   subject to configuration/zone ownership checks.
5. Confirm resolver, reverse DNS, time synchronization, firewall, and SELinux prerequisites.
6. For existing DNS, create the forward zone and every configured authoritative reverse zone and publish only the server
   A/PTR prerequisites before proceeding. The remaining FreeIPA SRV/TXT records are published after the installer
   captures them.

### Step 2 - Create the Environment File

```bash
cp ../../examples/freeipa/freeipa.env.example .env
chmod 600 .env
chown root:root .env
vi .env
chmod +x ./install.sh
```

Replace the documentation domain, hostname, and IP address. When running as root, keep `.env` root-owned as well as
mode 0600. Do not place real passwords in this article or in committed files.

### Step 3 - Run Preflight Checks

```bash
./install.sh --check
```

This mode is read-only. It detects the OS, architecture, package manager, CPU/RAM/disk, hostname and IP, resolver, DNS
state, required ports, firewall state, SELinux state, existing FreeIPA/Directory Server conflicts, and .env permissions.
With an existing DNS provider it also performs read-only DNS validation.

`dig` is required for the DNS checks performed by `--check`; `chronyc` may be absent when another supported
time-synchronization status command is authoritative. Install any missing utility reported by the check, or proceed with
normal execution, which installs bootstrap-owned prerequisites through the native package manager.

### Step 4 - Run Dry-Run

```bash
./install.sh --dry-run
```

Review the plan for:

- selected DNS mode and provider
- direct packages to be installed
- BIND and Webmin actions, if selected
- FreeIPA installer mode and repeated forwarders
- forward and reverse zones and records
- firewall behavior
- chrony and hostname behavior
- selected CA mode and CA-less certificate files, if applicable
- SSH trust DNS and subid installer options
- optional KRA and its existing-installation detection
- state and log locations

Dry-run does not create state, logs, generated files, packages, services, firewall rules, DNS records, or system
configuration.

### Step 5 - Install

```bash
./install.sh
```

If a required password was not exported or provided in .env, normal interactive execution prompts without echoing it.
The bootstrap then:

1. installs direct prerequisites with dnf or yum
2. optionally configures hostname and chrony
3. prepares and validates the selected DNS provider
4. configures active firewalld without enabling an inactive firewall
5. installs FreeIPA packages
6. runs ipa-server-install with the default integrated CA, or with the configured external LDAP/HTTP certificates for
   CA-less mode, plus the selected SSH trust DNS/subid options
7. performs the controlled reverse-zone or external-DNS record step
8. optionally installs KRA
9. applies future-user shell/home defaults
10. optionally enables server mkhomedir
11. runs full validation and prints a summary

### Step 6 - Validate

Use commands appropriate to the target:

```bash
ipactl status
kinit admin
klist
ipa server-show "$(hostname -f)"
# Run this only when IPA_SETUP_CA=true:
ipa ca-show ipa
```

If KRA is enabled:

```bash
ipa vaultconfig-show
```

DNS examples:

```bash
dig A ipa01.example.invalid
dig A ipa-ca.example.invalid
dig SRV _ldap._tcp.example.invalid
dig SRV _kerberos._tcp.example.invalid
dig SRV _kpasswd._tcp.example.invalid
dig -x 192.0.2.10
```

For integrated DNS, query the FreeIPA server directly if the surrounding resolver is not yet delegated:

```bash
dig @192.0.2.10 SRV _ldap._tcp.example.invalid
```

For managed BIND, also run:

```bash
named-checkconf /etc/named.conf
named-checkzone example.invalid /var/named/freeipa-bootstrap/example.invalid
named-checkzone 2.0.192.in-addr.arpa /var/named/freeipa-bootstrap/2.0.192.in-addr.arpa.zone
```

Time validation:

```bash
chronyc tracking
chronyc sources -n
```

## What the Installer Changes

### Packages

The bootstrap installs only direct dependencies it owns:

- bind-utils, curl, and ca-certificates for DNS and validation
- chrony when NTP_SERVERS is non-empty
- authselect, oddjob, and oddjob-mkhomedir when server mkhomedir is enabled
- ipa-server for all installations
- ipa-server-dns for integrated DNS
- bind and bind-utils for bind9-webmin
- webmin from the official Webmin repository for bind9-webmin

The native package manager resolves FreeIPA component dependencies. The bootstrap does not add a third-party FreeIPA
repository.

### Services

Depending on configuration, the bootstrap may enable or start chronyd, named, webmin, and oddjobd. FreeIPA services are
managed by ipa-server-install and validated with ipactl status. An existing Webmin installation is preserved; its
configuration, active service, and actual listener are validated instead of being reinstalled.

An already active BIND service is reloaded after safe configuration validation rather than restarted. A newly installed
or inactive BIND service is enabled and started.

### DNS resources

Integrated mode lets FreeIPA manage its forward zone and then adds one explicitly calculated reverse `/24` zone. In
external BIND primary mode, the provider writes only its dedicated include and marked managed zone files, configures
both DNS transport protocols on port 53, and preserves native `/etc/named.conf` ownership outside its marked blocks. In
BIND secondary mode, it writes only the zone declarations/key include and prepares the native slave directory; it never
creates or edits transferred slave data. Existing mode writes no external DNS data; it preserves the installer-generated
record file for the DNS administrator.

### Firewall resources

An active firewalld receives FreeIPA service definitions and DNS access when the selected design provides DNS locally.
If a service definition is unavailable, the bootstrap uses the required FreeIPA/DNS port list, including TCP/UDP 53 so
ordinary queries and AXFR/IXFR are both possible. For `DNS_PROVIDER=bind9-webmin`, it also converges `WEBMIN_PORT`
(default TCP 10000) in both the permanent and runtime rules after validating the real Webmin listener. For
`DNS_BACKEND=technitium`, active firewalld or UFW is converged automatically from the Technitium API feature settings;
optional Web, DoT, DoQ, DoH, DNS-over-HTTP, and DHCP ports are opened only when enabled and externally listening, while
source-restricted DNS rules use `DNS_NODES[]`. Existing rules are inspected and preserved, and only installer-marked
Technitium source rules are eligible for cleanup. It does not enable firewalld/UFW, install a firewall, change default
policies, or change SSH policy.

### NTP

With configured NTP_SERVERS, the bootstrap creates a backup under the run state directory and replaces only the marked
block in NTP_CHRONY_CONFIG_FILE. With an empty list, it leaves the file untouched and validates the existing time
service. In both cases it passes `--no-ntp` to the selected primary or replica FreeIPA installer so FreeIPA does not
take over NTP configuration.

### FreeIPA

The FreeIPA installer command is constructed as a Bash array. A primary includes hostname, domain, realm, local IPv4
address, unattended mode, Directory Manager password, admin password, DNS mode, and any explicitly enabled SSH trust DNS
or subid options. A replica uses `ipa-replica-install` with the source FQDN, supported principal/admin password,
`--no-ntp`, and `--setup-ca` when requested; it does not call `ipa-server-install`. The selected installer help output
is checked on the target; unsupported or unexpected option surfaces cause a clear failure instead of guessing.

The primary installation uses the platform's default integrated CA behavior when IPA_SETUP_CA=true. When
IPA_SETUP_CA=false, the bootstrap selects the platform's CA-less certificate mode by passing the configured
--dirsrv-cert-file and --http-cert-file values, optional --ca-cert-file chain values, and optional certificate PINs. The
installer help is checked before these options are used. CA-less mode is intended for a new server and does not install
Dogtag, certmonger-managed IPA certificates, or KRA; it requires externally issued LDAP and HTTP server certificates. A
healthy existing CA is preserved rather than removed when the setting is changed on a rerun.

### State Files

Normal runs create a root-only run directory under:

```text
/var/lib/freeipa-bootstrap/runs/RUN_ID/
```

State records include the run ID, pre-existing resource classifications, installation attempt, whether the current run
started/completed FreeIPA, backup paths, generated DNS record path, the raw `ipa dns-update-system-records` capture when
used, and ownership markers. Passwords are never stored.

### Logs

Normal runs create a root-only structured log under:

```text
/var/log/freeipa-bootstrap/RUN_ID.log
```

Operational child-command stdout and stderr are streamed to the same console while the command runs and are also
retained in the per-run bootstrap log. Native tool output is kept readable, while the bootstrap's structured stage and
command messages remain timestamped. The platform FreeIPA installer log remains at the location reported by the
installed package, normally /var/log/ipaserver-install.log. Per-attempt stdout/stderr is also kept root-only under the
run state directory. Failure messages reference these paths without echoing secret-bearing commands. If the SSH session
ends, review `/var/log/freeipa-bootstrap/RUN_ID.log`, `/var/lib/freeipa-bootstrap/runs/RUN_ID/`, and
`/var/log/ipaserver-install.log` on the target.

## DNS Configuration

### Forward Zone

Before external-mode installation, only these prerequisites are required on the authoritative primary:

```text
ipa01.example.invalid.                 A       configured server IP
2.0.192.in-addr.arpa.            PTR     ipa01.example.invalid.
```

The remaining SRV/TXT/A records are generated by the installed FreeIPA version. After FreeIPA runs, the version-specific
record output is the authoritative full record set. Managed BIND imports supported records from it on the primary; a
secondary validates the transferred result without editing its slave file. Existing DNS validates it without writing.

### Reverse Zone

The managed primary may derive one reverse zone from the local IPv4 address for backward-compatible single-server
operation. For a redundant pair, set `DNS_AUTHORITATIVE_REVERSE_ZONES` to every authoritative reverse zone on both
hosts; this can contain multiple IPv4 zones and explicit IPv6 reverse zones, although `update-server-ip.sh` performs
IPv4 address changes only. A secondary refuses to invent a zone from its local address. For example:

```text
192.0.2.10 -> 2.0.192.in-addr.arpa.
```

The zone contains a PTR for the final octet:

```text
2.0.192.in-addr.arpa. PTR ipa01.example.invalid.
```

Any zone omitted from the explicit list remains outside this provider's ownership. The secondary receives configured
zones by AXFR/IXFR and never writes the `/var/named/slaves` data directly.

### Required FreeIPA Records

The FreeIPA external-DNS output is required after external-mode installation because record requirements can vary by
installed FreeIPA version. Before installation, only the server A and configured reverse-zone PTR prerequisites are
validated. After installation, the implementation imports or validates supported A, AAAA, CNAME, PTR, SRV, TXT, and URI
records that appear in the legacy installer file or the normalized output of
`ipa dns-update-system-records --dry-run --out`; it does not require a hardcoded SRV/TXT list before the installer runs.

Do not add a PTR for ipa-ca. FreeIPA's external-DNS guidance warns that an ipa-ca PTR can interfere with later replica
installation.

### Public DNS Forwarding

Integrated DNS and managed BIND use DNS_FORWARDERS. Multiple values become repeated FreeIPA --forwarder options or a
BIND forwarders statement. The default values are:

```text
192.0.2.53
192.0.2.54
```

In managed BIND, forward only is used when forwarders are configured. If no forwarders are configured, the provider does
not invent them.

### BIND Recursion Behaviour

Managed BIND adds allow-recursion using DNS_RECURSION_NETWORKS. The default is loopback only. It never writes an
unrestricted recursion policy. Add only trusted internal CIDRs. The provider refuses to proceed if it detects an
unmanaged pre-existing policy containing `any`, `0.0.0.0/0`, or `::/0`.

The provider refuses to overwrite unmanaged pre-existing BIND forwarders. Review and reconcile an existing configuration
manually, or provide a clean host/dedicated configuration that can safely be managed.

### BIND Primary/Secondary Transfers

The primary's managed include contains one `type master` declaration per forward/reverse zone. With
`DNS_TRANSFER_SECURITY=tsig`, it adds `allow-transfer { key <DNS_TRANSFER_KEY_NAME>; };`, `notify yes`, and
`also-notify { <DNS_SECONDARY_IP>; };`. With the explicitly approved `DNS_TRANSFER_SECURITY=none`, the transfer ACL is
restricted to the configured secondary IP rather than opened globally. The protected key file is included from the main
configuration and is mode 0640 or stricter.

The secondary's managed include contains the same zones as `type slave`, a file path under `DNS_BIND_SLAVE_DIR`,
`allow-transfer { none; };`, `allow-notify` restricted to the primary, and a `masters` clause containing the primary
address and TSIG key when enabled. No zone file is created by the bootstrap on the secondary; named creates and updates
transferred files during AXFR/IXFR. A secondary is never treated as converged merely because its include exists:
`--check` and post-install validation compare SOA serials queried from the primary and localhost and verify that the
zone NS answer contains both configured nameservers.

Validate an operational pair from the primary and secondary:

```bash
named-checkconf /etc/named.conf
dig @192.0.2.10 example.invalid SOA +short
dig @192.0.2.11 example.invalid SOA +short
dig @192.0.2.11 example.invalid NS +short
dig @192.0.2.11 -x 192.0.2.10 +short
# Run from the secondary when TSIG is enabled:
dig -k /etc/named/freeipa-bootstrap-transfer.key +tcp @192.0.2.10 example.invalid AXFR
```

The SOA serials must match after NOTIFY/AXFR/IXFR. If they do not, inspect `journalctl -u named`, TSIG key
permissions/contents on both hosts, primary `allow-transfer`/`also-notify`, secondary `masters`/`allow-notify`, TCP and
UDP 53 firewall rules, and the explicit reverse-zone list. Do not edit a slave file to force convergence.

### Webmin Cluster Administration

Webmin is intentionally limited to the administration plane. The BIND provider writes and validates native BIND
configuration and does not click Webmin's initialization action, which can overwrite an existing `named.conf`. To manage
both nodes from one Webmin instance, open **Webmin Servers Index** or **Cluster Webmin Servers**, add the peer
FQDN/port, and use credentials approved for the environment. `WEBMIN_PEER_SERVER`, `WEBMIN_PEER_IP`, `WEBMIN_PEER_PORT`,
`WEBMIN_PEER_USERNAME`, and `WEBMIN_PEER_PASSWORD` parameterize the documented manual action; they do not cause the
bootstrap to edit undocumented Webmin files or invoke a private API.

### Address-only DNS Update

`update-server-ip.sh` is for a server whose hostname and FreeIPA identity remain unchanged while its managed
authoritative address changes. It is deliberately narrower than an OS network migration:

```bash
./update-server-ip.sh --check --new-ip 192.0.2.20
./update-server-ip.sh --dry-run --new-ip 192.0.2.20
./update-server-ip.sh --new-ip 192.0.2.20
```

The utility loads the same `.env` as `install.sh` and dispatches by
`DNS_BACKEND`:

- BIND validates and edits only marked managed A/PTR records, increments SOA
  serials, validates `named-checkconf`/`named-checkzone`, reloads named, and
  checks local/secondary convergence.
- FreeIPA integrated DNS authenticates with Kerberos and uses the supported
  `ipa dnsrecord-mod` plus `ipa dnsrecord-del/add` operations. It does not edit
  LDAP-backed DNS files and relies on FreeIPA replication for other servers.
- Technitium requires the local authoritative primary and uses the authenticated
  `/api/zones/records/update` operation with the existing PTR update flag; it
  does not edit Technitium files or a secondary. If an active firewalld or UFW
  is present, it then re-converges the installer-managed source rules from the
  updated `DNS_NODES[]` topology and removes only positively identified stale
  peer rules.

All backends require a healthy FreeIPA installation, preserve the hostname,
check duplicate/conflicting mappings and explicit reverse-zone coverage, update
the shared `IPA_IP_ADDRESS` and local `DNS_PRIMARY_IP` assignments, and attempt
backend-specific rollback if a mutation or post-validation check fails. The
operating-system interface migration remains a separate supported change.

## CA and KRA

### FreeIPA CA

With IPA_SETUP_CA=true, the primary FreeIPA installation uses the distribution-supported integrated CA default.
Validation requires the IPA CA object through ipa ca-show ipa and checks the Web UI over HTTPS using /etc/ipa/ca.crt
rather than disabling TLS verification.

With IPA_SETUP_CA=false, the primary installation uses externally issued LDAP and HTTP certificates. The bootstrap
validates the Web UI with /etc/ipa/ca.crt when the CA-less installer has populated the trusted issuer certificate, but
it skips the integrated IPA CA object check. The external certificate files and any required PINs must already exist on
the target; the bootstrap does not request, renew, or rotate them.

### KRA

KRA is optional:

```dotenv
IPA_SETUP_KRA=false
IPA_SETUP_CA=true
```

When true, the bootstrap first checks ipa vaultconfig-show. If KRA is already configured and healthy, the run logs that
it is skipping ipa-kra-install. If KRA is absent, the bootstrap runs ipa-kra-install independently after the base server
and CA are healthy. KRA cannot be selected with IPA_SETUP_CA=false. A KRA failure is not silently converted into a
KRA-less success; the run fails and the operator must review the KRA log.

### What Is Not Configured by This Bootstrap

The following remain separate day-2 work:

- users, groups, host groups, service accounts, and application principals
- HBAC and sudo policy
- password, lockout, and expiration policy
- certificate profiles and issuance policy
- delegated roles, external trust, or AD trust
- Webmin hardening, ACLs, accounts, network restrictions, or certificate policy
- backup scheduling and restore automation

## Firewall Behaviour

When active, firewalld is configured for the FreeIPA services needed by the installed server: LDAP/LDAPS, Kerberos,
HTTP/HTTPS, and, when locally provided, DNS. If native service definitions are missing, the provider falls back to
TCP/UDP port rules for the same services.

An inactive firewalld remains inactive. The bootstrap never globally disables or enables a firewall. Webmin access
remains subject to the organisation's management-plane policy; only the configured Webmin TCP port is added when
firewalld is already active and the managed BIND/Webmin provider is selected.

## SELinux Behaviour

The bootstrap does not call setenforce 0, disable SELinux, install broad custom policy, or modify unrelated SELinux
settings. It expects the normal RHEL SELinux policy and uses restorecon on managed BIND files when available.

If SELinux is disabled, preflight stops and asks the administrator to correct the host baseline. If it is permissive,
preflight warns but leaves the setting unchanged.

## Home Directory Behaviour

CONFIGURE_SERVER_MKHOMEDIR=true enables the RHEL authselect with-mkhomedir feature and oddjobd so an IPA user logging
into the FreeIPA server can receive a local home directory on first login.

This does not create users and does not set the FreeIPA user's LDAP homeDirectory attribute. IPA_HOME_ROOT controls the
default root for future FreeIPA user entries through ipa config-mod; it is separate from host PAM/SSSD home-directory
creation.

## Idempotency

The bootstrap is designed to be safe to rerun when the target is healthy:

- a healthy ipactl status result is detected and reported as already configured
- FreeIPA is not reinstalled and the realm is not destroyed
- already installed packages are skipped, and an RPM query failure stops rather than being mistaken for an absent
  package
- requested hostname, chrony, future-user defaults, server mkhomedir, and active-firewall rules are applied idempotently
  where enabled
- existing DNS provider mode is validated rather than rewritten in the healthy path
- an existing-DNS post-install record publication gap is reported as pending manual work, not treated as a reason to
  reinstall or uninstall FreeIPA
- the provider uses a dedicated BIND include and marked configuration/zone files
- chrony replaces only its own marked block
- Webmin's existing configuration and listener are validated without rewriting it
- firewalld uses idempotent permanent/runtime service and port additions and reloads only after a change

If a healthy installation does not match the requested hostname, domain, realm, or DNS design, validation fails for
operator review. The bootstrap does not force a destructive reconciliation.

## Installation Retry Behaviour

IPA_INSTALL_MAX_ATTEMPTS=2 means one initial attempt and one automatic retry. On a failed attempt the bootstrap:

1. records the attempt and failure log
2. re-detects FreeIPA state
3. checks that no FreeIPA configuration existed at the start
4. calls the supported ipa-server-install --uninstall --unattended process when the current run created a partial
   installation
5. confirms the target is clean enough to retry
6. retries while attempts remain

If FreeIPA was healthy or partial before the run, automatic uninstall is blocked. If supported uninstall does not leave
an absent state, retry stops. The bootstrap never guesses by deleting /etc/ipa, /var/lib/ipa, Directory Server data, or
arbitrary configuration files.

When DNS_PROVIDER=existing, a successful FreeIPA installation is not retried or uninstalled because an administrator has
not yet published the captured system-record file. The run reports the pending DNS status, preserves the file, and
directs the operator to publish it and rerun `./install.sh --check`.

## Rollback and Safety Boundaries

Rollback ownership is conservative:

- only a current-run partial FreeIPA installation may be automatically uninstalled
- pre-existing BIND, Webmin, DNS zones, records, packages, and unrelated configuration are not automatically removed
- modified chrony and BIND files receive root-only backups recorded in run state
- generated DNS record files are preserved for diagnosis
- provider-created DNS artifacts are not automatically deleted on a FreeIPA failure

Leaving a diagnosed partial state is safer than destructive recovery based on assumptions. Review the state directory,
bootstrap log, platform FreeIPA installer log, and provider configuration before manual recovery.

## Validation

### FreeIPA Validation

The installer validates service health through ipactl status and CLI operation through ipa ping. It also checks the IPA
server object and, when IPA_SETUP_CA=true, the integrated CA. CA-less mode validates the supplied certificate-backed Web
UI trust instead.

```bash
ipactl status
ipa ping
ipa server-show "$(hostname -f)"
ipa topologysegment-find
# Run this only when IPA_SETUP_CA=true:
ipa ca-show ipa
```

On a replica, also confirm the source server object and the replication segment:

```bash
ipa server-show ipa01.example.invalid
ipa server-show ipa02.example.invalid
ipa topologysegment-find
```

The result must show both servers in the intended topology. A CA replica is validated separately from KRA; use
`ipa ca-show ipa` only when `IPA_REPLICA_SETUP_CA=true` or the primary CA is enabled.

### Kerberos Validation

```bash
kinit admin
klist
```

The bootstrap obtains an admin ticket through a root-only temporary credential cache during normal validation. It never
prints the password.

### LDAP Validation

ipa server-show "$(hostname -f)" exercises the authenticated IPA CLI and LDAP/API path. Use standard LDAP diagnostics
for deeper protocol investigation; do not put Directory Manager passwords on command lines.

### DNS Validation

```bash
dig A ipa01.example.invalid
dig A ipa-ca.example.invalid
dig SRV _ldap._tcp.example.invalid
dig SRV _kerberos._tcp.example.invalid
dig SRV _kpasswd._tcp.example.invalid
dig -x 192.0.2.10
```

For managed BIND:

```bash
named-checkconf /etc/named.conf
named-checkzone example.invalid /var/named/freeipa-bootstrap/example.invalid
named-checkzone 2.0.192.in-addr.arpa /var/named/freeipa-bootstrap/2.0.192.in-addr.arpa.zone
dig @127.0.0.1 SRV _ldap._tcp.example.invalid
```

### CA Validation (when IPA_SETUP_CA=true)

```bash
ipa ca-show ipa
test -r /etc/ipa/ca.crt
curl --fail --cacert /etc/ipa/ca.crt https://$(hostname -f)/ipa/ui/ -o /dev/null
```

The validation command uses the installed CA certificate. Keep certificate verification enabled during troubleshooting.

### CA-less Validation (when IPA_SETUP_CA=false)

Confirm that the externally issued LDAP and HTTP certificates are still valid for the server hostname and that their
issuer chain is trusted by the server:

```bash
test -r /etc/ipa/ca.crt
curl --fail --cacert /etc/ipa/ca.crt https://$(hostname -f)/ipa/ui/ -o /dev/null
```

Certificate renewal, replacement, and expiry monitoring for CA-less mode remain external certificate-management
responsibilities.

### NTP Validation

```bash
chronyc tracking
chronyc sources -n
timedatectl
```

If the environment uses an existing non-chrony service and timedatectl or ntpq is the authoritative health check, use
that platform command instead.

## Logs and Troubleshooting

### Bootstrap Logs

Normal run logs are under:

```text
/var/log/freeipa-bootstrap/RUN_ID.log
/var/lib/freeipa-bootstrap/runs/RUN_ID/
```

The run directory contains non-secret state, configuration backups, per-attempt output, and generated record copies.
Inspect file permissions before sharing diagnostics.

### FreeIPA Installer Logs

The platform installer normally writes:

```text
/var/log/ipaserver-install.log
```

The bootstrap error output also identifies the per-attempt capture under the run state directory. Preserve both files
when opening a support case.

### Common Failure Scenarios

#### Invalid Hostname

Symptoms include a mismatch between hostname --fqdn and IPA_HOSTNAME, or a hostname that is not a valid FQDN.

Actions:

1. Check hostname --fqdn and hostnamectl status.
2. Confirm IPA_HOSTNAME is below IPA_DOMAIN.
3. Either correct the host baseline or deliberately set CONFIGURE_HOSTNAME=true for a normal run.
4. Confirm the requested IPv4 address is assigned to the intended interface.

#### DNS Resolution Failure

Before installation, confirm /etc/resolv.conf, the server forward A record, the server reverse PTR, and resolver
delegation. After installation, confirm the SRV/TXT records from the preserved installer-generated file. In managed BIND
mode, query @127.0.0.1 and inspect named-checkconf/named-checkzone. In existing mode, use the prerequisite plan before
installation and the captured record file after installation to coordinate with the DNS administrator.

Do not bypass FreeIPA hostname/DNS checks to force installation.

#### Reverse DNS Failure

For a single-server primary, the bootstrap can manage the server's own IPv4 `/24` by default. For a redundant pair,
confirm every explicit reverse zone exists, each server IP has one PTR, and each PTR returns the exact requested FQDN.
Configure parent delegation or any omitted networks manually.

#### Kerberos / Time Synchronisation Failure

Check chronyc tracking, chronyc sources -n, timedatectl, firewall UDP 123 behavior, and NTP server reachability. Ensure
the clock is corrected before retrying a FreeIPA install. Do not use the bootstrap to hide a time-sync problem.

#### FreeIPA Partial Installation

If the partial state predates this run, the bootstrap aborts by design. Review:

```bash
ls -la /var/lib/freeipa-bootstrap/runs
test -f /var/log/ipaserver-install.log && tail -n 100 /var/log/ipaserver-install.log
ipa-server-install --help
```

Use the supported platform uninstall procedure only after verifying topology, replication, and DNS impact. Never remove
FreeIPA data directories manually as a first response.

#### DNS Provider Failure

Check provider selection, package repositories, BIND logs, Webmin repository setup output, named-checkconf, and the
generated record file. For existing, the provider is intentionally read-only: fix records in the external DNS service
and rerun --check.

#### BIND Configuration Failure

Look for unmanaged existing forwarders or unrestricted allow-recursion statements. The provider refuses to overwrite
them. Review /etc/named.conf, the dedicated include, and the managed zone directory. Restore a backed-up file only after
confirming the backup belongs to the current run and no unrelated changes occurred.

#### Replica Source or Transfer Failure

For a FreeIPA replica, confirm that `IPA_REPLICA_SOURCE` resolves to the intended source and that TCP 443, 389, 636, 88,
and 464 are reachable. Run the supported connection check and inspect the replica installer log; do not substitute
`ipa-server-install`.

For a DNS secondary, compare SOA serials and inspect `journalctl -u named`. Confirm the primary/secondary have the same
TSIG key name and secret, the primary allows the key, the secondary names the primary in `masters`, both firewalls allow
TCP/UDP 53, and every authoritative reverse zone is present in `DNS_AUTHORITATIVE_REVERSE_ZONES`. Never edit a slave
file manually. Correct the primary and allow NOTIFY/AXFR/IXFR to converge, then rerun `./install.sh --check`.

#### Address-only IP Update Failure

Run `./update-server-ip.sh --check --new-ip <address>` and inspect the selected
backend's records plus current-run state. BIND checks marked forward/reverse
zone files; integrated DNS checks FreeIPA records; Technitium checks the
authenticated API and requires the local primary. The utility intentionally
refuses unmanaged/conflicting records, DNS secondary execution, read-only
existing DNS, missing explicit cross-zone reverse coverage, and hostname
changes. If the transaction failed, verify that the state-run backups and
backend-specific rollback restored the original state before retrying. Migrate
the operating-system interface separately; do not change FreeIPA's hostname or
LDAP topology as part of an IP-only update.

#### Firewall Issues

Check:

```bash
firewall-cmd --state
firewall-cmd --get-active-zones
firewall-cmd --list-all
ss -lntup
```

An inactive firewall is not enabled by this bootstrap. In managed BIND/Webmin mode, an active firewalld receives the
configured `WEBMIN_PORT` after Webmin listener validation. In Technitium mode, active firewalld or UFW receives the
API-derived DNS and feature ports; a localhost-only Web Console and disabled DHCP do not create externally open rules.
If `TECHNITIUM_DNS_CLIENT_NETWORKS` is set, inspect the generated source rules and
`$IPA_STATE_DIR/technitium-firewall.rules`; UFW uses the `freeipa-bootstrap-technitium` comment. A Technitium IP update
on the local primary reruns this reconciliation and removes only tracked old peer rules.

#### SELinux Issues

Check:

```bash
getenforce
ausearch -m AVC -ts recent
```

Do not resolve an AVC by disabling SELinux. Correct the narrowly scoped file context or policy issue using the
platform's supported procedure.

## Manual Recovery

1. Stop and preserve the bootstrap log and state directory.
2. Determine whether FreeIPA was absent, healthy, partial pre-existing, or current-run partial at the time of failure.
3. Review /var/log/ipaserver-install.log and the per-attempt capture.
4. Review the DNS record file and provider configuration.
5. If and only if the partial installation was created by the current run, use the supported ipa-server-install
   --uninstall process. Do not delete files by hand.
6. If it pre-dated the run, coordinate manual cleanup with the FreeIPA/DNS administrators; the bootstrap will not
   uninstall it.
7. Revalidate hostname, DNS, time, firewall, and SELinux before a new installation attempt.

FreeIPA installation failure can leave system files changed even after supported uninstall. If repeated supported
cleanup attempts fail, follow platform vendor recovery guidance and consider rebuilding the disposable host rather than
continuing destructive experimentation.

## Backup

### FreeIPA Backup

The bootstrap does not schedule backups. Establish a tested operational backup process using the platform-supported
command:

```bash
ipa-backup
```

Confirm the backup destination, permissions, encryption/retention controls, monitoring, and restore test procedure with
the infrastructure team.

### Restore Considerations

A FreeIPA restore is a service and topology operation, not just a file restore. Consider realm DNS, host identity,
CA/KRA material, replication agreements, time synchronization, clients, and external DNS records. Follow the installed
RHEL/IdM version's backup and restore documentation and do not restore into a different realm or hostname without a
documented migration plan.

## Post-Installation Tasks

After this bootstrap succeeds, separately plan and approve:

- FreeIPA user/group and host inventory
- HBAC and sudo policy
- password and lockout policy
- trust relationships and delegated administration
- certificate profiles and issuance policy
- application principals and service accounts
- Webmin hardening and management-plane firewall access
- backup scheduling and restore testing
- monitoring, alerting, certificate renewal, and capacity planning

## Security Considerations

- Keep .env mode 0600 and never commit it.
- Use exported secrets or the secure prompt when appropriate; avoid passwords in shell history.
- Password arguments required by FreeIPA tools can be visible to privileged process inspection for the short duration of
  the command. Use a controlled maintenance window.
- Review WEBMIN_SETUP_REPO_SHA256 pinning for production change control.
- Use only supported distribution FreeIPA packages and the official Webmin repository setup path.
- Do not disable SELinux, disable TLS verification, globally disable the firewall, or expose unrestricted DNS recursion.
- Review generated files and logs before sharing them; they are designed not to contain passwords but may contain
  infrastructure details.
- Keep the FreeIPA server on a restricted management network and apply separate Webmin access policy.

## Known Limitations

- The package must run on a real supported RHEL-family host for runtime installer validation; the development
  environment does not provide RHEL/FreeIPA/BIND/systemd.
- Technitium is API-managed and supports Primary/Secondary zones, transfers,
  NOTIFY, TSIG, explicit RFC 2136 update policy, and idempotent record sync. It
  does not implement FreeIPA GSS-TSIG/Kerberos semantics; secure mode is TSIG
  plus a source-network ACL.
- BIND/Webmin is a local BIND provider. It does not implement Webmin hardening or call Webmin's internal DNS API.
- Existing DNS must contain the server A/PTR prerequisites before installation and the installer-generated system
  records after installation; the provider cannot repair external DNS.
- A primary may derive one IPv4 `/24` reverse zone for backward-compatible single-server operation; redundant
  deployments must explicitly list every authoritative reverse zone. The IP update utility changes IPv4 A/PTR mappings
  only.
- IPv6 reverse-zone declarations can be passed to BIND as explicit authoritative zones, but arbitrary IPv6 address
  migration, network reconfiguration, and DNS delegation outside the selected zones remain out of scope.
- FreeIPA replica creation and BIND/Technitium primary/secondary transfer validation are implemented, but the task does
  not automate arbitrary multi-master topology design, cross-site latency policy, backup scheduling, or Webmin's
  internal cluster state.
- Backup scheduling, restore automation, and day-2 identity policy are out of scope.
- The installer requires the version-specific primary/replica installer option surface on the target; it fails rather
  than guessing unsupported syntax. External DNS records use the legacy installer output when available or the supported
  `ipa dns-update-system-records --dry-run --out` fallback.

## Adding Another DNS Provider

Create a module under dns/providers/provider-name/provider.sh implementing:

```text
dns_provider_check
dns_provider_install
dns_provider_configure
dns_provider_configure_forwarders
dns_provider_create_forward_zone
dns_provider_create_reverse_zone
dns_provider_create_record
dns_provider_validate_prerequisites
dns_provider_validate
dns_provider_sync_freeipa_records
dns_provider_uninstall
```

The implementation must:

1. return a clear error when prerequisites are missing
2. be safe in check and dry-run modes
3. avoid writing secrets to logs or generated records
4. create only the IPA forward zone and the configured authoritative reverse zones; a secondary must never guess or
   locally edit a new reverse zone
5. preserve and classify pre-existing resources
6. validate the version-specific FreeIPA record file after installation
7. add only one provider selection branch in dns/provider.sh
8. add tests and update this article only after runtime validation

Do not add provider-specific if/elif branches throughout the FreeIPA core.

## Uninstallation

There is no normal ./install.sh --uninstall mode. This is deliberate: removing a FreeIPA server can affect replication,
DNS delegation, clients, CA/KRA material, and other infrastructure.

For a current-run partial installation, the retry path uses the supported ipa-server-install --uninstall --unattended
command when the target advertises that option. For a complete lifecycle removal, follow the installed platform's
FreeIPA server/replica removal procedure, remove DNS records and delegation through the DNS owner, and remove only
BIND/Webmin resources that have been reviewed as bootstrap-owned.

Never use recursive deletion of broad system directories as an uninstall procedure.

## Operational Checklist

1. [ ] Supported RHEL-family OS and architecture confirmed.
2. [ ] Static IPv4 address configured and assigned to the intended interface.
3. [ ] Permanent FQDN and IPA_DOMAIN confirmed.
4. [ ] `IPA_SERVER_ROLE` selected; replica source FQDN, principal, credentials, and CA-replica choice recorded when
   applicable.
5. [ ] DNS mode and independent `DNS_SERVER_ROLE` selected and documented.
6. [ ] Forward-zone and authoritative reverse-zone strategy confirmed; every redundant reverse zone is explicit.
7. [ ] Primary/secondary A, PTR, NS, TSIG, NOTIFY, and firewall TCP/UDP 53 design reviewed.
8. [ ] Existing external DNS A/PTR prerequisites are present before installation, and the generated system-record file
   is published afterward when `DNS_PROVIDER=existing`.
9. [ ] NTP is healthy and source strategy is confirmed.
10. [ ] `.env` and TSIG key files are private and mode 0600/0640 as appropriate.
11. [ ] `./install.sh --check` completed successfully.
12. [ ] `./install.sh --dry-run` reviewed by the change owner.
13. [ ] Installation completed without an unsafe retry or rollback condition.
14. [ ] FreeIPA services validated with `ipactl status`.
15. [ ] Kerberos validated with `kinit` and `klist`.
16. [ ] LDAP/IPA CLI and, for replicas, `ipa topologysegment-find` validated.
17. [ ] Forward, SRV, NS, SOA, and reverse DNS validated on both DNS nodes; secondary serials converged.
18. [ ] CA choice validated: integrated CA/CA replica with `ipa ca-show ipa` when enabled, or the external certificate
    chain when CA-less.
19. [ ] `IPA_SSH_TRUST_DNS` and `IPA_SETUP_SUBID` selections were recorded before the initial install.
20. [ ] Optional KRA validated when enabled.
21. [ ] Webmin peer registered manually through the supported Webmin UI when required; no initialization overwrite was
    used.
22. [ ] `./update-server-ip.sh --check` procedure and separate OS network migration are documented for future address
    changes.
23. [ ] Backup approach and restore considerations reviewed.
24. [ ] Post-install identity and policy configuration identified as a separate task.

## References

- [Red Hat Enterprise Linux 9 Installing Identity Management](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html-single/installing_identity_management/index)
- [Red Hat Enterprise Linux 9 Working with DNS in Identity Management](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html-single/working_with_dns_in_identity_management/index)
- [Red Hat Enterprise Linux 9 Managing networking infrastructure services — BIND](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/managing_networking_infrastructure_services/assembly_setting-up-and-configuring-a-bind-dns-server_networking-infrastructure-services)
- [Red Hat Enterprise Linux 9 Managing IdM users, groups, hosts, and access control rules](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html-single/managing_idm_users_groups_hosts_and_access_control_rules/managing_idm_users_groups_hosts_and_access_control_rules)
- [FreeIPA project source and documentation](https://github.com/freeipa/freeipa)
- [Webmin BIND DNS Server module](https://webmin.com/docs/modules/bind-dns-server/)
- [Webmin Cluster Webmin Servers module](https://webmin.com/docs/modules/cluster-webmin-servers/)
- [Webmin official download and repository instructions](https://webmin.com/download/)
- [BIND 9 Administrator Reference Manual](https://bind9.readthedocs.io/en/latest/)
- [Technitium DNS Server project](https://github.com/TechnitiumSoftware/DnsServer)
- [Technitium DNS Server HTTP API reference](https://raw.githubusercontent.com/TechnitiumSoftware/DnsServer/master/APIDOCS.md)
- [Technitium official Linux installer](https://download.technitium.com/dns/install.sh)
- [FreeIPA DNS record modification API](https://freeipa.readthedocs.io/en/ipa-4-11/api/dnsrecord_mod.html)
- [Red Hat chrony documentation](https://docs.redhat.com/en/documentation/red_hat_enterprise_linux/9/html/configuring_basic_system_settings/configuring-time-synchronization_configuring-basic-system-settings)
