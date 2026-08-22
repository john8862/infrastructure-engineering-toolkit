#!/usr/bin/env sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
fixture_dir="$repo_root/examples/keepalived"
ansible_tmp=${TMPDIR:-/tmp}

ANSIBLE_CONFIG="$fixture_dir/ansible.cfg" \
  ANSIBLE_LOCAL_TEMP="$ansible_tmp" \
  ANSIBLE_ROLES_PATH="$repo_root/ansible/roles" \
  ansible-playbook --syntax-check \
  -i "$fixture_dir/inventory.yml" \
  "$fixture_dir/playbook.yml"
