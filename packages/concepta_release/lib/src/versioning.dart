import 'package:pub_semver/pub_semver.dart';

import 'config.dart';

/// Result of proposing one version. Either [version] is set, or the proposal
/// is rejected with a stable [errorCode].
class VersionProposal {
  const VersionProposal.success(this.version, {this.note})
    : errorCode = null,
      errorMessage = null;

  const VersionProposal.failure(this.errorCode, this.errorMessage)
    : version = null,
      note = null;

  final Version? version;
  final String? note;
  final String? errorCode;
  final String? errorMessage;

  bool get isSuccess => version != null;
}

Version _withoutSuffixes(Version v) => Version(v.major, v.minor, v.patch);

Version _applyBump(Version base, BumpLevel bump) => switch (bump) {
  BumpLevel.none => base,
  BumpLevel.patch => Version(base.major, base.minor, base.patch + 1),
  BumpLevel.minor => Version(base.major, base.minor + 1, 0),
  BumpLevel.major => Version(base.major + 1, 0, 0),
};

/// Proposes the next version for [current].
///
/// Arithmetic is plain semver: `major` always moves to `X+1.0.0`, including for
/// `0.x` packages. Pre-release channels append `-<id>.<n>` to the bumped base
/// and increment `<n>` while the base and identifier stay the same.
///
/// A pre-release `current` on the stable channel with `bump: none` graduates to
/// its own base version instead of moving forward.
VersionProposal proposeVersion({
  required Version current,
  required BumpLevel bump,
  required ReleaseChannel channel,
}) {
  final base = _applyBump(_withoutSuffixes(current), bump);
  final id = channel.preReleaseId;

  if (id == null) {
    if (base == current) {
      return const VersionProposal.failure(
        'no-version-change',
        'The proposed version equals the current version. '
            'Request a bump level, or drop the package from this release.',
      );
    }
    if (base < current) {
      return VersionProposal.failure(
        'version-would-go-backwards',
        'Proposed $base is lower than the current $current.',
      );
    }
    final graduating = current.isPreRelease && bump == BumpLevel.none;
    return VersionProposal.success(
      base,
      note: graduating ? 'Graduating pre-release $current to $base.' : null,
    );
  }

  final continuesSeries =
      current.isPreRelease &&
      _withoutSuffixes(current) == base &&
      current.preRelease.isNotEmpty &&
      current.preRelease.first == id;

  if (!continuesSeries && bump == BumpLevel.none && !current.isPreRelease) {
    return VersionProposal.failure(
      'prerelease-requires-bump',
      'A $id release from the stable version $current needs a bump level; '
          '$base-$id.0 would sort below $current.',
    );
  }

  if (continuesSeries) {
    final counter = current.preRelease.length > 1 ? current.preRelease[1] : 0;
    final next = counter is int ? counter + 1 : 0;
    return VersionProposal.success(Version.parse('$base-$id.$next'));
  }

  final proposed = Version.parse('$base-$id.0');
  if (proposed < current) {
    return VersionProposal.failure(
      'version-would-go-backwards',
      'Proposed $proposed is lower than the current $current.',
    );
  }
  return VersionProposal.success(proposed);
}

/// What happened when a dependency version floor was examined.
enum FloorOutcome {
  /// The declared floor already allows the new version.
  unchanged,

  /// A new constraint string is available in [FloorResult.constraint].
  raised,

  /// The declaration has no floor to raise, such as `any`.
  unbounded,

  /// The new version falls outside the declared upper bound.
  conflict,
}

class FloorResult {
  const FloorResult(this.outcome, {this.constraint});

  final FloorOutcome outcome;
  final String? constraint;
}

/// Raises the lower bound of [raw] to [released], preserving the written style.
///
/// Caret constraints stay caret constraints, ranges keep their upper bound, and
/// exact pins stay exact. Pre-release versions never move a floor.
FloorResult raiseDependencyFloor(String raw, Version released) {
  final trimmed = raw.trim();
  if (released.isPreRelease) return const FloorResult(FloorOutcome.unchanged);

  final VersionConstraint parsed;
  try {
    parsed = VersionConstraint.parse(trimmed);
  } on FormatException {
    return const FloorResult(FloorOutcome.unbounded);
  }

  if (parsed.isAny) return const FloorResult(FloorOutcome.unbounded);

  if (parsed is Version) {
    if (parsed == released) return const FloorResult(FloorOutcome.unchanged);
    return FloorResult(FloorOutcome.raised, constraint: released.toString());
  }

  if (parsed is! VersionRange || parsed.min == null || !parsed.includeMin) {
    return const FloorResult(FloorOutcome.unbounded);
  }

  final min = parsed.min!;
  if (min >= released) return const FloorResult(FloorOutcome.unchanged);

  if (trimmed.startsWith('^')) {
    return FloorResult(FloorOutcome.raised, constraint: '^$released');
  }
  if (!parsed.allows(released)) {
    return const FloorResult(FloorOutcome.conflict);
  }
  final rewritten = trimmed.replaceFirst(min.toString(), released.toString());
  return FloorResult(FloorOutcome.raised, constraint: rewritten);
}

/// Renders a git tag from a template containing `{version}` and, for
/// independently versioned packages, `{package}`.
String renderTag(String template, {String? package, required Version version}) {
  var out = template.replaceAll('{version}', version.toString());
  if (package != null) out = out.replaceAll('{package}', package);
  return out;
}
