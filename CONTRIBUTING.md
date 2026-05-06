# Contributing

Thank you for contributing to `pwned-check`.

## Design Bias

Prefer simple, explicit contracts over transition layers. The project has no production users yet, so breaking changes are acceptable when they make the model clearer, safer, or easier to operate.

Security-sensitive behavior should be easy to explain:

- password via stdin only
- no plaintext password logging
- hard timeouts
- explicit fail-open/fail-closed behavior
- small platform integration layers

## Local Validation

Before pushing:

```bash
make validate
```

This checks formatting, tests, vet, Staticcheck, build, checker smoke behavior,
native PAM build gates, and package install behavior on the configured distro
VMs.

For Linux runtime compatibility checks across minimal distro images:

```bash
make docker-smoke
```

Native PAM package integration is validated through the distro VM and package
smoke targets documented in `docs/distro-testing.md`.

## Git Hooks

Install the local pre-push hook:

```bash
scripts/install-git-hooks.sh
```

The hook runs:

```bash
scripts/validate-before-push.sh
```

This is intentionally heavier than a pre-commit hook because it runs
race-enabled tests and distro package smokes. It should catch package or CI
failures before code reaches `origin`.

## Public Contract

The public contract is the operator and integration surface:

- `pwned-check --stdin`
- exit codes
- environment variables
- logs
- release package files
- future PAM integration behavior

Go packages under `internal/` are implementation details.

## Pull Request Checklist

- [ ] `make validate` passes
- [ ] tests cover changed behavior
- [ ] docs updated when CLI, config, logs, or operations change
- [ ] project board entry is linked and current
- [ ] no plaintext password is logged, printed, or persisted
- [ ] failure mode and timeout impact considered

## Project Workflow

Use [docs/project-board-workflow.md](docs/project-board-workflow.md) for issue and project-board conventions.

Prefer:

```bash
scripts/project-transition.sh --issue <number> --stage in-progress
scripts/project-transition.sh --issue <number> --stage review
scripts/project-transition.sh --issue <number> --stage done --close
```

Run:

```bash
scripts/project-board-audit.sh
```

before declaring release or milestone tracking complete.
