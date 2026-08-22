#!/usr/bin/env bash

set -Eeuo pipefail

repo_root=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)

# The quality-gates branch is merged after the component branches.  Keep this
# guard explicit so a partial topic branch cannot report a misleading green
# final-union check.
required_paths=(
  "components/freeipa-bootstrap"
  "examples/freeipa"
  "tests/freeipa-bootstrap/test.sh"
  "ansible/roles/dns_update"
  "examples/dns-update"
  "tests/dns_update/test_contract.py"
  "ansible/roles/mariadb"
  "examples/mariadb"
  "tests/mariadb/test_contract.py"
  "ansible/roles/mariadb_replication"
  "examples/mariadb-replication"
  "tests/mariadb_replication/test_contract.py"
  "ansible/roles/maxscale"
  "examples/maxscale-ha"
  "tests/maxscale/test_static.sh"
  "ansible/roles/keepalived"
  "examples/keepalived"
  "tests/keepalived/test_syntax.sh"
)

missing=()
for relative_path in "${required_paths[@]}"; do
  if [[ ! -e "$repo_root/$relative_path" ]]; then
    missing+=("$relative_path")
  fi
done

if ((${#missing[@]} > 0)); then
  printf 'final-union check failed; merge the component branches before CI:\n' >&2
  printf '  missing: %s\n' "${missing[@]}" >&2
  exit 1
fi

for forbidden_name in PUBLICATION_REVIEW.md SECURITY.md AGENTS.md; do
  forbidden_path=$(find "$repo_root" \
    -path "$repo_root/.git" -prune -o \
    -type f -name "$forbidden_name" -print -quit)
  if [[ -n "$forbidden_path" ]]; then
    printf 'publication guard failed: %s must not be committed\n' "$forbidden_path" >&2
    exit 1
  fi
done

printf 'final-union check passed: all public components and fixtures are present\n'
