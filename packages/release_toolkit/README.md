# release_toolkit

Deterministic release planning for Dart and Flutter workspaces.

The same library and CLI run on a maintainer's machine and inside GitHub
Actions, so a release decision does not depend on where it was made.

```bash
dart run release_toolkit doctor
dart run release_toolkit plan --bump my_package:minor --json
dart run release_toolkit prepare --plan release-plan.json \
  --directory /path/to/repository --output /path/to/prepared --json
```

## Status

`doctor` validates a workspace against its `release.yaml`; `plan` produces a
read-only release plan. `prepare` verifies an approved plan and uses the
repository-resolved Melos 7.8.1 to produce a reviewable diff in a new isolated
checkout. It never changes the source checkout, publishes, pushes, or creates a
tag.

Publishing, deployment execution, and recovery are later stages. This package
sets `publish_to: none`: the name is proposed, not reserved.

## Layout

| Path | Holds |
| --- | --- |
| `lib/src/config.dart` | `release.yaml` schema and strict parsing |
| `lib/src/workspace.dart` | package and dependency models |
| `lib/src/loader.dart` | the only file system access |
| `lib/src/versioning.dart` | version proposals, dependency floors, tags |
| `lib/src/planner.dart` | the pure planner and configuration validation |
| `lib/src/plan.dart` | the serializable plan document |
| `lib/src/preparation.dart` | isolated, validated Melos release preparation |
| `lib/src/cli.dart` | argument parsing and output |

`planRelease` takes a `Workspace`, a `ReleaseConfig`, a `ReleaseRequest`, and a
`RemoteState`, and returns a `ReleasePlan`. Everything it needs to know about
Git, pub.dev, and the calling workflow arrives through those inputs.

Full reference: [`docs/release-toolkit.md`](../../docs/release-toolkit.md).
