# Continuous integration

The repository's quality-gates workflow is deliberately read-only. It runs on
pull requests and pushes to `main` with `contents: read`, cancels superseded
runs, and does not connect to or change live infrastructure. No credentials or
deployment secrets are required.

## Merge order

The `ci/quality-gates` branch is the final integration change. Merge the public
component branches first, then merge this branch after the final union contains
the paths checked by `scripts/ci/require-final-union.sh`. That guard fails with
a clear list when a topic branch is evaluated before the component branches;
this prevents a partial repository from being reported as a complete build.

## Checks

- Shell scripts are parsed with `bash -n`, followed by the FreeIPA contract
  suite.
- Python contract suites for DNS, MariaDB, and MariaDB replication run on
  Python 3.13.
- Ansible collections are installed into the runner's temporary directory from
  `ansible/requirements.yml`, with exact versions. `ansible-lint`, `yamllint`,
  and syntax checks cover every public role fixture, including MaxScale and
  Keepalived.
- YAML is checked with the version-controlled `.yamllint` profile. Structural
  rules remain strict; the line-length rule is disabled because long task
  expressions, URLs, and workflow declarations are often clearer when kept
  together. The workflow passes this profile explicitly rather than relying on
  a runner default.
- Markdown is scanned recursively with PyMarkdown using
  `.pymarkdown.json`. MD013 is disabled for the same content-aware reason,
  while all other default rules remain enabled and failing. The workflow
  passes this configuration explicitly; it does not suppress scan failures or
  exclude repository paths.
- `git diff --check` rejects whitespace errors in the change range.

The workflow intentionally does not enable dependency caching. This keeps the
validation environment easy to audit and avoids reusing a stale or
cross-branch collection cache.
