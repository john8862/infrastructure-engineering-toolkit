# MariaDB, MaxScale, VRRP, and DNS composition

The database and service-availability components are deliberately independent. A caller can use the MariaDB baseline
without replication, replication without MaxScale, MaxScale without Keepalived, and any of those without changing DNS.
Composition is expressed in the caller's inventory and playbooks rather than hidden in role dependencies.

## Layers and ownership

```text
  DNS name / record ownership
              |
       optional Keepalived VRRP VIP
              |
       optional MaxScale listener
              |
   MariaDB replication primary/replicas
              |
       MariaDB baseline on each node
```

The arrows describe a possible traffic path, not an automatic deployment. Each layer has a separate contract:

| Layer | Owns | Consumes | Does not own |
| --- | --- | --- | --- |
| MariaDB baseline | Official repository selection, packages, split configuration, hardening, TLS stable links, deterministic node identity, and guarded first-node initialisation | Host variables, external certificate paths, and Vault-supplied secret values | Application databases/users, replication channels, failover, MaxScale users, backups, or DNS |
| MariaDB replication | One writable primary, one or more asynchronous replicas, replication account, GTID or explicit file/position channel, consistency checks, and health summary | Existing MariaDB settings, a consistent data copy, topology variables, and existing TLS assets | Data copy/restore, server identity changes, repository selection, Galera, failover, MaxScale, Keepalived, or PKI |
| MaxScale | Data-only server/monitor/service/listener model, configuration rendering, candidate validation, optional service reload, logging, and optional health endpoint check | Caller-supplied backend addresses, module options, credentials from an external secret workflow, and TLS paths | MariaDB account creation, database state, binlog retention, external replicas, VIP ownership, DNS, or software redistribution |
| Keepalived | Independent VRRP instances, peer selection, least-privilege references to caller-supplied health programs, and opt-in generic VRRP firewall rules | Explicit interface, peer, priority, VIP, and health-script paths | Database/proxy semantics, service discovery, DNS changes, failover policy, or health-program implementation |
| DNS | Names, zones, A/PTR/SRV/TXT records, and provider-specific authority or transfer policy | An approved external zone policy and component-produced record contract | Identity policy, database failover, VIP ownership, or application-level health decisions |
| `dns_update` | Explicit A/PTR inspection and optional reconciliation, per-record result reporting, and conservative PTR conflict handling | Caller-supplied server, zone, record values, and external GSS-TSIG or TSIG credentials | Zone or server discovery, FreeIPA/MariaDB/MaxScale/VRRP state, and unsigned production updates |

## MariaDB foundation before topology

The MariaDB role is a standalone Ubuntu baseline. Its default release series is MariaDB 11.8 on Ubuntu 24.04/noble,
but the release and target distribution values remain explicit inputs. It uses split option files rather than a
distribution monolithic file and prepares GTID/binlog readiness without configuring a primary/replica relationship.

The role derives a deterministic `server_id` from inventory when one is not supplied. A caller should provide an
explicit stable value when the identity must survive inventory ordering changes. TLS is a consumer contract: source
certificate paths come from an external PKI workflow, and the role creates MariaDB-owned stable links without
requesting, renewing, copying, or taking ownership of the source assets.

First-node GTID reset is guarded by an explicit new-server declaration, an enabled reset switch, an absent ready marker,
empty GTID positions, no application databases or unexpected accounts, and no replication state. Later runs do not
reset existing state. This guard is a boundary, not a substitute for a backup or restore plan.

## Replication as a separate layer

The replication role supports MariaDB 11.x and 12.x standard asynchronous replication. GTID with the replica position
model is the default; traditional binary-log file/position mode is available when a caller supplies coordinates tied to
the consistent data copy. TLS can be one-way or mutual, but all certificate files already exist on the target hosts.

The role validates server IDs, binary logging, network reachability, account transport policy, data inventories, storage
engines, and checksums before configuring a replica. It does not copy data, derive a safe position, enable binary
logging, change `server_id`, edit `my.cnf`, or recover a divergent replica. Per-replica failures are reported and
isolated so that a separate replica can still be assessed; a primary safety failure remains a failed run.

The baseline and replication role can therefore be used in two explicit phases:

1. Prepare every host with the baseline and an approved data-copy workflow.
2. Apply replication with an explicit topology, account, position policy, and health check.

Do not infer the second phase from the presence of the first role.

## MaxScale above the database

MaxScale receives data-only definitions for MariaDB servers, monitor modules, services, routers, and listeners. The role
defaults to rendering and review; repository, package, service, firewall, and health changes are opt-in. A managed
reload occurs only after candidate configuration validation succeeds. An optional REST health check runs after the
service is active and does not bootstrap an administrator account.

TLS paths are validated against files provisioned by an external PKI workflow. Credentials are references supplied by
the caller; no database or MaxScale account is created. The role does not manage Binlog Router, GTID/binlog retention,
Config Sync bootstrap, SSH/sudo, PAM, external replica state, or runtime failover.

MaxScale software, packages, repository metadata, and vendor legal text are not redistributed or relicensed here. The
role's automation is MIT-licensed; MaxScale remains subject to MariaDB's current terms. See the [MaxScale role guide](../../ansible/roles/maxscale/README.md)
and the [MariaDB MaxScale licensing information](https://mariadb.com/bsl11/) before enabling repository or package
management.

## Keepalived and VRRP at the edge

Keepalived describes one or more independent VRRP instances. It does not know whether a VIP fronts MariaDB, MaxScale,
or another service. The caller supplies interface, state, priority, peer addresses, VIP, and optional script paths.
Authentication is disabled by default in the public example; any secret must come from an external secret workflow.

Existing running deployments are validation-only by default. Reconciliation requires an explicit maintenance switch. The
role validates rendered configuration, does not claim a VIP for testing, and does not force failover. Firewall changes
are opt-in and limited to generic VRRP rules through an already installed UFW policy.

If a caller wants a proxy health check to influence VRRP, it must provide and review that health program separately, then
reference its path in the Keepalived instance. No application-specific health logic is inferred from a MaxScale or
MariaDB variable.

## DNS is a naming layer, not a failover controller

DNS can publish a stable service name such as `db-writer.example.invalid`, but the DNS roles do not decide which node
is healthy or claim a VIP. A caller may choose one of these patterns:

- point the name at a Keepalived VIP and let the VRRP layer manage local ownership;
- point the name at a MaxScale listener address; or
- publish direct backend records for diagnostics or controlled maintenance.

The choice belongs to the caller's service design. It must not be inferred by combining role names. Use documentation
addresses such as `192.0.2.20` for a VIP, `198.51.100.10` for a proxy listener, and `203.0.113.11`/`203.0.113.12` for
database examples.

## Explicit A/PTR reconciliation

The `dns_update` role handles a different concern from DNS authority: it reconciles caller-supplied records when the
caller already knows the update server and zone. A record must declare `name`, `type` (`A` or `PTR`), `value`, `zone`,
and `state`; reverse-zone discovery is intentionally absent. The role queries current values first, reports matching
values as unchanged, and leaves a different PTR untouched when the default `report` conflict policy is active.

Both `dns_update_enabled` and `dns_update_manage` default to `false`. Check mode performs read-only inspection and never
obtains a Kerberos ticket or invokes `community.general.nsupdate`. GSS-TSIG is the secure default, standard TSIG is
optional, and unsigned mode requires an explicit test-only opt-in. Credentials are supplied at runtime and are not
stored in the repository. The pinned example uses `community.general` 13.0.0.

The role's contract, syntax, `yamllint`, and `ansible-lint` checks pass. Live target validation remains required: a
local run was blocked before reaching DNS by a Python 3.14 controller RPC incompatibility, so this composition guide
does not claim a live DNS deployment outcome.

## Suggested composition sequence

1. Validate DNS authority and service-name policy separately. Keep external DNS writes out of a database change.
2. Prepare MariaDB nodes and external TLS assets with the baseline role. Record stable server IDs and the ready marker.
3. Establish and verify the data copy and replication coordinates with the replication role.
4. Render and validate MaxScale server, monitor, service, and listener definitions in check mode.
5. Configure Keepalived independently, validate the file, and schedule serial maintenance if an existing deployment is
   being reconciled.
6. Publish or update DNS only after the selected listener/VIP address and health policy have been verified.
7. Re-run component health checks and preserve the change records and rollback material.

The sequence is a safe default, not an automatic workflow. Each step remains independently reversible according to its
own role documentation.
