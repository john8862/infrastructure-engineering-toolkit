# MariaDB replication role example

This is a role-only example for a two-node, single-primary asynchronous
MariaDB topology. It uses documentation addresses and the reserved
`example.invalid` DNS suffix; replace them with values from the caller's
inventory.

The example keeps package management disabled and leaves the replication
channel stopped (`mariadb_replication_auto_start: false`) until an operator
has reviewed validation output. Enable channel start deliberately only after
the primary and replica data copies, GTID state, network policy, and TLS
policy have been prepared outside this role.

The replication password is referenced as
`vault_mariadb_replication_password`; no credential or Vault material belongs
in this example. Put the value in the caller's protected Vault data.

## Run

```bash
ansible-galaxy collection install \
  --requirements-file ../../ansible/roles/mariadb_replication/meta/requirements.yml
ansible-playbook -i inventory.yml playbook.yml --check
ansible-playbook -i inventory.yml playbook.yml
```

The commands assume the `ansible.mariadb` collection and PyMySQL are already
available in the selected Ansible environment. The role does not install a
repository, copy data, create a backup, restore a backup, generate or copy
certificates, or perform failover.

For TLS, set the role's existing-file path variables in protected inventory or
Vault data. Paths are remote paths on each replica and are passed to the
MariaDB module; this example intentionally includes no certificate or key
asset.
