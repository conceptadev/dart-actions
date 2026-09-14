# Concepta Release: implementation plan

Updated September 14, 2026. Implements the [proposed architecture](release-standard.md). This replaces the earlier publisher-first rollout and incorporates the organization-wide, workspace-first direction.

**Ready now:** inventory, foundation review, and a read-only Dart core. **Not ready yet:** automatic releases, production deployments, repository renaming, or organization-wide migration.

Phase IDs below are planning identifiers, not GitHub PR numbers. PR #9 contains this plan; PR #10 contains the existing foundation code. Neither was merged when checked for this revision.

## Act on these first

| Priority | Action | Output |
| --- | --- | --- |
| 1 | Review this revised architecture and the reusable parts of PR #10. | One agreed CLI/workflow boundary; explicit retained components and gaps. |
| 2 | Record current release/deployment consumers and protect live paths before changing them. | Public-safe inventory, baseline workflow pins, and administration checklist. |
| 3 | Start `feat(core): add release configuration and read-only planning`. | A tested `concepta_release` package with `doctor`, `plan`, and mixed-version-group fixtures. No remote writes. |

Inventory and core implementation may proceed in parallel. Do not make the Dart core wait for every repository migration. Do not start by renaming the repository, moving every package, or building more generic YAML.

## Sequence and dependencies

| Phase | Deliverable | Depends on |
| --- | --- | --- |
| R0 | Baseline inventory and live-path safeguards | Can start now |
| R1 | Architecture/API contract and foundation alignment | This plan and review of PR #10 |
| R2 | Dart core, configuration, and read-only planner | R1; representative fixtures from R0 |
| R3 | Melos-backed preparation and metadata synchronization | R2 |
| R4 | Shared validation/builds and artifact contract | R1 + R2; release validation integrates R3 |
| R5 | Resumable tag-triggered OIDC publisher | R3 + R4; R0 safeguards before live adoption |
| R6 | First deployment adapter: GitHub Pages | R4; independent of the full publishing rollout |
| R7 | Automatic release-PR and tag handoff | R3 + R5; verified App/environment protections |
| R8 | Pilot, package distribution, and phased adoption | Relevant R2-R7 capabilities and caller checks |

Each implementation PR must have a bounded scope, tests, documentation, and explicit compatibility impact. R5 and R6 can progress in parallel once the artifact/validation contract is stable. Use reviewed maintainer-created tags during the publisher pilot; automatic tag creation is not a prerequisite for proving publishing.

## R0 — Inventory and protect current behavior

Inspect repositories with Dart content, including mixed-language repositories; do not rely only on the repository's primary-language classification. Separate active package publishers, deployable apps/docs, private tooling, and projects outside the rollout. Identify renamed repositories and workflow references, not just familiar names.

For each in-scope repository record:

- Package/workspace paths, publishability, development SDK, consumer SDK floors, and resolved Melos/toolkit versions.
- Synchronized groups, independently versioned targets, dependency/metadata synchronization, and existing tag/history conventions.
- CI gates, build/generation commands, current publishers, deployment providers, environments, and rollback limits.
- Workflow/action refs, last verified release/deployment evidence, owners, migration blockers, and intended pilot.

The existing review sampled standalone Dart (`standard-schema-dart`, `okf`), standalone Flutter (`nodeflow`), native workspaces (`noir`), and Melos workspaces (`mix`, `remix`, `naked_ui`, `ack`, `superdeck`, `wayfinder`). Revalidate before migration. This is not a complete inventory.

Keep private repository/deployment details in access-appropriate records; do not publish them in this public toolkit repository. The public inventory contains only approved public information and coverage status.

Before merging changes to a shared path used at `@main`, pin and test every live consumer of that path or introduce an opt-in replacement that leaves it unchanged. Mix and Naked UI were identified as floating publisher consumers in the prior review; search for others. Pinning is an early safeguard, not a late migration task.

Repository administrators must verify default-branch and release-tag rules, required reviews/checks, and publishing/deployment environment protections. Record unknown or inaccessible settings as unverified. This plan does not grant permission to weaken existing protections.

**Exit:** every first-wave project has an owner and an evidence-backed baseline; shared-path changes cannot silently alter a live caller. Read-only development need not wait for all administration work.

## R1 — Agree on interfaces; reuse the foundation selectively

Revise PR #9's documents rather than accumulating conflicting architecture comments. Establish the common convention: Pub workspace + resolved Melos, with a reviewed root-package transition path. Workspace structure does not imply synchronized versions or common deployment cadence.

Review PR #10 independently. Retain tested source-drift checks, workflow linting, fixtures, pinned dependencies, and SDK integrity controls where they fit. It is still an opt-in Linux/Flutter foundation, not the final cross-project CI contract. Do not merge it solely because its checks passed previously; recheck the proposed merge and any review feedback.

Define in the core PR:

- Versioned `release.yaml` and JSON plan/result schemas, diagnostics, and CLI exit behavior.
- Package/group/target models, merge/source identity, and compatibility between CLI and workflow versions.
- Exact SDK selection for Dart-only and Flutter projects. Bootstrap precedes the Dart CLI.
- A tested toolchain matrix based on actual consumers; do not force a Melos upgrade that conflicts with existing development dependencies.

Evaluate maintained official setup actions against the required contract before extending custom installers. Document Linux as initial release-runner support; add/test Windows and macOS integrations for real consumers without claiming coverage merely because the CLI is pure Dart.

**Exit:** the core can be implemented without guessing ownership of version files, release decisions, credentials, or deployment artifacts. No live publisher changes.

## R2 — Implement the first Dart package and read-only plan

Suggested PR title: `feat(core): add release configuration and read-only planning`.

Create the private toolkit workspace and one package at `packages/concepta_release`, with a small library API, CLI entrypoint, tests, and private fixture projects. The working package name is not yet reserved or published. Do not split it into multiple public packages or depend on Melos internals.

Implement `doctor` and `plan` first. Parse manifests and explicit release configuration. Model workspace membership, target allowlists, synchronized groups, independent packages, required hosted dependency edges, metadata edits, and deployment-only targets. Produce human-readable output and stable JSON. Keep planning functions separate from Git/process/network effects; remote status inputs are explicit and testable.

The plan records source/base identity, selected targets, current/proposed versions and reasons, tags, synchronization changes, dependency stages, SDK/tool versions, and blocked or pending work. Bind it to the final reviewed merge commit later; avoid a self-referential commit hash stored in its own commit.

**Acceptance tests:**

- One-member Dart workspace, existing root-package transition, Flutter workspace, fixed group, and a mixed group plus independent CLI.
- A change to one synchronized member selects its approved group; unrelated independent targets retain their versions.
- Dependency-floor updates do not silently version the whole workspace. Private apps may deploy but cannot become publish targets.
- Unknown config fields, duplicate/overlapping groups, escaping paths, wrong tag mappings, and unsatisfiable new-version dependency cycles fail clearly.
- No source edits, credentials, tags, GitHub writes, uploads, or deployments occur during planning. Identical inputs produce equivalent plans; no-op work is explicit.

**Exit:** local and CI users can inspect the same safe plan. This is the first new implementation deliverable, not a publishing change.

## R3 — Prepare versions and synchronized metadata

Suggested PR title: `feat(release): prepare reviewed versions with Melos`.

Add `prepare` using an isolated checkout and the repository-resolved Melos executable. Use supported version/changelog operations, with explicit package selection. Prove synchronized subsets and independent packages can coexist without workspace-wide version propagation. Unsupported tool versions stop with an actionable diagnostic.

Add declared synchronization for manifests, required hosted floors, CLI version constants, registries, and generated release metadata. Prefer structured edits and existing reviewed generators, not global string replacement. Preserve previous changelog sections. Show additional affected targets in the proposed plan; never silently release dependents or lower constraints to pass validation.

**Acceptance:** stable/beta/RC proposals, explicit overrides, group boundaries, idempotent preparation, no-op behavior, failure without corrupting the original checkout, unchanged published history, and private-package exclusion. Preparation creates neither tags nor uploads. The returned diff names every changed file and why it changed.

## R4 — Unify checks, builds, and artifact evidence

Suggested PR title: `feat(ci): share validation and build artifact contracts`.

Add shared `check`/`build` behavior and thin CI adapters. Support genuine Dart-only setup and Flutter's bundled Dart SDK. Delegate specialized commands to named repository scripts in unprivileged jobs. Preserve existing Windows, browser, Android, native-library, code-generation, and documentation checks; do not replace them with a generic test command.

Keep workspace candidate tests separate from detached hosted-consumer checks. Detachment must be tested against package layout, overrides, SDK floors, and workspace-dependent fixtures. Known SDK configuration migration must occur before final checks; unexpected source changes fail without silently restoring files.

Build records identify source, builder run, platform, toolkit/SDK versions, artifact reference, digest, and retention. Validate cross-job artifact origin as well as its digest; a matching digest is not authorization to deploy an untrusted PR artifact. Release and deployment jobs receive verified data, not arbitrary executable hooks.

**Acceptance:** consumer-floor tests stay separate from the toolchain floor; exact file drift is diagnosed; tampered or wrong-source artifacts fail; deployment-only builds require no package bump; real fixture jobs match local CLI behavior. Extend OS coverage only when actually tested.

## R5 — Implement resumable OIDC publication

Suggested PR title: `feat(publish): add verified resumable pub.dev releases`.

Keep tag-triggered publication and the official Dart OIDC integration. Use separate unprivileged validation and privileged upload jobs with minimum permissions. Verify caller repository, tag, package version, intended commit, environment requirements, and prior validation before upload. Fixed groups preserve their authorized common tag; independent packages use their own matching tags.

Implement exact-version registry lookup, dependency-stage gates, mandatory dry runs, upload, bounded availability checks, and a result report. Specify/test how a hosted version is matched to intended publishable content before skipping it on retry. Never use existence alone as content proof or network failure as a missing version. Resume the same approved release; do not move tags or cancel an active upload.

Keep pub-dev #9576 cleanup as a focused, evidence-gated change. Test public and dummy-bearer reads, then a real-OIDC tag-context dry run. Confirm upload on an approved real release. Track both the shared workflow and ACK's local workaround. No automatic validation bypass after arbitrary failures.

**Acceptance:** wrong identity/ref/version fails; required unpublished dependencies block consumers; registry 403/5xx/timeouts/invalid bodies stop the decision; partial retry, content mismatch, cache effects, and post-upload verification are covered. First-package publication is reported as a maintainer prerequisite, not retried with OIDC.

## R6 — Implement deployments as a separate path

Suggested PR title: `feat(deploy): deploy verified static artifacts to GitHub Pages`.

Start with the demonstrated static-site need, including Remix's mixed Flutter/Node output. Use official Pages upload/deploy actions. The deploy job consumes a verified artifact, enforces its environment and trusted ref, deploys, verifies a target-specific route/health check, and records the resulting URL and status. Planning/building must not acquire deployment credentials.

Document explicit preview/production policy. Default PR runs validate/build only; they do not deploy to production. A deployment may run without publication; dependencies on hosted releases are explicit, not universal.

Test redeployment or rollback of a retained previous artifact where supported. State retention and provider limits, including the different failure recovery rules for immutable pub.dev versions. Do not implement a fictional common rollback API.

**Exit:** one approved Pages pilot covers build -> deploy -> verify and a recovery exercise. Other providers get separate adapters only after R0 establishes concrete requirements, credentials, signing, platforms, and owners.

## R7 — Automate release PRs and verified tag handoff

Suggested PR title: `feat(release): automate release PR and tag handoff`.

Wrap R3 in a shared preparation workflow. A separate narrowly scoped GitHub App job opens/updates the release PR; it does not run caller generators with the App key. After merge and the required checks on that exact commit, a dedicated job validates the plan and creates only approved tags. Keep the App token out of validation, publishing, and deployment jobs.

For independent packages, prefer caller-owned dependency stages in the first implementation. Do not make an organization-wide scheduler a prerequisite. Coordinate only the tags/dependencies declared in the approved plan, and verify tag-push workflows actually start. Preserve a reviewed manual-tag recovery path.

**Acceptance:** repeated events are idempotent, stale plans/wrong commits fail, existing tags are never moved, Remix's two tags agree when required, and automation does not bypass reviews/environments. Verify a real App-created tag handoff separately from dry-run tests. Final reports distinguish completed, partial, blocked, failed, and unverified work.

## R8 — Distribute the toolkit and adopt in controlled waves

Check package naming/ownership and package dependency compatibility before publishing the toolkit. Initially consume a reviewed Git SHA plus package path as a dev dependency; after an approved first manual publication, configure OIDC for the toolkit itself. Record a tested CLI/workflow compatibility policy and automate reviewed pin/lockfile updates. Do not globally install an unpinned latest release.

Use read-only pilots early; enable writes only after the relevant gates pass:

1. A small standalone Dart package and a standalone Flutter package prove the one-member/root transition and absence of unnecessary SDK dependencies.
2. Remix proves mixed release metadata, independent CLI/icons, its current tag exception, hosted consumer checks, and Pages deployment.
3. Mix and Naked UI migrate through separate caller PRs, preserving generation and platform release gates. Tooling/layout changes are reviewed separately from publisher changes.
4. ACK proves coordinated versioning and staged, resumable publishing before its local generic implementation is removed.
5. Remaining inventory projects follow their documented capabilities. Native binaries, Homebrew, mobile stores, and other deployment providers retain existing paths until their own adapters pass.

A caller is migrated only when its actual validation, approved release or deployment, and recovery checks pass. Package names, published history, consumer SDK floors, and existing protections must not change incidentally. Root layout changes are local migrations, not an organization-wide repository merge.

## Decisions deliberately deferred

- Repository rename or a new home: keep the current Actions path until a separate consumer migration is proven.
- One global version/Melos upgrade: choose a compatible development-tooling baseline; preserve each product's release policy and consumer support.
- General plugin system, cross-repository scheduler, all-cloud deployment library: not required for the first usable toolkit.
- Live publisher replacement, credential provisioning, and production settings: require their explicit implementation and administration gates.

## Tracking and completion

GitHub documents, PRs, and checks are the source of truth. Keep the existing Todoist item as one owner-level tracker linking to PR #9 and PR #10, with the next action and current phase only. Do not duplicate this checklist into Todoist or describe it as automatic synchronization.

The plan is complete when the toolkit has a documented local/CI interface, mixed-version policy tests, verified publication/deployment adapters for the inventoried needs, and caller migration evidence. Completing this design PR or the foundation PR alone does not complete the rollout.

This revision changes documentation only. It creates no implementation PR, package publication, tag, repository rename, deployment, or protection setting.
