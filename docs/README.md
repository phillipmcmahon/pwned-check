# Documentation Index

The documentation set is intentionally small. User-facing Linux guidance lives
in one package-first guide. The remaining documents are for maintainers,
release work, architecture, design, testing, and roadmap tracking.

## User Documentation

| Need | Start here |
|---|---|
| Install, enable, validate, roll back, remove, or troubleshoot | [Linux install and operations guide](linux-install.md) |

## Architecture And Design

| Need | Start here |
|---|---|
| Confirm product scope and constraints | [Requirements](requirements.md) |
| Understand the Linux PAM module design | [Native PAM module](native-pam-module.md) |
| Review security boundaries | [Security model](security-model.md) |
| Review safe logging rules | [Logging policy](logging-policy.md) |
| Understand checker stdin and exit codes | [Checker contract](checker-contract.md) |
| Understand provider behavior | [Provider policy](provider-policy.md) |
| Review the roadmap | [Roadmap](roadmap.md) |

## Release And Validation

| Need | Start here |
|---|---|
| Maintain signed package repositories | [Package repositories](package-repositories.md) |
| Prepare or publish a release | [Release playbook](release-playbook.md) |
| Check production release criteria | [Production release gate](production-release-gate.md) |
| Validate code and package changes | [Testing](testing.md) |
| Validate distro runtime behavior | [Distro testing](distro-testing.md) |
| Review VM inventory and recovery expectations | [VM fleet](vm-fleet.md) |
| Rebuild or refresh release validation VMs | [VM runbooks](vm-runbooks.md) |
| Track issues and board workflow | [Project board workflow](project-board-workflow.md) |
| Review Linux production baseline evidence | [Linux production baseline](linux-production-baseline.md) |

## Release Notes

Release notes in this repository start at the production package era. Earlier
history remains available through Git tags and GitHub Releases.

| Release | Notes |
|---|---|
| v0.3.0 | [Production package baseline](releases/v0.3.0.md) |
| v0.3.0 | [Production gate evidence](releases/v0.3.0-production-gate.md) |
| v0.3.1 | [Apt multiarch correction](releases/v0.3.1.md) |
| v0.3.2 | [Package repository refresh](releases/v0.3.2.md) |
