# Proposed release standard

Status: Draft for review. This document specifies target behavior; it does not change the existing workflows.

Initial scope: `conceptadev/dart-actions`, `conceptadev/remix`, `conceptadev/mix`, `conceptadev/naked_ui`, and `conceptadev/ack`.

## Decision

Use `conceptadev/dart-actions` as the shared implementation for Dart and Flutter release automation. Keep package configuration and specialized checks in each caller repository.

Retain repository-resolved Melos for version preparation. Use Conventional Commits to propose release notes and versions. Publish existing pub.dev packages with short-lived OIDC credentials through the official Dart integration.

Standardize the release process, not every package's version number. Do not introduce a second tool that rewrites the same versions and changelogs.

See [the rollout plan](release-rollout.md) for the proposed implementation PRs and migration gates.

## Maintainer experience

Prepare release -> review the release PR -> merge -> verify the release commit -> create approved tags -> publish with OIDC -> verify registry availability.

The preparation action accepts a package or coordinated release group and a stable, beta, or release-candidate channel. It proposes versions, with an explicit version override available for review. It opens or updates a release PR containing the version changes, changelogs, required dependency changes, and derived release metadata.

Preparation never publishes. Publication remains tag-triggered and subject to the caller's required checks and publishing environment. Automation creates tags only after verifying the reviewed release commit. A label, arbitrary branch name, or supplied artifact is not release authorization.

The final summary distinguishes published, already present and verified, blocked, failed, and unverified packages. Finalize a GitHub Release only after the selected exact pub.dev versions have been confirmed.

## Shared and repository-specific responsibilities

| Dart Actions owns | Caller repository owns |
| --- | --- |
| SDK installation, integrity checks, and caching | The reviewed SDK version source and supported consumer SDK floor |
| Release preparation and plan validation | Package allowlist, paths, release groups, and versioning policy |
| Common analysis, test, and publication checks | Special tests, generation checks, and release metadata synchronization |
| Tag verification and automatic handoffs | Existing tag patterns and required release checks |
| Hosted-dependency and exact-version checks | Dependency constraints and explicit release-order exceptions |
| OIDC upload and result reporting | Package publishing authorization and environment protections |

Use package manifests and Melos configuration as the source of package versions. Supplemental configuration may define targets, tag patterns, and hooks, but must not duplicate current versions.

The implementation must respect the trust boundary when loading shared helpers: checking out the caller does not also check out Dart Actions. Load provider helpers from an explicit reviewed provider revision and test that the workflow and helper versions agree.

### Proposed workflow interfaces

These names describe responsibilities, not implemented APIs:

| Workflow | Purpose |
| --- | --- |
| `prepare-release.yml` | Propose versions, run preparation checks, validate a release plan, and create or update the release PR. |
| `tag-release.yml` | Verify the merged release and create only its approved, non-conflicting tags. |
| `publish.yml` | Validate tagged packages, perform hosted checks, upload through OIDC, and verify publication. |

Use reusable workflows for jobs and permission boundaries. Use small shared actions or helpers for logic that needs to compose with a caller's platform-specific jobs. Preserve current callers until a tested migration is available; do not replace `publish.yml` with an incompatible contract in one step.

## Versioning and tags

Run the locally resolved tool with `dart run melos`. Establish a tested Melos compatibility matrix before migration. A toolchain upgrade must not silently raise the minimum SDK required by package consumers.

Use Conventional Commit PR titles and a consistent feature-merge policy. Review breaking changes and prerelease increments explicitly. Preserve published changelog sections and exclude private packages from release selection even when they carry a workspace version.

| Release model | Target convention |
| --- | --- |
| One publishable package | `v<version>` |
| Independently versioned packages | `<package>-v<version>` |
| Coordinated fixed-version group | One `v<version>` for the approved group |

The workflow trigger, version parser, release-history lookup, and pub.dev authorization must agree. These conventions do not authorize renaming existing tags or changing publisher settings.

Preserve ACK's coordinated versioning. Preserve independent package versions in Mix and Remix. Initially preserve Remix's two-tag exception: `v<version>` publishes Remix, while `remix-v<version>` records Melos history. Both must point at the same approved commit. Consolidate them only through a separately verified migration. Never move published tags.

A release plan records the selected targets, expected versions, tags, dependency order, prepared base commit, relevant content identity, and toolchain/provider revisions. Bind the validated plan to the final merge commit after merge; do not require a tracked plan to contain its own commit hash.

For independent packages, use each package's correctly tagged publishing run. A matrix under an unrelated package's tag is not sufficient. Advance dependent releases only after their required hosted versions are available. Coordinated groups may publish in dependency stages under their authorized shared tag.

## Credentials and permissions

The caller repository remains the package's publishing identity. Dart Actions supplies reusable implementation, not a replacement repository identity for every package.

Separate three permission scopes:

| Scope | Required boundary |
| --- | --- |
| Validation and preparation computation | Read-only repository access; no release App key or publishing permission. |
| PR and tag writes | Narrowly scoped GitHub App installation token in dedicated jobs; no arbitrary caller test or generation hooks. |
| Upload | `contents: read` and `id-token: write`, protected by the approved publishing environment. |

GitHub does not start a new push workflow for tags pushed with the ordinary `GITHUB_TOKEN`. A narrowly scoped GitHub App installation token is the proposed automatic handoff. The App key still needs secret management; OIDC does not eliminate that separate responsibility. [2]

Use the official `dart-lang/setup-dart` OIDC integration for pub.dev. Prefer the official reusable publisher when its tested contract fits; otherwise preserve exact SDK selection in one shared publisher. Do not build custom JWT minting or require a permanent pub.dev token. Existing packages need repository/tag authorization, and first publication of a new package remains a maintainer step. [1]

Acquire publishing credentials near upload, but do not confuse late provisioning with a step-level permission boundary. All steps in an OIDC-enabled job are privileged. Keep tests and generators in separate unprivileged jobs and keep the upload job small.

Retain the existing `Production` name during migration. Verify the actual environment protections, tag rules, App permissions, and pub.dev requirements. Do not assume a YAML declaration proves those protections exist or silently create a replacement unprotected environment.

## Validation and resumable publication

Validate names, paths, versions, publishability, tag uniqueness, approved source identity, and required checks before requesting publishing credentials. Parse manifests rather than relying on text searches. Pass inputs through arguments or environment variables, not interpolated shell source.

Run formatting, static analysis, tests, generation-drift checks, and repository-specific release checks. Fail on unexpected changes to source or generated files. Handle any known SDK configuration migration explicitly before final validation instead of discarding arbitrary tracked changes after tests.

Keep these checks distinct:

- Candidate tests may exercise unpublished sibling packages together.
- Hosted consumer checks must detach from workspace overrides and resolve actual registry dependencies.

Workspace tests alone cannot establish hosted installability. A consumer that requires an unpublished dependency remains blocked until that dependency is available. Keep workspace-dependent fixtures in their workspace tests and use detached resolution and analysis for the hosted check. [3]

Before upload, check the exact package version. Treat only a confirmed missing response as unpublished; timeouts, 403 responses, invalid payloads, and server errors must stop the decision. On reruns, establish consistency with the intended release before classifying an existing version as complete. Existence alone is not content proof. When consistency cannot be established, report unverified and require review rather than uploading again.

Keep a mandatory publish dry run. Bind validation evidence to the exact reviewed content and SDK used for publication; validate any cross-job artifact identity before use. Publish with normal client validation as the target behavior. Verify exact-version availability after upload with bounded retries before advancing dependents.

Do not cancel an active upload when a new release arrives. Separate caller and provider concurrency groups to avoid collisions. Treat concurrency control as a lock, not an unlimited durable queue. Retry a partial release against the same approved tags and content.

## Incident workaround: pub-dev #9576

The reviewed Dart Actions publisher and ACK's separate publisher both contain `--skip-validation`. Track removal in both paths; centralizing one does not automatically migrate the other.

Retire the flag after focused tests on an approved runner: public metadata and advisory reads, harmless dummy-bearer reads, and a tag-context dry run after real OIDC setup. Never log credentials. These tests provide different evidence: a dummy-header success does not prove publishing authorization, and a dry run does not prove upload authorization.

Confirm the full path through the first approved real release. Do not publish test versions as part of this documentation change. A temporary bypass must remain explicit, linked to the incident, and gated by successful prior validation of unchanged content. Never enable it automatically after an arbitrary error. The flag skips client validation and dependency resolution. [4]

## Acceptance and maintenance

Pin provider workflows and underlying actions to reviewed full commit SHAs. Use a reviewed exact SDK with integrity verification. Automate update PRs rather than moving consumers silently with `main`. [5]

Before changing live callers, test standalone Dart, Flutter, independent-package, and coordinated-workspace fixtures. Cover private-package rejection, wrong tags, wrong commits, missing dependencies, source drift, partial-release retry, registry failures, helper revision selection, and credential isolation.

Keep release records of the caller, source commit, package versions, tag names, SDK, provider revision, and verification result. Migrate one caller at a time and remove duplicated generic scripts only after approved releases demonstrate parity.

## References and review baseline

Baseline reviewed on September 12, 2026: Dart Actions commit `9bb0b129ef4984963f9df9e03733eb2851e413ad`. This is a design proposal, not evidence that protection settings or new workflows have been deployed.

- [Current shared publisher](https://github.com/conceptadev/dart-actions/blob/9bb0b129ef4984963f9df9e03733eb2851e413ad/.github/workflows/publish.yml)
- [ACK publisher reviewed for reusable checks](https://github.com/conceptadev/ack/blob/c5367ff1a93c9ee07b3c31e1d1bce304858508ee/.github/workflows/publish-packages.yml)
- [Remix release preparation reviewed](https://github.com/conceptadev/remix/blob/f2a3f2b1e8629fc2475002307c5770aab7bb960c/.github/workflows/version.yml)
- [Incident: dart-lang/pub-dev#9576](https://github.com/dart-lang/pub-dev/issues/9576)
- [1: Dart automated publishing](https://dart.dev/tools/pub/automated-publishing)
- [2: GitHub workflow triggering and token behavior](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/trigger-a-workflow)
- [3: Pub workspaces](https://dart.dev/tools/pub/workspaces)
- [4: dart pub publish](https://dart.dev/tools/pub/cmd/pub-lish)
- [5: GitHub secure use of Actions](https://docs.github.com/en/actions/reference/security/secure-use)
- [Melos versioning](https://melos.invertase.dev/commands/version)
- [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/)
