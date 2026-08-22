# Continuous integration

The repository's quality-gates workflow is deliberately read-only. It runs on
pull requests targeting `develop` or `main`, and on pushes to `develop` or
`main`, with `contents: read`. It cancels superseded runs and does not connect
to or change live infrastructure. No credentials or deployment secrets are
required.

## Branch flow

`develop` is the normal integration branch. Start a focused topic branch from
the latest `develop`, open its pull request against `develop`, and wait for all
four quality-gate jobs to pass. The `scripts/ci/require-final-union.sh` guard
keeps the public component union complete, so a partial topic branch is not
reported as a complete build.

After the integrated change set has been reviewed and is ready for promotion,
open a separate `develop` to `main` pull request. The `main` workflow run is
the release-promotion validation; Release Please remains restricted to pushes
on `main` and does not publish from `develop`.

The preferred branch naming model is documented in
[`CONTRIBUTING.md`](../CONTRIBUTING.md). A branch that follows that model and
provides a focused public-safe diff, Conventional Commit history, relevant
validation, and four green quality gates is prioritised for review and
integration. This priority does not bypass technical, security, compatibility,
or maintainer review.

## Checks

- Shell scripts are parsed with `bash -n`, followed by the FreeIPA contract
  suite.
- Python contract suites for DNS, MariaDB, and MariaDB replication run on
  Python 3.13.
- The release asset contract builds the five Ansible role archives and the
  separate FreeIPA archive twice in temporary directories, then verifies
  deterministic bytes, archive roots, safe modes, package boundaries, the
  machine-readable manifest, and SHA-256 checksums. It never uploads assets.
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
