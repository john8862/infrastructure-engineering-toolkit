# Building a safe MariaDB foundation before high availability

> Article draft — Infrastructure Engineering Toolkit

A database baseline should make a host predictable without pretending to be a complete high-availability platform. The
MariaDB role follows that boundary: it prepares a standalone Ubuntu host, hardens the service, establishes stable
configuration and certificate paths, and verifies prerequisites that a future topology role will consume.

## Select the release deliberately

The default target is Ubuntu 24.04 (noble) with MariaDB 11.8 from the official MariaDB APT repository. The target
distribution, codename, repository series, and server series remain explicit variables. This avoids silently replacing
the selected release with a distribution-provided package that has a different lifecycle or option surface.

The role declares its Ansible collection requirements and expects PyMySQL, `python3-debian`, and ACL support on the
target. Collections are not bundled. A caller can review collection versions and the target image as part of the same
change that selects a MariaDB release.

## Split configuration by responsibility

The role owns focused files under the distribution's MariaDB configuration directory for server identity and connection
policy, GTID/binlog/relay defaults, security and optional TLS, logging, performance, and inventory-derived node
identity.

The templates use MariaDB's `[server]`, `[mariadbd]`, and release-specific option groups rather than the MySQL
`[mysqld]` group. Splitting files makes a rendered diff easier to review and gives a later topology role a clear
contract to consume without making the baseline own replication commands.

When a server ID is not provided, the role derives one from inventory order and an offset. That is convenient for a
fixture but not always sufficient for a long-lived service. An operator who needs an immutable identity should set an
explicit unique value and preserve it across inventory changes.

## Consume certificates without owning the PKI

TLS is a consumer contract. An external certificate workflow supplies the server certificate, key, and CA paths. The
role validates those files, grants the MariaDB service account only the required traversal and read access, and creates
stable MariaDB-owned links such as:

```text
/etc/mysql/ssl/ca.pem
/etc/mysql/ssl/server-cert.pem
/etc/mysql/ssl/server-key.pem
```

MariaDB configuration references stable links rather than a provider's changing storage path. The role does not
request, renew, copy, own, or publish certificates. When a provider rotates its files, the provider output and a normal
role convergence are the only parts that need to change.

The reserved `replication` account requires SSL, but it uses the same server TLS links. This is an account transport
policy, not an invitation for the baseline role to create a replication channel.

## Guard first-node initialisation

Resetting GTID or binary-log state can invalidate an existing topology. The role therefore allows a first-node reset only
when the caller declares a new server, enables the reset switch, the ready marker is absent, GTID positions are empty,
no application databases or unexpected accounts exist, and no replication status is present. A successful run writes a
ready marker; later runs never reset state unconditionally.

This guard is intentionally stricter than a “fresh enough” heuristic. If a host already contains accounts or data, the
role reports existing state and expects a separately reviewed decision. It does not delete data or users just to satisfy
the initialisation path.

## Stop before topology-specific work

The baseline ends at a Ready-for-HA assertion. It does not create databases, application users, MaxScale users, backup
schedules, Galera configuration, a replication channel, `CHANGE MASTER TO`, `CHANGE REPLICATION SOURCE TO`, or
`START REPLICA`.

That separation gives a later replication role a useful starting point: server identity, binary-log readiness, TLS paths,
and account transport policy are known, while topology and data-copy decisions remain explicit. It also allows a caller
to use the baseline on a standalone service with no high-availability requirement.

## Validate in two modes

Check mode is useful for reviewing package, directory, file, ACL, and symlink changes:

```bash
ansible-playbook -i examples/mariadb/inventory.example.yml \
  examples/mariadb/site.yml --check --diff
```

On a fresh host, checks that require a not-yet-created socket, repository keyring, TLS asset, or authenticated query are
deferred. The final runtime assertion belongs to a real run after those prerequisites exist. This distinction avoids
confusing “the playbook parsed” with “the database is ready for a topology change”.

## Conclusion

A strong baseline is deliberately incomplete. It manages host concerns that should be consistent on every node, exposes
stable contracts for TLS and identity, and refuses to make irreversible topology assumptions. The result is a smaller
change surface for replication, proxy, and failover roles—and a clearer answer when a validation gate fails.
