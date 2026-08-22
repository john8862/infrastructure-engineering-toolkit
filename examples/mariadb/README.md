# MariaDB baseline example

This fixture shows how to call the standalone `mariadb` role with generic host
names and documentation-only addresses. It is intentionally safe to inspect:
`mariadb_fixture_apply` defaults to `false`, TLS is disabled because no
certificate assets are shipped, and both bootstrap reset switches remain
`false`.

The fixture is not an inventory or configuration for a real environment. Copy
the files into an isolated Ansible project and replace the placeholders only
after reviewing the role's prerequisites and safety contract.

## Syntax check

From the repository root, install the collection dependencies in an external
collection path and run:

```bash
ANSIBLE_ROLES_PATH=ansible/roles \
ansible-playbook \
  -i examples/mariadb/inventory.example.yml \
  examples/mariadb/site.yml \
  --syntax-check
```

The example uses `192.0.2.10` and `192.0.2.11`, which are reserved for
documentation. The host names are `db-primary` and `db-replica-a`; this role
does not configure a replication channel between them.

## Deliberate application

To apply the baseline, set `mariadb_fixture_apply=true` and provide both
environment variables from an external secret manager or an ephemeral shell
environment:

```bash
export MARIADB_ROOT_PASSWORD='obtain-from-secret-store'
export MARIADB_REPLICATION_PASSWORD='obtain-from-secret-store'
ANSIBLE_ROLES_PATH=ansible/roles \
ansible-playbook \
  -i examples/mariadb/inventory.example.yml \
  examples/mariadb/site.yml \
  -e mariadb_fixture_apply=true
```

Do not commit those variables, shell history, Vault exports, certificates,
private keys, or runtime state. For a TLS-enabled run, an external certificate
provider must publish existing assets and the play must be adapted to pass
their paths through `mariadb_tls_certificate`.
