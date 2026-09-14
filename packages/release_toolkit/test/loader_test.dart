import 'dart:io';

import 'package:release_toolkit/release_toolkit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'support.dart';

void main() {
  test('treats a repository without a workspace key as one package', () {
    final (workspace, diagnostics) = loadFixture('dart_single');
    expect(diagnostics, isEmpty);
    expect(workspace!.packages.map((x) => x.name), ['sample_cli']);
    final package = workspace.root;
    expect(package.path, '.');
    expect(package.version.toString(), '1.2.0');
    expect(package.isPrivate, isFalse);
    expect(package.usesFlutter, isFalse);
    expect(package.sdkConstraint.toString(), '^3.8.0');
  });

  test('detects a Flutter package from its environment and SDK dependency', () {
    final (workspace, _) = loadFixture('flutter_single');
    final package = workspace!['sample_widget']!;
    expect(package.usesFlutter, isTrue);
    expect(package.flutterConstraint, isNotNull);
    expect(
      package.dependencies.single.kind,
      DependencyKind.sdk,
      reason: 'an SDK dependency carries no version floor to raise',
    );
    expect(package.dependencies.single.carriesVersionFloor, isFalse);
  });

  test('always includes the workspace root as a member', () {
    final (workspace, _) = loadFixture('one_member_workspace');
    expect(workspace!.names, containsAll(['solo_workspace', 'solo']));
    expect(workspace.root.name, 'solo_workspace');
    expect(workspace.root.version, isNull);
    expect(workspace.root.isPrivate, isTrue);
  });

  test('supports a published root package alongside members', () {
    final (workspace, _) = loadFixture('root_package_workspace');
    expect(workspace!.root.name, 'legacy_root');
    expect(workspace.root.version.toString(), '2.0.0');
    expect(workspace.root.isPrivate, isFalse);
    expect(workspace['legacy_helper']!.path, 'packages/helper');
  });

  test('reads every dependency shape', () {
    final (workspace, _) = loadFixture('mixed_workspace');
    final generator = workspace!['sample_generator']!;
    final runtime = generator.dependenciesOn('sample_core').single;
    expect(runtime.section, DependencySection.dependencies);
    expect(runtime.kind, DependencyKind.hosted);
    expect(runtime.rawConstraint, '>=1.4.0 <2.0.0');
    expect(runtime.carriesVersionFloor, isTrue);

    final dev = generator.dependenciesOn('sample_cli_tool').single;
    expect(dev.section, DependencySection.devDependencies);
    expect(dev.rawConstraint, '^0.9.0');
  });

  test('expands a trailing glob at language version 3.11 or later', () {
    final (workspace, diagnostics) = loadFixture('glob_workspace');
    expect(diagnostics, isEmpty);
    expect(workspace!.names, containsAll(['alpha', 'beta']));
    expect(workspace['alpha']!.path, 'packages/alpha');
  });

  test('rejects a glob below the language version pub requires', () {
    final root = scratchWorkspace({
      'pubspec.yaml': '''
name: old_root
publish_to: none
environment:
  sdk: ^3.8.0
workspace:
  - packages/*
''',
      'packages/a/pubspec.yaml': 'name: a\nversion: 1.0.0\n',
    });
    final (workspace, diagnostics) = WorkspaceLoader(root).load();
    expect(workspace, isNull);
    expect(
      diagnostics.map((d) => d.code),
      contains('workspace-glob-language-version'),
    );
  });

  test('rejects a member path that escapes the repository', () {
    final root = scratchWorkspace({
      'pubspec.yaml': '''
name: escaping
publish_to: none
environment:
  sdk: ^3.8.0
workspace:
  - ../outside
''',
    });
    final (_, diagnostics) = WorkspaceLoader(root).load();
    expect(diagnostics.map((d) => d.code), contains('workspace-path-escapes'));
  });

  test('rejects an unsupported glob shape rather than half-matching it', () {
    final root = scratchWorkspace({
      'pubspec.yaml': '''
name: patterned
publish_to: none
environment:
  sdk: ^3.11.0
workspace:
  - packages/*/src
''',
    });
    final (_, diagnostics) = WorkspaceLoader(root).load();
    expect(
      diagnostics.map((d) => d.code),
      contains('unsupported-workspace-pattern'),
    );
  });

  test('rejects two members that claim the same package name', () {
    final root = scratchWorkspace({
      'pubspec.yaml': '''
name: duplicated
publish_to: none
environment:
  sdk: ^3.8.0
workspace:
  - packages/one
  - packages/two
''',
      'packages/one/pubspec.yaml': 'name: same\nversion: 1.0.0\n',
      'packages/two/pubspec.yaml': 'name: same\nversion: 2.0.0\n',
    });
    final (workspace, diagnostics) = WorkspaceLoader(root).load();
    expect(workspace, isNull);
    expect(diagnostics.map((d) => d.code), contains('duplicate-package-name'));
  });

  test('reports a missing member pubspec', () {
    final root = scratchWorkspace({
      'pubspec.yaml': '''
name: incomplete
publish_to: none
environment:
  sdk: ^3.8.0
workspace:
  - packages/ghost
''',
    });
    final (_, diagnostics) = WorkspaceLoader(root).load();
    expect(diagnostics.map((d) => d.code), contains('missing-member-pubspec'));
  });

  test('reports an invalid package version', () {
    final root = scratchWorkspace({
      'pubspec.yaml': 'name: bad\nversion: not-a-version\n',
    });
    final (_, diagnostics) = WorkspaceLoader(root).load();
    expect(diagnostics.map((d) => d.code), contains('invalid-package-version'));
  });

  test('reports a missing root pubspec', () {
    final root = scratchWorkspace({});
    final (workspace, diagnostics) = WorkspaceLoader(root).load();
    expect(workspace, isNull);
    expect(diagnostics.map((d) => d.code), contains('missing-root-pubspec'));
  });

  test('reports a missing release configuration instead of assuming one', () {
    final (config, diagnostics) = loadReleaseConfig(
      p.join(scratchWorkspace({}), 'release.yaml'),
    );
    expect(config, isNull);
    expect(diagnostics.map((d) => d.code), contains('missing-release-config'));
  });

  test('loads the release configuration next to a fixture', () {
    final (config, diagnostics) = loadReleaseConfig(
      p.join(fixturePath('mixed_workspace'), 'release.yaml'),
    );
    expect(diagnostics, isEmpty);
    expect(config!.groups.single.name, 'core');
  });

  test('fixture directories exist where the tests expect them', () {
    expect(Directory(fixturePath('mixed_workspace')).existsSync(), isTrue);
  });
}
