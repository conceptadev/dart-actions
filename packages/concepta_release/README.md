# concepta_release

Deterministic release planning for Concepta Dart and Flutter workspaces.

The same library and CLI run on a maintainer's machine and inside GitHub
Actions, so a release decision does not depend on where it was made.

```bash
dart run concepta_release doctor
dart run concepta_release plan --bump my_package:minor --json
```

## Status

Read-only. `doctor` validates a workspace against its `release.yaml`; `plan`
produces a release plan. Neither writes a file, creates a tag, contacts a
registry, or reads a credential.

Preparation, publishing, and deployment are later stages. This package sets
`publish_to: none`: the name is proposed, not reserved.

## Layout

| Path | Holds |
| --- | --- |
| `lib/src/config.dart` | `release.yaml` schema and strict parsing |
| `lib/src/workspace.dart` | package and dependency models |
| `lib/src/loader.dart` | the only file system access |
| `lib/src/versioning.dart` | version proposals, dependency floors, tags |
| `lib/src/planner.dart` | the pure planner and configuration validation |
| `lib/src/plan.dart` | the serializable plan document |
| `lib/src/cli.dart` | argument parsing and output |

`planRelease` takes a `Workspace`, a `ReleaseConfig`, a `ReleaseRequest`, and a
`RemoteState`, and returns a `ReleasePlan`. Everything it needs to know about
Git, pub.dev, and the calling workflow arrives through those inputs.

Full reference: [`docs/concepta-release.md`](../../docs/concepta-release.md).
