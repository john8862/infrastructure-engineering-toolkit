# Keepalived fixture

This directory contains a role-only, localhost fixture for parsing and
syntax-checking the generic Keepalived role. The role is explicitly disabled
(`keepalived_enabled: false`), so running the fixture does not install a
package, alter a service, change firewall policy, render a configuration, or
claim a virtual IP.

From the repository root, run:

```console
ANSIBLE_CONFIG=examples/keepalived/ansible.cfg \
  ansible-playbook --syntax-check \
  -i examples/keepalived/inventory.yml \
  examples/keepalived/playbook.yml
```

For a real deployment, provide a reviewed inventory and external variables.
Use documentation addresses such as `192.0.2.0/24` only in examples; they are
not valid production network settings.
