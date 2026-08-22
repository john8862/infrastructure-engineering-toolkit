# Troubleshooting and bounded recovery

Start with the component's read-only check, capture the exact error, and stop at the first failed safety gate. The
commands below use generic names and documentation addresses. Do not paste passwords, private keys, tokens, or complete
environment configuration into an issue or change record.

## FreeIPA bootstrap and DNS

| Symptom | First checks | Bounded response |
| --- | --- | --- |
| Preflight rejects operating system or architecture | `cat /etc/os-release`, `uname -m`, and `./install.sh --check` | Use a supported RHEL-family 8, 9, or 10 host and `dnf`/`yum` path. Do not bypass the allowlist. |
| A healthy server is already configured | Inspect the role marker and run component validation commands | Treat the run as validation-only. Do not reinstall, change the realm, or switch role in place. |
| A pre-existing partial installation is found | Read the structured run log and verify whether this run created the state | Stop and use the platform recovery procedure. Automatic uninstall/retry is limited to state created by the same run. |
| Replica source validation fails | Resolve `ipa-primary.example.invalid`, test required ports, verify realm/time, and run `ipa-replica-conncheck` | Correct source reachability, DNS, time, or credentials. Do not substitute `ipa-server-install` for a replica. |
| Existing DNS reports pending | Inspect `generated/freeipa-dns-prerequisites.txt` and `freeipa-dns-records-<run-id>.db` | Publish records through the authorised DNS process, then rerun `./install.sh --check`. Existing DNS is read-only. |
| BIND validation or secondary SOA convergence fails | Run `named-checkconf`, `named-checkzone`, `dig SOA`, and `dig NS` | Fix the primary zone, TSIG/ACL, NOTIFY, or transfer path. Never edit a transferred slave file by hand. |
| Technitium API validation fails | Confirm endpoint, external credential source, zone type, TSIG policy, source ACL, and listener | Correct the API or policy input. Do not convert or delete a zone implicitly. |
| Address update fails or remains pending | Run `./update-server-ip.sh --check`, then `--dry-run --new-ip <new-address>`; inspect authoritative SOA and managed records | Reconcile marked A/PTR records only on an authoritative primary. The utility refuses existing or secondary DNS. |

Use `ipa server-show`, `ipa topologysegment-find`, and provider-specific validation only on an approved target. A
successful local command does not prove that all secondaries or clients have converged.

## MariaDB baseline

| Symptom | First checks | Bounded response |
| --- | --- | --- |
| Ansible collection or PyMySQL is missing | `ansible-galaxy collection list`, managed-node Python, and syntax check | Install declared dependencies in the intended environment. The role does not vendor collections or guess an interpreter. |
| Repository or release assertion fails | Target distribution, codename, repository series, and MariaDB candidate | Align explicit variables or stop. Do not silently switch to an operating-system repository. |
| TLS source files are unavailable | Externally managed certificate paths and parent-directory traversal permissions | Repair the PKI workflow or paths. The role does not request, copy, renew, or change source ownership. |
| Ready-for-HA assertion fails | Server ID, `log_bin`, GTID positions, account inventory, TLS links, and ready marker | Correct prerequisites outside the role or review existing-host mode. Do not enable first-node reset on a host with state. |
| Existing accounts or databases prevent initialisation | Inspect catalogue and account inventory with an authorised read-only query | Treat the host as existing state. Do not delete data or accounts to satisfy the guard. |
| `read_only`, bind, or binary-log policy is unsuitable | Inspect effective variables and service startup options | Change the server policy through a separate reviewed action; replication validates rather than edits these values. |

Check mode can defer checks requiring a service, keyring, TLS asset, authenticated query, or ready marker. A deferred
check on a fresh host is not evidence of runtime convergence.

## MariaDB replication

| Symptom | First checks | Bounded response |
| --- | --- | --- |
| Controller preflight fails | Intended virtual environment, `pyvenv.cfg`, imports for `ansible`/`pymysql`, and optional lint dependency | Activate or repair the environment. Do not disable the check without a separately enforced execution contract. |
| Managed node lacks PyMySQL | `ansible_python_interpreter` and an import using that interpreter | Install PyMySQL there or select the approved interpreter. The role stops before database changes. |
| Primary validation fails | `log_bin`, stable log basename, `server_id`, `read_only`, `skip_networking`, bind address, and GTID variables | Correct the prerequisite separately. The role does not enable logging, rewrite identity, or change GTID settings. |
| Replication account cannot connect | Account host part, TCP access to `3306`, privilege, and TLS policy | Correct account or network policy. Keep the password in Vault; do not widen the host part by default. |
| Replica is skipped by consistency checks | Table inventories, engines, and `CHECKSUM TABLE` results on a quiesced copy | Reinitialise or repair through a supported backup/restore process. This role does not copy data or invent a position. |
| I/O or SQL thread is not running | `Last_IO_Error`, `Last_SQL_Error`, DNS/routing/firewall, endpoint, account, and TLS | Correct the underlying connection or data divergence. Do not automate a skip-counter workaround. |
| `SHOW REPLICA HOSTS` is empty | `report_host`/`report_port` and the replica's own thread status | Treat thread status as authoritative; primary-side registration is informational. |

In position mode, every file and position must belong to the exact consistent copy being configured. In GTID mode,
`gtid_slave_pos`/`replica_pos` must describe that copy; the role does not derive it from a backup.

## DNS A/PTR reconciliation

| Symptom | First checks | Bounded response |
| --- | --- | --- |
| No DNS records are queried or changed | `dns_update_enabled`, `dns_update_manage`, coordinator, and the play output | Both switches are intentionally `false` by default. Enable management only with an explicit server, zone, ownership, and authentication policy. |
| A record definition is rejected | Record `name`, `type`, `value`, `state`, explicit `zone`, and optional per-record transport values | Use only `A` or `PTR`; declare the zone for every record. The role does not discover reverse zones or authoritative servers. |
| A lookup fails | `dig` availability, explicit server, TCP/UDP setting, port, timeout, and resolver reachability | Treat a failed lookup as unknown, not proof that the record is absent. Correct the query path before enabling writes. |
| GSS-TSIG authentication fails | Kerberos client, principal, password source, realm, `kinit`, and temporary credential-cache handling | Correct the external Kerberos path. The role never stores the password and does not obtain a ticket in check mode. |
| TSIG authentication fails | External key name, secret, algorithm, server, and zone ACL | Use a supported HMAC algorithm and runtime secret source. Do not fall back to unsigned updates. |
| A different PTR already exists | `dns_update_conflict_policy` and the current value reported by the role | `report` leaves the conflict untouched. Use `replace` only after establishing ownership of the complete managed record. |
| One record fails while others continue | Per-record result, `dns_rc`, `query_failed`, and `dns_update_fail_on_error` | This is the default isolation behaviour. Set `dns_update_fail_on_error: true` only when DNS is a hard prerequisite. |
| Collection or runtime dependency is missing | Pinned `community.general` 13.0.0, target-side `dnspython`, and GSS-TSIG `gssapi`/Kerberos dependencies | Install dependencies in the intended execution environment; collections are not bundled. |
| A local run fails before reaching DNS | Controller Python and Ansible RPC environment | A Python 3.14 controller RPC incompatibility can block local execution before DNS. Re-run from a supported controller/target environment; no live deployment outcome is implied. |

The role's contract, syntax, `yamllint`, and `ansible-lint` checks pass. Check mode performs read-only inspection and
does not invoke `community.general.nsupdate`.

## MaxScale

| Symptom | First checks | Bounded response |
| --- | --- | --- |
| Fixture syntax or YAML validation fails | Fixture syntax check and `yamllint` from the [safe-usage runbook](safe-usage.md) | Correct the data-only server, monitor, service, listener, or option map. Keep package/service switches off while iterating. |
| Candidate configuration check fails | Installed MaxScale `--config-check` and rendered backup/diff | Fix the configuration model or installed-release compatibility. Do not reload a rejected candidate. |
| REST health check fails after reload | Service state, endpoint, status code, external credentials, and TLS trust | Stop and restore the last known-good configuration. The role does not create an administrator or force failover. |
| TLS validation fails | Paired certificate/key/CA paths, permissions, and optional hostname identity | Repair external PKI output or paths. The role never creates or publishes certificates or keytabs. |
| Repository or package management is unexpected | Management switches, target platform, and MariaDB terms | Keep management disabled until terms and provenance are approved. MaxScale is not redistributed or relicensed here. |
| Listener is unreachable | Listener, host firewall, source allow-list, and network path | Adjust explicit listener or already managed firewall policy. MaxScale does not claim a VIP or infer DNS. |

The MaxScale role has no Binlog Router, Config Sync, PAM, SSH/sudo, account-creation, external-replica, or runtime-state
repair path. The absence of such a task is deliberate.

## Keepalived and VRRP

| Symptom | First checks | Bounded response |
| --- | --- | --- |
| Configuration test fails | `keepalived -t -f <rendered-file>`, interface, VRID, state, priority, VIP, and peers | Correct the explicit instance. Every `virtual_router_id` must be unique within the file. |
| Existing deployment is unchanged | Existing-deployment mode and reconciliation switch | This is the default guard. Schedule serial maintenance and enable reconciliation deliberately if required. |
| Peer does not see advertisements | Interface, unicast source/peer addresses, VRRP firewall rules, and routing | Correct network policy or explicit peers. The role does not widen firewall policy. |
| Health script is not executed | Path, mode, ownership, least-privilege user, and exit contract | Repair the separately managed script. The role references a script; it does not create application health logic. |
| VIP fails over unexpectedly | Priorities, pre-emption policy, logs, and maintenance window | Stop and review the VRRP policy. Do not use live failover as an installation test. |

Keepalived firewall integration is opt-in and generic. It does not know whether a VIP fronts MariaDB, MaxScale, or
another service, and DNS does not provide the health signal.

## Escalation boundary

Escalate to relevant platform or vendor documentation for an unsupported operating system, MariaDB release behaviour,
an unaccepted FreeIPA option, BIND/Technitium authority, MaxScale licensing or module semantics, or a VRRP/network
policy outside the role contract. Preserve read-only output and the last known-good configuration; do not broaden
privileges or disable a safety assertion merely to produce a green run.
