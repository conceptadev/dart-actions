import 'dart:convert';
import 'dart:io';

import 'package:concepta_release/concepta_release.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:test/test.dart';

import 'support.dart';

ReleasePlan plan(
  String fixture, {
  Map<String, BumpLevel> bumps = const {},
  Map<String, Version> overrides = const {},
  ReleaseChannel channel = ReleaseChannel.stable,
  Set<String> existingTags = const {},
  Map<String, Set<Version>> published = const {},
}) {
  final inputs = loadFixtureInputs(fixture);
  return planRelease(
    workspace: inputs.workspace,
    config: inputs.config,
    request: ReleaseRequest(
      channel: channel,
      bumps: bumps,
      versionOverrides: overrides,
    ),
    remote: RemoteState(
      existingTags: existingTags,
      publishedVersions: published,
    ),
  );
}

List<String> codes(ReleasePlan plan) =>
    plan.diagnostics.map((d) => d.code).toList();

ReleaseTarget target(ReleasePlan plan, String name) =>
    plan.releases.firstWhere((r) => r.package == name);

Version v(String value) => Version.parse(value);

void main() {
  group('single-package repositories', () {
    test('plans a Dart-only root package', () {
      final result = plan(
        'dart_single',
        bumps: {'sample_cli': BumpLevel.minor},
      );
      expect(result.hasErrors, isFalse);
      expect(result.isNoop, isFalse);
      final only = result.releases.single;
      expect(only.package, 'sample_cli');
      expect(only.path, '.');
      expect(only.action, ReleaseAction.publish);
      expect(only.proposedVersion.toString(), '1.3.0');
      expect(only.stage, 0);
      expect(result.tags.single.tag, 'sample_cli-v1.3.0');
    });

    test('plans a standalone Flutter package with a bare version tag', () {
      final result = plan(
        'flutter_single',
        bumps: {'sample_widget': BumpLevel.patch},
      );
      expect(result.hasErrors, isFalse);
      expect(result.tags.single.tag, 'v0.3.1');
      expect(
        codes(result),
        isNot(contains('tag-template-collision')),
        reason: 'one independent package cannot collide with itself',
      );
    });

    test('plans a one-member workspace the same way', () {
      final result = plan(
        'one_member_workspace',
        bumps: {'solo': BumpLevel.patch},
      );
      expect(result.releases.single.package, 'solo');
      expect(result.releases.single.path, 'packages/solo');
      expect(result.tags.single.tag, 'v0.4.3');
    });

    test('plans a published root package alongside a member', () {
      final result = plan(
        'root_package_workspace',
        bumps: {'legacy_helper': BumpLevel.minor},
      );
      expect(result.releases.map((r) => r.package), [
        'legacy_helper',
        'legacy_root',
      ]);
      expect(target(result, 'legacy_helper').stage, 0);
      expect(target(result, 'legacy_root').stage, 1);
      expect(
        target(result, 'legacy_root').dependencyUpdates.single.to,
        '^0.2.0',
      );
    });
  });

  group('synchronized groups', () {
    test('one member selects the whole group at one version and one tag', () {
      final result = plan(
        'mixed_workspace',
        bumps: {'sample_core': BumpLevel.minor},
      );
      expect(target(result, 'sample_core').proposedVersion.toString(), '1.5.0');
      expect(
        target(result, 'sample_annotations').proposedVersion.toString(),
        '1.5.0',
      );
      expect(target(result, 'sample_annotations').group, 'core');
      final groupTag = result.tags.firstWhere((t) => t.tag == 'v1.5.0');
      expect(groupTag.packages, ['sample_annotations', 'sample_core']);
      expect(target(result, 'sample_core').tag, 'v1.5.0');
      expect(target(result, 'sample_annotations').tag, 'v1.5.0');
    });

    test('records why a member that was not requested is included', () {
      final result = plan(
        'mixed_workspace',
        bumps: {'sample_core': BumpLevel.minor},
      );
      expect(
        target(result, 'sample_annotations').reasons.single,
        contains('synchronized with group "core"'),
      );
      expect(target(result, 'sample_core').reasons.single, 'requested minor');
    });

    test('takes the largest requested bump across the group', () {
      final result = plan(
        'mixed_workspace',
        bumps: {
          'sample_core': BumpLevel.patch,
          'sample_annotations': BumpLevel.minor,
        },
      );
      expect(target(result, 'sample_core').proposedVersion.toString(), '1.5.0');
      expect(target(result, 'sample_core').bump, BumpLevel.minor);
    });
  });

  group('independent packages', () {
    test('releasing one leaves unrelated packages untouched', () {
      final result = plan(
        'mixed_workspace',
        bumps: {'sample_cli_tool': BumpLevel.minor},
      );
      expect(result.releases.map((r) => r.package), ['sample_cli_tool']);
      expect(result.tags.single.tag, 'cli-v0.10.0');
      final update = result.metadata.single;
      expect(update.package, 'sample_generator');
      expect(update.update.section, 'dev_dependencies');
      expect(
        result.releases.map((r) => r.package),
        isNot(contains('sample_generator')),
        reason: 'a dev dependency floor alone never forces a release',
      );
    });

    test('keeps its own version when a group releases', () {
      final result = plan(
        'mixed_workspace',
        bumps: {'sample_core': BumpLevel.minor},
      );
      expect(
        target(result, 'sample_generator').proposedVersion.toString(),
        '2.1.1',
      );
      expect(target(result, 'sample_generator').group, isNull);
      expect(target(result, 'sample_generator').tag, 'sample_generator-v2.1.1');
    });
  });

  group('dependency floors and ordering', () {
    test('orders publication by runtime dependencies only', () {
      final result = plan(
        'mixed_workspace',
        bumps: {'sample_core': BumpLevel.minor},
      );
      expect(result.stages, [
        ['sample_annotations'],
        ['sample_core'],
        ['sample_generator'],
        ['sample_cli_tool'],
      ]);
    });

    test('preserves the written constraint style when raising a floor', () {
      final result = plan(
        'mixed_workspace',
        bumps: {'sample_core': BumpLevel.minor},
      );
      final generator = target(result, 'sample_generator');
      final runtime = generator.dependencyUpdates.firstWhere(
        (u) => u.section == 'dependencies',
      );
      expect(runtime.from, '>=1.4.0 <2.0.0');
      expect(runtime.to, '>=1.5.0 <2.0.0');

      final core = target(result, 'sample_core');
      expect(core.dependencyUpdates.single.from, '^1.4.0');
      expect(core.dependencyUpdates.single.to, '^1.5.0');
    });

    test('records a private package floor without releasing it', () {
      final result = plan(
        'mixed_workspace',
        bumps: {'sample_core': BumpLevel.minor},
      );
      expect(
        result.releases.map((r) => r.package),
        isNot(contains('sample_playground')),
      );
      final update = result.metadata.single;
      expect(update.package, 'sample_playground');
      expect(update.path, 'apps/playground');
      expect(update.update.to, '^1.5.0');
    });

    test('does not version dependents when the policy says not to', () {
      final inputs = loadFixtureInputs('mixed_workspace');
      final config = ReleaseConfig(
        configVersion: inputs.config.configVersion,
        defaultTagTemplate: inputs.config.defaultTagTemplate,
        defaultGroupTagTemplate: inputs.config.defaultGroupTagTemplate,
        bumpDependents: BumpLevel.none,
        groups: inputs.config.groups,
        packages: inputs.config.packages,
        deployments: inputs.config.deployments,
      );
      final result = planRelease(
        workspace: inputs.workspace,
        config: config,
        request: const ReleaseRequest(bumps: {'sample_core': BumpLevel.minor}),
      );
      expect(result.releases.map((r) => r.package), [
        'sample_annotations',
        'sample_core',
      ]);
      expect(codes(result), contains('unreleased-dependency-floor'));
      expect(
        result.metadata.map((m) => m.package),
        containsAll(['sample_generator', 'sample_playground']),
      );
    });

    test('does not report a package that a later pass selects', () {
      // sample_cli_tool only dev-depends on sample_annotations, so the first
      // pass sees it as an unreleased dependent. A later pass selects it
      // through sample_generator, and the earlier finding must not survive.
      final result = plan(
        'mixed_workspace',
        bumps: {'sample_core': BumpLevel.minor},
      );
      expect(
        result.releases.map((r) => r.package),
        contains('sample_cli_tool'),
      );
      expect(
        result.diagnostics.where(
          (d) =>
              d.code == 'unreleased-dependency-floor' &&
              d.target == 'sample_cli_tool',
        ),
        isEmpty,
      );
      expect(
        target(
          result,
          'sample_cli_tool',
        ).dependencyUpdates.map((u) => '${u.section}:${u.dependency}'),
        contains('dev_dependencies:sample_annotations'),
      );
      expect(
        result.metadata.map((m) => m.package),
        isNot(contains('sample_cli_tool')),
      );
    });

    test('warns when a dev dependency floor publishes later', () {
      final result = plan(
        'mixed_workspace',
        bumps: {'sample_core': BumpLevel.minor},
      );
      expect(codes(result), contains('dev-dependency-published-later'));
    });

    test('reports an unsatisfiable dependency graph', () {
      final result = plan('cyclic_workspace', bumps: {'left': BumpLevel.minor});
      expect(result.hasErrors, isTrue);
      expect(codes(result), contains('dependency-cycle'));
    });

    test('never widens a constraint that excludes the new version', () {
      final inputs = loadFixtureInputs('mixed_workspace');
      final result = planRelease(
        workspace: inputs.workspace,
        config: inputs.config,
        request: const ReleaseRequest(bumps: {'sample_core': BumpLevel.major}),
      );
      expect(result.hasErrors, isTrue);
      expect(codes(result), contains('dependency-floor-conflict'));
    });
  });

  group('pre-release channels', () {
    test('proposes a group beta and keeps floors off the pre-release', () {
      final result = plan(
        'mixed_workspace',
        bumps: {'sample_core': BumpLevel.minor},
        channel: ReleaseChannel.beta,
      );
      expect(
        target(result, 'sample_core').proposedVersion.toString(),
        '1.5.0-beta.0',
      );
      expect(result.tags.single.tag, 'v1.5.0-beta.0');
      expect(
        result.releases.map((r) => r.package),
        ['sample_annotations', 'sample_core'],
        reason: 'a pre-release does not drag dependents into the release',
      );
      expect(result.metadata, isEmpty);
    });

    test('proposes an rc from the same base', () {
      final result = plan(
        'dart_single',
        bumps: {'sample_cli': BumpLevel.patch},
        channel: ReleaseChannel.rc,
      );
      expect(result.releases.single.proposedVersion.toString(), '1.2.1-rc.0');
    });
  });

  group('explicit versions', () {
    test('accepts an override for a whole group', () {
      final result = plan(
        'mixed_workspace',
        overrides: {'sample_core': v('1.9.0')},
      );
      expect(
        target(result, 'sample_annotations').proposedVersion.toString(),
        '1.9.0',
      );
      expect(
        target(result, 'sample_core').reasons.single,
        'requested version 1.9.0',
      );
    });

    test('refuses an override that is not an increase', () {
      final result = plan('dart_single', overrides: {'sample_cli': v('1.0.0')});
      expect(result.hasErrors, isTrue);
      expect(codes(result), contains('version-would-go-backwards'));
    });

    test('refuses conflicting overrides inside one group', () {
      final result = plan(
        'mixed_workspace',
        overrides: {
          'sample_core': v('1.9.0'),
          'sample_annotations': v('1.8.0'),
        },
      );
      expect(result.hasErrors, isTrue);
      expect(codes(result), contains('conflicting-group-override'));
    });
  });

  group('remote state', () {
    test('never proposes a tag that already exists', () {
      final result = plan(
        'dart_single',
        bumps: {'sample_cli': BumpLevel.minor},
        existingTags: {'sample_cli-v1.3.0'},
      );
      expect(result.hasErrors, isTrue);
      expect(codes(result), contains('tag-exists'));
    });

    test('flags a version already on the registry for review', () {
      final result = plan(
        'dart_single',
        bumps: {'sample_cli': BumpLevel.minor},
        published: {
          'sample_cli': {v('1.3.0')},
        },
      );
      expect(result.hasErrors, isTrue);
      final diagnostic = result.diagnostics.firstWhere(
        (d) => d.code == 'version-already-published',
      );
      expect(diagnostic.message, contains('Existence alone is not proof'));
    });

    test('a partial release can resume on the remaining packages', () {
      // sample_annotations published, sample_core did not. Re-planning the
      // same release must still describe the whole approved set so the
      // publisher can skip what is already done deliberately.
      final result = plan(
        'mixed_workspace',
        bumps: {'sample_core': BumpLevel.minor},
        published: {
          'sample_annotations': {v('1.5.0')},
        },
      );
      expect(codes(result), contains('version-already-published'));
      expect(
        result.releases.map((r) => r.package),
        containsAll(['sample_annotations', 'sample_core']),
      );
      expect(target(result, 'sample_core').proposedVersion.toString(), '1.5.0');
    });
  });

  group('authorization boundaries', () {
    test('a private package can deploy but never publish', () {
      final result = plan(
        'mixed_workspace',
        bumps: {'sample_core': BumpLevel.minor},
      );
      expect(result.deployments.single.name, 'playground');
      expect(result.deployments.single.package, 'sample_playground');
      expect(
        result.releases
            .where((r) => r.action == ReleaseAction.publish)
            .map((r) => r.package),
        isNot(contains('sample_playground')),
      );
    });

    test('records deployments even when nothing is released', () {
      final result = plan('mixed_workspace');
      expect(result.isNoop, isTrue);
      expect(
        result.deployments,
        isNotEmpty,
        reason: 'a deployment does not require a version bump',
      );
    });

    test('refuses to release a package that is not declared', () {
      final result = plan(
        'mixed_workspace',
        bumps: {'sample_workspace': BumpLevel.patch},
      );
      expect(result.hasErrors, isTrue);
      expect(codes(result), contains('unknown-request-target'));
      expect(result.releases, isEmpty);
    });
  });

  group('no-op behaviour', () {
    test('an empty request produces an explicit no-op', () {
      final result = plan('mixed_workspace');
      expect(result.isNoop, isTrue);
      expect(result.hasErrors, isFalse);
      expect(codes(result), contains('no-release'));
      expect(result.tags, isEmpty);
      expect(result.stages, isEmpty);
    });

    test('a bump of none on a stable version is a no-op, not an error', () {
      final result = plan('dart_single', bumps: {'sample_cli': BumpLevel.none});
      expect(result.isNoop, isTrue);
      expect(result.hasErrors, isFalse);
      expect(codes(result), contains('no-version-change'));
    });
  });

  group('determinism and purity', () {
    test('identical inputs produce byte-identical plans', () {
      final first = plan(
        'mixed_workspace',
        bumps: {'sample_core': BumpLevel.minor},
      );
      final second = plan(
        'mixed_workspace',
        bumps: {'sample_core': BumpLevel.minor},
      );
      expect(second.toJsonString(), first.toJsonString());
    });

    test('request order does not change the plan', () {
      final inputs = loadFixtureInputs('mixed_workspace');
      String planWith(Map<String, BumpLevel> bumps) => planRelease(
        workspace: inputs.workspace,
        config: inputs.config,
        request: ReleaseRequest(bumps: bumps),
      ).toJsonString();
      expect(
        planWith({
          'sample_annotations': BumpLevel.patch,
          'sample_core': BumpLevel.minor,
        }),
        planWith({
          'sample_core': BumpLevel.minor,
          'sample_annotations': BumpLevel.patch,
        }),
      );
    });

    test('planning does not touch the workspace on disk', () {
      final root = fixturePath('mixed_workspace');
      Map<String, String> snapshot() {
        final contents = <String, String>{};
        for (final entity in Directory(root).listSync(recursive: true)) {
          if (entity is! File) continue;
          contents[p.relative(entity.path, from: root)] = entity
              .readAsStringSync();
        }
        return contents;
      }

      final before = snapshot();
      plan('mixed_workspace', bumps: {'sample_core': BumpLevel.minor});
      expect(snapshot(), before);
    });

    test('the serialized plan has a stable shape', () {
      final result = plan(
        'dart_single',
        bumps: {'sample_cli': BumpLevel.minor},
      );
      final decoded = jsonDecode(result.toJsonString()) as Map<String, Object?>;
      expect(decoded.keys, [
        'schemaVersion',
        'toolkitVersion',
        'channel',
        'noop',
        'releases',
        'tags',
        'stages',
        'metadataUpdates',
        'deployments',
        'diagnostics',
      ]);
      expect(decoded['schemaVersion'], ReleasePlan.schemaVersion);
      expect(decoded['toolkitVersion'], toolkitVersion);
      expect(
        decoded.toString(),
        isNot(contains(Directory.current.path)),
        reason: 'plans must not embed absolute paths',
      );
    });

    test('a recorded source is carried through without being looked up', () {
      final inputs = loadFixtureInputs('dart_single');
      const revision = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
      final result = planRelease(
        workspace: inputs.workspace,
        config: inputs.config,
        request: const ReleaseRequest(
          bumps: {'sample_cli': BumpLevel.minor},
          source: PlanSource(
            repository: 'conceptadev/example',
            ref: 'refs/heads/main',
            revision: revision,
          ),
        ),
      );
      final decoded = jsonDecode(result.toJsonString()) as Map<String, Object?>;
      expect(decoded['source'], {
        'repository': 'conceptadev/example',
        'ref': 'refs/heads/main',
        'revision': revision,
      });
    });
  });

  group('configuration validation against the workspace', () {
    List<String> validate(
      String releaseYaml, {
      String fixture = 'mixed_workspace',
    }) {
      final (workspace, _) = loadFixture(fixture);
      final (config, parseDiagnostics) = ReleaseConfig.parse(releaseYaml);
      if (config == null) return parseDiagnostics.map((d) => d.code).toList();
      return validateConfiguration(
        workspace: workspace!,
        config: config,
      ).map((d) => d.code).toList();
    }

    test('rejects a package that is not in the workspace', () {
      expect(
        validate('version: 1\npackages:\n  - name: nope\n'),
        contains('unknown-package'),
      );
    });

    test('rejects publishing a package marked publish_to: none', () {
      expect(
        validate('''
version: 1
packages:
  - name: sample_playground
    publish: true
'''),
        contains('private-package-publish'),
      );
    });

    test('rejects overlapping groups', () {
      expect(
        validate('''
version: 1
groups:
  - name: one
    packages: [sample_core]
  - name: two
    packages: [sample_core]
packages:
  - name: sample_core
    publish: true
'''),
        contains('overlapping-groups'),
      );
    });

    test('rejects a duplicate group name', () {
      expect(
        validate('''
version: 1
groups:
  - name: core
    packages: [sample_core]
  - name: core
    packages: [sample_annotations]
packages:
  - name: sample_core
    publish: true
  - name: sample_annotations
    publish: true
'''),
        contains('duplicate-group'),
      );
    });

    test('rejects a group member that was never declared', () {
      expect(
        validate('''
version: 1
groups:
  - name: core
    packages: [sample_core, sample_annotations]
packages:
  - name: sample_core
    publish: true
'''),
        contains('group-member-not-declared'),
      );
    });

    test('rejects a tag template without a version placeholder', () {
      expect(
        validate('''
version: 1
defaults:
  tag: "release"
packages:
  - name: sample_core
    publish: true
'''),
        contains('tag-template-missing-version'),
      );
    });

    test('rejects a group tag template that varies by package', () {
      expect(
        validate('''
version: 1
groups:
  - name: core
    tag: "{package}-v{version}"
    packages: [sample_core, sample_annotations]
packages:
  - name: sample_core
    publish: true
  - name: sample_annotations
    publish: true
'''),
        contains('group-tag-template-package'),
      );
    });

    test('warns when two independent packages share a tag shape', () {
      expect(
        validate('''
version: 1
defaults:
  tag: "v{version}"
packages:
  - name: sample_core
    publish: true
  - name: sample_generator
    publish: true
'''),
        contains('tag-template-collision'),
      );
    });

    test('rejects a deployment source outside the workspace', () {
      expect(
        validate('''
version: 1
deployments:
  - name: bad
    provider: github-pages
    source: ../elsewhere
'''),
        contains('deployment-source-escapes'),
      );
    });

    test('rejects a deployment naming an unknown package', () {
      expect(
        validate('''
version: 1
deployments:
  - name: bad
    provider: github-pages
    source: apps/playground
    package: ghost
'''),
        contains('unknown-package'),
      );
    });

    test('notes every workspace member that cannot be released', () {
      expect(
        validate('version: 1\npackages:\n  - name: sample_core\n'),
        contains('package-undeclared'),
      );
    });

    test('rejects publishing a package that depends on a private one', () {
      expect(
        plan(
          'mixed_workspace',
          bumps: {'sample_core': BumpLevel.minor},
        ).diagnostics.map((d) => d.code),
        isNot(contains('publish-depends-on-private')),
      );
      final (workspace, _) = loadFixture('mixed_workspace');
      final (config, _) = ReleaseConfig.parse('''
version: 1
packages:
  - name: sample_core
    publish: true
  - name: sample_annotations
    publish: false
''');
      final result = planRelease(
        workspace: workspace!,
        config: config!,
        request: const ReleaseRequest(bumps: {'sample_core': BumpLevel.minor}),
      );
      expect(
        result.diagnostics.map((d) => d.code),
        contains('publish-depends-on-private'),
      );
    });
  });
}
