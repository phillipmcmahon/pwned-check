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

For Linux runtime compatibility checks across minimal distro images:

```bash
make docker-smoke
```

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
