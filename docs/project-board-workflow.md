# Project Board Workflow

This project uses GitHub Projects as the source of truth for delivery tracking. Repository docs describe direction; project board entries track execution.

## Board

Board: [`pwned-check Planning`](https://github.com/users/phillipmcmahon/projects/2)

Default status flow:
- `Todo`: accepted work that is not yet being actively changed.
- `In Progress`: actively being implemented, researched, or validated.
- `Done`: implemented, documented, tested, and merged where code changes are involved.

Workflow flow:
- `Ready`: defined, accepted, and available to start.
- `In Progress`: actively being changed.
- `Review`: implementation is complete and being reviewed or validated.
- `Done`: complete, merged where applicable, and closed unless it is an intentionally open tracking epic.

## Entry Types

Use labels to classify entries:
- `type: epic`: a large outcome made up of multiple stories.
- `type: story`: a user-visible or operator-visible increment of value.
- `type: task`: implementation work that does not stand alone as user value.
- `type: spike`: bounded research with a written conclusion.
- `status:in-progress`: issue is actively being changed.
- `status:review`: issue is ready for review or validation.
- `area: cli`: checker CLI behavior.
- `area: linux`: Linux/PAM integration.
- `area: provider`: live HIBP provider behavior and mocked provider tests.
- `area: release`: packaging, artifacts, and release automation.
- `area: security`: threat model, logging, operational controls.
- `area: macos`: macOS-specific work.
- `area: windows`: Windows-specific work.

## Standard Epic Format

Every epic entry should use this structure:

```markdown
## Outcome
What capability or decision this epic delivers.

## Context
Why the work matters and what constraints shape it.

## User Stories
- As a ..., I want ..., so that ...

## Deliverables
- Concrete artifact, behavior, or decision.

## Acceptance Criteria
- Observable criteria that must be true before the epic is Done.

## Dependencies
- Other epics, technical decisions, credentials, platforms, or environments needed.

## Notes
- Useful implementation notes, links, or non-goals.
```

## Standard Story Format

Every story entry should use this structure:

```markdown
## User Story
As a ..., I want ..., so that ...

## Context
What the implementer needs to know before starting.

## Acceptance Criteria
- Given ..., when ..., then ...

## Implementation Notes
- Preferred approach, constraints, and known risks.

## Test/Validation Plan
- Commands, manual checks, or environments required.

## Documentation Impact
- README, docs, examples, or operational notes to update.
```

## Definition of Ready

An item is ready for `Todo` when:
- The outcome is clear.
- Acceptance criteria are testable.
- Dependencies and blockers are listed.
- The item is small enough to start or clearly marked as an epic.

## Definition of Done

An item can move to `Done` when:
- Acceptance criteria are satisfied.
- Tests or validation steps have passed.
- Documentation is updated where behavior or operation changed.
- Security-sensitive behavior has been reviewed for logging, timeout, and failure-mode impact.
- Follow-up work is captured as separate board entries.

## Operating Rhythm

Recommended working pattern:
- Keep epics broad and stable.
- Break active epics into stories before implementation.
- Limit `In Progress` to the work currently being changed or validated.
- Prefer small pull requests tied to one story.
- Record architecture or security decisions in `docs/` when they change long-term direction.
- Prefer `scripts/project-transition.sh` for moving issue status and board fields together.
- Run `scripts/project-board-audit.sh` before declaring milestone or release tracking complete.
