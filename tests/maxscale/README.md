# MaxScale role checks

The fixture is intentionally generic and does not install MaxScale or contact
an external host. Run the following checks from the repository root:

```sh
ANSIBLE_LOCAL_TEMP=/tmp/ansible-tmp ANSIBLE_ROLES_PATH=ansible/roles \
  ansible-playbook --syntax-check \
  -i examples/maxscale-ha/inventory/hosts.yml examples/maxscale-ha/site.yml

yamllint -d relaxed ansible/roles/maxscale examples/maxscale-ha tests/maxscale
ANSIBLE_LOCAL_TEMP=/tmp/ansible-tmp ANSIBLE_ROLES_PATH=ansible/roles \
  ansible-playbook --check \
  -i examples/maxscale-ha/inventory/hosts.yml examples/maxscale-ha/site.yml
```

The non-check fixture command can be used on a disposable local host to
inspect the rendered fragments under `examples/maxscale-ha/tmp/`; that path is
ignored by Git.
