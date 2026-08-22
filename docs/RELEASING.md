# Releasing

This repository uses [Release Please](https://github.com/googleapis/release-please)
with the official
[Release Please GitHub Action](https://github.com/googleapis/release-please-action)
to maintain one semantic version for the repository. Release automation is
deliberately limited to `main`: work on a feature branch cannot publish a tag or
GitHub Release.

## Configuration

- `release-please-config.json` declares one manifest package at `.` and uses
  the `simple` release type.
- `.release-please-manifest.json` records the root package's current version.
- `version.txt` is the version file managed by the `simple` releaser.
- `CHANGELOG.md` is the root changelog generated from merged Conventional
  Commits.
- `.github/workflows/release-please.yml` runs only for pushes to `main` and
  pins `googleapis/release-please-action` to a full commit SHA (with its
  friendly release version documented beside the pin).

`include-component-in-tag` is `false`, so releases use the repository-wide
`v<MAJOR>.<MINOR>.<PATCH>` tag form rather than a component-prefixed tag.

## Normal release flow

1. Merge component changes into `develop` through focused pull requests using
   Conventional Commit subjects. Release Please does not run from `develop`.
2. Open a separate `develop` to `main` promotion pull request after the
   integrated branch is reviewed and all four Quality Gates pass. `main` uses
   strict, up-to-date checks and a linear history; the solo maintainer does not
   need a second human approval.
3. The resulting `main` push opens or updates one Release PR. Review its
   generated `CHANGELOG.md`, `version.txt`, and manifest changes; changelog
   entries link back to the merged commits and pull requests.
4. Merge the Release PR into `main`. Release Please then creates the
   `v<version>` tag and published GitHub Release whose notes come from the same
   merged commit history.
5. Confirm the tag, GitHub Release, version file, manifest, and changelog agree.

## Promotion and branch synchronisation

The normal path is `topic or fork -> develop -> main`. The `develop` branch is
protected but deliberately allows faster, non-strict integration; `main` is
the stable and release branch with strict freshness and linear-history rules.
Normal topic merges should use squash where practical, and promotion should
use squash or rebase according to the repository merge settings.

A squash promotion can leave `develop` and `main` with different commit
histories. If a later promotion pull request is behind, use GitHub's **Update
branch** action to merge current `main` into `develop` and rerun the Quality
Gates, or open a focused `main` to `develop` synchronisation pull request. Do
not reset or force-push either protected branch. An urgent hotfix starts from
`main`, is promoted through a focused pull request, and must then be applied
back to `develop` before the next normal release.

The repository owner/admin has a break-glass recovery path, but direct bypass
is not the standard release method. Neither branch requires a second approval,
Code Owner review, a merge queue, signed commits, or a deployment environment.

## Release PR metadata

Release PR bodies use a small, machine-readable envelope around the semantic
version and release notes. Keep both horizontal rules and the version heading
on their own lines; replace the version, date, and notes for each release.

```markdown
---
## [0.1.0] (2026-08-22)

Initial public baseline for reusable infrastructure engineering automation.

### Components

- Five independent Ansible role archives.
- One separate FreeIPA bootstrap archive.
- Deterministic manifests and SHA-256 checksums.

### Validation

- Shell, Python, Ansible, YAML, Markdown, and fixture checks passed.
---
```

## Independent release assets

Every published root release includes six separately installable archives:

| Asset | Contents |
| --- | --- |
| `ansible-role-dns-update-v<version>.tar.gz` | The `dns_update` role only |
| `ansible-role-keepalived-v<version>.tar.gz` | The `keepalived` role only |
| `ansible-role-mariadb-v<version>.tar.gz` | The `mariadb` role only |
| `ansible-role-mariadb-replication-v<version>.tar.gz` | The `mariadb_replication` role only |
| `ansible-role-maxscale-v<version>.tar.gz` | The `maxscale` role only |
| `freeipa-bootstrap-v<version>.tar.gz` | Public FreeIPA bootstrap scripts, docs, and safe example templates |

`SHA256SUMS-v<version>.txt` covers those archives and the accompanying
`release-manifest-v<version>.json`. The manifest records the release tag,
asset kind, component, size, and SHA-256 digest. Role archives extract to one
role root and carry the repository MIT `LICENSE`; the FreeIPA archive extracts
to `freeipa-bootstrap/` and does not include CI, tests, internal policy files,
or runtime secrets.

The release job calls the official Release Please Action's documented root
outputs (`release_created`, `tag_name`, and `version`). Only when
`release_created` is true does it check out the new tag, run
[`scripts/release/build-assets.py`](../scripts/release/build-assets.py), and
upload the generated files with the runner's `gh release upload`. The upload
uses the job's least-privilege `contents: write` permission. Since the upload
uses `GITHUB_TOKEN`, it does not recursively trigger another workflow run.

The local packaging smoke test is:

```bash
python3 tests/release/test_assets.py
```

It builds v0.1.0 twice in temporary directories and fails on a changed hash,
an unexpected path or link, unsafe archive permissions, a forbidden boundary,
known internal-policy or credential-marker content, or a checksum mismatch.
These markers are a bounded contract check, not a claim to detect every
possible secret. The builder accepts a strict SemVer value or a `v`-prefixed
tag and fails closed for malformed versions or non-Git source trees. It never
creates a tag or GitHub Release itself.

No feature-branch workflow run can publish a release. Do not manually edit a
generated release section while a Release PR is open; correct the source
commit or update the Release PR instead.

## Initial release

The first public baseline is `0.1.0`. The release tag, GitHub Release,
`version.txt`, manifest, and changelog entry must all identify the same source
tree. Subsequent releases follow the same reviewed Release PR flow and retain
the independent role and FreeIPA asset boundaries described above.

## References

- [Release Please Action README](https://github.com/googleapis/release-please-action)
  (workflow inputs and manifest setup)
- [Manifest-driven Release Please](https://github.com/googleapis/release-please/blob/main/docs/manifest-releaser.md)
  (root package, manifest, tag, and changelog behaviour)
- [Release Please configuration schema](https://github.com/googleapis/release-please/blob/main/schemas/config.json)
- [GitHub Actions workflow syntax](https://docs.github.com/en/actions/using-workflows/workflow-syntax-for-github-actions)
