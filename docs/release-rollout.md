# Release automation rollout

This document turns the [proposed release standard](release-standard.md) into reviewable implementation pull requests. Each pull request should be independently testable and should avoid changing live package behavior until its acceptance criteria pass.

## PR 1 — Document the release contract

**Goal:** Agree on the shared/repository boundary before changing live publishing.

Changes:

- Add `docs/release-standard.md`.
- Add this rollout plan.
- Record the current incident workaround and the repositories that still carry it.
- Define the target maintainer flow, permission boundaries, tag conventions, and migration gates.

No publishing behavior changes in this PR.

Acceptance:

- The proposed interfaces are understood as design, not deployed APIs.
- Remix, Mix, Naked UI, and ACK retain their current release behavior.

## PR 2 — Harden the Dart Actions foundation

**Goal:** Make Dart Actions safe enough to become a wider release dependency.

Changes:

- Add workflow linting and fixture validation to Dart Actions CI.
- Pin third-party actions to reviewed full commit SHAs.
- Replace the CI workflow's unverified FVM installer pipe with one reviewed SDK setup path.
- Support one exact SDK source that CI and publishing can share.
- Fix the reusable PR-title workflow so runtime step output is not referenced from an input default.
- Add explicit timeouts and minimum job permissions.
- Document the supported Melos/toolchain compatibility matrix.

Keep this PR independent from package publishing semantics.

Acceptance:

- A standalone Dart fixture and Flutter fixture run through the common setup.
- CI never downloads and executes an unverified installer script.
- All underlying action revisions are immutable.
- Ordinary validation jobs cannot request pub.dev OIDC credentials.

## PR 3 — Build the resumable publisher

**Goal:** Replace repository-specific generic publish logic with one tested shared implementation.

Changes:

- Add exact-version publication status handling that distinguishes 404 from network, auth, and server failures.
- Add detached hosted-dependency resolution and analysis for workspace packages.
- Preserve package-local tests as caller/repository checks rather than assuming hosted staging can run every fixture.
- Fail on unexpected tracked-file drift instead of restoring arbitrary changes after tests.
- Keep the mandatory `dart pub publish --dry-run`.
- Add post-upload exact-version verification with bounded retries.
- Add dependency-stage support so consumers wait for required hosted versions.
- Make reruns resumable against the same approved release without blindly re-uploading existing versions.
- Ensure publish concurrency never cancels an active upload.

### pub-dev #9576 transition

Keep `--skip-validation` behind an explicit temporary compatibility path while regression tests are added. Verify metadata/advisory reads with public access and a harmless bearer header, then exercise a tag-context dry run with real OIDC setup. Remove the bypass only when the current client path is proven healthy on the runner used for releases.

Acceptance:

- Wrong tag/package/version combinations fail before OIDC provisioning.
- Missing hosted dependencies block downstream packages.
- 403, timeout, invalid response, and 5xx never mean "not published".
- Partial-release reruns resume safely.
- The published source matches the content that passed release validation.

## PR 4 — Add release preparation and tag handoff

**Goal:** Reduce the normal maintainer action to reviewing a generated release PR.

Proposed reusable entrypoints:

- `prepare-release.yml`
- `tag-release.yml`

Changes:

- Use repository-resolved Melos for version/changelog preparation.
- Produce a validated release plan containing targets, versions, tags, dependency order, source identity, SDK, and Dart Actions revision.
- Open or update a release PR through a narrowly scoped GitHub App installation token.
- After merge and required checks, verify the exact release commit and create only the approved tags.
- Use the App token for the tag push so the caller's tag-triggered publish workflow starts normally.
- Keep the App credential out of validation and upload jobs.

Acceptance:

- Preparation cannot publish.
- A stale plan or wrong merge commit cannot create a release tag.
- Existing tags are never moved.
- Automatically created tags trigger the caller's publishing workflow.
- Stable, beta, and release-candidate plans are reviewer-visible.

## PR 5 — Pilot Remix on the standard

**Goal:** Prove the contract on an existing repository without removing Remix-specific checks.

Dart Actions changes only if the pilot exposes a generic missing capability. The caller PR lives in `conceptadev/remix`.

Preserve:

- Registry synchronization.
- Fortal preset generation/parity checks.
- Windows CLI tests and icon checks.
- Hosted Remix consumer verification before CLI publication.
- Independent `remix_cli` and `remix_ui_icons` releases.
- The current two-tag Remix exception during the first migration.

Acceptance:

- Release PR preparation replaces the manual version-branch handoff.
- Both Remix tags are created at the same reviewed commit when required.
- Publishing remains tag-triggered and OIDC-based.
- No internal package becomes publishable by accident.

## Consumer migrations after the pilot

These should be separate caller-repository PRs, not bundled into a Dart Actions implementation PR.

### Mix

- First pin the shared workflow revision instead of following `@main`.
- Validate the repository's current Melos version or upgrade it in a separate tooling PR.
- Preserve generation and package-specific release hooks.
- Keep independent package tag/version behavior.

### Naked UI

- First pin the shared workflow revision instead of following `@main`.
- Preserve Android and web release gates.
- Migrate publishing after the shared publisher proves parity.

### ACK

- Migrate last because it currently has the strongest resumable and hosted-dependency checks.
- Preserve fixed workspace versioning and dependency-stage order.
- Remove local generic publishing code only after the shared implementation matches or exceeds it.
- Remove the local #9576 workaround at the same time the shared path is proven healthy.

## Repository administration follow-up

Before treating Dart Actions as production release infrastructure, configure and verify repository protection for its default branch through GitHub rulesets or branch protection. Require review and the new validation checks for changes to shared workflows. Also verify the `Production` environments and pub.dev automated-publishing configuration in every caller repository.

These settings are administration work, not content that should be encoded as assumed facts in reusable workflow YAML.

## Tracking

Keep technical decisions, acceptance criteria, and implementation history in GitHub. Use a task manager only for a small number of owner/action reminders, for example:

- Review and merge the Dart Actions release-standard PR.
- Implement PR 2 (foundation hardening).
- Pilot the standard on Remix after PRs 2–4 pass.

Do not duplicate the full design or detailed checklist in Todoist; the GitHub PRs and docs are the source of truth.
