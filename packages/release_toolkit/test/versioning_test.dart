import 'package:release_toolkit/release_toolkit.dart';
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';

Version v(String value) => Version.parse(value);

String? propose(String current, BumpLevel bump, ReleaseChannel channel) =>
    proposeVersion(
      current: v(current),
      bump: bump,
      channel: channel,
    ).version?.toString();

String? failure(String current, BumpLevel bump, ReleaseChannel channel) =>
    proposeVersion(current: v(current), bump: bump, channel: channel).errorCode;

void main() {
  group('stable proposals', () {
    test('applies plain semver arithmetic', () {
      expect(propose('1.2.3', BumpLevel.patch, ReleaseChannel.stable), '1.2.4');
      expect(propose('1.2.3', BumpLevel.minor, ReleaseChannel.stable), '1.3.0');
      expect(propose('1.2.3', BumpLevel.major, ReleaseChannel.stable), '2.0.0');
    });

    test('treats a major bump on 0.x as 1.0.0, not 0.x+1', () {
      expect(propose('0.5.1', BumpLevel.major, ReleaseChannel.stable), '1.0.0');
      expect(propose('0.5.1', BumpLevel.minor, ReleaseChannel.stable), '0.6.0');
    });

    test('graduates a pre-release without a bump', () {
      expect(
        propose('1.3.0-beta.4', BumpLevel.none, ReleaseChannel.stable),
        '1.3.0',
      );
      final proposal = proposeVersion(
        current: v('1.3.0-rc.1'),
        bump: BumpLevel.none,
        channel: ReleaseChannel.stable,
      );
      expect(proposal.note, contains('Graduating'));
    });

    test('reports a no-op instead of inventing a version', () {
      expect(
        failure('1.2.3', BumpLevel.none, ReleaseChannel.stable),
        'no-version-change',
      );
    });
  });

  group('pre-release proposals', () {
    test('starts a series from a stable version', () {
      expect(
        propose('1.2.3', BumpLevel.minor, ReleaseChannel.beta),
        '1.3.0-beta.0',
      );
    });

    test('continues the same series', () {
      expect(
        propose('1.3.0-beta.0', BumpLevel.none, ReleaseChannel.beta),
        '1.3.0-beta.1',
      );
      expect(
        propose('1.3.0-beta.7', BumpLevel.none, ReleaseChannel.beta),
        '1.3.0-beta.8',
      );
    });

    test('switches identifier without moving the base', () {
      expect(
        propose('1.3.0-beta.2', BumpLevel.none, ReleaseChannel.rc),
        '1.3.0-rc.0',
      );
    });

    test('refuses a pre-release that would sort below the current version', () {
      expect(
        failure('1.2.3', BumpLevel.none, ReleaseChannel.beta),
        'prerelease-requires-bump',
      );
    });
  });

  group('dependency floors', () {
    test('keeps caret style', () {
      final result = raiseDependencyFloor('^1.2.0', v('1.3.0'));
      expect(result.outcome, FloorOutcome.raised);
      expect(result.constraint, '^1.3.0');
    });

    test('keeps an explicit upper bound', () {
      final result = raiseDependencyFloor('>=1.2.0 <2.0.0', v('1.3.0'));
      expect(result.outcome, FloorOutcome.raised);
      expect(result.constraint, '>=1.3.0 <2.0.0');
    });

    test('raises an exact pin to the new exact version', () {
      final result = raiseDependencyFloor('1.2.0', v('1.3.0'));
      expect(result.outcome, FloorOutcome.raised);
      expect(result.constraint, '1.3.0');
    });

    test('leaves a floor that already allows the release', () {
      expect(
        raiseDependencyFloor('^1.3.0', v('1.3.0')).outcome,
        FloorOutcome.unchanged,
      );
      expect(
        raiseDependencyFloor('^2.0.0', v('1.3.0')).outcome,
        FloorOutcome.unchanged,
      );
    });

    test('never widens a range to fit a version it excludes', () {
      expect(
        raiseDependencyFloor('>=1.2.0 <2.0.0', v('2.0.0')).outcome,
        FloorOutcome.conflict,
      );
    });

    test('reports an unbounded constraint instead of guessing', () {
      expect(
        raiseDependencyFloor('any', v('1.3.0')).outcome,
        FloorOutcome.unbounded,
      );
      expect(
        raiseDependencyFloor('', v('1.3.0')).outcome,
        FloorOutcome.unbounded,
      );
    });

    test('never moves a floor onto a pre-release', () {
      expect(
        raiseDependencyFloor('^1.2.0', v('1.3.0-beta.0')).outcome,
        FloorOutcome.unchanged,
      );
    });
  });

  group('tags', () {
    test('renders both placeholders', () {
      expect(
        renderTag('{package}-v{version}', package: 'mix', version: v('1.2.3')),
        'mix-v1.2.3',
      );
      expect(renderTag('v{version}', version: v('1.2.3')), 'v1.2.3');
    });
  });
}
