# Public roadmap

The toolkit follows a small-component model: a feature is published when its inputs, outputs, validation path, and
operational boundary can be explained without environment-specific data. Dates are intentionally omitted; work moves
when the corresponding interface and tests are ready.

## Current baseline

- The FreeIPA bootstrap provides primary and replica orchestration, integrated DNS, managed BIND/Webmin and Technitium
  provider paths, a read-only existing-DNS provider, transactional record handling, and preflight/dry-run modes.
- The MariaDB baseline provides a supported Ubuntu target contract, official repository integration, split configuration,
  guarded first-node initialisation, hardening, deterministic identity, and an external TLS consumer contract.
- The MariaDB replication role provides standard asynchronous one-primary/many-replica configuration, GTID and explicit
  file/position modes, per-replica validation, consistency checks, and health summaries.
- The MaxScale role provides a bounded 24.02-oriented configuration model with candidate validation, optional service
  and firewall integration, and explicit MariaDB licensing boundaries. MaxScale software is not included.
- The Keepalived role provides independent VRRP instances with protected existing-deployment defaults and optional
  generic firewall rules.
- The `dns_update` role provides explicit A/PTR inspection and optional reconciliation through the official
  `community.general.nsupdate` module. GSS-TSIG is the secure default, TSIG is optional, and unsigned mode is test-only
  and disabled by default. Its contract, syntax, `yamllint`, and `ansible-lint` checks pass.
- Live DNS target validation remains pending. A local run was blocked before reaching DNS by a Python 3.14 controller
  RPC incompatibility, so no live deployment outcome is claimed.

## Near-term work

### Validate DNS updates on a supported target

Exercise explicit A/PTR records against a disposable authoritative service using external GSS-TSIG or TSIG credentials.
Confirm read-only check-mode behaviour, per-record error isolation, PTR conflict handling, and the hard-failure switch.
Repeat the run with a supported controller Python/Ansible environment before making a live-runtime claim. The role must
continue to require an explicit server and zone and must not infer authority.

### Add composition fixtures without coupling roles

Provide a small documentation-only inventory demonstrating the hand-off from MariaDB baseline to replication to
MaxScale and, separately, Keepalived and DNS naming. The fixture should render contracts and checks without installing
packages, creating accounts, claiming a VIP, or contacting an external DNS service.

### Expand disposable-host validation

Add repeatable staging coverage for supported OS/release combinations, certificate rotation, restrictive parent
directory permissions, existing-service guards, BIND primary/secondary transfers, Technitium API reconciliation,
MariaDB 11/12 behaviour, MaxScale candidate reload checks, and Keepalived peer validation. Runtime claims should remain
scoped to versions and host images actually exercised.

### Strengthen upgrade and recovery notes

Document version-specific upgrade sequencing, MariaDB data-copy records, FreeIPA backup/restore drills, MaxScale
configuration recovery, DNS SOA/serial recovery, and serial VRRP maintenance. Preserve the current boundaries around
PKI, credentials, application policy, and authoritative external services.

## Release and maintenance direction

The public repository should use Semantic Versioning for component interface changes, Conventional Commits for reviewable
history, and annotated tags for published baselines. Release notes should describe user-visible changes, compatibility,
validation performed, known limitations, and third-party terms without claiming unverified deployment outcomes. A tag
must identify the exact source tree and corresponding changelog entry.

### Initial public release target

The initial public baseline is targeted as `0.1.0`. This pre-1.0 marker identifies a
coherent, reviewable toolkit baseline while the component interfaces and disposable-host
validation continue to mature. It is a release milestone, not a claim of production
readiness or universal platform compatibility; release notes will state the tested
scope, known limitations, and third-party terms for the exact source tree.

Breaking configuration or CLI changes are major-version work once public interfaces are stable. Backward-compatible
features are minor changes; fixes and documentation corrections are patch changes. During `0.x` development, the
compatibility contract may still require a minor release for a breaking adjustment.

## Explicit non-goals

The roadmap does not promise a single end-to-end installer, automatic database failover, application account or schema
management, PKI enrolment, backup/restore orchestration, hidden DNS writes, or redistribution of MaxScale software.
Those concerns require separate ownership, policy, and validation.
