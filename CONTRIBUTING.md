# Contributing

Thank you for contributing to `pwned-check`.

## Design Bias

Prefer simple, explicit contracts over compatibility shims. The project has no production users yet, so breaking changes are acceptable when they make the model clearer, safer, or easier to operate.

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

This checks formatting, tests, vet, build, and binary smoke behavior.
It also runs Staticcheck via the module-pinned tool dependency.
The validation gate mirrors CI and includes the Docker smoke matrix.
It also installs the Linux package into minimal distro containers and validates PAM outcomes through `pam_exec.so expose_authtok`.
It also builds Linux release packages for `amd64` and `arm64`.

For Linux runtime compatibility checks across minimal distro images:

```bash
make docker-smoke
```

For Linux PAM package integration checks across minimal distro images:

```bash
make docker-pam-smoke
```

## Git Hooks

Install the local pre-push hook:

```bash
scripts/install-git-hooks.sh
```

The hook runs:

```bash
scripts/validate-before-push.sh
```

This is intentionally heavier than a pre-commit hook because it runs race-enabled tests and Docker smoke. It should catch CI failures before code reaches `origin`.

## Public Contract

The public contract is the operator and integration surface:

- `pwned-check --stdin`
- exit codes
- environment variables
- logs
- release artifacts
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
