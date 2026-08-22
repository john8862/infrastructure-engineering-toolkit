# Generic MaxScale role

This role provides a small, reusable MaxScale 24.02-oriented core for Debian
family hosts. It can integrate the official MariaDB APT repository, render the
global/server/monitor/service/listener configuration model, validate externally
provisioned TLS paths, manage logging and an optional systemd drop-in, and
perform a candidate configuration check followed by a guarded reload and
health check.

The role is intentionally independent of a particular database topology. Use
`example.invalid`, documentation addresses from RFC 5737/3849, and secret
manager lookups in examples. `maxscale_servers`, `maxscale_monitors`,
`maxscale_services`, and `maxscale_listeners` are data-only lists. The options
maps are passed through so that callers can select documented MaxScale module
settings without embedding customer assumptions.

## Usage

```yaml
maxscale_enabled: true
maxscale_manage_repository: false  # enable after reviewing the vendor terms
maxscale_manage_package: false
maxscale_manage_service: false
maxscale_config_validate_enabled: false  # true on a host with MaxScale installed

maxscale_servers:
  - name: db-a
    address: 192.0.2.11
    port: 3306
  - name: db-b
    address: 192.0.2.12
    port: 3306

maxscale_monitors:
  - name: mariadb-monitor
    module: mariadbmon
    servers: [db-a, db-b]
    # user/password can be external lookups; no account is created here.

maxscale_services:
  - name: read-write
    router: readwritesplit
    servers: [db-a, db-b]

maxscale_listeners:
  - name: read-write-listener
    service: read-write
    address: 0.0.0.0
    port: 3306
```

The role defaults to rendering only. Repository, package, service, firewall,
and health changes are explicit switches so a caller can stage and review a
deployment. A managed service is reloaded only after Ansible's candidate
validation succeeds. When enabled, the post-reload HTTP check is sent to the
configured MaxScale REST endpoint; it does not create an admin user or infer
credentials.

TLS settings (`ssl_cert`, `ssl_key`, and `ssl_ca`) are paths to files managed
by an external PKI workflow. The role checks that required files exist and that
certificate/key values are paired. It never creates, copies, or publishes
private keys, certificates, keytabs, or secrets. Set
`maxscale_tls_validate_hostname: true` only when the caller has supplied a
hostname identity that should be checked by its own certificate workflow.

The optional UFW integration adds explicit listener/admin rules only when
`maxscale_firewall_enabled` is true. It never enables, flushes, or replaces a
host firewall policy.

## Deliberate boundaries

This public v0.3 core does not manage Binlog Router instances, GTID/binlog
retention, external replicas, Config Sync bootstrap/rebuild, SSH or sudo
access, PAM, MaxScale administrator bootstrap, database credential creation,
generated maxkeys/.secrets material, customer health scripts, or runtime
state. Those concerns require a separate, reviewed integration and are not
silently inferred from this role.

Keepalived/VRRP and DNS are separate roles. Compose them in a playbook when
needed; this role has no dependency on either role and does not embed health
logic in VRRP.

## Licensing boundary

The role code in this repository is released under the MIT License. MaxScale
software, repository metadata, packages, and documentation remain governed by
MariaDB's current Business Source License (BSL), EULA, and other applicable
terms; they are not redistributed or relicensed by this repository. Review the
[MariaDB MaxScale licensing information](https://mariadb.com/bsl11/) and the
[official MaxScale documentation](https://mariadb.com/docs/maxscale/) before
using the repository integration in production. This README links to vendor
terms rather than copying them.

## Validation and operations

Run the role in check mode first. On an installed host enable
`maxscale_config_validate_enabled`, keep credentials in an external secret
manager, and verify that the candidate check, service state, and REST health
endpoint pass before relying on a reload. The role does not claim VIPs or
force failover. If a reload or health check fails, stop the change and restore
the last known-good configuration using the backup produced by your change
workflow; automated rollback is intentionally outside this bounded core.
