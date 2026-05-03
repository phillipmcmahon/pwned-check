# Documentation Index

Use this page as the front door for project and operator documentation. The docs are organized by task so a new contributor or operator can find the right starting point without reading internals first.

## Operator Path

| Need | Start here |
|---|---|
| Try the checker locally | [Quickstart](quickstart.md): local CLI examples, fail-open/fail-closed checks, and binary smoke |
| Understand checker stdin/exit behavior | [Checker contract](checker-contract.md): canonical stdin, `--min-count`, exit-code, and stderr contract |
| Confirm platform and deployment assumptions | [Requirements](requirements.md): current Linux-first scope and integration constraints |
| Configure live HIBP provider behavior | [Provider policy](provider-policy.md): live API use, timeout, request volume, and test-provider boundary |
| Understand install, upgrade, and rollback shape | [Operations](operations.md): package layout, Ubuntu PAM walkthrough, rollback, and helper mapping |
| Plan package repository distribution | [Package repositories](package-repositories.md): apt, dnf/yum, Arch, and Alpine repository publication plan |
| Test Linux password-change integration | [Linux PAM PoC](linux-pam-poc.md): PAM helper contract and manual password-change test plan |
| Plan native Linux PAM integration | [Native PAM module](native-pam-module.md): optional native module contract, Rust/FFI posture, packaging, and tests |
| Understand secret-handling and privilege boundaries | [Security model](security-model.md): provider boundary, process exposure, env, argv, and non-goals |
| Review log events and safe diagnostics | [Logging policy](logging-policy.md): event catalog, example lines, and safe fields |
| Prepare for secure rollout | [Deployment security checklist](deployment-security-checklist.md): rollout and recovery controls |
| Diagnose rollout issues | [Operational troubleshooting](troubleshooting.md): exit codes, helper events, and outage checks |
| Understand the CLI contract and long-term design | [Development and architecture](development-architecture.md): design principles and stability expectations |

## Maintainer Path

| Need | Start here |
|---|---|
| Understand the roadmap | [Roadmap](roadmap.md): epics, user stories, and current implementation notes |
| Track issues and board workflow | [Project board workflow](project-board-workflow.md): issue fields, workflow statuses, and audit rules |
| Validate code changes | [Testing](testing.md): local gate, coverage threshold, fuzz schedule, and CI expectations |
| Validate Linux distro runtime and PAM package integration | [Distro testing runbook](distro-testing.md): Docker and persistent VM package smoke process; [Docker smoke matrix](docker-smoke.md): distro image matrix and PAM package smoke behavior |
| Prepare a release | [Release playbook](release-playbook.md): release validation, Linux artifacts, and failure rule |

## Suggested First-Time Flow

1. Read [Requirements](requirements.md) to understand the Linux-first target.
2. Run the local checker with [Quickstart](quickstart.md).
3. Review [Security model](security-model.md) before changing password-handling behavior.
4. Review [Development and architecture](development-architecture.md) before changing the CLI contract.
5. Use [Project board workflow](project-board-workflow.md) when creating or moving issues.
