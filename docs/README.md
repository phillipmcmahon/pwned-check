# Documentation Index

Use this page as the front door for project and operator documentation. The docs are organized by task so a new contributor or operator can find the right starting point without reading internals first.

## Operator Path

| Need | Start here |
|---|---|
| Try the checker locally | [Quickstart](quickstart.md) |
| Confirm platform and deployment assumptions | [Requirements](requirements.md) |
| Configure live HIBP provider behavior | [Provider policy](provider-policy.md) |
| Understand install, upgrade, and rollback shape | [Operations](operations.md) |
| Test Linux password-change integration | [Linux PAM PoC](linux-pam-poc.md) |
| Understand secret-handling and privilege boundaries | [Security model](security-model.md) |
| Understand the CLI contract and long-term design | [Development and architecture](development-architecture.md) |

## Maintainer Path

| Need | Start here |
|---|---|
| Understand the roadmap | [Roadmap](roadmap.md) |
| Track issues and board workflow | [Project board workflow](project-board-workflow.md) |
| Validate code changes | [Testing](testing.md) |
| Validate Linux distro runtime and PAM package integration | [Docker smoke matrix](docker-smoke.md) |
| Prepare a release | [Release playbook](release-playbook.md) |

## Suggested First-Time Flow

1. Read [Requirements](requirements.md) to understand the Linux-first target.
2. Run the local checker with [Quickstart](quickstart.md).
3. Review [Security model](security-model.md) before changing password-handling behavior.
4. Review [Development and architecture](development-architecture.md) before changing the CLI contract.
5. Use [Project board workflow](project-board-workflow.md) when creating or moving issues.
