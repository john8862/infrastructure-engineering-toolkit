# Changelog

## [0.1.0](https://github.com/john8862/infrastructure-engineering-toolkit/compare/v0.1.0...v0.1.0) (2026-08-22)


### Features

* **dns-update:** add explicit A and PTR reconciliation role ([77f2dcc](https://github.com/john8862/infrastructure-engineering-toolkit/commit/77f2dcc991c5de11c1dc7f0058ecdbdb2f03b043))
* **dns-update:** add explicit record reconciliation ([#7](https://github.com/john8862/infrastructure-engineering-toolkit/issues/7)) ([2ffac18](https://github.com/john8862/infrastructure-engineering-toolkit/commit/2ffac18c1850dfcd5b2afaafd337f332806411c2))
* **freeipa:** add bounded bootstrap component ([#2](https://github.com/john8862/infrastructure-engineering-toolkit/issues/2)) ([b16b5d8](https://github.com/john8862/infrastructure-engineering-toolkit/commit/b16b5d8fe7804bf5921e0a493d1b311b652f32d6))
* **freeipa:** add configuration and preflight foundation ([90e3b09](https://github.com/john8862/infrastructure-engineering-toolkit/commit/90e3b0966cdbb095404e4fdb6ed4b8c544bf89c6))
* **freeipa:** add primary and replica orchestration ([a90b476](https://github.com/john8862/infrastructure-engineering-toolkit/commit/a90b4765aed10ec3ab65066b06715748e8a5edf7))
* **freeipa:** add transactional server IP updates ([97c180f](https://github.com/john8862/infrastructure-engineering-toolkit/commit/97c180fb60fdee0995d66e696bc2cd74b9fb4f80))
* **freeipa:** define external DNS provider contracts ([df3b631](https://github.com/john8862/infrastructure-engineering-toolkit/commit/df3b6312509748f3b9bb48ed28ad3841f0f267b3))
* **keepalived:** add generic VRRP role ([db3af2c](https://github.com/john8862/infrastructure-engineering-toolkit/commit/db3af2c11bfc44e8da4e420341c9c7d14b7a8fd7))
* **keepalived:** add generic VRRP role ([#6](https://github.com/john8862/infrastructure-engineering-toolkit/issues/6)) ([802fa82](https://github.com/john8862/infrastructure-engineering-toolkit/commit/802fa829c3438dc36fc4dccd02c7bd8c2cb2b05b))
* **mariadb-replication:** add async replication role ([#4](https://github.com/john8862/infrastructure-engineering-toolkit/issues/4)) ([71e3bcf](https://github.com/john8862/infrastructure-engineering-toolkit/commit/71e3bcfd7608b1106b17a9da1445459a9a07d828))
* **mariadb-replication:** add standalone async replication role ([390705e](https://github.com/john8862/infrastructure-engineering-toolkit/commit/390705e6d7967ced59ad0eb60adf881bb05d1a42))
* **mariadb:** add standalone Ubuntu baseline role ([1359647](https://github.com/john8862/infrastructure-engineering-toolkit/commit/1359647bb000a06b2b29bffd8ade282fcdbe0c5f))
* **mariadb:** add Ubuntu baseline role ([#3](https://github.com/john8862/infrastructure-engineering-toolkit/issues/3)) ([03a7156](https://github.com/john8862/infrastructure-engineering-toolkit/commit/03a7156248eb3e612ec32e7ca0c7a1e3e10e4567))
* **maxscale:** add bounded generic role core ([9bef8fb](https://github.com/john8862/infrastructure-engineering-toolkit/commit/9bef8fbc2c37589b984e2430cb7b5dfee3403721))
* **maxscale:** add bounded routing role ([#5](https://github.com/john8862/infrastructure-engineering-toolkit/issues/5)) ([7871218](https://github.com/john8862/infrastructure-engineering-toolkit/commit/7871218146bb94ec38ab5e270ecc2117b8494ede))
* **release:** publish independent component assets ([dbf45bd](https://github.com/john8862/infrastructure-engineering-toolkit/commit/dbf45bd3bb426b80a106ca786d024681982cd750))


### Documentation

* **release:** document initial pre-1.0 target ([d1ff51b](https://github.com/john8862/infrastructure-engineering-toolkit/commit/d1ff51b9637dc6267d83ff596cb24afcedc28e5f))

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
