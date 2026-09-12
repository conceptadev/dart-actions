# Verified workflow foundation

This is the first implementation phase of the release standard in #9. It is opt-in and does not implement release planning, automated tags, resumable publishing, or caller migrations.

## Added in this phase

- `actions/setup-flutter` installs an exact Linux x64 Flutter archive from caller-reviewed configuration. It verifies SHA-256 on downloads and cache hits, rejects unsafe archive entries, checks the bundled Dart and Flutter versions, and exposes the SDK only after verification.
- `actions/check-worktree` fails on tracked or unignored source drift. It never restores or deletes files.
- `.github/workflows/ci-verified.yml` provides read-only reusable CI with no OIDC or release credentials.
- `.github/workflows/foundation-tests.yml` runs offline regression tests, actionlint, real Dart/Flutter fixture jobs, and repository-resolved Melos smoke tests for 6.3.3, 7.3.0, 8.5.0, and 8.7.0.
- `pr-title-check.yml` no longer references a runtime step from an input default. Its action dependencies are immutable pins, and the write-enabled job does not check out PR source.
- Dependabot proposes GitHub Action pin updates for review; it does not auto-merge them.

## Existing releases remain unchanged

The existing `.github/workflows/ci.yml` and `.github/workflows/publish.yml` are intentionally unchanged. The foundation test checks their baseline blob hashes so this phase cannot silently change live consumers. The pub-dev #9576 `--skip-validation` workaround also remains unchanged.

Mix and Naked UI still consume the existing publisher from `@main`; pin those callers before any later PR changes the existing publisher entrypoint. Caller adoption of `ci-verified.yml` should also be a separate reviewed PR.

## Caller configuration

Store the selected SDK in `.fvmrc`:

```json
{"flutter": "3.44.0"}
```

Add a reviewed `.github/flutter-releases.json` that maps exact Flutter versions to the bundled Dart version and Linux archive SHA-256. Copy both values from the official Flutter Linux release catalog. Do not calculate the trusted digest from the archive being installed.

Call the reusable workflow at a reviewed full commit SHA:

```yaml
jobs:
  checks:
    permissions:
      contents: read
    uses: conceptadev/dart-actions/.github/workflows/ci-verified.yml@<reviewed-full-commit-sha>
    with:
      version-file: .fvmrc
      releases-file: .github/flutter-releases.json
      bootstrap-command: dart pub get
      validation-command: dart run melos run ci --no-select
```

The command inputs are trusted repository configuration, not values copied from PR titles, issue bodies, or other untrusted text. They execute without release App secrets or pub.dev OIDC permission.

The reusable workflow pins provider composite actions to the reviewed Dart Actions commit that introduced them. This avoids resolving `./actions` from the caller repository by accident.

## What the tests prove

Offline Python tests cover exact-version validation, configuration path containment, command-file injection, cache re-verification, archive traversal/link rejection, version mismatch cleanup, failed downloads, and source-drift behavior.

Runner fixtures then exercise the real reviewed Flutter archives:

| Scenario | SDK | Expected proof |
| --- | --- | --- |
| Standalone Dart fixture | Flutter 3.41.2 / Dart 3.11.0 | dependency resolution, format, analysis, tests, clean tree |
| Flutter fixture | Flutter 3.44.0 / Dart 3.12.0 | analysis, widget test, clean tree |
| Melos 6.3.3 / 7.3.0 / 8.5.0 / 8.7.0 | Flutter 3.44.0 / Dart 3.12.0 | isolated repository-resolved bootstrap and smoke command |

The fixture manifest values come from the official Flutter Linux release catalog. Passing these smoke tests does not claim that every caller's full release workflow supports every Melos version or SDK combination. Full caller validation belongs in migration PRs.

## Next phase

After this PR is green and reviewed, build the resumable publisher as a separate change. Preserve ACK's hosted-dependency and partial-release safeguards until the shared implementation proves parity. Do not remove the #9576 compatibility path, create release tags, or change live publisher permissions in this foundation phase.
