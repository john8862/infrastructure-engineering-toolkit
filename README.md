# Infrastructure Engineering Toolkit

The Infrastructure Engineering Toolkit is a public collection of small, reviewable infrastructure components. Each
component has a narrow contract, safe example inputs, validation guidance, and an explicit boundary around state it
does not manage. Components can be used independently or composed by a caller's playbook.

## Status and component matrix

The toolkit is in the `0.x` development phase. The status below describes the public interfaces intended for the
integrated repository; it does not claim that a component has been exercised on a particular operator's infrastructure.

| Component | Form | Public scope | Status | Start here |
| --- | --- | --- | --- | --- |
| FreeIPA server bootstrap | Bash | FreeIPA/IdM primary or replica bootstrap on supported RHEL-family hosts, with integrated or external DNS provider boundaries | Available; target-host validation remains required | [component guide](components/freeipa-bootstrap/README.md) |
| MariaDB baseline | Ansible role | Ubuntu 24.04/noble baseline with a configurable MariaDB release series, split configuration, hardening, and TLS consumer contract | Available; topology is intentionally separate | [role guide](ansible/roles/mariadb/README.md) |
| MariaDB replication | Ansible role | One writable primary and one or more asynchronous replicas, with GTID by default, optional file/position mode, and health reporting | Available; data copy and failover remain outside the role | [role guide](ansible/roles/mariadb_replication/README.md) |
| MaxScale | Ansible role | Generic server, monitor, service, listener, TLS-path, logging, and guarded validation model | Available; MaxScale software is not included | [role guide](ansible/roles/maxscale/README.md) |
| Keepalived | Ansible role | Independent VRRP instances, optional least-privilege health-script references, and opt-in generic firewall rules | Available; database and proxy health semantics remain with the caller | [role guide](ansible/roles/keepalived/README.md) |
| DNS A/PTR reconciliation | Ansible role | Explicit caller-supplied A and PTR inspection and reconciliation through the official `community.general.nsupdate` module | Available; live target validation remains required | [role guide](ansible/roles/dns_update/README.md) |

The roles are not a single installer. The MariaDB baseline does not configure a replication channel; the replication
role does not initialise data; MaxScale does not create database accounts or claim a virtual IP; and Keepalived does
not infer application health. These boundaries keep FreeIPA/DNS independently usable from the MariaDB/MaxScale/VRRP
data plane.

The DNS update role's contract, syntax, `yamllint`, and `ansible-lint` checks pass. A local live run was blocked before
reaching DNS by a Python 3.14 controller RPC incompatibility, so the repository makes no live DNS deployment claim.

## Architecture and operations

- [Identity and DNS boundaries](docs/architecture/identity-and-dns.md) explains FreeIPA primary/replica choices and
  integrated, BIND, Technitium, and existing-DNS provider contracts.
- [MariaDB, MaxScale, VRRP, and DNS composition](docs/architecture/data-plane.md) maps the independent role
  interfaces and a safe composition order.
- [Safe usage and validation](docs/operations/safe-usage.md) gives read-only, check-mode, apply, and post-change
  validation patterns.
- [Troubleshooting](docs/operations/troubleshooting.md) groups common validation failures and bounded recovery steps.
- [Public roadmap](docs/roadmap.md) records planned interfaces and validation work.

Publication-ready article drafts are collected under [`docs/articles/`](docs/articles/):

- [A bounded FreeIPA bootstrap](docs/articles/bounded-freeipa-bootstrap.md)
- [Building a safe MariaDB foundation](docs/articles/mariadb-foundation.md)
- [Composing replication, MaxScale, and VRRP](docs/articles/mariadb-maxscale-vrrp.md)

## Quick links

Safe, documentation-only fixtures use RFC 5737 IPv4 ranges, RFC 3849 IPv6 ranges, and the reserved `example.invalid`
namespace. They do not represent reachable hosts.

| Area | Entry points |
| --- | --- |
| FreeIPA example and tests | [`examples/freeipa/freeipa.env.example`](examples/freeipa/freeipa.env.example), [`tests/freeipa-bootstrap/test.sh`](tests/freeipa-bootstrap/test.sh) |
| MariaDB baseline example and tests | [`examples/mariadb/site.yml`](examples/mariadb/site.yml), [`tests/mariadb`](tests/mariadb) |
| MariaDB replication example and tests | [`examples/mariadb-replication/playbook.yml`](examples/mariadb-replication/playbook.yml), [`tests/mariadb_replication`](tests/mariadb_replication) |
| MaxScale fixture and tests | [`examples/maxscale-ha/site.yml`](examples/maxscale-ha/site.yml), [`tests/maxscale`](tests/maxscale) |
| Keepalived fixture and tests | [`examples/keepalived/playbook.yml`](examples/keepalived/playbook.yml), [`tests/keepalived`](tests/keepalived) |
| DNS update example and tests | [`examples/dns-update/site.yml`](examples/dns-update/site.yml), [`tests/dns_update/test_contract.py`](tests/dns_update/test_contract.py) |
| Licence | [`LICENSE`](LICENSE) |

Begin with the component README and run its syntax or read-only checks before making state-changing changes. Keep
passwords, certificates, private keys, access tokens, and environment-specific inventory outside this repository.

## Design principles

- Keep assumptions, required privileges, supported versions, and operational limits visible.
- Prefer idempotent, state-aware changes and explicit opt-in switches for package, service, firewall, or topology work.
- Validate prerequisites before making changes; do not silently repair database identity, replication coordinates, DNS
  authority, or an existing high-availability deployment.
- Keep credentials and certificate material in an approved external secret or PKI workflow. Examples contain paths or
  references only; they do not contain secret values.
- Treat logging, backup, recovery, and maintenance as part of the operational contract.
- Test examples on disposable hosts before adapting them to an environment with real data or authoritative services.

## Licence and third-party boundary

Original automation, examples, and documentation in this repository are provided under the [MIT License](LICENSE).
An MIT-licensed role is not a licence for the software it installs or configures. MariaDB Server, FreeIPA, BIND,
Webmin, Technitium DNS Server, MaxScale, Keepalived, `community.general`, other Ansible collections, and operating-system
packages retain their own licences, repository terms, trademarks, and attribution requirements.

MaxScale has an explicit boundary: this repository does not redistribute MaxScale software, packages, repository
metadata, vendor legal text, or credentials, and it does not relicense MaxScale. The role only renders a caller-supplied
configuration model and, when explicitly enabled, integrates with the official MariaDB repository. Review the current
[MariaDB MaxScale licensing information](https://mariadb.com/bsl11/) and [official MaxScale documentation](https://mariadb.com/docs/maxscale/)
before enabling package or repository management.

Likewise, MariaDB packages are obtained from the selected official repository at deployment time rather than bundled
in this repository. Read each vendor's current terms and the role README before using a package or integration.

## Public-use boundary

Only material suitable for public distribution belongs here. Do not add credentials, private keys, access tokens,
personal information, internal addresses or hostnames, restricted configuration, or data copied from a live service.
Use placeholders, documentation ranges, and `*.example` files. A caller remains responsible for reviewing its own
inventory, secrets, change controls, backups, and legal obligations before applying any component.
