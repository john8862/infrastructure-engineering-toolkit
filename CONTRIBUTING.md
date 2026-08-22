# Contributing

Contributions are welcome when they improve the reliability, clarity, or
reproducibility of this toolkit. Please keep changes focused and suitable for
a public repository.

## Branch and pull-request model

`develop` is the normal integration branch. Create every ordinary topic branch
from the latest `origin/develop`, and open its pull request against `develop`.
The protected `main` branch is reserved for reviewed integration and release
promotion from `develop`. An emergency hotfix may target `main` when the normal
path cannot be used, but the pull request must explain the reason and the
equivalent fix must be brought back to `develop` afterwards.

The intended contribution hierarchy is:

```text
fork or feature/fix branch  ->  develop  ->  main
```

Working branches are deliberately lightweight. Contributors may push, amend,
rebase, or force-push their own topic branch as needed; protection is applied
when the work crosses into `develop`. A fork contributor does not need push
permission in this repository and should open a pull request from the fork to
`develop`.

### Protection policy

Both protected branches require a pull request, the four named Quality Gates,
resolved conversations, and protection against force-push and deletion. The
solo-maintainer policy deliberately sets approvals to zero: external review is
welcome and expected where available, but GitHub must not require a second
person or Code Owner approval before the owner can merge a green pull request.

| Control | `develop` | `main` |
| --- | --- | --- |
| Pull request required | Yes | Yes |
| Required Quality Gates | Four checks | Four checks |
| Branch must be up to date | No; reduce integration churn | Yes; release consistency |
| Linear history | No; preserve fast integration | Yes; use squash or rebase |
| Conversation resolution | Required | Required |
| Required approvals | 0 | 0 |
| Code Owner or last-push approval | No | No |
| Merge queue, signed commits, deployment gate | None | None |
| Force-push and deletion | Blocked | Blocked |

The owner/admin break-glass path remains available for recovery, but it is not
the normal development workflow and does not justify direct pushes. Do not
reset, rewrite, or force-push `main` or `develop`.

Normal topic merges should use squash where practical. A squash promotion can
leave the two protected branches with different commit graphs. If a later
`develop` to `main` pull request is reported as behind, use GitHub's **Update
branch** action to merge current `main` into `develop` and rerun the checks, or
open a focused `main` to `develop` synchronisation pull request. Never repair
this state by rewriting a protected branch.

The four required check contexts are documented in [`docs/CI.md`](docs/CI.md).
They are the same on both protected branches; only the branch-freshness and
history rules differ.

For a fresh clone, the recommended starting sequence is:

```bash
git clone https://github.com/john8862/infrastructure-engineering-toolkit.git
cd infrastructure-engineering-toolkit
git fetch origin develop
git switch --track -c develop origin/develop
git pull --ff-only origin develop
git switch -c feature/mariadb-replication-safety
```

Use one of these prefixes for a focused branch: `feature/`, `fix/`, `bugfix/`,
`docs/`, `ci/`, `test/`, `refactor/`, or `chore/`. The preferred format is:

```text
<prefix>/<focused-scope>-<short-description>
```

For example, `docs/contributing-develop-workflow` and
`fix/dns-ptr-conflict` describe one clear subject. Existing branches with a
simple scope remain compatible; choose a name that makes the intended change
obvious and avoid combining unrelated work.

### Keep a topic branch current

Before starting work and before opening a pull request, update the local
integration branch without creating an accidental merge commit:

```bash
git fetch origin
git switch develop
git pull --ff-only origin develop
git switch feature/mariadb-replication-safety
git rebase origin/develop
```

Resolve conflicts deliberately, run the relevant checks again, and inspect
the resulting diff. If a topic branch is shared with another contributor,
coordinate before rebasing it; do not overwrite someone else's work. Push a
new topic branch with:

```bash
git push --set-upstream origin feature/mariadb-replication-safety
```

After a local rebase of an already-published topic branch, use
`--force-with-lease` only when the branch is yours and the remote change is
expected. Never force-push `main` or `develop`.

Before opening a pull request:

- remove credentials, private keys, personal information, restricted project
  material, internal hostnames, and other non-public data;
- use representative placeholders in examples and document prerequisites,
  assumptions, validation, and recovery steps; and
- run the checks relevant to the component and describe what was verified.

## Commit messages and pull requests

Use a [Conventional Commit](https://www.conventionalcommits.org/en/v1.0.0/)
subject so that the release notes and root `CHANGELOG.md` remain useful:

```text
<type>(<scope>): <imperative summary>
```

Use these types where applicable: `feat`, `fix`, `docs`, `test`, `refactor`,
`perf`, `build`, `ci`, `chore`, or `revert`. The supported component scopes are:

- `freeipa`
- `mariadb`
- `mariadb-replication`
- `maxscale`
- `keepalived`
- `dns-update`

Use no scope for a genuinely repository-wide change. Mark an incompatible
change with `!` after the type or scope and explain it in the commit body with
`BREAKING CHANGE:`. Examples:

```text
feat(mariadb-replication): add a validation check
fix(maxscale): handle an unavailable backend
docs(freeipa): clarify bootstrap prerequisites
ci: configure automated releases
```

Pull requests should explain the user-visible effect, affected component,
validation performed, and any compatibility or migration considerations.
Set the base branch to `develop` for normal work. A promotion pull request from
`develop` to `main` should summarise the reviewed changes, release impact, and
the validation evidence that applies to the integrated set. Release Please
reads merged Conventional Commits on `main`; clear subjects make the generated
release PR, changelog, and GitHub Release easier to review.

An urgent hotfix starts from `main` and targets `main` through a focused pull
request. Once it is merged, apply the equivalent change to `develop` through a
separate pull request before the next promotion.

Each pull request should meet these requirements:

- Keep the diff focused on one component, documentation subject, or directly
  related integration change.
- Use the branch naming model above and a Conventional Commit subject.
- Describe the motivation, affected paths, operational boundaries, and any
  compatibility or migration considerations.
- Include the exact local checks run and link relevant documentation or
  examples.
- Ensure all four Quality Gates are green before requesting integration.
- Re-read the complete diff for public safety and remove generated or
  environment-specific files.

A branch that meets these requirements is prioritised for review and
integration. This priority does not guarantee acceptance or bypass technical,
security, compatibility, or maintainer review.

## Public-safe and security review

Do not commit passwords, tokens, private keys, certificates, Kerberos or TSIG
material, personal information, live inventories, internal hostnames, private
network details, customer data, or runtime state. Use RFC documentation ranges,
`example.invalid`, and clearly labelled placeholders in fixtures. Keep secret
values in an external secret manager or an approved runtime workflow.

Before opening a pull request, inspect tracked files and the complete diff:

```bash
git status --short
git diff --check origin/develop...HEAD
git diff --stat origin/develop...HEAD
git diff origin/develop...HEAD
```

Do not add bundled vendor packages, generated credentials, or files that are
not required by the public component contract. If a change touches authority,
privilege, credentials, certificates, firewall rules, DNS, database state, or
failover behaviour, document the preconditions, check-mode or dry-run path,
rollback boundary, and residual operator responsibility.

## Validation

Run the checks that cover the changed component. The following dependency-free
contract and syntax checks are a useful baseline:

```bash
python tests/dns_update/test_contract.py
python tests/mariadb/test_contract.py
python tests/mariadb_replication/test_contract.py
bash tests/freeipa-bootstrap/test.sh
bash tests/maxscale/test_static.sh
sh tests/keepalived/test_syntax.sh
```

For role or fixture changes, also run the pinned Ansible and Markdown checks
described in [`docs/CI.md`](docs/CI.md). Use the same Python and collection
versions as CI where possible. Do not claim live-host success from syntax,
contract, or check-mode validation alone.

## Branch lifecycle

The normal lifecycle is:

1. Create a focused topic branch from the latest `develop`.
2. Implement one coherent change, commit it with Conventional Commit subjects,
   and run the relevant validation.
3. Push the topic branch and open a pull request against `develop`.
4. Address review feedback, keep the branch current, and wait for all Quality
   Gates to pass before integration.
5. After the change is integrated, maintainers may delete the merged topic
   branch; recreate future work from the latest `develop`.
6. Promote a reviewed, green `develop` state to `main` through a separate pull
   request. `main` must be current because its required checks are strict;
   release automation and version publication remain main-only.

The branch model prioritises changes that are easy to review and integrate,
but it does not replace maintainer judgement or the required technical,
security, and compatibility review. Keep hotfixes narrowly scoped and record
why the normal develop path was not viable; synchronise the fix back to
`develop` after the main-branch repair.

## Licence

By contributing, you agree that your contribution may be distributed under
the repository's [MIT License](LICENSE). Include third-party notices when a
change introduces material that is not original to this repository.
