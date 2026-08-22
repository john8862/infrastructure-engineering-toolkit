# Infrastructure Engineering Toolkit

[![CI](https://github.com/john8862/infrastructure-engineering-toolkit/actions/workflows/ci.yml/badge.svg)](https://github.com/john8862/infrastructure-engineering-toolkit/actions/workflows/ci.yml)
[![Release Please](https://github.com/john8862/infrastructure-engineering-toolkit/actions/workflows/release-please.yml/badge.svg)](https://github.com/john8862/infrastructure-engineering-toolkit/actions/workflows/release-please.yml)
[![Latest release](https://img.shields.io/github/v/release/john8862/infrastructure-engineering-toolkit?display_name=tag&sort=semver)](https://github.com/john8862/infrastructure-engineering-toolkit/releases)
[![Licence: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

An openly licensed, deliberately bounded toolkit for identity, DNS, MariaDB, proxy, and VRRP operations. It packages
small Bash and Ansible components with explicit contracts, read-only validation, and public-safe fixtures. Components
can be used independently or composed by a caller's playbook; this repository is not an end-to-end platform installer.

The project is in `0.x` development. The component contracts and static validation are published, while target-host
runtime validation remains the responsibility of the operator. In particular, the DNS update role has passed its
contract, syntax, `yamllint`, and `ansible-lint` checks, but a local Python 3.14 controller RPC incompatibility blocked
live execution before DNS was reached. No live DNS deployment outcome is claimed.

## Contents

- [Why this repository exists](#why-this-repository-exists)
- [Goals and engineering principles](#goals-and-engineering-principles)
- [Component catalogue](#component-catalogue)
- [Architecture and composition](#architecture-and-composition)
- [Supported platforms and prerequisites](#supported-platforms-and-prerequisites)
- [Safe Quick Start](#safe-quick-start)
- [Repository layout](#repository-layout)
- [Validation and CI](#validation-and-ci)
- [Release, versioning, and changelog](#release-versioning-and-changelog)
- [Operational safety, secrets, and certificates](#operational-safety-secrets-and-certificates)
- [Roadmap](#roadmap)
- [Contributing](#contributing)
- [Licence and third-party boundaries](#licence-and-third-party-boundaries)
- [Documentation index](#documentation-index)

## Why this repository exists

Infrastructure automation is easier to review when each change has an owner, a preflight path, and a clear stopping
point. This toolkit focuses on repeatable foundations and operational checks:

- identity and DNS bootstrapping with explicit authority boundaries;
- MariaDB host preparation and standard asynchronous replication;
- a bounded MaxScale configuration core;
- generic Keepalived/VRRP configuration; and
- explicit DNS `A`/`PTR` inspection and reconciliation.

The boundaries are intentional. The MariaDB baseline does not configure a replication channel; replication does not
copy data or promote a new primary; MaxScale does not create database accounts or claim a virtual IP; Keepalived does
not infer application health; and DNS does not decide which service is healthy. A caller can therefore adopt one
component without accepting the assumptions of the others.

## Goals and engineering principles

### Goals

- Make infrastructure changes inspectable before they are applied.
- Keep every component independently usable with a documented interface.
- Prefer idempotent, state-aware operations over broad host mutation.
- Make version, dependency, privilege, recovery, and limitation information visible.
- Provide fixtures that are safe to parse or render with RFC documentation addresses and `example.invalid` names.
- Record validation evidence without implying a deployment result that was not observed.

### Engineering principles

- **Validate before mutating.** Use preflight, syntax checks, check mode, dry runs, and candidate configuration checks
  before enabling package, service, firewall, DNS, or topology changes.
- **Keep ownership explicit.** A role manages only the files, records, services, and state named in its contract. It does
  not discover authority or repair an ambiguous existing installation.
- **Separate layers.** Identity/DNS and the MariaDB/replication/MaxScale/VRRP path have independent inputs and failure
  boundaries.
- **Use least privilege.** Credentials, certificates, keys, health programs, and database state are supplied or owned
  by the workflow that is responsible for them.
- **Prefer recoverable operations.** Guard first-node initialisation, refuse unsafe PTR replacement by default, protect
  running Keepalived deployments, and preserve configuration recovery paths.
- **Publish safe examples.** Examples use RFC 5737 IPv4 ranges, RFC 3849 IPv6 ranges, and the reserved
  `example.invalid` namespace. Replace them only in an approved runtime inventory.

## Component catalogue

The table is a quick index. Each component guide remains authoritative for its complete variable contract, supported
versions, and recovery notes.

| Component | Interface and status | Primary responsibility | Explicitly not responsible for | Guide | Example | Tests |
| --- | --- | --- | --- | --- | --- | --- |
| FreeIPA bootstrap | Bash; available, with supported-target validation required | Primary/replica bootstrap, CA mode, integrated or external DNS provider orchestration, validation, and managed server-address updates | Users, groups, access policy, application principals, trust policy, backup/restore, or workstation testing | [README](components/freeipa-bootstrap/README.md) | [examples/freeipa](examples/freeipa) | [test suite](tests/freeipa-bootstrap/test.sh) |
| MariaDB baseline | Ansible; available, with Ubuntu target validation required | Official repository/package baseline, split configuration, hardening, deterministic identity, guarded first-node initialisation, and TLS consumer links | Replication topology, data copy, failover, application schemas/users, backup schedules, Galera, or MaxScale | [role guide](ansible/roles/mariadb/README.md) | [examples/mariadb](examples/mariadb) | [contracts](tests/mariadb) |
| MariaDB replication | Ansible; available, with existing data-copy evidence required | One writable primary and one or more asynchronous replicas, GTID or explicit file/position channels, consistency checks, and health summaries | Data copy/restore, server identity changes, binary-log enablement, PKI, Galera, failover, MaxScale, or Keepalived | [role guide](ansible/roles/mariadb_replication/README.md) | [examples/mariadb-replication](examples/mariadb-replication) | [contracts](tests/mariadb_replication) |
| MaxScale core | Ansible; available, render-first, software not bundled | Generic server/monitor/service/listener model, configuration validation, optional service reload, logging, TLS-path checks, and optional REST health checks | MariaDB or MaxScale account creation, Binlog Router, Config Sync, binlog retention, external replicas, VIP/DNS, or MaxScale redistribution | [role guide](ansible/roles/maxscale/README.md) | [examples/maxscale-ha](examples/maxscale-ha) | [static checks](tests/maxscale) |
| Keepalived | Ansible; available, generic VRRP only | Explicit VRRP instances, peer selection, protected existing deployments, least-privilege health-script references, and opt-in generic firewall rules | Health-program implementation, database/proxy semantics, DNS, certificates, or forced failover | [role guide](ansible/roles/keepalived/README.md) | [examples/keepalived](examples/keepalived) | [syntax check](tests/keepalived/test_syntax.sh) |
| DNS update | Ansible; available interface, live target validation pending | Explicit `A`/`PTR` inspection and optional reconciliation through `community.general.nsupdate`, with per-record results and conservative PTR conflicts | Zone/server discovery, DNS authority management, operating-system network changes, or identity/database/proxy/VRRP state | [role guide](ansible/roles/dns_update/README.md) | [examples/dns-update](examples/dns-update) | [contract test](tests/dns_update/test_contract.py) |

### FreeIPA bootstrap

The Bash component supports a FreeIPA/IdM primary or replica on allowlisted RHEL-family 8, 9, or 10 hosts and
`x86_64` or `aarch64` architectures. It uses the supported `ipa-server-install` or `ipa-replica-install` path,
validates foundational host and realm inputs, and keeps DNS provider behaviour behind a provider contract. The public
DNS choices are FreeIPA integrated DNS, managed BIND9/Webmin, Technitium, and a read-only existing-DNS path.

`./install.sh --check` is read-only and `./install.sh --dry-run` prints the planned actions. The address-update utility
changes only its managed records and keeps host-network migration separate. The bootstrap does not create identity
policy, application configuration, or a backup/restore system.

### MariaDB baseline

The baseline defaults to MariaDB 11.8 on Ubuntu 24.04 (noble), with the release and target values explicit. It manages
official repository integration, packages, split option files, logging, performance defaults, deterministic `server_id`
and `report_host`, root hardening, a reserved SSL-protected replication account, and stable links for externally managed
TLS assets. First-node GTID/binlog reset is guarded by an explicit new-server declaration and clean-state assertions.

The role stops at a Ready-for-HA contract. It does not create application databases or users, initialise a topology,
schedule backups, or configure `CHANGE MASTER TO`, `CHANGE REPLICATION SOURCE TO`, or `START REPLICA`.

### MariaDB replication

The replication role supports MariaDB 11.x and 12.x standard asynchronous replication: one initial writable primary and
one or more replicas. GTID with the replica-position model is the default; file/position mode is available when the
operator supplies coordinates tied to a consistent copy. The role validates server identity, binary logging, network
reachability, account transport policy, table inventories, storage engines, and checksums before changing a channel.

It does not copy or restore data, discover a safe coordinate, change `server_id`, enable binary logging, enrol
certificates, implement failover, or configure MaxScale/Keepalived. A replica failure is reported in its own result so
other declared replicas can still be assessed; a primary safety failure remains a failed run.

### MaxScale core

The MaxScale role is a bounded, 24.02-oriented configuration core for Debian-family hosts, with Ubuntu `jammy` and
`noble` as the documented defaults. It renders server, monitor, service, router, and listener definitions; validates
caller-supplied TLS paths; and can optionally manage the official repository, package, service, firewall rules, logging,
and REST health checks. Rendering and management are separate switches so a caller can review a configuration first.

MaxScale software, packages, repository metadata, and vendor legal text are not redistributed or relicensed by this
repository. The role does not create database or MaxScale accounts, manage Binlog Router or Config Sync, claim a VIP,
or infer DNS and application health.

### Keepalived

The Keepalived role describes one or more independent VRRP instances. The caller supplies interface, state, priority,
peer addresses, virtual IP addresses, and optional paths to separately managed health programs. Existing running
deployments are validation-only unless a planned reconciliation switch is enabled. The role validates the rendered
configuration and does not claim a VIP or force failover during a check.

### DNS update

The `dns_update` role requires every record to declare `name`, `type` (`A` or `PTR`), `value`, `zone`, and `state`.
It queries current values with `dig` first and delegates updates to the official `community.general.nsupdate` module.
Both `dns_update_enabled` and `dns_update_manage` default to `false`. GSS-TSIG is the secure default; standard TSIG is
optional; unsigned mode is test-only, disabled by default, and requires an explicit opt-in. A matching record is a
no-op. A different PTR is reported and left untouched under the default `report` policy.

The pinned public example uses `community.general` 13.0.0. Check mode performs read-only inspection and never obtains a
Kerberos ticket or invokes `nsupdate`. Runtime dependency, authority, credential, and target-host checks remain the
caller's responsibility.

## Architecture and composition

### Independent identity and DNS plane

FreeIPA is an independent identity plane. Its primary/replica relationship, realm, CA choice, and DNS provider choice
are established by the FreeIPA component and are not inferred from the database or availability roles. A FreeIPA replica
is not automatically a BIND or Technitium secondary, and a DNS secondary is not automatically a FreeIPA replica.

The [identity and DNS architecture guide](docs/architecture/identity-and-dns.md) describes integrated DNS, managed
BIND9/Webmin, Technitium, existing-DNS read-only operation, provider boundaries, and the separate address-update paths.

### Optional data-plane sequence

The database and service path can be composed in this order when a caller needs all layers:

```text
MariaDB baseline -> MariaDB replication -> MaxScale -> Keepalived/VRRP -> DNS name
```

Each arrow is a caller-controlled hand-off, not a hidden role dependency:

1. **MariaDB baseline** prepares each database host, stable identity, server configuration, and external TLS links.
2. **MariaDB replication** consumes existing data-copy evidence and explicit topology inputs to configure and validate
   the asynchronous channel.
3. **MaxScale** consumes backend definitions and exposes an optional listener after candidate configuration validation.
4. **Keepalived/VRRP** can own a virtual IP for a caller-supplied edge or listener policy; it does not know whether the
   address fronts MariaDB, MaxScale, or another service.
5. **DNS** can name the chosen edge, but it does not decide health, promote a primary, or claim a virtual IP.

The [data-plane architecture guide](docs/architecture/data-plane.md) contains the responsibility matrix and safe
composition sequence. Use a stable service name such as `db-writer.example.invalid` only in documentation; replace it
with an approved zone and authority in a reviewed runtime configuration.

## Supported platforms and prerequisites

The component guides are authoritative when a variable or platform detail changes. The following table gives the public
baseline:

| Area | Supported/default environment | Prerequisites and boundaries |
| --- | --- | --- |
| FreeIPA bootstrap | RHEL, Rocky, AlmaLinux, CentOS Stream, or Oracle Linux 8/9/10; `x86_64` or `aarch64` | Root or approved privilege, native `dnf`/`yum`, hostname/realm/time/DNS prerequisites, and a disposable supported target. Do not run the installer on a workstation. |
| MariaDB baseline | Ubuntu 24.04/noble by default; MariaDB 11.8 release series by default | `ansible-core`, `ansible.mariadb`, `ansible.posix`, target-side PyMySQL, `python3-debian`, and ACL support. Root/database secrets and certificates come from external workflows. |
| MariaDB replication | MariaDB 11.x or 12.x | Controller virtual environment, `ansible.mariadb` 6.x or newer, target-side PyMySQL, a reachable TCP primary, unique server IDs, binary logging, and a consistent preloaded copy with GTID or position metadata. |
| MaxScale | Debian family; Ubuntu `jammy` or `noble` defaults; 24.02-oriented configuration | An installed or explicitly managed MaxScale package, external account/TLS material, and reviewed MariaDB terms. Repository/package/service management is opt-in. |
| Keepalived | A target with the distribution Keepalived package and validation binary | Explicit interface, peers, VRID, priorities, VIPs, and separately managed health programs. Existing deployments are protected by default. |
| DNS update | Any supported Ansible target with `dig`; `community.general` 13.0.0 | Target-side `dnspython`; GSS-TSIG additionally needs `kinit`, Kerberos, and `gssapi`; TSIG keys or Kerberos credentials must be supplied at runtime. |
| CI and local validation | Ubuntu 24.04 runner, Python 3.13 | Pinned tools in [`requirements-ci.txt`](requirements-ci.txt) and collections in [`ansible/requirements.yml`](ansible/requirements.yml). Python 3.14 may trigger the documented local Ansible RPC issue. |

### Install validation dependencies

Use a supported Python 3.13 interpreter for local validation, matching CI. Keep the virtual environment and Ansible
collections outside source control:

```bash
python3.13 -m venv .venv
source .venv/bin/activate
python -m pip install --requirement requirements-ci.txt
ansible-galaxy collection install \
  --requirements-file ansible/requirements.yml \
  --collections-path "$PWD/collections"
```

The pinned collection set includes `ansible.mariadb` 6.0.2, `ansible.posix` 2.2.2, and `community.general` 13.0.0.
The DNS role may require target-side `dnspython`, and GSS-TSIG requires a working Kerberos client and `gssapi` in the
runtime environment. The roles do not vendor collections or install guessed package names by default.

## Safe Quick Start

The commands below are designed for inspection, parsing, and check mode. They do not provide credentials, publish DNS,
configure a database topology, claim a VIP, or enable a package/service change.

### 1. Clone and prepare the validation environment

```bash
git clone https://github.com/john8862/infrastructure-engineering-toolkit.git
cd infrastructure-engineering-toolkit
python3.13 -m venv .venv
source .venv/bin/activate
python -m pip install --requirement requirements-ci.txt
ansible-galaxy collection install \
  --requirements-file ansible/requirements.yml \
  --collections-path "$PWD/collections"
```

### 2. Inspect the FreeIPA plan

Run these commands only on a disposable, supported RHEL-family target with a reviewed environment file. They are not
workstation installation commands:

```bash
cd components/freeipa-bootstrap
./install.sh --version
./install.sh --check
./install.sh --dry-run
cd ../..
```

`--check` performs read-only preflight and provider validation. `--dry-run` validates and prints planned packages,
files, services, DNS operations, firewall behaviour, and FreeIPA mode. A normal run remains outside this Quick Start.

### 3. Run local Ansible syntax and check-mode fixtures

Set paths to the checked-out role and collection directories:

```bash
export ANSIBLE_ROLES_PATH="$PWD/ansible/roles"
export ANSIBLE_COLLECTIONS_PATH="$PWD/collections"
export ANSIBLE_LOCAL_TEMP="/tmp/ietk-ansible-tmp"
mkdir -p "$ANSIBLE_LOCAL_TEMP"
```

The DNS and MaxScale fixtures use local execution and safe documentation values:

```bash
ansible-playbook --syntax-check \
  -i localhost, -c local examples/dns-update/site.yml
ansible-playbook --check --diff \
  -i localhost, -c local examples/dns-update/site.yml
ansible-playbook --syntax-check \
  -i examples/maxscale-ha/inventory/hosts.yml examples/maxscale-ha/site.yml
ansible-playbook --check --diff \
  -i examples/maxscale-ha/inventory/hosts.yml examples/maxscale-ha/site.yml
ansible-playbook --syntax-check \
  -i examples/keepalived/inventory.yml examples/keepalived/playbook.yml
```

The MariaDB inventories contain RFC documentation addresses and are not reachable targets. Use syntax checks against
those files, and use `--check --diff` only with a separately reviewed local or disposable inventory:

```bash
ansible-playbook --syntax-check \
  -i examples/mariadb/inventory.example.yml examples/mariadb/site.yml
ansible-playbook --syntax-check \
  -i examples/mariadb-replication/inventory.yml \
  examples/mariadb-replication/playbook.yml
```

### 4. Run dependency-free contracts and repository checks

```bash
python tests/dns_update/test_contract.py
python tests/mariadb/test_contract.py
python tests/mariadb_replication/test_contract.py
bash tests/freeipa-bootstrap/test.sh
bash tests/maxscale/test_static.sh
sh tests/keepalived/test_syntax.sh
pymarkdown scan --recurse --respect-gitignore .
git diff --check
```

These commands validate source contracts and fixtures. They do not prove that a target's package repository, DNS
authority, Kerberos realm, database state, proxy health, or VRRP network will behave as expected.

## Repository layout

```text
components/freeipa-bootstrap/          FreeIPA Bash bootstrap and DNS helpers
ansible/roles/                          Independent Ansible roles
  dns_update/                           Explicit A/PTR inspection and reconciliation
  keepalived/                           Generic VRRP configuration
  mariadb/                              Standalone MariaDB baseline
  mariadb_replication/                  Standard asynchronous replication
  maxscale/                             Bounded MaxScale configuration core
examples/                               Public-safe inventories and localhost fixtures
tests/                                  Contract, syntax, and static checks
docs/                                   Architecture, operations, CI, release, and articles
.github/workflows/ci.yml               Read-only quality gates
.github/workflows/release-please.yml   Main-branch release preparation/publication
ansible/requirements.yml               Pinned Ansible collections
requirements-ci.txt                    Pinned Python validation tools
version.txt                            Root semantic-version bookkeeping
CHANGELOG.md                            Release Please managed changelog
CONTRIBUTING.md                         Contribution and Conventional Commit guidance
LICENSE                                 MIT licence for original repository material
```

The directory layout reflects independent responsibilities. A caller can use a role README and example without
adopting an unrelated role. Collections are installed into an ignored path rather than committed.

## Validation and CI

The [quality-gates workflow](.github/workflows/ci.yml) runs on pull requests and pushes to `main` with read-only
permissions. It does not connect to live infrastructure or require deployment credentials.

| Gate | What it covers | Local entry point |
| --- | --- | --- |
| Shell | `bash -n` over shell files and FreeIPA contracts | `bash tests/freeipa-bootstrap/test.sh` plus the component shell syntax command in [`docs/CI.md`](docs/CI.md) |
| Python contracts | DNS, MariaDB, and MariaDB replication dependency-free checks on Python 3.13 | `python tests/dns_update/test_contract.py`, `python tests/mariadb/test_contract.py`, and `python tests/mariadb_replication/test_contract.py` |
| Ansible | Pinned collections, `ansible-lint --offline --profile basic`, YAML lint, and fixture syntax | `ansible-lint --offline --profile basic ansible/roles`; see [`docs/CI.md`](docs/CI.md) |
| Fixtures | DNS, MariaDB, replication, MaxScale, and Keepalived parse/render checks | Commands in [Safe Quick Start](#safe-quick-start) |
| Markdown and Git hygiene | Recursive PyMarkdown scan and whitespace validation | `pymarkdown scan --recurse --respect-gitignore .` and `git diff --check` |

CI installs the exact versions from [`requirements-ci.txt`](requirements-ci.txt) and [`ansible/requirements.yml`](ansible/requirements.yml)
into temporary runner paths. The `require-final-union.sh` guard confirms that all public component paths are present before
the quality gates report a complete repository. The workflow intentionally does not use a dependency cache.

## Release, versioning, and changelog

The repository uses [Release Please](https://github.com/googleapis/release-please) to maintain one root semantic version.
The [release workflow](.github/workflows/release-please.yml) runs only after pushes to `main`.

- [`version.txt`](version.txt) and [`.release-please-manifest.json`](.release-please-manifest.json) start at `0.0.0`
  as bookkeeping, not as a claim that a `0.0.0` release exists.
- [`release-please-config.json`](release-please-config.json) declares one root package and the `simple` release type.
- [`CHANGELOG.md`](CHANGELOG.md) is maintained from merged Conventional Commits.
- Published repository tags use `v<MAJOR>.<MINOR>.<PATCH>` and GitHub Release notes are derived from the same merged
  history.
- Release automation is limited to `main`; a feature branch cannot publish a tag or GitHub Release.

Use commit subjects such as `feat(mariadb): ...`, `fix(maxscale): ...`, `docs(freeipa): ...`, or `ci: ...`. See the
[release guide](docs/RELEASING.md) and [contribution guide](CONTRIBUTING.md) for the release flow and compatibility
rules. The FreeIPA bootstrap also maintains its own component configuration baseline in its component guide; that does
not replace the root release version.

### Release assets

Each published `v<version>` GitHub Release contains independent, versioned
installation assets rather than one combined toolkit archive:

| Asset family | Published files | Archive root | Intended use |
| --- | --- | --- | --- |
| Ansible roles | `ansible-role-dns-update-v<version>.tar.gz`, `ansible-role-keepalived-v<version>.tar.gz`, `ansible-role-mariadb-v<version>.tar.gz`, `ansible-role-mariadb-replication-v<version>.tar.gz`, and `ansible-role-maxscale-v<version>.tar.gz` | The role name, with its own `README.md` and `LICENSE` | Install or vendor one role without importing unrelated roles |
| FreeIPA bootstrap | `freeipa-bootstrap-v<version>.tar.gz` | `freeipa-bootstrap/` | Run the public bootstrap scripts with their operational documentation and safe example templates |
| Integrity metadata | `SHA256SUMS-v<version>.txt` and `release-manifest-v<version>.json` | N/A | Verify downloaded assets and inspect the machine-readable package inventory |

The release workflow builds these assets from the exact published tag using
the explicit allowlists in [`scripts/release/build-assets.py`](scripts/release/build-assets.py).
It rejects untracked inputs, symlinks, unsafe archive paths, writable archive
entries, and secret or internal repository material. The CI packaging contract
builds the assets twice, checks byte-for-byte reproducibility, validates the
archive boundaries, and verifies every checksum before any upload step can run.

## Operational safety, secrets, and certificates

- Keep passwords, Kerberos credentials, TSIG secrets, private keys, certificates, access tokens, and environment-specific
  inventories outside this repository. Use Vault, an external secret manager, or an approved PKI workflow.
- The MariaDB roles consume certificate paths and create stable service links; they do not request, renew, copy, or
  publish certificate material.
- The replication role expects a consistent preloaded data copy and its GTID or file/position metadata. It is not a
  backup/restore system and does not silently repair divergence.
- The DNS update role requires an explicit server and zone for every record. Check mode is read-only, GSS-TSIG is the
  secure default, TSIG is optional, and unsigned mode is test-only and explicitly disabled by default.
- The FreeIPA bootstrap redacts known credential arguments in displayed commands and protects state/log directories on
  the target, but the underlying installer may briefly expose password arguments in a process list.
- Keepalived does not claim a VIP or force failover to test a run. MaxScale reloads only after candidate configuration
  validation when service management is enabled.
- Review backup, restore, rollback, authority, and change-window requirements before applying any component to a host
  with real data or authoritative services.

The public examples are intentionally non-production. `192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24`,
`2001:db8::/32`, and `example.invalid` are documentation values only.

## Roadmap

The [public roadmap](docs/roadmap.md) tracks work by interface and validation evidence. The current next steps are:

- validate DNS A/PTR reconciliation against a disposable authoritative service with external GSS-TSIG or TSIG
  credentials;
- add composition fixtures that render hand-offs without installing packages, creating accounts, claiming a VIP, or
  contacting an external DNS service;
- expand disposable-host coverage for supported operating systems, certificate rotation, DNS transfer paths, MariaDB
  11/12 behaviour, MaxScale reload checks, and Keepalived peers; and
- strengthen upgrade, backup/restore, SOA recovery, proxy recovery, and serial VRRP maintenance guidance.

The roadmap does not promise a single end-to-end installer, automatic database promotion, application account/schema
management, PKI enrolment, backup/restore orchestration, hidden DNS writes, or redistribution of MaxScale software.

## Contributing

Contributions are welcome when they improve reliability, clarity, or reproducibility while preserving component
boundaries. Before opening a pull request:

1. Keep the change focused and public-safe.
2. Use RFC documentation values and `*.example` placeholders in examples.
3. Document prerequisites, assumptions, validation, failure modes, and recovery boundaries.
4. Run the checks relevant to the component and describe exactly what was verified.
5. Use a Conventional Commit subject and explain incompatible interface changes with `BREAKING CHANGE:`.

Read [`CONTRIBUTING.md`](CONTRIBUTING.md) for the complete commit and pull-request guidance. Do not add credentials,
private keys, personal information, restricted configuration, live-service data, or environment-specific hostnames.

## Licence and third-party boundaries

Original automation, examples, and documentation in this repository are provided under the [MIT License](LICENSE).
The MIT licence applies to this repository's original material; it does not relicense software installed or configured
by a role. FreeIPA, BIND, Webmin, Technitium DNS Server, MariaDB Server, MaxScale, Keepalived, Ansible collections, and
operating-system packages retain their own licences, repository terms, trademarks, and attribution requirements.

MaxScale has a specific boundary. This repository does not redistribute MaxScale software, packages, repository
metadata, vendor legal text, or credentials, and it does not relicense MaxScale. The role only renders a caller-supplied
configuration model and, when explicitly enabled, integrates with the official MariaDB repository. Review the current
[MariaDB MaxScale licensing information](https://mariadb.com/bsl11/) and [official MaxScale documentation](https://mariadb.com/docs/maxscale/)
before enabling package or repository management.

MariaDB packages are obtained from the selected official repository at deployment time rather than bundled here.
Collections are installed from pinned requirement files rather than vendored. Review each vendor's current terms before
using a package, repository, or integration.

## Documentation index

- Architecture: [identity and DNS](docs/architecture/identity-and-dns.md) and [data-plane composition](docs/architecture/data-plane.md)
- Operations: [safe usage and validation](docs/operations/safe-usage.md) and [troubleshooting](docs/operations/troubleshooting.md)
- Articles: [bounded FreeIPA bootstrap](docs/articles/bounded-freeipa-bootstrap.md), [MariaDB foundation](docs/articles/mariadb-foundation.md), and [MariaDB/MaxScale/VRRP composition](docs/articles/mariadb-maxscale-vrrp.md)
- Project operations: [CI](docs/CI.md), [releasing](docs/RELEASING.md), [contribution guide](CONTRIBUTING.md), and [CHANGELOG](CHANGELOG.md)
- Component details: the role and component guides linked in the [catalogue](#component-catalogue)
