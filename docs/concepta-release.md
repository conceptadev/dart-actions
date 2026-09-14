# Concepta Release core

`packages/concepta_release` is the Dart library and CLI that holds the
deterministic part of Concepta's release process. The same code runs on a
maintainer's machine and inside GitHub Actions.

This document covers what exists today: configuration, workspace loading, and
the read-only `doctor` and `plan` commands. Preparation, publishing, and
deployment are later stages tracked in the rollout plan (PR #9).

## What the core owns, and what it does not

The library owns decisions that must be identical everywhere:

- reading pub workspace membership and package manifests
- validating `release.yaml` against the real workspace
- selecting release targets, expanding synchronized groups, and isolating
  independently versioned packages
- proposing versions for the stable, beta, and rc channels
- raising declared dependency version floors
- ordering publication into dependency stages
- rendering release tags
- producing a stable, serializable release plan

GitHub Actions owns everything environmental: runners, SDK bootstrap,
credentials, protected environments, event and ref authorization, artifact
transport, OIDC, GitHub App operations, and provider deployment steps.

`release.yaml` never contains a credential.

### Planning is read-only

`planRelease` is a pure function. It does not read Git, contact a registry,
mutate a file, or acquire a credential. Facts about the outside world arrive as
explicit inputs:

| Input | Carries |
| --- | --- |
| `Workspace` | package manifests as loaded from disk |
| `ReleaseConfig` | parsed `release.yaml` |
| `ReleaseRequest` | requested bumps, explicit versions, channel, source identity |
| `RemoteState` | tags that already exist, versions already on the registry |

A test asserts that planning the `mixed_workspace` fixture leaves every file on
disk byte-identical, and that identical inputs produce identical JSON.

## `release.yaml`

Releases are opt-in. A workspace member that is not declared here can never be
released, and `publish` defaults to `false`, so discovery alone never authorizes
an upload.

```yaml
version: 1

defaults:
  # Tag template for independently versioned packages.
  tag: "{package}-v{version}"
  # Tag template for a synchronized group. One tag covers every member.
  group_tag: "v{version}"
  # Bump applied to a publishable package when a dependency floor it declares
  # has to be raised. Use `none` to record the edit without releasing it.
  bump_dependents: patch

groups:
  - name: core
    # Optional per-group override of defaults.group_tag.
    tag: "v{version}"
    packages:
      - sample_core
      - sample_annotations

packages:
  - name: sample_core
    publish: true
  - name: sample_cli_tool
    publish: true
    # Optional per-package override of defaults.tag.
    tag: "cli-v{version}"
  - name: sample_playground
    publish: false

deployments:
  - name: playground
    provider: github-pages
    source: apps/playground
    environment: github-pages
    package: sample_playground
```

Unknown fields are errors, not warnings, at every level. A typo must not
silently disable a release rule.

### Rules that are enforced

| Code | Meaning |
| --- | --- |
| `config-unknown-field` | A field not in the schema |
| `config-version-unsupported` | `version:` is not 1 |
| `unknown-package` | A declared package is not a workspace member |
| `private-package-publish` | `publish: true` on a `publish_to: none` package |
| `package-missing-version` | A declared package has no pubspec version |
| `overlapping-groups` | A package appears in two groups |
| `group-member-not-declared` | A group lists a package with no `packages:` entry |
| `tag-template-missing-version` | A template with no `{version}` |
| `group-tag-template-package` | A group template using `{package}` |
| `tag-template-collision` | Two independent packages resolve to one tag shape |
| `deployment-source-escapes` | A deployment source outside the workspace |
| `package-undeclared` | A workspace member that cannot be released (note) |

## Commands

```
concepta_release doctor [--directory .] [--config <path>] [--json]
concepta_release plan   [--directory .] [--config <path>] [--json]
                        [--channel stable|beta|rc]
                        [--bump <package>:<none|patch|minor|major>]...
                        [--set-version <package>:<version>]...
                        [--existing-tag <tag>]...
                        [--published <package>:<version>]...
                        [--source-repository <slug>]
                        [--source-ref <ref>]
                        [--source-revision <sha>]
```

Exit codes: `0` success, `2` the command could not be understood, `3` the
command ran and reported at least one error diagnostic. Neither command writes
anything; redirect stdout to capture a plan.

`--bump` is the caller's decision, not a guess. Nothing in the core parses
commit messages; an adapter that derives bumps from history can be added later
without changing the planner.

`--existing-tag` and `--published` are how a workflow tells the planner about
the outside world. Both are checked before a plan is accepted.

## How versions are proposed

Arithmetic is plain semver. `major` always moves to `X+1.0.0`, including for
`0.x` packages, so `0.5.1 -> major` is `1.0.0`, not `0.6.0`.

| Current | Bump | Channel | Proposed |
| --- | --- | --- | --- |
| `1.2.3` | patch | stable | `1.2.4` |
| `1.2.3` | minor | beta | `1.3.0-beta.0` |
| `1.3.0-beta.0` | none | beta | `1.3.0-beta.1` |
| `1.3.0-beta.2` | none | rc | `1.3.0-rc.0` |
| `1.3.0-rc.1` | none | stable | `1.3.0` (graduation) |
| `1.2.3` | none | stable | no-op, reported as `no-version-change` |
| `1.2.3` | none | beta | `prerelease-requires-bump` error |

A synchronized group advances from the highest current version among its
members. Members at different versions are reported as `group-version-drift`
before they are aligned.

## How dependency floors move

When a package releases, every declared floor on it is examined. The written
style is preserved:

| Declared | Released | Result |
| --- | --- | --- |
| `^1.2.0` | `1.3.0` | `^1.3.0` |
| `>=1.2.0 <2.0.0` | `1.3.0` | `>=1.3.0 <2.0.0` |
| `1.2.0` (exact pin) | `1.3.0` | `1.3.0` |
| `^1.3.0` | `1.3.0` | unchanged |
| `>=1.2.0 <2.0.0` | `2.0.0` | `dependency-floor-conflict` error |
| `any` | `1.3.0` | `dependency-floor-unbounded` warning |
| `^1.2.0` | `1.3.0-beta.0` | unchanged; a pre-release never moves a floor |

A constraint is never widened to make a release fit. Crossing an upper bound is
a deliberate decision that has to be made in the pubspec.

A floor change on a publishable package selects it for release at
`defaults.bump_dependents`. A floor change on a package that is not being
released is recorded under `metadataUpdates` instead, so preparation can still
apply the edit without the plan claiming to authorize a release.

Only runtime `dependencies` pull a package into a release, and only runtime
dependencies determine publication order. Dev-dependency floors are still
updated; when one points at a package that publishes in a later stage, the plan
reports `dev-dependency-published-later` rather than silently producing a
release that cannot resolve.

## The plan document

`--json` writes a stable document with a fixed key order, sorted lists, no
timestamp, and no absolute paths.

```json
{
  "schemaVersion": 1,
  "toolkitVersion": "0.1.0",
  "channel": "stable",
  "source": { "repository": "...", "ref": "...", "revision": "..." },
  "noop": false,
  "releases": [
    {
      "package": "sample_core",
      "path": "packages/core",
      "action": "publish",
      "group": "core",
      "currentVersion": "1.4.0",
      "proposedVersion": "1.5.0",
      "bump": "minor",
      "tag": "v1.5.0",
      "stage": 1,
      "reasons": ["requested minor"],
      "dependencyUpdates": [
        {
          "dependency": "sample_annotations",
          "section": "dependencies",
          "from": "^1.4.0",
          "to": "^1.5.0"
        }
      ]
    }
  ],
  "tags": [{ "tag": "v1.5.0", "packages": ["sample_annotations", "sample_core"] }],
  "stages": [["sample_annotations"], ["sample_core"]],
  "metadataUpdates": [],
  "deployments": [],
  "diagnostics": []
}
```

`source` is recorded from caller-supplied flags. The planner never looks a
commit up, which keeps a plan reboundable to the final reviewed merge commit
instead of embedding a hash inside its own commit.

`action` is `publish` or `version-only`. A private package can be
version-synchronized with a group and can be deployed, but never becomes a
publish target.

## Fixtures

`packages/concepta_release/test/fixtures` holds the layouts the toolkit has to
support:

| Fixture | Proves |
| --- | --- |
| `dart_single` | Dart-only root package, no workspace declaration |
| `flutter_single` | standalone Flutter package, SDK dependency handling |
| `one_member_workspace` | workspace with exactly one member |
| `root_package_workspace` | published root package plus a member |
| `mixed_workspace` | synchronized group, independent packages, private app, deployment |
| `glob_workspace` | `workspace:` glob expansion |
| `cyclic_workspace` | an unsatisfiable publication order |

### Verified pub behaviour

`workspace:` globs such as `packages/*` require language version 3.11 or later.
Below that, pub fails resolution with `No workspace packages matching`. The
loader reports `workspace-glob-language-version` instead of silently finding no
members. The Dart analyzer's pubspec validator still flags glob entries even
when pub resolves them, which is why the fixture directory is excluded from
analysis.

## Relationship to the rest of the rollout

- PR #9 holds the architecture and rollout documents. This is the R2
  deliverable from that plan.
- PR #10 holds the workflow-hardening foundation: the source-drift action,
  actionlint, immutable action pins, and the checksum-verified Flutter setup.
  Those remain useful and are not duplicated here.
- `concepta_release` sets `publish_to: none`. The package name is proposed, not
  reserved. Distribution is R8 and needs its own review.
- The existing `ci.yml` and `publish.yml` reusable workflows are untouched.
  Live callers keep their current behaviour.
