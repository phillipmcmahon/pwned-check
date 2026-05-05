# Documentation Index

Use this page as the front door for project and operator documentation. The docs are organized by task so operators can install and recover the service without reading maintainer internals first.

## Operator Path

| Need | Start here |
|---|---|
| Install and operate the native PAM package | [Operations](operations.md): package install, dry-run, enforcement, disable, removal, and emergency recovery |
| Try the CLI checker locally | [Quickstart](quickstart.md): local checker examples, fail-open/fail-closed checks, and binary smoke |
| Prepare a secure rollout | [Deployment security checklist](deployment-security-checklist.md): rollout and recovery controls |
| Diagnose rollout issues | [Operational troubleshooting](troubleshooting.md): exit codes, module events, and outage checks |
| Understand secret-handling and privilege boundaries | [Security model](security-model.md): provider boundary, process exposure, env, argv, and non-goals |
| Review log events and safe diagnostics | [Logging policy](logging-policy.md): event catalog, example lines, and safe fields |
| Understand checker stdin/exit behavior | [Checker contract](checker-contract.md): canonical stdin, `--min-count`, exit-code, and stderr contract |
| Configure live HIBP provider behavior | [Provider policy](provider-policy.md): live API use, timeout, request volume, and test-provider boundary |
| Confirm platform and deployment assumptions | [Requirements](requirements.md): current Linux-first scope and integration constraints |

## Maintainer Path

| Need | Start here |
|---|---|
| Understand the roadmap | [Roadmap](roadmap.md): epics, user stories, and current implementation notes |
| Track issues and board workflow | [Project board workflow](project-board-workflow.md): issue fields, workflow statuses, and audit rules |
| Validate code changes | [Testing](testing.md): local gate, coverage threshold, fuzz schedule, and CI expectations |
| Validate Linux distro runtime and PAM package integration | [Distro testing runbook](distro-testing.md): persistent VM smoke process and GitHub Docker package smoke behavior |
| Understand release VM capacity and recovery | [VM fleet](vm-fleet.md): persistent VM inventory, recovery expectations, fallback boundaries, and access rules |
| Rebuild or refresh release validation VMs | [VM runbooks](vm-runbooks.md): per-distro bootstrap packages, smoke commands, recovery checks, and known quirks |
| Prepare a release | [Release playbook](release-playbook.md): release validation, Linux artifacts, and failure rule |
| Check production release readiness | [Production release gate](production-release-gate.md): signing, repository, smoke, rollback, outage, documentation, and board criteria |
| Plan production package repositories | [Package repositories](package-repositories.md): apt, dnf/yum, Arch, and Alpine repository publication plan |
| Review native PAM design details | [Native PAM module](native-pam-module.md): Rust/FFI contract and PAM placement |

## Suggested First-Time Flow

1. Read [Requirements](requirements.md) to understand the Linux-first target.
2. Install or test the checker with [Quickstart](quickstart.md) or [Operations](operations.md).
3. Review [Security model](security-model.md) before changing password-handling behavior.
4. Use [Testing](testing.md) and [Distro testing runbook](distro-testing.md) before changing packaging or PAM behavior.
5. Use [Project board workflow](project-board-workflow.md) when creating or moving issues.
