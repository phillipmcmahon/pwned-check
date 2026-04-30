# pwned-check Roadmap

This roadmap captures the product direction as epics and user stories. The current strategy is Linux-first integration with a small native Go checker. macOS and Windows are deferred until their signing and platform-security requirements can be handled deliberately.

## Epic 1: Harden the Go CLI

Project entry: [#4](https://github.com/phillipmcmahon/pwned-check/issues/4)

Goal: make the standalone checker predictable, safe, and simple enough for OS password-change integrations to call.

User stories:
- As an integrator, I want `pwned-check --stdin` to have a stable documented contract so PAM or other callers can enforce password rejection.
- As a security reviewer, I want proof that plaintext passwords are never logged or emitted.
- As an operator, I want clear timeout, provider, and fail-open/fail-closed settings.
- As a maintainer, I want live HIBP calls isolated from CI through mocked provider tests.
- As an operator, I want `pwned-check --version` so deployed binaries can be identified.

Deliverables:
- CLI contract tests.
- Config validation.
- Timeout tests.
- Structured stderr logging.
- Release version metadata.
- CI artifacts for Linux `amd64` and `arm64`.

## Epic 2: Linux PAM PoC

Project entry: [#5](https://github.com/phillipmcmahon/pwned-check/issues/5)

Goal: prove real password-change integration on Linux.

User stories:
- As a Linux administrator, I want a PAM integration that invokes `pwned-check` during password changes.
- As an administrator, I want a strict execution timeout so password changes cannot hang.
- As an administrator, I want configurable fail-open/fail-closed behavior.
- As a tester, I want a documented local VM or container test path for `passwd`.
- As an operator, I want clear rollback instructions if the PAM integration blocks password changes unexpectedly.

Deliverables:
- PAM helper/module approach decision.
- Minimal PAM integration.
- Example PAM config.
- Linux test harness.
- Manual test guide for Ubuntu/Debian first.
- Rollback instructions.

## Epic 3: Live HIBP Provider Policy

Project entry: [#6](https://github.com/phillipmcmahon/pwned-check/issues/6)

Goal: make current live HIBP provider use explicit, tested, and operationally understandable while preserving the provider boundary for future offline cache or mirror work.

User stories:
- As an operator, I want to use the live HIBP Pwned Passwords range API for production checks.
- As an administrator, I want explicit fail-open/fail-closed configuration for live provider outages.
- As a maintainer, I want automated tests that mock HIBP responses without adding offline cache or mirror scope to the current release.
- As a security reviewer, I want documentation explaining exactly what hash material is sent to HIBP.

Deliverables:
- Live HIBP provider configuration guidance.
- Mocked HIBP-compatible test fixtures.
- Fail-open/fail-closed decision notes.
- Provider privacy documentation.
- Future provider extension notes for offline cache or mirror support.

Current implementation notes:
- [Provider policy](provider-policy.md) documents the current live HIBP posture.
- Automated tests use mocked HIBP-compatible range responses and do not call the live HIBP API.

## Epic 4: Packaging and Release

Project entry: [#7](https://github.com/phillipmcmahon/pwned-check/issues/7)

Goal: make the tool installable, auditable, and repeatable.

User stories:
- As an administrator, I want a downloadable Linux binary with checksums.
- As a release manager, I want repeatable GitHub release artifacts.
- As an operator, I want PAM installation examples for live HIBP checks with fail-open/fail-closed configuration.
- As a security reviewer, I want dependency visibility for each release.

Deliverables:
- GitHub release workflow.
- Linux `amd64` and `arm64` binaries.
- SHA256 checksums.
- Install docs.
- SBOM or dependency report.
- Decision on `.deb` and `.rpm` packaging.

## Epic 5: Operational Security

Project entry: [#8](https://github.com/phillipmcmahon/pwned-check/issues/8)

Goal: make the tool production-shaped for security-sensitive deployment.

User stories:
- As an administrator, I want audit-friendly logs without secrets.
- As an operator, I want clear failure counters or diagnostics for rollout validation.
- As a security reviewer, I want documented threat assumptions.
- As a maintainer, I want fuzz or property tests for provider response parsing.
- As an operator, I want hard timeout behavior across provider and integration layers.

Deliverables:
- Threat model.
- Logging policy.
- Parser fuzz tests.
- Timeout behavior tests.
- Deployment security checklist.
- Operational troubleshooting guide.

## Epic 6: Native Linux PAM Module Delivery

Project entry: [#10](https://github.com/phillipmcmahon/pwned-check/issues/10)

Goal: deliver a native Linux PAM module once the current `pam_exec` helper integration has proven the checker contract, security controls, and operator workflow.

User stories:
- As a Linux administrator, I want a native PAM module so password-change enforcement integrates cleanly with PAM without relying on `pam_exec` process glue.
- As a security reviewer, I want the PAM module to preserve the no-plaintext-logging and no-password-argv guarantees of the helper path.
- As an operator, I want the native module to support explicit timeout and fail-open/fail-closed behavior consistent with the checker contract.
- As a maintainer, I want parity tests proving the native module maps checker outcomes the same way as `pwned-check-pam-helper`.
- As a release manager, I want native module packaging and installation guidance that clearly separates experimental rollout from production rollout.

Deliverables:
- Native PAM module feasibility and design note.
- Decision on implementation language and ABI strategy.
- PAM module configuration format and examples.
- Outcome mapping parity with `pwned-check-pam-helper`.
- Timeout and fail-open/fail-closed behavior parity.
- Minimal distro validation matrix for the module.
- Install, rollback, and emergency recovery documentation.
- Security review checklist for native PAM deployment.

## Epic 7: macOS and Windows Feasibility

Project entry: [#9](https://github.com/phillipmcmahon/pwned-check/issues/9)

Goal: plan non-Linux integrations without reducing platform security posture.

User stories:
- As a macOS administrator, I want a signed and notarized checker binary before any password integration.
- As a Windows administrator, I want an Authenticode-signed checker binary before Password Filter DLL work.
- As a Windows integration developer, I want a native DLL shim that does not embed unnecessary runtime complexity into LSASS.
- As a macOS integration developer, I want a clear feasibility note for PAM, OpenDirectory, or other supported password-change hooks.
- As a product owner, I want clear cost and security tradeoffs before expanding beyond Linux.

Deliverables:
- macOS signing and notarization spike.
- Windows Authenticode signing spike.
- Windows Password Filter DLL design.
- macOS integration feasibility note.
- Decision record for each platform.

## Near-Term Recommendation

Start with Epic 2 after the current Go CLI baseline is stable. The preferred shape is a minimal PAM component that receives the candidate password, invokes `pwned-check --stdin` with a strict timeout, and maps the checker exit code to allow or reject. Keep all breach-checking logic in the Go binary.
