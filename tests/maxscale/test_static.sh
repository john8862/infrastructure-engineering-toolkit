#!/usr/bin/env bash
set -euo pipefail

repo_root="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
cd "$repo_root"

export ANSIBLE_LOCAL_TEMP="${ANSIBLE_LOCAL_TEMP:-/tmp/ansible-tmp}"
export ANSIBLE_ROLES_PATH="${ANSIBLE_ROLES_PATH:-$repo_root/ansible/roles}"
ansible-playbook --syntax-check \
  -i examples/maxscale-ha/inventory/hosts.yml examples/maxscale-ha/site.yml
yamllint -d relaxed ansible/roles/maxscale examples/maxscale-ha tests/maxscale

# Keep the bounded public core free from deployment-specific identifiers and
# from files that would indicate an implementation of a deferred feature.
if find ansible/roles/maxscale/tasks -type f \
  \( -iname '*binlog*' -o -iname '*sync*' -o -iname '*pam*' \
     -o -iname '*ssh*' -o -iname '*sudo*' -o -iname '*credential*' \) \
  -print -quit | grep -q .; then
  echo "An out-of-scope MaxScale task file was found" >&2
  exit 1
fi
if rg -n -i 'BEGIN (RSA|OPENSSH|EC|PRIVATE)|[.]pem$|[.]key$|[.]keytab$' \
  ansible/roles/maxscale examples/maxscale-ha tests/maxscale \
  --glob '!README.md' --glob '!test_static.sh'; then
  echo "A private-key or certificate marker was detected" >&2
  exit 1
fi
