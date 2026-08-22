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

1. Merge changes into `main` using Conventional Commit subjects. Release Please
   classifies `feat`, `fix`, `perf`, and breaking changes to calculate the next
   semantic version.
2. The workflow opens or updates one Release PR. Review its generated
   `CHANGELOG.md`, `version.txt`, and manifest changes; the changelog entries
   link back to the merged commits and pull requests.
3. Merge the Release PR into `main`. The resulting `main` push lets Release
   Please create the `v<version>` tag and a published GitHub Release whose notes
   come from the same merged commit history.
4. Confirm the tag, GitHub Release, version file, manifest, and changelog agree.

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

The manifest and `version.txt` start at `0.0.0` as a bookkeeping baseline, not
as a claim that a `0.0.0` release exists. The first public release is created
only after Release Please opens a release PR and that PR is reviewed and merged.
The initial changelog text is intentionally not a fabricated release section;
Release Please will add the first dated section when it prepares that PR.

## References

- [Release Please Action README](https://github.com/googleapis/release-please-action)
  (workflow inputs and manifest setup)
- [Manifest-driven Release Please](https://github.com/googleapis/release-please/blob/main/docs/manifest-releaser.md)
  (root package, manifest, tag, and changelog behaviour)
- [Release Please configuration schema](https://github.com/googleapis/release-please/blob/main/schemas/config.json)
- [GitHub Actions workflow syntax](https://docs.github.com/en/actions/using-workflows/workflow-syntax-for-github-actions)
