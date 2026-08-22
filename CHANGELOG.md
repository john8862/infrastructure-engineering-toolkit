# Changelog

## 0.1.0 (2026-08-22)

Initial public baseline for reusable infrastructure engineering automation.

### Components

- **DNS update** — An Ansible role for explicit forward and reverse record reconciliation. [Commit](https://github.com/john8862/infrastructure-engineering-toolkit/commit/2ffac18c1850dfcd5b2afaafd337f332806411c2)
- **FreeIPA bootstrap** — A bounded installer and configuration component with primary and replica orchestration. [Commit](https://github.com/john8862/infrastructure-engineering-toolkit/commit/b16b5d8fe7804bf5921e0a493d1b311b652f32d6)
- **Keepalived** — A generic VRRP role for high-availability failover. [Commit](https://github.com/john8862/infrastructure-engineering-toolkit/commit/802fa829c3438dc36fc4dccd02c7bd8c2cb2b05b)
- **MariaDB** — A standalone Ubuntu database baseline role. [Commit](https://github.com/john8862/infrastructure-engineering-toolkit/commit/03a7156248eb3e612ec32e7ca0c7a1e3e10e4567)
- **MariaDB replication** — An asynchronous replication role. [Commit](https://github.com/john8862/infrastructure-engineering-toolkit/commit/71e3bcfd7608b1106b17a9da1445459a9a07d828)
- **MaxScale** — A bounded routing role for MariaDB services. [Commit](https://github.com/john8862/infrastructure-engineering-toolkit/commit/7871218146bb94ec38ab5e270ecc2117b8494ede)
- **Release assets** — Five independent role archives plus a separate FreeIPA archive, each with deterministic checksums and a machine-readable manifest. [Commit](https://github.com/john8862/infrastructure-engineering-toolkit/commit/dbf45bd3bb426b80a106ca786d024681982cd750)

### Documentation

- Documented the pre-1.0 release target and its scope. [Commit](https://github.com/john8862/infrastructure-engineering-toolkit/commit/d1ff51b9637dc6267d83ff596cb24afcedc28e5f)

### Validation

- Shell syntax and the FreeIPA contract suite (231 tests).
- Python component contracts and deterministic release-asset checks.
- Ansible lint, YAML validation, fixture syntax checks, and Markdown/whitespace gates.
