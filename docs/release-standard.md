# Concepta Release: proposed architecture

Status: implementation proposal, revised September 14, 2026. This document describes the target, not deployed functionality. It incorporates the direction agreed in PR #9 and replaces the earlier YAML-first design. See [the implementation plan](release-rollout.md) for dependencies, acceptance tests, and first actions.

## Goal and scope

Build one versioned release and deployment toolkit for Concepta's Dart and Flutter projects. Use the same release logic locally and in GitHub Actions. Keep caller workflows small, with shared behavior tested in one place.

Use **Concepta Release** as the working product name and `concepta_release` as the proposed Dart package name. Package availability and ownership must be checked before first publication. Keep the repository at `conceptadev/dart-actions` during implementation. Renaming is not a prerequisite; GitHub does not redirect calls to actions after a repository rename. [7]

The scope includes package CI, builds, version preparation, pub.dev publishing, and application/documentation deployment. It includes Dart projects inside mixed-language repositories. It does not mean moving the whole organization into one repository or deploying every discovered project automatically.

## Repository convention

The target organization convention is a Pub workspace plus repository-resolved Melos for each project. New projects use a private workspace root, `packages/` for libraries and CLIs, and `apps/` for applications where useful. One-member workspaces are valid. Existing root packages may retain their layout through Melos's documented `useRootAsPackage` support during reviewed migration. Do not set `publish_to: none` on an existing public root package merely to copy a workspace template. [1, 2]

Adoption does not require renaming packages, moving existing source immediately, or synchronizing all package versions. Record legacy exceptions until their migrations pass. Pub workspace membership and tooling compatibility must be checked before a layout change; workspace resolution combines development dependencies too. Preserve consumer SDK support with separate consumer tests rather than raising package minimums to match newer release tooling. [1]

Use an exact, reviewed build SDK. Dart projects must not install Flutter just to run this toolkit. Flutter projects use their chosen Flutter SDK and its bundled Dart SDK. CI and local development use the same version source. No SDK download is the responsibility of a Dart CLI that cannot run until the SDK exists.

## One codebase, thin integrations

Start with **one pure-Dart library/CLI package**, not several small public packages:

```text
conceptadev/dart-actions/
  pubspec.yaml                   # Private toolkit workspace
  packages/concepta_release/
    bin/concepta_release.dart    # Command-line interface
    lib/concepta_release.dart    # Small supported library API
    lib/src/                    # Config, planning, sync, and tool adapters
    test/
  actions/                      # SDK/bootstrap and small Actions integrations
  .github/workflows/            # CI, publish, release handoff, deployment jobs
  fixtures/                     # Private test projects, never auto-published
  docs/
```

This is a proposed layout. Existing workflows remain available until their consumers migrate.

| Component | Responsibility |
| --- | --- |
| Dart library/CLI | Validate configuration; read manifests; compute release plans; enforce version groups; synchronize declared metadata; coordinate checks/builds through maintained tools; verify release results. |
| GitHub workflows/actions | Bootstrap SDKs, choose runners, validate event/ref identity, transfer artifacts, enforce job permissions/environments, and acquire credentials. |
| Caller repository | Declare release/deployment targets, SDK source, specialized checks, version policies, and environment configuration. |

Keep policy and planning functions separate from filesystem, Git, process, and network operations inside the package. Inject those operations in tests. Do not build a general plugin framework or a second workflow scheduler.

The CLI delegates version/changelog operations to the caller's resolved Melos through `dart run melos`. It must not import a competing Melos runtime or overwrite the same files through a second version manager. Prefer official SDK and deployment integrations where their tested contracts fit. Reuse the useful components of PR #10; its Flutter-only CI interface is not the final organization contract.

## Installation and configuration

Consumers add the toolkit as a **workspace-root dev dependency**, not as a runtime dependency of every library. CI resolves the reviewed lockfile and records the actual toolkit version. Until a first hosted release exists, pilot repositories may use an explicitly pinned Git commit and package path. The toolkit tests its own source; it must not need to download an unpublished copy of itself to bootstrap. [8]

Use one root `release.yaml` for policy that Pub and Melos do not already own. The first core PR defines schema version 1, parser validation, and example fixtures. The proposed sections are:

| Section | Contents |
| --- | --- |
| `schema` | Configuration schema version. |
| `toolchain` | Reference to the existing exact SDK source; no credentials. |
| `release_groups` | Explicit member package names, independent or synchronized policy, and tag conventions/exceptions. |
| `synchronizations` | Declared source-of-truth fields and derived metadata or dependency-floor rules. |
| `builds` | Named, reviewed commands or Melos scripts, input paths, output artifact, and required platform. |
| `deployments` | Provider, build artifact, environment, trigger policy, required published dependencies, and verification check. |

Read package names, current versions, dependencies, workspace members, and publishability from manifests. Read Melos scripts from Melos configuration. Do not duplicate current package versions in `release.yaml`. A generated plan may record proposed versions as a review artifact; it is not a second maintained version database.

Reject unsupported schema versions, unknown fields, overlapping groups, duplicate names/tags, paths escaping the checkout, and publish targets marked private. Discovery assists configuration but never authorizes publication. Deployment-only private apps may be explicitly selected without becoming package publish targets.

## Version policy and synchronization

Treat these concerns separately:

| Concern | Required behavior |
| --- | --- |
| Synchronized versions | All selected publishable members of a declared group advance to the same approved version. Unrelated groups do not move. |
| Independent versions | Each package retains its own version and release cadence. |
| Dependency/metadata synchronization | Update a required dependency floor or derived version field without forcing the whole repository into one shared version. |
| Publication order | Wait for required hosted dependency versions, even when upstream and downstream use different versions. |

Melos documents independent and whole-workspace fixed versioning. A mixed workspace containing a synchronized subset and independent packages needs a tested policy adapter; do not assume an existing named-group API or turn on workspace-wide fixed mode for that case. [3]

The adapter computes explicit target versions, invokes supported Melos operations in an isolated preparation checkout, and validates the resulting diff against the plan. Version proposals, prerelease promotion, and breaking-change decisions remain visible to reviewers. Use Conventional Commit titles and a consistent merge convention; API checks supplement them rather than treating titles as proof of compatibility. [9]

Preserve published changelog sections and required dependency minimums. SemVer range compatibility alone does not establish that an older dependency contains a newly used API. Synchronization rules must account for actual required floors. If changing bundled metadata alters an independently published CLI's shipped content, the plan must either include that CLI's own release or explicitly leave its change pending; it must not claim that the old CLI version contains new data.

Preparation never tags or publishes. Repeating preparation against the same source and inputs must produce the same diff, not duplicate changelog entries or keep incrementing versions.

## CLI contract

These are target commands, not commands available today:

| Command | Contract |
| --- | --- |
| `doctor` | Report workspace, configuration, SDK/tooling, and migration problems without editing source. Remote checks are explicit and never change settings. |
| `plan` | Compute target versions, reasons, synchronization edits, tags, dependencies, and blocked work. No source edits, tags, uploads, or deployments. Support human output and versioned JSON. |
| `prepare` | Apply an approved plan to an isolated working copy; run Melos and declared metadata updates; return a reviewable diff. No remote writes. |
| `check` | Run the declared validation suite and report results bound to source/tool versions. |
| `build` | Run a named build and write an artifact record; never deploy implicitly. |
| `verify` | Check publication/deployment results, distinguishing success, failure, and unverified state. |

Example future invocation: `dart run concepta_release:concepta_release plan`.

Publishing and deploying remain explicit privileged workflow operations, not default side effects of these commands. The same library can validate their inputs without executing caller-provided generators or scripts under publishing credentials.

## Release and deployment lifecycles

**Package release:** plan -> prepare -> review release PR -> merge -> verify exact release commit/checks -> create approved tags -> publish through OIDC -> verify exact registry versions -> finalize release report.

Use `v<version>` for an existing root package or authorized fixed workspace, and `<package>-v<version>` for independent packages. Preserve existing tag authorization during migration, including Remix's two-tag exception and ACK's coordinated release. A new group tag convention requires explicit publisher configuration and history tests, not just a new trigger string.

Pub.dev's GitHub integration requires a tag-push run with matching package/repository authorization. Independent targets must run under their own authorized tags; a shared matrix under another package's tag is not enough. New packages need one-time initial publication before automated publishing. [4]

A synchronized release is not an atomic registry transaction. Report partial completion honestly and resume against the same tags and intended content. Network errors, authentication errors, invalid responses, and server errors are not evidence that a version is missing. An existing version needs release-consistency verification, not just an HTTP 200. Define and test that comparison before enabling automated skip-on-retry behavior.

Keep mandatory publish validation. Test workspace candidates and detached hosted consumers separately. Bind validation to the actual publishable content; define the SDK's file selection and any supported transformation explicitly. Do not assume separately produced compressed archives have identical hashes. If content consistency cannot be established, stop for review rather than republish or silently mark complete.

**Deployment:** approved source -> validate/build -> identify artifact -> approve target environment -> deploy existing artifact -> verify -> record result. A deployment can happen without a library version bump. It waits on package publication only when its declared requirements need those hosted versions.

Start with static-site deployment to GitHub Pages, using the official Pages artifact/deploy actions. Builds may combine Flutter, Node, documentation generation, or other existing tools. The deployment consumes an artifact, not an assumed `flutter build web` directory. [6]

Artifact records identify the source commit, builder run, tool versions, target/platform, immutable artifact reference, and digest. Keep artifacts for an explicit retention period. Redeploy a previous verified artifact where the provider permits it; unavailable artifacts and provider-specific rollback limits must be explicit. Do not promise generic rollback or rebuild old source and call it the identical artifact. Package publication has no equivalent rollback: published versions and release tags stay immutable.

Other providers, native binaries, mobile signing/stores, and Homebrew integrations follow the inventory. Keep their existing release paths until individually implemented and tested.

## Security and maintenance boundaries

Separate read-only planning/tests/builds, GitHub PR/tag writes, pub.dev uploads, and deployments into distinct permission scopes. Late token acquisition is not a step-level security boundary: every step in an OIDC-enabled job is privileged. No caller-defined test/generation commands in that job. No private keys in configuration, build artifacts, caches, or logs.

Use the official Dart OIDC integration, with environment restrictions verified in GitHub and pub.dev. Keep caller repository identity; the shared workflow repository is not a replacement publisher identity. A dedicated, narrowly scoped GitHub App token handles automatic PR/tag writes. Ordinary `GITHUB_TOKEN` tag pushes do not trigger a new push workflow. Keep a maintainer-driven tag path until the automatic handoff is proven. [4, 5]

Load shared helpers and the privileged CLI from reviewed provider revisions, not from arbitrary caller source or an untrusted build artifact. Test compatibility between toolkit package, configuration schema, and workflow revision; record all three in results. Read-only local planning uses the root dev dependency, while privileged operations enforce an approved compatible toolkit version independently.

Pin workflows/actions, require review and validation checks, and isolate caches and cross-job artifacts by trust level. Verify protections rather than treating YAML as evidence that they exist. Update pinned dependencies through reviewed PRs. Never auto-cancel an active publish; serialize conflicting releases without relying on concurrency controls as an unlimited durable queue. [10]

Retire the `pub-dev#9576` workaround only after runner regression tests. Dummy-bearer reads, real-OIDC dry runs, and successful authorized uploads prove different things. Track both the shared publisher and ACK's local copy. No automatic `--skip-validation` fallback on arbitrary errors; keep any temporary exception explicit and gated by prior validation of unchanged content.

## Evidence and references

PR #9 is the design; PR #10 is the existing opt-in foundation implementation. Both were open and unmerged when rechecked on September 14, 2026. The broader repository review is a sample, not a complete organization inventory. Administration, provider coverage, and package-name ownership are still rollout gates.

- [1: Pub workspaces](https://dart.dev/tools/pub/workspaces)
- [2: Melos configuration and root-package support](https://melos.invertase.dev/configuration/overview)
- [3: Melos versioning](https://melos.invertase.dev/commands/version)
- [4: Dart automated publishing](https://dart.dev/tools/pub/automated-publishing)
- [5: GitHub token event behavior](https://docs.github.com/en/actions/concepts/security/github_token)
- [6: GitHub Pages custom workflows](https://docs.github.com/en/pages/getting-started-with-github-pages/using-custom-workflows-with-github-pages)
- [7: Repository rename limitations](https://docs.github.com/en/repositories/creating-and-managing-repositories/renaming-a-repository)
- [8: Package and development dependencies](https://dart.dev/tools/pub/dependencies)
- [9: Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/)
- [10: Secure use of GitHub Actions](https://docs.github.com/en/actions/reference/security/secure-use)
- [Design PR #9](https://github.com/conceptadev/dart-actions/pull/9)
- [Foundation PR #10](https://github.com/conceptadev/dart-actions/pull/10)
- [pub.dev incident #9576](https://github.com/dart-lang/pub-dev/issues/9576)
