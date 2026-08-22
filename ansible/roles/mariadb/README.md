# MariaDB Ansible role

This role installs and hardens a standalone MariaDB release series on a
configured Ubuntu target. The defaults select MariaDB 11.8 on Ubuntu 24.04
(noble). It is intentionally generic and can be reused in an independent
Ansible project. Environment-specific values belong in inventory or play
variables; credentials belong in Ansible Vault or an external secret store.

## Scope

The role provides:

- the selected MariaDB release series from the official MariaDB APT
  repository, never Ubuntu's built-in MariaDB packages;
- mariadb-server, client, backup, operational tooling, PyMySQL, and the
  optional auth_pam plugin package when the repository provides one;
- split configuration under /etc/mysql/mariadb.conf.d/;
- a production baseline for UTF-8, connection limits, InnoDB durability,
  bounded slow logging, GTID/binlog readiness, and optional TLS;
- deterministic inventory-derived server_id and report_host values;
- root hardening and one reserved replication account requiring SSL;
- a MariaDB-owned stable TLS directory with server and future replication
  client certificate links;
- idempotent, guarded first-node GTID initialization; and
- a final Ready-for-HA assertion without configuring replication topology.

The role does not create application databases, MaxScale/monitor users,
application users, backup schedules, Galera configuration, CHANGE MASTER TO,
START REPLICA, or any primary/replica relationship.

## Supported platform and dependencies

- Ubuntu 24.04 LTS (noble) by default; the target distribution, version, and
  release variables are explicit;
- ansible-core 2.15 or newer
- ansible.mariadb for MariaDB modules
- ansible.posix for TLS ACLs
- PyMySQL on the target Python interpreter
- python3-debian on the target Python interpreter for the deb822 repository module
- acl on the target host

Collection requirements are declared in `meta/requirements.yml`; collections
are intentionally not vendored. The collection modules require PyMySQL on the
managed host, not only on the Ansible controller.

## Configuration layout

The role owns these files and not the distribution's monolithic server file.
The templates use MariaDB option groups deliberately: [server] for common
server settings, [mariadbd] for daemon settings, and
[mariadbd-<selected-series>] for version-specific settings. The
MySQL-compatible [mysqld] group is not used.

| File | Responsibility |
| --- | --- |
| 50-server.cnf | bind address, name resolution, charset, collation, connections, secure file directory |
| 60-replication.cnf | node-independent GTID/binlog/relay defaults, durability, optional filters |
| 70-security.cnf | optional TLS, secure transport, optional auth_pam load |
| 80-logging.cnf | error/general/slow log destinations and one-second slow threshold |
| 90-performance.cnf | InnoDB buffer pool, redo, file-per-table, flush durability, purge threads |
| 99-node.cnf | dynamic server-id and report-host |

Replication filters are empty by default, so all databases replicate when a
future HA role configures a topology. Optional filter variables exist, but
must be introduced deliberately:

~~~yaml
mariadb_binlog_do_db: []
mariadb_binlog_ignore_db: []
mariadb_replicate_do_db: []
mariadb_replicate_ignore_db: []
~~~

The default log paths are /var/log/mysql/mariadb-bin and
/var/log/mysql/mariadb-relay-bin. The role creates /var/log/mysql with
ownership suitable for the MariaDB service.

## Node identity

If mariadb_server_id is unset, the role calculates:

~~~text
mariadb_server_id_offset + index(inventory_hostname in groups[mariadb_inventory_group]) + 1
~~~

The default group is mariadb and the default offset is 1000. This means a host
added to the group receives a deterministic identity without hardcoded
hostnames. For an immutable production identity, set an explicit
mariadb_server_id in host variables and keep it unique. report_host defaults
to the discovered FQDN and can be overridden with mariadb_report_host.

## TLS consumer contract

TLS is enabled and require_secure_transport is on by default for backwards
compatibility. The role consumes already-managed certificate assets through a
generic interface:

~~~yaml
mariadb_tls_enabled: true
mariadb_tls_certificate:
  certificate: /provider-managed/path/server.crt
  private_key: /provider-managed/path/server.key
  ca_certificate: /provider-managed/path/ca.crt
mariadb_ssl_directory: /etc/mysql/ssl
~~~

The role validates the configured source files, grants the mysql service
account only the directory-traversal and file-read ACLs it needs, and creates
these MariaDB-owned stable links:

~~~text
/etc/mysql/ssl/ca.pem
/etc/mysql/ssl/server-cert.pem
/etc/mysql/ssl/server-key.pem
~~~

The directory and link location are configurable through mariadb_ssl_directory
and the mariadb_tls_*_link variables. MariaDB configuration references only
those stable links; it never embeds a provider storage path. Certificate
renewal or a provider filename/path change therefore requires only the
provider output and normal role convergence, not a MariaDB template change.

The role does not request, renew, copy, own, or otherwise manage certificates.
It never changes provider-file ownership or mode. Set mariadb_tls_enabled to
false to omit TLS configuration, source validation, ACL grants, and link
creation. Any existing role-managed TLS symlinks are removed in that mode;
provider ACL entries are not revoked because the role cannot safely assume
that provider files are not shared with another consumer.

## Replication account TLS

The reserved `replication` account is created with `REQUIRE SSL`. This is an
account transport policy; it does not require a second certificate request or
separate `replication-*.pem` links. MariaDB uses the same three server TLS
links shown above:

~~~text
/etc/mysql/ssl/ca.pem
/etc/mysql/ssl/server-cert.pem
/etc/mysql/ssl/server-key.pem
~~~

Downstream HA roles should consume the `mariadb_tls_runtime_paths` fact or
these same stable paths. This role does not configure channels, issue `CHANGE
MASTER TO` or `CHANGE REPLICATION SOURCE TO`, or start replication.

## Bootstrap safety

The role waits for the local socket, supports implicit root authentication on a
new installation, sets a Vault-provided root password, removes anonymous and
alternate root accounts, removes the default test database, flushes
privileges, and creates only:

~~~text
replication@'%' REQUIRE SSL
GRANT REPLICATION SLAVE ON *.*
~~~

RESET MASTER is never unconditional. It can run only when all of the
following are true:

1. mariadb_bootstrap_new_server is true;
2. mariadb_bootstrap_reset_master is true;
3. the Ready marker is absent;
4. no application databases or unexpected accounts exist;
5. gtid_slave_pos and gtid_binlog_pos are empty; and
6. no replication status is present.

After successful initialization the role writes
/etc/mysql/.ansible-mariadb-ready. Later runs never reset GTID/binlog state.
If a host already contains state and must be inspected without account
mutation, set mariadb_bootstrap_existing_host_mode to skip after an operator
review. That mode still renders configuration and performs TLS link/ACL
preparation but does not claim Ready-for-HA status.

The final verification requires the selected MariaDB series, the expected
identity and settings, clean replica state, exactly one reserved replication
account with TLS, no unexpected users, and the Ready marker.

## Idempotence and convergence

The role is designed so a second run converges to the same state without
repeating successful writes. Managed directories, files, templates, ACLs, and
symbolic links are state-aware; the repository keyring is not force-downloaded;
and database account modules compare the current password, grants, and TLS
requirements before changing them. Privilege flushing runs only when account
or test-database cleanup actually changed state. Bootstrap markers prevent
re-writing completed initialization metadata.

Read-only probes and final verification still run on every normal execution.
They are intentional: they detect drift while preserving idempotence rather
than assuming that a previous run guarantees the current server state.

## Dry-run and standard tags

The role supports Ansible check mode. Use `--diff` with `--check` when reviewing
configuration changes:

~~~bash
ansible-playbook playbooks/mariadb.yml --check --diff
~~~

Existing configuration files are rendered with diff output, and state-aware
directory, package, ACL, and symbolic-link tasks report the changes they would
make. Read-only MariaDB Pre-checks run when the service is already reachable.
On a fresh host, check mode does not start a service or create provider assets,
so checks that require the not-yet-created socket, TLS files, repository
keyring, or APT metadata are reported as deferred instead of failing. Database
account, privilege, and GTID writes are also deferred as one unit because a
check-mode root-password prediction cannot be used for subsequent authenticated
queries. The final Ready-for-HA runtime assertion is performed by a real run
after those changes have been applied.

The role exposes standard tags for focused execution:

| Tag | Scope |
| --- | --- |
| install | Official repository, packages, operational directories, and service availability |
| configure | Service configuration, TLS links/ACLs, and guarded database bootstrap |
| healthcheck | Read-only MariaDB Pre-checks and the final runtime contract on a real run |
| validate | Input assertions, Pre-checks, and the final runtime contract on a real run |

Examples:

~~~bash
ansible-playbook playbooks/mariadb.yml --check --diff --tags install
ansible-playbook playbooks/mariadb.yml --check --diff --tags configure
ansible-playbook playbooks/mariadb.yml --check --diff --tags healthcheck
ansible-playbook playbooks/mariadb.yml --check --diff --tags validate
~~~

`healthcheck` and `validate` are intended for an already-installed and
reachable MariaDB host. In check mode they still perform the safe read-only
Pre-checks, while the final runtime assertion is intentionally deferred until
the role can observe the state produced by a real convergence run.

## Example role invocation

~~~yaml
---
- name: Prepare database nodes
  hosts: mariadb
  become: true
  roles:
    - role: mariadb
~~~

An external certificate provider must run before this role and expose its
current certificate paths through inventory or another external adapter.
The MariaDB role has no dependency on a particular provider, enrollment
protocol, filename convention, or storage directory.

## Important variables

| Variable | Default | Notes |
| --- | --- | --- |
| mariadb_server_version | 11.8 | MariaDB release series; latest patch in the series is selected |
| mariadb_repository_version | same as server series | Official repository series; must match mariadb_server_version |
| mariadb_target_distribution | Ubuntu | Target operating system distribution |
| mariadb_target_distribution_version | 24.04 | Required target OS version |
| mariadb_target_distribution_release | noble | Required Ubuntu codename and APT suite |
| mariadb_repository_distribution | target release | APT suite used by the MariaDB repository |
| mariadb_root_password | empty | Required; use Vault |
| mariadb_replication_password | empty | Required; use Vault |
| mariadb_server_id | unset | Explicit value overrides inventory-derived identity |
| mariadb_server_id_offset | 1000 | Used for deterministic derived IDs |
| mariadb_report_host | discovered FQDN | Optional explicit report host |
| mariadb_tls_enabled | true | Set false to omit TLS config, ACL grants, and links |
| mariadb_tls_certificate | empty paths | Provider-managed source asset paths |
| mariadb_ssl_directory | /etc/mysql/ssl | MariaDB-owned stable certificate directory |
| mariadb_tls_*_link | under mariadb_ssl_directory | Stable server certificate links |
| mariadb_replication_tls_requires | `{SSL: null}` | Account transport policy; does not create separate certificate links |
| mariadb_bootstrap_new_server | false | Explicit new-server declaration required before any reset |
| mariadb_bootstrap_reset_master | false | Guarded first-node reset switch; remains disabled by default |
| mariadb_bootstrap_existing_host_mode | fail | skip only after review |
| mariadb_auth_pam_enabled | true | Load plugin when a package candidate exists |
| mariadb_auth_pam_required | false | Fail if the selected repository lacks the plugin |
| mariadb_package_state | present | Install the selected candidate without implicit upgrades |
| mariadb_innodb_buffer_pool_size | 8G | Tune by host capacity |
| mariadb_max_connections | 300 | Connection ceiling |

See defaults/main.yml for the complete interface.

## Verification

Run validation from the repository root:

~~~bash
ansible-playbook -i examples/mariadb/inventory.example.yml examples/mariadb/site.yml --syntax-check
ansible-lint ansible/roles/mariadb
python3 -m unittest discover -s tests/mariadb -p 'test_*.py'
~~~

Do not run the example playbook against a real host until the two secret
variables are supplied, the external provider has published usable assets, the
new-server decision is explicit, and network access to the MariaDB hosts is
confirmed.

## Future architecture

This role is the baseline layer. A later HA role should consume its marker and
configuration contract, then own topology-specific actions such as source and
replica selection, CHANGE MASTER TO or CHANGE REPLICATION SOURCE TO, GTID
position selection, START REPLICA, replication health checks, failover, and
MaxScale integration. It can consume the stable MariaDB server TLS paths
without additional certificate preparation. Application databases/users should be
separate roles.

## Official references

- [MariaDB package repository setup and usage](https://mariadb.com/docs/server/server-management/install-and-upgrade-mariadb/installing-mariadb/binary-packages/mariadb-package-repository-setup-and-usage)
- [MariaDB package-signing keys](https://mariadb.com/docs/server/server-management/install-and-upgrade-mariadb/installing-mariadb/binary-packages/gpg)
- [Ansible `ansible.mariadb` collection](https://galaxy.ansible.com/ui/repo/published/ansible/mariadb/)

## Remaining recommended improvements

- Add Molecule or equivalent staging tests that exercise both TLS-enabled and
  TLS-disabled convergence, certificate rotation, wrong-type link
  destinations, and provider paths with restrictive parent directories.
- Version the external certificate-provider adapter separately from this
  role, with an explicit contract test for the exported certificate fields.
- Have the future HA role consume the published stable runtime paths and add
  replication-channel configuration and health checks without changing this
  baseline role.
- If the certificate provider can guarantee that its assets are not shared by
  other consumers, add an explicit, provider-approved policy for revoking the
  mysql ACL entries when TLS is disabled.
