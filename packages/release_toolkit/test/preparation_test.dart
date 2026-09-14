import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:release_toolkit/release_toolkit.dart';
import 'package:test/test.dart';

class _Repository {
  const _Repository(this.path, this.revision);

  final String path;
  final String revision;
}

ProcessResult _run(
  String executable,
  List<String> arguments, {
  required String cwd,
}) {
  final result = Process.runSync(executable, arguments, workingDirectory: cwd);
  if (result.exitCode != 0) {
    fail(
      '$executable ${arguments.join(' ')} failed in $cwd\n'
      '${result.stdout}\n${result.stderr}',
    );
  }
  return result;
}

void _git(String root, List<String> arguments) =>
    _run('git', arguments, cwd: root);

String _head(String root) =>
    (_run('git', ['rev-parse', 'HEAD'], cwd: root).stdout as String).trim();

_Repository _repository({
  String melosVersion = '7.8.1',
  bool useRootAsPackage = false,
  bool rootIsPackage = false,
  bool includePrivate = false,
  bool fixedVersioning = false,
  bool unexpectedHook = false,
  String bumpDependents = 'none',
}) {
  final root = Directory.systemTemp.createTempSync('release_prepare_source_');
  addTearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  final workspaceEntries = [
    '  - packages/alpha',
    '  - packages/beta',
    '  - packages/gamma',
    if (includePrivate) '  - apps/private_app',
  ].join('\n');
  final rootVersion = rootIsPackage ? 'version: 1.0.0\n' : '';
  final rootPublish = rootIsPackage ? '' : 'publish_to: none\n';
  final fixed = fixedVersioning ? '  versioning: fixed\n' : '';
  final command = unexpectedHook
      ? '''
  command:
    version:
      hooks:
        preCommit: touch unexpected-hook.txt
'''
      : '';
  final groups = includePrivate
      ? 'groups:\n  - name: mixed\n    packages: [alpha, private_app]\n'
      : 'groups: []\n';
  final files = <String, String>{
    '.gitignore': '.dart_tool/\n',
    'pubspec.yaml':
        '''
name: test_workspace
$rootVersion$rootPublish
environment:
  sdk: ^3.9.0
workspace:
$workspaceEntries
dev_dependencies:
  melos: $melosVersion
melos:
  useRootAsPackage: $useRootAsPackage
$fixed$command''',
    'release.yaml':
        '''
version: 1
defaults:
  bump_dependents: $bumpDependents
$groups
packages:
  - name: alpha
    publish: true
  - name: beta
    publish: true
  - name: gamma
    publish: true
${includePrivate ? '''  - name: private_app
    publish: false
''' : ''}${rootIsPackage ? '''  - name: test_workspace
    publish: true
''' : ''}''',
    'packages/alpha/pubspec.yaml': '''
name: alpha
version: 1.0.0
resolution: workspace
environment:
  sdk: ^3.9.0
''',
    'packages/alpha/lib/alpha.dart': "const value = 'alpha';\n",
    'packages/alpha/CHANGELOG.md': '''
# 1.0.0

- Historical alpha notes must remain byte-identical.
''',
    'packages/beta/pubspec.yaml': '''
name: beta
description: Keep this unrelated YAML.
version: 1.0.0
resolution: workspace
environment:
  sdk: ^3.9.0
dependencies:
  alpha: ^1.0.0 # Preserve this comment.
''',
    'packages/beta/lib/beta.dart': "const value = 'beta';\n",
    'packages/beta/CHANGELOG.md': '''
# 1.0.0

- Historical beta notes.
''',
    'packages/gamma/pubspec.yaml': '''
name: gamma
version: 1.0.0
resolution: workspace
environment:
  sdk: ^3.9.0
''',
    'packages/gamma/lib/gamma.dart': "const value = 'gamma';\n",
    'packages/gamma/CHANGELOG.md': '''
# 1.0.0

- Historical unrelated notes.
''',
    if (includePrivate) ...{
      'apps/private_app/pubspec.yaml': '''
name: private_app
version: 1.0.0
publish_to: none
resolution: workspace
environment:
  sdk: ^3.9.0
''',
      'apps/private_app/lib/app.dart': "const value = 'private';\n",
      'apps/private_app/CHANGELOG.md': '# 1.0.0\n\n- Historical app notes.\n',
    },
    if (rootIsPackage) 'CHANGELOG.md': '# 1.0.0\n\n- Historical root notes.\n',
  };
  for (final entry in files.entries) {
    final file = File(p.join(root.path, p.joinAll(p.posix.split(entry.key))));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(entry.value.trimLeft());
  }

  _run('dart', ['pub', 'get'], cwd: root.path);
  _git(root.path, ['init', '-b', 'main']);
  _git(root.path, ['config', 'user.email', 'release-test@example.invalid']);
  _git(root.path, ['config', 'user.name', 'Release Test']);
  _git(root.path, ['add', '.']);
  _git(root.path, ['commit', '-m', 'chore: initial workspace']);
  _git(root.path, ['tag', 'alpha-v1.0.0']);
  _git(root.path, ['tag', 'beta-v1.0.0']);
  _git(root.path, ['tag', 'gamma-v1.0.0']);

  final alpha = File(p.join(root.path, 'packages/alpha/lib/alpha.dart'));
  alpha.writeAsStringSync("${alpha.readAsStringSync()}const feature = true;\n");
  _git(root.path, ['add', 'packages/alpha/lib/alpha.dart']);
  _git(root.path, ['commit', '-m', 'feat(alpha): add a planned feature']);
  return _Repository(root.path, _head(root.path));
}

ReleasePlan _plan(
  _Repository repository, {
  Map<String, BumpLevel> bumps = const {'alpha': BumpLevel.minor},
  Map<String, Version> versions = const {},
}) {
  final (workspace, workspaceDiagnostics) = WorkspaceLoader(
    repository.path,
  ).load();
  final (config, configDiagnostics) = loadReleaseConfig(
    p.join(repository.path, 'release.yaml'),
  );
  expect(
    workspaceDiagnostics.where((d) => d.severity == DiagnosticSeverity.error),
    isEmpty,
  );
  expect(
    configDiagnostics.where((d) => d.severity == DiagnosticSeverity.error),
    isEmpty,
  );
  final result = planRelease(
    workspace: workspace!,
    config: config!,
    request: ReleaseRequest(
      bumps: bumps,
      versionOverrides: versions,
      source: PlanSource(revision: repository.revision),
    ),
  );
  expect(result.hasErrors, isFalse, reason: result.toReport());
  return result;
}

String _writePlan(ReleasePlan plan) {
  final directory = Directory.systemTemp.createTempSync(
    'release_prepare_plan_',
  );
  addTearDown(() {
    if (directory.existsSync()) directory.deleteSync(recursive: true);
  });
  final file = File(p.join(directory.path, 'plan.json'))
    ..writeAsStringSync(plan.toJsonString());
  return file.path;
}

String _output() {
  final parent = Directory.systemTemp.createTempSync('release_prepare_output_');
  final output = p.join(parent.path, 'prepared');
  addTearDown(() {
    if (parent.existsSync()) parent.deleteSync(recursive: true);
  });
  return output;
}

String _gitOutput(String root, List<String> arguments) =>
    (_run('git', arguments, cwd: root).stdout as String).trim();

void main() {
  final supportsMelos781 =
      Version.parse(Platform.version.split(' ').first) >= Version(3, 9, 0);
  final melos781Skip = supportsMelos781
      ? false
      : 'Melos 7.8.1 requires Dart 3.9.0 or later.';

  group('real Melos 7.8.1 preparation', () {
    test('CLI emits the preparation handoff as JSON', () {
      final repository = _repository();
      final output = _output();
      final stdout = StringBuffer();
      final stderr = StringBuffer();
      final exitCode = run(
        [
          'prepare',
          '--plan',
          _writePlan(_plan(repository)),
          '--directory',
          repository.path,
          '--output',
          output,
          '--json',
        ],
        out: stdout,
        err: stderr,
      );
      final result = jsonDecode(stdout.toString()) as Map<String, Object?>;
      expect(exitCode, ExitCodes.ok, reason: '$stdout\n$stderr');
      expect(result['status'], 'success');
      expect(result['usable'], isTrue);
      expect(result['preparedDirectory'], output);
      expect(result['sourceRevision'], repository.revision);
      expect(result['melosVersion'], '7.8.1');
      expect(result['changedFiles'], isNotEmpty);
    });

    test(
      'applies exact versions and planned dependency edits in isolation',
      () {
        final repository = _repository();
        final sourceStatus = _gitOutput(repository.path, [
          'status',
          '--porcelain',
          '--untracked-files=all',
        ]);
        final sourceTags = _gitOutput(repository.path, ['tag', '--list']);
        final result = prepareRelease(
          planPath: _writePlan(_plan(repository)),
          sourceDirectory: repository.path,
          outputDirectory: _output(),
        );

        expect(result.success, isTrue, reason: result.toReport());
        expect(result.usable, isTrue);
        expect(result.melosVersion, '7.8.1');
        expect(
          result.changedFiles.map((file) => file.path),
          containsAll([
            'CHANGELOG.md',
            'packages/alpha/CHANGELOG.md',
            'packages/alpha/pubspec.yaml',
            'packages/beta/pubspec.yaml',
          ]),
        );
        expect(
          File(
            p.join(result.preparedDirectory, 'packages/alpha/pubspec.yaml'),
          ).readAsStringSync(),
          contains('version: 1.1.0'),
        );
        final beta = File(
          p.join(result.preparedDirectory, 'packages/beta/pubspec.yaml'),
        ).readAsStringSync();
        expect(beta, contains('description: Keep this unrelated YAML.'));
        expect(beta, contains('alpha: ^1.1.0 # Preserve this comment.'));
        final alphaChangelog = File(
          p.join(result.preparedDirectory, 'packages/alpha/CHANGELOG.md'),
        ).readAsStringSync();
        expect(alphaChangelog, contains('**FEAT**(alpha)'));
        expect(
          alphaChangelog,
          endsWith(
            '# 1.0.0\n\n- Historical alpha notes must remain byte-identical.\n',
          ),
        );
        final commitDate = _gitOutput(repository.path, [
          'show',
          '-s',
          '--format=%cs',
          repository.revision,
        ]);
        expect(
          File(
            p.join(result.preparedDirectory, 'CHANGELOG.md'),
          ).readAsStringSync(),
          contains('## $commitDate'),
        );
        for (final relative in [
          'packages/gamma/pubspec.yaml',
          'packages/gamma/CHANGELOG.md',
        ]) {
          expect(
            File(p.join(result.preparedDirectory, relative)).readAsStringSync(),
            File(p.join(repository.path, relative)).readAsStringSync(),
            reason: 'unrelated package files must remain byte-identical',
          );
        }
        expect(
          _gitOutput(result.preparedDirectory, ['tag', '--list']),
          sourceTags,
        );
        expect(_head(result.preparedDirectory), repository.revision);
        expect(_head(repository.path), repository.revision);
        expect(
          _gitOutput(repository.path, [
            'status',
            '--porcelain',
            '--untracked-files=all',
          ]),
          sourceStatus,
        );
      },
    );

    test('supports stable, beta, RC, and explicit exact versions', () {
      for (final version in ['1.1.0', '1.1.0-beta.0', '1.1.0-rc.0', '1.7.8']) {
        final repository = _repository();
        final result = prepareRelease(
          planPath: _writePlan(
            _plan(
              repository,
              bumps: const {},
              versions: {'alpha': Version.parse(version)},
            ),
          ),
          sourceDirectory: repository.path,
          outputDirectory: _output(),
        );
        expect(
          result.success,
          isTrue,
          reason: '$version\n${result.toReport()}',
        );
        expect(
          File(
            p.join(result.preparedDirectory, 'packages/alpha/pubspec.yaml'),
          ).readAsStringSync(),
          contains('version: $version'),
        );
      }
    });

    test('versions a synchronized mixed public and private group', () {
      final repository = _repository(includePrivate: true);
      final plan = _plan(
        repository,
        bumps: const {'private_app': BumpLevel.patch},
      );
      expect(plan.tags.single.packages, ['alpha']);
      final result = prepareRelease(
        planPath: _writePlan(plan),
        sourceDirectory: repository.path,
        outputDirectory: _output(),
      );
      expect(result.success, isTrue, reason: result.toReport());
      expect(
        File(
          p.join(result.preparedDirectory, 'apps/private_app/pubspec.yaml'),
        ).readAsStringSync(),
        contains('version: 1.0.1'),
      );
      expect(
        File(
          p.join(result.preparedDirectory, 'packages/alpha/pubspec.yaml'),
        ).readAsStringSync(),
        contains('version: 1.0.1'),
      );
    });

    test('generates an entry for a dependency-only release target', () {
      final repository = _repository(bumpDependents: 'patch');
      final plan = _plan(repository);
      expect(
        plan.releases.map((release) => release.package),
        containsAll(['alpha', 'beta']),
      );
      final result = prepareRelease(
        planPath: _writePlan(plan),
        sourceDirectory: repository.path,
        outputDirectory: _output(),
      );
      expect(result.success, isTrue, reason: result.toReport());
      final changelog = File(
        p.join(result.preparedDirectory, 'packages/beta/CHANGELOG.md'),
      ).readAsStringSync();
      expect(changelog, contains('## 1.0.1'));
      expect(changelog, contains('Bump "beta" to `1.0.1`'));
      expect(changelog, endsWith('# 1.0.0\n\n- Historical beta notes.\n'));
    });

    test('supports a root package when Melos explicitly includes it', () {
      final repository = _repository(
        useRootAsPackage: true,
        rootIsPackage: true,
      );
      final result = prepareRelease(
        planPath: _writePlan(
          _plan(repository, bumps: const {'test_workspace': BumpLevel.patch}),
        ),
        sourceDirectory: repository.path,
        outputDirectory: _output(),
      );
      expect(result.success, isTrue, reason: result.toReport());
      expect(
        File(
          p.join(result.preparedDirectory, 'pubspec.yaml'),
        ).readAsStringSync(),
        contains('version: 1.0.1'),
      );
    });

    test('repeated preparation produces an equivalent release diff', () {
      final repository = _repository();
      final planPath = _writePlan(_plan(repository));
      final first = prepareRelease(
        planPath: planPath,
        sourceDirectory: repository.path,
        outputDirectory: _output(),
      );
      final second = prepareRelease(
        planPath: planPath,
        sourceDirectory: repository.path,
        outputDirectory: _output(),
      );
      expect(first.success, isTrue, reason: first.toReport());
      expect(second.success, isTrue, reason: second.toReport());
      expect(
        _gitOutput(first.preparedDirectory, ['diff', '--binary', 'HEAD']),
        _gitOutput(second.preparedDirectory, ['diff', '--binary', 'HEAD']),
      );
    });
  }, skip: melos781Skip);

  group('preparation rejection', () {
    test('rejects a dirty source before creating an output checkout', () {
      final repository = _repository();
      File(p.join(repository.path, 'untracked.txt')).writeAsStringSync('dirty');
      final output = _output();
      final result = prepareRelease(
        planPath: _writePlan(_plan(repository)),
        sourceDirectory: repository.path,
        outputDirectory: output,
      );
      expect(result.success, isFalse);
      expect(
        result.diagnostics.map((diagnostic) => diagnostic.code),
        contains('source-not-clean'),
      );
      expect(Directory(output).existsSync(), isFalse);
    });

    test('rejects an unsupported repository-resolved Melos version', () {
      final repository = _repository(melosVersion: '8.7.0');
      final result = prepareRelease(
        planPath: _writePlan(_plan(repository)),
        sourceDirectory: repository.path,
        outputDirectory: _output(),
      );
      expect(result.success, isFalse);
      expect(
        result.diagnostics.map((diagnostic) => diagnostic.code),
        contains('melos-version-unsupported'),
      );
      expect(
        File(
          p.join(result.preparedDirectory, '.release_toolkit_unusable.json'),
        ).existsSync(),
        isTrue,
      );
    });

    test('rejects a selected root package excluded by Melos configuration', () {
      final repository = _repository(rootIsPackage: true);
      final result = prepareRelease(
        planPath: _writePlan(
          _plan(repository, bumps: const {'test_workspace': BumpLevel.patch}),
        ),
        sourceDirectory: repository.path,
        outputDirectory: _output(),
      );
      expect(result.success, isFalse);
      expect(
        result.diagnostics.map((diagnostic) => diagnostic.code),
        contains('package-excluded-by-melos'),
      );
    });

    test('rejects conflicting Melos fixed versioning configuration', () {
      final repository = _repository(fixedVersioning: true);
      final result = prepareRelease(
        planPath: _writePlan(_plan(repository)),
        sourceDirectory: repository.path,
        outputDirectory: _output(),
      );
      expect(result.success, isFalse);
      expect(
        result.diagnostics.map((diagnostic) => diagnostic.code),
        contains('melos-fixed-versioning-conflict'),
      );
    });

    test('rejects stale plan inputs', () {
      final repository = _repository();
      final decoded =
          jsonDecode(_plan(repository).toJsonString()) as Map<String, Object?>;
      final releases = decoded['releases']! as List<Object?>;
      (releases.single as Map<String, Object?>)['currentVersion'] = '0.9.0';
      final directory = Directory.systemTemp.createTempSync(
        'release_stale_plan_',
      );
      addTearDown(() {
        if (directory.existsSync()) directory.deleteSync(recursive: true);
      });
      final planFile = File(p.join(directory.path, 'plan.json'))
        ..writeAsStringSync(jsonEncode(decoded));
      final result = prepareRelease(
        planPath: planFile.path,
        sourceDirectory: repository.path,
        outputDirectory: _output(),
      );
      expect(result.success, isFalse);
      expect(
        result.diagnostics.map((diagnostic) => diagnostic.code),
        contains('stale-plan-version'),
      );
    });

    test('rejects version hooks before they can make unexpected edits', () {
      final repository = _repository(unexpectedHook: true);
      final result = prepareRelease(
        planPath: _writePlan(_plan(repository)),
        sourceDirectory: repository.path,
        outputDirectory: _output(),
      );
      expect(result.success, isFalse);
      expect(Directory(result.preparedDirectory).existsSync(), isTrue);
      expect(
        result.diagnostics.map((diagnostic) => diagnostic.code),
        contains('melos-version-hooks-unsupported'),
      );
      expect(
        File(
          p.join(result.preparedDirectory, 'unexpected-hook.txt'),
        ).existsSync(),
        isFalse,
      );
      expect(
        File(
          p.join(result.preparedDirectory, '.release_toolkit_unusable.json'),
        ).existsSync(),
        isTrue,
      );
      expect(_head(repository.path), repository.revision);
    });
  }, skip: melos781Skip);
}
