# mariadb_replication

Configure standard asynchronous MariaDB replication as one writable primary and one or more replicas.

The role is intentionally standalone. It does not import or modify any other role, does not render a project-specific MariaDB configuration file, and does not require a particular inventory group name. All topology, credentials, paths, and policy decisions are supplied through role variables, normally from inventory or Ansible Vault.

## Supported topology

```text
                         TCP replication
                 +----------------------------+
                 |                            |
        +-------------------+       +-------------------+
        | Initial primary   |       | Replica 1         |
        | writable           | ----> | read_only         |
        | binary log         |       | IO + SQL threads  |
        +-------------------+       +-------------------+
                 |
                 +----------------------------+
                                              +-------------------+
                                              | Replica N         |
                                              | read_only         |
                                              +-------------------+
```

Supported:

- One initial primary and one or more replicas.
- MariaDB 11.x and 12.x community/server releases.
- MariaDB GTID replication, the default, using the replica position (`slave_pos`/`replica_pos`) model.
- Traditional binary-log file/position replication when explicitly selected.
- Optional one-way TLS or mutual TLS using certificate files that already exist on each replica.
- Per-replica validation and failure isolation. A replica whose prerequisites or data checks fail is skipped while other replicas continue.

Out of scope:

- Galera, multi-primary, multi-source, failover, MaxScale, Keepalived, SST, PKI, certificate enrollment, backup, restore, and replica data initialization.
- Copying or synchronizing data. The role verifies the copy and refuses to configure a replica whose selected tables do not match the primary.
- Editing `my.cnf`, changing `server_id`, enabling binary logging, changing `bind_address`, or changing GTID server settings. Those are deliberate prerequisites and must be prepared outside this role.

## Versions and MariaDB behavior

The role validates the server implementation and major release before it changes anything. MariaDB 11.x and 12.x use the same MariaDB GTID model, but the role and the `ansible.mariadb` collection account for the compatibility details:

- The role requests `primary_use_gtid: replica_pos`. The collection translates this to `MASTER_USE_GTID=slave_pos` on MariaDB releases whose command terminology predates the newer replica aliases. `slave_pos` and `replica_pos` are MariaDB-compatible aliases in the supported range.
- `START REPLICA`/`STOP REPLICA` and their older `SLAVE` spellings are selected by the collection based on server version. The role does not hand-roll version-specific SQL for these operations.
- Server certificate verification is passed explicitly through `mariadb_replication_ssl_verify_server_cert`, so the change in default verification behavior from MariaDB 11.3 does not create an implicit policy change.
- MariaDB 12.x represents `read_only` as an enum with `ON`/`OFF` values. The role uses `ON`/`OFF` for MariaDB 12.x and the compatible numeric form on MariaDB 11.x.

For cross-version topologies, MariaDB recommends that the primary be the older version and replicas be the same or newer version. Test upgrades with the exact patch releases used in production.

## Prerequisites

### Controller environment

Run the role from the intended Ansible project virtual environment. At the beginning of a normal role run it checks:

- The Python interpreter that launched Ansible exists.
- A `pyvenv.cfg` marker exists for that interpreter, proving that Ansible was launched from a virtual environment.
- The required controller Python modules are importable. By default these are `ansible` and `pymysql`; set `mariadb_replication_check_ansible_lint_dependency: true` to include `ansiblelint` in the check.

The role does not assume a project path. `mariadb_replication_controller_python` defaults to `ansible_playbook_python`, and `mariadb_replication_controller_venv_path` can be set when the virtual environment root cannot be derived from that executable.

For a caller project containing this role, the expected setup is equivalent to:

```bash
./setup-venv.sh
source .venv/bin/activate
ansible-galaxy collection install --requirements-file requirements.yml --collections-path collections
```

The role requires the `ansible.mariadb` collection (6.x or newer) and PyMySQL on every managed node that executes the database modules. The role checks the managed-node Python imports before contacting MariaDB and reports a clear dependency failure.

### MariaDB and topology

Before applying the role:

1. Install and start MariaDB 11.x or 12.x on every target. Repository selection and package version pinning are outside the role.
2. Apply the role to the initial primary and every declared replica in the same play. The role needs the other hosts' collected facts to validate server ID uniqueness.
3. Set a unique `server_id` on every server. The value must be between 1 and 4,294,967,295.
4. On the primary, enable binary logging, set a stable `log_basename`, and make the primary reachable over TCP. `skip-networking=ON`, a loopback-only `bind_address`, or `read_only=ON` on the primary causes primary validation to fail.
5. In GTID mode, initialize each replica from a consistent copy and ensure its `gtid_slave_pos` describes that copy. In position mode, provide the exact primary log file and position associated with the copy.
6. Give the Ansible administrative account enough privilege to inspect settings, create/update the replication account, and configure a replica. The role does not grant administrative privileges.
7. Store `mariadb_replication_password` and any administrative password in Ansible Vault. The role marks account and channel tasks as `no_log`.

The role can optionally install a caller-supplied package list when `mariadb_replication_manage_packages` is true. It never selects a repository or silently installs a server version.

## Role variables

The complete defaults are in [`defaults/main.yml`](defaults/main.yml). The important variables are grouped below. Values marked “required” must be supplied by inventory/group variables or a host variable; empty defaults are intentional safety guards.

### Topology and connections

| Variable | Default | Description |
| --- | --- | --- |
| `mariadb_replication_node_role` | `""` | Required per host: `primary` or `replica`. |
| `mariadb_replication_initial_primary` | `""` | Required inventory hostname of the one initial primary. |
| `mariadb_replication_primary_host` | `""` | Required on replicas: TCP DNS name/address used to reach the primary. |
| `mariadb_replication_replica_hosts` | `[]` | Required inventory hostnames of all replicas. |
| `mariadb_replication_topology_hosts` | derived | The initial primary plus replica hostnames; normally leave derived. |
| `mariadb_replication_port` | `3306` | TCP port used by the replication channel. |
| `mariadb_replication_connect_retry` | `10` | MariaDB `MASTER_CONNECT_RETRY` value. |
| `mariadb_replication_force_reconfigure` | `false` | Re-send connection settings even when the current channel appears equivalent. Required for deliberate password rotation because MariaDB does not expose the stored channel password in status. |

`mariadb_replication_initial_primary` and `mariadb_replication_replica_hosts` are inventory hostnames. `mariadb_replication_primary_host` is the network endpoint; it may be different from the inventory name.

### Replication account and position mode

| Variable | Default | Description |
| --- | --- | --- |
| `mariadb_replication_user` | `""` | Required account name created on the primary. |
| `mariadb_replication_password` | `""` | Required account password. Keep it in Vault. |
| `mariadb_replication_user_host` | `""` | Required MariaDB account host part. Set an explicit replica source address/range; a wildcard is not a role default. |
| `mariadb_replication_user_privileges` | `*.*:REPLICATION SLAVE` | Minimum privilege string passed to `ansible.mariadb.mariadb_user`; validation requires a replication privilege. |
| `mariadb_replication_mode` | `gtid` | `gtid` or `position`. |
| `mariadb_replication_gtid_use` | `replica_pos` | `replica_pos` or `current_pos`; `replica_pos` is the safe default for preloaded replicas. |
| `mariadb_replication_primary_log_file` | `""` | Required in position mode unless overridden per replica. |
| `mariadb_replication_primary_log_pos` | `null` | Required in position mode; must be at least 4 and match the consistent copy. |
| `mariadb_replication_log_coordinates` | `{}` | Optional mapping keyed by inventory hostname. In position mode each entry must contain the caller-supplied `file` and `position` for that replica's consistent data copy. |
| `mariadb_replication_require_gtid_strict_mode` | `false` | Set true when the topology policy requires `gtid_strict_mode=ON`; the role never enables it silently. |
| `mariadb_replication_require_replica_binlog` | `false` | Set true when replicas must also have binary logging. Primary binary logging is always required. |

The role creates/updates the account on the primary with the configured minimum privilege. It does not grant `SUPER`, `REPLICATION ADMIN`, or unrelated privileges.

### TLS

| Variable | Default | Description |
| --- | --- | --- |
| `mariadb_replication_ssl_enabled` | `false` | Enable TLS for the replication channel. |
| `mariadb_replication_ssl_ca` | `""` | Required absolute path to the existing CA file on every replica. |
| `mariadb_replication_ssl_client_certificate` | `""` | Optional existing replica client certificate for mutual TLS. |
| `mariadb_replication_ssl_client_key` | `""` | Optional existing replica client private key; must be supplied with the certificate. |
| `mariadb_replication_ssl_require_client_certificate` | `false` | Require both client certificate and key. |
| `mariadb_replication_ssl_verify_server_cert` | `true` | Explicit `MASTER_SSL_VERIFY_SERVER_CERT` policy. |
| `mariadb_replication_ssl_check_hostname` | `false` | Hostname verification for the role's preflight TCP probe through PyMySQL. |

When TLS is enabled, the role validates the primary's `have_ssl` value and checks every supplied file on each replica. It also requires the replication account to use SSL. It does not create directories, copy files, request certificates, enroll with a CA, or renew anything. The existing primary server certificate/key must be configured outside this role.

One-way TLS supplies only the CA. Mutual TLS supplies the CA, client certificate, and client key. If the private key is encrypted, configure MariaDB using the facilities supported by the exact server release; this role only passes paths to MariaDB.

### Replica state and validation

| Variable | Default | Description |
| --- | --- | --- |
| `mariadb_replication_replica_read_only` | `true` | Set `read_only=ON` after the channel is configured; the primary is only validated as writable. |
| `mariadb_replication_auto_start` | `true` | Start the channel after configuration. When false, leave the channel stopped. This controls the current channel state; boot-time service options remain outside the role. |
| `mariadb_replication_consistency_databases` | `[]` | Databases to check. Empty means all non-system databases. |
| `mariadb_replication_consistency_excluded_databases` | system schemas | Schemas excluded from data checks; override only with a deliberate policy. |
| `mariadb_replication_consistency_excluded_tables` | `[]` | Fully-qualified `database.table` names excluded from checks. |
| `mariadb_replication_consistency_checksum_mode` | `extended` | `extended` scans table rows; `default` lets MariaDB select its normal checksum method. |
| `mariadb_replication_consistency_allow_null_checksum` | `false` | Do not weaken validation unless the operator accepts a NULL checksum for a known unsupported table. |
| `mariadb_replication_validate_network` | `true` | Validate that the primary is not using `skip-networking` and is not loopback-only. |
| `mariadb_replication_allow_loopback_bind` | `false` | Explicitly allow a loopback-only primary bind when the deployment provides reachability another way. |
| `mariadb_replication_require_log_basename` | `true` | Require a stable binary-log basename (`log_bin_basename`, derived from MariaDB's `log-bin`/`log-basename` startup options) as recommended for replication. |
| `mariadb_replication_healthcheck_enabled` | `true` | Collect status and print the final summary. |

The consistency check compares table inventories, storage engines, and `CHECKSUM TABLE` results. It is a read-only check, but `EXTENDED` can be expensive and can observe concurrent writes. Run it during a quiesced write window or provide a consistency scope suited to the maintenance window.

### Controller/install options

| Variable | Default | Description |
| --- | --- | --- |
| `mariadb_replication_verify_controller_environment` | `true` | Enable the controller venv/import preflight. Disable only when the caller has a separately enforced execution environment. |
| `mariadb_replication_controller_python` | `ansible_playbook_python` | Controller Python executable to verify. |
| `mariadb_replication_controller_venv_path` | `""` | Optional explicit venv root containing `pyvenv.cfg`. |
| `mariadb_replication_required_controller_python_modules` | `[ansible, pymysql]` | Python modules imported on the controller. |
| `mariadb_replication_check_ansible_lint_dependency` | `false` | Also require `ansiblelint` in the controller venv. |
| `mariadb_replication_remote_python_modules` | `[pymysql]` | Python modules imported on each managed node. |
| `mariadb_replication_manage_packages` | `false` | Enable optional package installation. |
| `mariadb_replication_packages` | `[]` | Exact caller-supplied packages when package management is enabled. |
| `mariadb_replication_package_state` | `present` | Package state. |
| `mariadb_replication_manage_service` | `true` | Start the service after optional installation. |
| `mariadb_replication_service_name` | `mariadb` | Service name supplied by the caller's distribution. |
| `mariadb_replication_service_state` | `started` | Service state after optional installation. |

Administrative connection variables are `mariadb_replication_admin_login_user`, `mariadb_replication_admin_login_password`, `mariadb_replication_admin_login_host`, `mariadb_replication_admin_login_port`, `mariadb_replication_admin_unix_socket`, `mariadb_replication_admin_config_file`, and `mariadb_replication_connect_timeout`. The default credential-file path is the MariaDB module convention `~/.my.cnf`; override it or provide login variables from Vault.

## Inventory examples

### GTID topology

`inventory/hosts.yml`:

```yaml
all:
  children:
    mariadb_replication:
      hosts:
        db-primary:
          ansible_host: 192.0.2.10
          mariadb_replication_node_role: primary
        db-replica-a:
          ansible_host: 192.0.2.11
          mariadb_replication_node_role: replica
```

`group_vars/mariadb_replication.yml`:

```yaml
---
mariadb_replication_initial_primary: db-primary
mariadb_replication_primary_host: db-primary.example.invalid
mariadb_replication_replica_hosts:
  - db-replica-a

mariadb_replication_user: mariadb_repl
mariadb_replication_password: "{{ vault_mariadb_replication_password }}"
mariadb_replication_user_host: "192.0.2.%"
mariadb_replication_port: 3306
mariadb_replication_mode: gtid
mariadb_replication_gtid_use: replica_pos
mariadb_replication_replica_read_only: true
mariadb_replication_auto_start: true

mariadb_replication_consistency_databases:
  - application
```

The primary and replica hosts must already have matching data. `gtid_slave_pos` on each replica must describe the copy being checked; this role does not derive or inject a GTID position from a backup.

### Binary-log file/position topology

Set `mariadb_replication_mode: position` and provide either the global
`mariadb_replication_primary_log_file` plus
`mariadb_replication_primary_log_pos`, or a per-replica entry in
`mariadb_replication_log_coordinates`. Values must be supplied from the
operator's consistent data-copy record; this documentation intentionally does
not contain file names or positions. The role does not take a lock, create a
backup, or discover a safe coordinate for an arbitrary existing replica.

### TLS topology

```yaml
mariadb_replication_ssl_enabled: true
mariadb_replication_ssl_ca: /etc/mariadb/replication/ca.pem
mariadb_replication_ssl_verify_server_cert: true

# Optional mutual TLS. Both files must already exist on every replica.
mariadb_replication_ssl_require_client_certificate: true
mariadb_replication_ssl_client_certificate: /etc/mariadb/replication/client-cert.pem
mariadb_replication_ssl_client_key: /etc/mariadb/replication/client-key.pem
```

The paths are remote paths on the replicas, not paths on the Ansible controller. The primary's server TLS configuration is managed outside this role.

## Example playbooks

```yaml
---
- name: Configure MariaDB standard replication
  hosts: mariadb_replication
  become: true
  gather_facts: true
  roles:
    - role: mariadb_replication
```

With an explicit optional install list:

```yaml
---
- name: Install and configure MariaDB replication prerequisites
  hosts: mariadb_replication
  become: true
  vars:
    mariadb_replication_manage_packages: true
    mariadb_replication_packages:
      - mariadb-server
      - mariadb-client
      - python3-pymysql
  roles:
    - role: mariadb_replication
```

The second example does not configure a repository or select a MariaDB release. Supply packages appropriate to the operating system and version policy.

## Tags

| Tag | Purpose |
| --- | --- |
| `install` | Optional caller-supplied package installation and service start. |
| `configure` | Primary account and replica channel/read-only configuration. |
| `replication` | Replication-specific account/channel operations. |
| `validate` | Controller, topology, version, settings, connectivity, SSL, ID, and consistency validation. |
| `healthcheck` | Primary/replica status collection and consolidated summary. |

Validation and the final summary are tagged `always` so a normal tagged run cannot accidentally bypass the safety gate. For example:

```bash
ansible-playbook replication.yml --check
ansible-playbook replication.yml --tags validate
ansible-playbook replication.yml --tags healthcheck
ansible-playbook replication.yml --tags configure,replication
```

The role's normal execution path validates before changing the replication channel. A `healthcheck`-only run is observational; it does not configure a channel.

## Idempotency and check mode

- `ansible.mariadb.mariadb_user` manages the primary account idempotently.
- The current replica status is read before `CHANGE MASTER TO`. The role only stops/reconfigures a channel when its primary endpoint, account, mode, or TLS policy differs, or when `mariadb_replication_force_reconfigure` is true.
- MariaDB does not expose the stored replication password in `SHOW REPLICA STATUS`. Password rotation therefore requires `mariadb_replication_force_reconfigure: true` for one run, followed by setting it back to false.
- Read-only checks and consistency checks run in check mode. Mutating replication, account, and `read_only` tasks are skipped by check mode where the upstream module cannot predict safely.
- Check mode cannot make an absent replication account or channel real, so connectivity and post-change health can still report a failure when the target is not yet initialized. This is expected and does not change the target.

## Health check and final summary

The primary health data includes:

- Connected replica count and `SHOW REPLICA HOSTS` data when MariaDB exposes it.
- `read_only`/writable state.
- GTID position.
- Primary-side replica status.

Each replica health record includes:

- Whether a replication channel is configured.
- I/O and SQL thread state, including both `Replica_*` and legacy `Slave_*` field names.
- Replication delay.
- `Last_IO_Error` and `Last_SQL_Error`.
- `Using_Gtid`, GTID position, and `read_only`.

The final task prints a consolidated block for the primary and every declared replica. A replica validation/configuration failure is included in that replica's section and does not stop other replicas. A controller or primary safety failure is reported after the summary and fails the role run.

## Troubleshooting

### Controller environment failure

Confirm that the command is running with the intended `.venv/bin/ansible-playbook`, that the venv contains `pyvenv.cfg`, and that `ansible`/`pymysql` import successfully. If lint is part of the execution contract, set `mariadb_replication_check_ansible_lint_dependency: true` and install `ansible-lint` in that same venv.

### Missing PyMySQL on a managed node

Install PyMySQL into the Python interpreter selected by `ansible_python_interpreter`, or set that interpreter to the managed node's MariaDB automation environment. The role intentionally stops before database configuration when the module dependency is absent.

### Primary validation fails

Check `SHOW GLOBAL VARIABLES` for `log_bin`, `server_id`, `log_basename`, `read_only`, `skip_networking`, `bind_address`, `gtid_domain_id`, and `gtid_strict_mode`. The role does not edit these settings because changing them can require a restart or can invalidate existing replication.

### Replication account connectivity fails

Check that the account host part matches the source address observed by the primary, that TCP port access is allowed, and that `REPLICATION SLAVE` is present. For TLS, check the CA path, the primary server certificate chain, `have_ssl`, and whether mutual TLS is required.

### A replica is skipped for consistency

The role found a different table inventory, storage engine, or checksum. Stop application writes, initialize the replica from a supported backup/restore workflow, and set GTID/file-position metadata for that copy. Do not use this role to copy data.

### I/O thread is not running

Inspect `Last_IO_Error`, DNS/routing/firewall rules, account host matching, port, and TLS. MariaDB replicas connect to a primary over TCP; a Unix socket cannot be used for the replication channel.

### SQL thread is not running

Inspect `Last_SQL_Error` and the replica error log. Do not use `sql_slave_skip_counter` as an automated repair; correct the data or schema divergence and reinitialize the replica when necessary.

### `SHOW REPLICA HOSTS` is empty

That statement only lists replicas that register with the primary. Configure a suitable `report_host`/`report_port` outside this role if the environment needs primary-side host registration. The replica's own thread status remains the authoritative health signal.

## Upgrade considerations

- Upgrade replicas before the primary where possible; MariaDB's cross-version guidance favors an older primary and same/newer replicas.
- Validate exact patch-level compatibility, especially when changing binary-log formats, authentication plugins, TLS libraries, or system table layouts.
- GTID state is part of the replica's data/metadata contract. Do not clear `gtid_slave_pos` or reset replication metadata casually; reinitialize or deliberately migrate the replica first.
- In position mode, capture a new exact file/position for each backup/restore operation. Reusing an old coordinate can duplicate or omit transactions.
- MariaDB retains `MASTER`/`SLAVE` compatibility spellings while newer releases expose primary/replica aliases. The role delegates that translation to the official collection instead of embedding a release-specific SQL script.
- MariaDB 12.x changes some variable types and introduces new replication options. This role uses only the common 11/12 behavior and intentionally does not use MariaDB 12.3-only server-level `DEFAULT` replication parameters.
- Certificate lifecycle remains outside the role. Rotate existing certificate assets through the owning PKI workflow, then run the role with the new paths and, if required, `mariadb_replication_force_reconfigure: true`.

## Design decisions

1. **Validate, do not silently repair server prerequisites.** Enabling binary logging, changing IDs, or changing GTID settings can affect existing data and require a restart, so the role fails with an actionable message.
2. **Use official modules first.** Account management uses `ansible.mariadb.mariadb_user`; status uses `mariadb_info`/`mariadb_replication`; runtime `read_only` uses `mariadb_variables`. SQL is limited to read-only grant, catalog, and checksum queries where no more specific module is appropriate.
3. **Keep replica failures isolated.** Per-replica validation and configuration are rescued into host facts rather than terminating the whole topology. The summary exposes the failure.
4. **Make data initialization an explicit boundary.** Checksums are strong enough to catch an accidental or partial copy, but the role does not pretend to be a backup/restore system.
5. **Make TLS explicit and file-only.** Existing CA/client assets are validated and passed to MariaDB. No certificate request, generation, copy, or PKI behavior is hidden in a replication role.
6. **Prefer GTID replica position.** `replica_pos` resumes from the GTID position stored with the replica's applied data and avoids fragile file/offset discovery. Traditional coordinates remain available for migrations and legacy workflows.

## Official references

- [MariaDB: Setting Up Replication](https://mariadb.com/docs/server/ha-and-performance/standard-replication/setting-up-replication)
- [MariaDB: Global Transaction ID](https://mariadb.com/docs/server/ha-and-performance/standard-replication/gtid)
- [MariaDB: Replication with Secure Connections](https://mariadb.com/docs/server/security/encryption/data-in-transit-encryption/replication-with-secure-connections)
- [MariaDB: SHOW REPLICA STATUS](https://mariadb.com/docs/server/reference/sql-statements/administrative-sql-statements/show/show-replica-status)
- [MariaDB: CHECKSUM TABLE](https://mariadb.com/docs/server/reference/sql-statements/table-statements/checksum-table)
- [Ansible `ansible.mariadb.mariadb_replication` module](https://docs.ansible.com/ansible/latest/collections/ansible/mariadb/mariadb_replication_module.html)
- [Ansible `ansible.mariadb.mariadb_user` module](https://docs.ansible.com/ansible/latest/collections/ansible/mariadb/mariadb_user_module.html)
