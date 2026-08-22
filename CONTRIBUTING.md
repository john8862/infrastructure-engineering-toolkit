# Contributing

Contributions are welcome when they improve the reliability, clarity, or
reproducibility of this toolkit. Please keep changes focused and suitable for
a public repository.

Before opening a pull request:

- remove credentials, private keys, personal information, restricted project
  material, internal hostnames, and other non-public data;
- use representative placeholders in examples and document prerequisites,
  assumptions, validation, and recovery steps; and
- run the checks relevant to the component and describe what was verified.

## Commit messages

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
Release Please reads merged Conventional Commits on `main`; clear subjects
make the generated release PR, changelog, and GitHub Release easier to review.

## Licence

By contributing, you agree that your contribution may be distributed under
the repository's [MIT License](LICENSE). Include third-party notices when a
change introduces material that is not original to this repository.
