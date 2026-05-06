# Documentation Index

Use this page as the front door for project and operator documentation. The
Linux production path is package based: install the native PAM package from a
signed repository, enable dry-run, validate, then switch to enforcement.

## Operator Path

| Need | Start here |
|---|---|
| Install and operate the native PAM package | [Linux package install](linux-install.md): repository setup, package install, dry-run, enforcement, rollback, removal, and emergency recovery |
| Plan production operations | [Operations](operations.md): rollout validation, rollback checks, and configuration notes |
| Review signed repository internals | [Package repositories](package-repositories.md): repository layout, signing, key rotation, and live endpoint checks |
| Try the CLI checker locally | [Quickstart](quickstart.md): standalone checker examples, fail-open/fail-closed checks, and binary smoke |
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
| Review the Linux production baseline | [Linux production baseline](linux-production-baseline.md): EP11 closeout evidence and remaining non-Linux scope |
| Maintain package repositories | [Package repositories](package-repositories.md): repository layout, signing, key rotation, and live endpoint checks |
| Review native PAM design details | [Native PAM module](native-pam-module.md): Rust/FFI contract and PAM placement |

## Suggested First-Time Flow

1. Install and enable from [Linux package install](linux-install.md).
2. Review [Deployment security checklist](deployment-security-checklist.md) before production enforcement.
3. Use [Troubleshooting](troubleshooting.md) if package, PAM, or provider checks fail.
4. Use maintainer docs only when changing code, packaging, release automation, or project-board state.
