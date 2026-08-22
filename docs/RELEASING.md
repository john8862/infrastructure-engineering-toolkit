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
