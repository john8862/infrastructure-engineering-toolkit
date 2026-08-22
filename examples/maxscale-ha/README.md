# MaxScale generic fixture

This fixture renders a small, public MaxScale configuration model without
installing MaxScale, changing a service, changing a firewall, creating
accounts, or contacting a database. It uses documentation-only addresses and
the reserved `example.invalid` namespace. The `tmp/` directory is ignored and
is suitable for a local render on a disposable host.

Run from the repository root:

```sh
ANSIBLE_LOCAL_TEMP=/tmp/ansible-tmp \
ANSIBLE_ROLES_PATH=ansible/roles \
  ansible-playbook -i examples/maxscale-ha/inventory/hosts.yml \
  examples/maxscale-ha/site.yml
```

For a non-mutating parse and validation pass, add `--check`. To exercise
package/repository/service integration, provide explicit variables in a
separate inventory and review the MariaDB MaxScale terms first.
