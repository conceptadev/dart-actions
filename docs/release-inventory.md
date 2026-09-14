# Concepta release inventory

Public-information baseline for the release/deployment rollout, recorded
2026-09-14. Every row below comes from a public manifest or workflow file in
the `conceptadev` organization. No private repository, credential, environment,
or deployment detail is recorded here.

These are manifest observations. They are not proof of installed tool versions,
of a successful release, or of protection settings, and this is not a complete
inventory of the organization.

## Repository layouts

| Repository | Root package | Layout | Melos | Notes |
| --- | --- | --- | --- | --- |
| `mix` | `mix` | root package, `melos.yaml` | `6.3.3` | only sampled repository still using a separate `melos.yaml` |
| `remix` | `remix_workspace` (private) | pub workspace, 11 members | `^8.5.0` | apps and packages in one workspace |
| `naked_ui` | `naked_ui_workspace` | pub workspace, 2 members | `^7.3.0` | package plus example |
| `ack` | `ack_workspace` (private) | pub workspace, 7 members | `^8.7.0` | keeps its own resumable publisher |
| `standard-schema-dart` | `standard_schema` | single Dart package | none | no workspace declaration |
| `okf` | `okf` | single Dart package with an executable | none | no workspace declaration |
| `nodeflow` | `node_flow` | single Flutter package | none | no workspace declaration |
| `noir` | `noir_workspace` (private) | pub workspace, 2 members | none | workspace without Melos |
| `wayfinder` | `wayfinder_workspace` (private) | pub workspace, 3 members | `^7.1.1` | native/model build steps |
| `superdeck` | `superdeck_workspace` (private) | pub workspace, `packages/*` globs | `7.8.1` | pins Melos for a `cli_util` conflict with `custom_lint` |

Declared SDK floors across the sample span `>=3.8.0` to `>=3.12.0`, and Flutter
floors span `>=3.35.0` to `>=3.44.6`. The toolkit must not raise any of them.

Consequences the core already accounts for:

- Single packages, one-member workspaces, and multi-member workspaces are all
  first-class. None of them may be required to restructure.
- Melos version spread is `6.3.3` through `8.7.0`. The core delegates to the
  repository-resolved executable rather than pinning one version.
- `superdeck` pins Melos `7.8.1` because `7.8.2+` needs `cli_util` 0.5.x while
  `custom_lint` 0.8.1 needs 0.4.x. A forced organization-wide Melos upgrade
  would break that workspace.
- `superdeck` uses `workspace:` globs, which pub only supports from language
  version 3.11. The loader checks this explicitly.

## Shared workflow consumers

Callers of `conceptadev/dart-actions`, from public workflow files:

| Repository | Workflow | Reference | Status |
| --- | --- | --- | --- |
| `mix` | `.github/workflows/publish.yml` | `publish.yml@main` (6 jobs) | **floating** |
| `naked_ui` | `.github/workflows/release.yml` | `publish.yml@main` | **floating** |
| `remix` | `.github/workflows/publish.yml` | `publish.yml@9bb0b12` | pinned |
| `remix` | `.github/workflows/ci.yaml` | `ci.yml@9075ce1` | pinned |
| `ack` | `.github/workflows/ci.yml` | none; comment records a former `ci.yml@main` call | migrated away |

**Open safeguard.** `mix` and `naked_ui` still resolve `publish.yml@main` at run
time. Any change to that file reaches their next release without review. Those
two callers should be pinned to reviewed SHAs, in their own repositories, before
`publish.yml` on `main` changes. Nothing in this repository can pin them.

Neither this inventory nor the core changes `ci.yml` or `publish.yml`. The new
Dart package is additive.

## Not recorded here

- Private repositories, private deployment targets, and internal tooling.
- Environment names, protection rules, required reviewers, and secrets.
- Release history and publishing evidence per package.

Those belong in access-appropriate records. This file tracks only what is
already public and what the shared toolkit must therefore support.
