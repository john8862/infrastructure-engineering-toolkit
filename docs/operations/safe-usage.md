# Safe usage and validation

This runbook provides a conservative workflow for the public components. It assumes a disposable test host or local
fixture, an approved inventory, an external secret workflow, and a recovery plan. Examples use documentation-only
addresses and never contain real credentials.

## Before a change

Confirm that:

- the component README, supported operating system, release series, and required Ansible collections are understood;
- inventory uses `example.invalid` names or real values kept outside the repository;
- passwords and certificate material are supplied through Vault, an external secret manager, or an approved PKI
  workflow;
- database data has a documented backup or restore path before topology changes;
- DNS authority, reverse zones, transfer keys, and update ACLs have an owner outside the role defaults;
- existing FreeIPA, MaxScale, or Keepalived state has been inspected before enabling reconciliation; and
- the fixture or syntax check passes on the same branch and variable set that will be applied.

Never replace an environment value with a documentation address. `192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24`,
and `2001:db8::/32` are reserved for examples.

## Read-only and check-mode passes

### FreeIPA bootstrap

Run from `components/freeipa-bootstrap/` on a supported RHEL-family target:

```bash
./install.sh --version
./install.sh --check
./install.sh --dry-run
```

`--check` performs read-only preflight and provider validation. `--dry-run` validates planned packages, files,
services, DNS operations, firewall behaviour, and FreeIPA mode without changing the host. Normal execution is not a
workstation test. Use the dependency-free test suite and shell syntax checks from the repository root:

```bash
bash tests/freeipa-bootstrap/test.sh
bash -n components/freeipa-bootstrap/install.sh \
  components/freeipa-bootstrap/lib/*.sh \
  components/freeipa-bootstrap/dns/provider.sh \
  components/freeipa-bootstrap/dns/providers/*/*.sh
```

### MariaDB baseline

The public fixture parses a local role without supplying secrets:

```bash
ansible-playbook -i examples/mariadb/inventory.example.yml \
  examples/mariadb/site.yml --syntax-check
ansible-playbook -i examples/mariadb/inventory.example.yml \
  examples/mariadb/site.yml --check --diff
python3 -m unittest discover -s tests/mariadb -p 'test_*.py'
```

On a target host, set the root and reserved replication account values through Vault or an external secret source.
Keep `mariadb_bootstrap_new_server` and the guarded first-node reset decision explicit. A check-mode run cannot create a
service, repository keyring, TLS assets, database account, or ready marker; deferred checks are expected on a fresh
host. Run the real health assertion only after the state exists.

### MariaDB replication

Run the role from the caller's Ansible project with its virtual environment active:

```bash
ansible-playbook replication.yml --check
ansible-playbook replication.yml --tags validate
ansible-playbook replication.yml --tags healthcheck
```

Validation is tagged `always` so a focused run cannot skip the safety gate. Check mode reads prerequisites but does not
make a missing account or channel real. Supply either a GTID position tied to a consistent copy or explicit file and
position coordinates. Do not ask this role to copy data, discover a safe coordinate, or repair divergence.

### MaxScale

The fixture renders a generic configuration on localhost without installing software, contacting a database, or
changing a service:

```bash
ANSIBLE_LOCAL_TEMP=/tmp/ansible-tmp ANSIBLE_ROLES_PATH=ansible/roles \
  ansible-playbook --syntax-check \
  -i examples/maxscale-ha/inventory/hosts.yml examples/maxscale-ha/site.yml
ANSIBLE_LOCAL_TEMP=/tmp/ansible-tmp ANSIBLE_ROLES_PATH=ansible/roles \
  ansible-playbook --check \
  -i examples/maxscale-ha/inventory/hosts.yml examples/maxscale-ha/site.yml
yamllint -d relaxed ansible/roles/maxscale examples/maxscale-ha tests/maxscale
```

Keep repository, package, service, firewall, and REST health switches disabled until MariaDB terms, listener policy,
certificate paths, credentials, and recovery procedure are approved. A managed reload follows candidate validation and
is not a failover test.

### Keepalived

The fixture is deliberately disabled and only syntax-checks the role:

```bash
ANSIBLE_CONFIG=examples/keepalived/ansible.cfg \
  ansible-playbook --syntax-check \
  -i examples/keepalived/inventory.yml examples/keepalived/playbook.yml
bash tests/keepalived/test_syntax.sh
```

For an actual change, supply explicit VRRP instances, interface, peer, priority, VIP, and any externally managed
health-script path. Existing deployments remain validation-only unless a planned maintenance variable enables
reconciliation. Do not claim a VIP or force failover as part of a check.

## Applying a change

After the read-only pass:

1. Review the rendered diff and every variable that enables packages, services, firewalls, DNS writes, or topology.
2. Confirm backup, restore, and rollback material is available for the change window.
3. Apply the smallest independent component change. Keep DNS publication, database topology, MaxScale reload, and VRRP
   reconciliation as separate actions.
4. Capture command output and health summaries without recording secret values.
5. Stop when a validation gate fails. Do not force the next layer to compensate for a failed lower layer.

The FreeIPA bootstrap writes root-owned state and structured per-run logs on the target. It redacts known credential
arguments, but the underlying installer may briefly expose password arguments in a process list; use the target host's
documented maintenance controls.

## Post-change validation

### Identity and DNS

For FreeIPA, validate the server object and topology with `ipa server-show` and `ipa topologysegment-find`. For managed
BIND, run `named-checkconf`, `named-checkzone`, SOA/NS queries, and `dig` against the expected authority. For
Technitium, use the authenticated provider API checks. For existing DNS, publish the preserved FreeIPA system-record
file through the authorised DNS process and rerun `./install.sh --check`.

For a generic service name, query an approved resolver and documented record set such as `db-writer.example.invalid`.
Do not use a public resolver for a private zone or assume that a successful local query proves secondary convergence.

### MariaDB and replication

Check the selected MariaDB series, server ID, bind policy, TLS links, ready marker, and expected account policy. For
replication, inspect the final summary and `SHOW REPLICA STATUS` on every declared replica. Confirm I/O and SQL threads,
GTID or file/position policy, read-only state, delay, and error fields. Run consistency checks during a quiesced write
window when the scope uses extended checksums.

Never use an automated `sql_slave_skip_counter`-style shortcut to hide SQL-thread errors. Reconcile data and schema
through a supported reinitialisation procedure.

### MaxScale and VRRP

On a host with MaxScale installed, run the configured candidate check, verify service state, and use the optional REST
health endpoint only when credentials and certificate policy are supplied externally. Confirm listener reachability from
an approved test client without creating accounts through the role.

For Keepalived, run the installed binary's configuration test, inspect service state and logs, and verify peer
configuration from both nodes. A syntax check does not prove that VRRP packets cross the intended network or that a
health script expresses the desired service policy.

## Rollback and recovery boundaries

- FreeIPA, realm, CA, and DNS authority choices are foundational. Do not uninstall or convert them as an automatic
  reaction to a failed run; use the supported platform backup and restore procedure.
- MariaDB's guarded initialisation prevents an unconditional GTID reset. Preserve the last known-good configuration and
  data-copy record; reinitialise a divergent replica through the approved backup path.
- A MaxScale configuration change may create a role-managed backup before reload. Restore that known-good file through
  the service procedure if candidate or health validation fails.
- Keepalived does not claim a VIP for testing or force failover. Revert variables and perform serial maintenance when
  reconciling an existing deployment.
- DNS address updates operate only on records within the selected managed provider contract. Investigate a failed or
  pending update at the provider and SOA level; do not edit transferred secondary files by hand.

The roles are intentionally conservative where a silent repair could destroy data, change authority, or mask an
availability failure.
