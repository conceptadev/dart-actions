import 'dart:convert';

import 'package:concepta_release/concepta_release.dart';
import 'package:test/test.dart';

import 'support.dart';

class CommandResult {
  CommandResult(this.code, this.out, this.err);

  final int code;
  final String out;
  final String err;

  Map<String, Object?> get json => jsonDecode(out) as Map<String, Object?>;
}

CommandResult cli(List<String> arguments) {
  final out = StringBuffer();
  final err = StringBuffer();
  final code = run(arguments, out: out, err: err);
  return CommandResult(code, out.toString(), err.toString());
}

void main() {
  group('usage', () {
    test('prints the version', () {
      final result = cli(['--version']);
      expect(result.code, ExitCodes.ok);
      expect(result.out.trim(), toolkitVersion);
    });

    test('help succeeds and lists both commands', () {
      final result = cli(['--help']);
      expect(result.code, ExitCodes.ok);
      expect(result.out, contains('doctor'));
      expect(result.out, contains('plan'));
    });

    test('no command is a usage error', () {
      expect(cli(const []).code, ExitCodes.usage);
    });

    test('an unknown option is a usage error, not a crash', () {
      final result = cli(['plan', '--nope']);
      expect(result.code, ExitCodes.usage);
      expect(result.err, isNotEmpty);
    });

    test('a malformed --bump is a usage error', () {
      final result = cli([
        'plan',
        '-C',
        fixturePath('dart_single'),
        '--bump',
        'sample_cli',
      ]);
      expect(result.code, ExitCodes.usage);
      expect(result.err, contains('<package>:<value>'));
    });

    test('an unknown bump level is a usage error', () {
      final result = cli([
        'plan',
        '-C',
        fixturePath('dart_single'),
        '--bump',
        'sample_cli:enormous',
      ]);
      expect(result.code, ExitCodes.usage);
    });

    test('an invalid --set-version is a usage error', () {
      final result = cli([
        'plan',
        '-C',
        fixturePath('dart_single'),
        '--set-version',
        'sample_cli:latest',
      ]);
      expect(result.code, ExitCodes.usage);
    });
  });

  group('doctor', () {
    test('succeeds on a valid workspace and lists every member', () {
      final result = cli(['doctor', '-C', fixturePath('mixed_workspace')]);
      expect(result.code, ExitCodes.ok);
      expect(result.out, contains('sample_core'));
      expect(result.out, contains('group:core'));
      expect(result.out, contains('private'));
    });

    test('reports JSON with a per-package authorization summary', () {
      final result = cli([
        'doctor',
        '-C',
        fixturePath('mixed_workspace'),
        '--json',
      ]);
      expect(result.code, ExitCodes.ok);
      final workspace = result.json['workspace']! as Map<String, Object?>;
      final packages = workspace['packages']! as List<Object?>;
      final playground = packages.cast<Map<String, Object?>>().firstWhere(
        (p) => p['name'] == 'sample_playground',
      );
      expect(playground['private'], isTrue);
      expect(playground['publish'], isFalse);
      expect(playground['declared'], isTrue);
      expect(result.json['ok'], isTrue);
    });

    test('fails when the release configuration is missing', () {
      final root = scratchWorkspace({
        'pubspec.yaml': 'name: lonely\nversion: 1.0.0\n',
      });
      final result = cli(['doctor', '-C', root]);
      expect(result.code, ExitCodes.diagnosticsFailed);
      expect(result.err, contains('missing-release-config'));
    });

    test('fails when configuration contradicts the workspace', () {
      final root = scratchWorkspace({
        'pubspec.yaml': 'name: app\nversion: 1.0.0\npublish_to: none\n',
        'release.yaml':
            'version: 1\npackages:\n  - name: app\n    publish: true\n',
      });
      final result = cli(['doctor', '-C', root]);
      expect(result.code, ExitCodes.diagnosticsFailed);
      expect(result.err, contains('private-package-publish'));
    });

    test('accepts an explicit --config path', () {
      final result = cli([
        'doctor',
        '-C',
        fixturePath('dart_single'),
        '--config',
        '${fixturePath('dart_single')}/release.yaml',
      ]);
      expect(result.code, ExitCodes.ok);
    });
  });

  group('plan', () {
    test('emits a plan and exits zero', () {
      final result = cli([
        'plan',
        '-C',
        fixturePath('mixed_workspace'),
        '--bump',
        'sample_core:minor',
      ]);
      expect(result.code, ExitCodes.ok);
      expect(result.out, contains('sample_core  1.4.0 -> 1.5.0'));
      expect(result.out, contains('v1.5.0'));
    });

    test('JSON output is byte-identical across runs', () {
      List<String> arguments() => [
        'plan',
        '-C',
        fixturePath('mixed_workspace'),
        '--bump',
        'sample_core:minor',
        '--json',
      ];
      expect(cli(arguments()).out, cli(arguments()).out);
    });

    test('records the caller-supplied source identity', () {
      final result = cli([
        'plan',
        '-C',
        fixturePath('dart_single'),
        '--bump',
        'sample_cli:patch',
        '--source-repository',
        'conceptadev/example',
        '--source-revision',
        'deadbeef',
        '--json',
      ]);
      expect(result.json['source'], {
        'repository': 'conceptadev/example',
        'revision': 'deadbeef',
      });
    });

    test('an existing tag fails the command', () {
      final result = cli([
        'plan',
        '-C',
        fixturePath('dart_single'),
        '--bump',
        'sample_cli:minor',
        '--existing-tag',
        'sample_cli-v1.3.0',
      ]);
      expect(result.code, ExitCodes.diagnosticsFailed);
      expect(result.out, contains('tag-exists'));
    });

    test('a published version fails the command', () {
      final result = cli([
        'plan',
        '-C',
        fixturePath('dart_single'),
        '--bump',
        'sample_cli:minor',
        '--published',
        'sample_cli:1.3.0',
      ]);
      expect(result.code, ExitCodes.diagnosticsFailed);
    });

    test('a no-op plan succeeds and says so', () {
      final result = cli(['plan', '-C', fixturePath('mixed_workspace')]);
      expect(result.code, ExitCodes.ok);
      expect(result.out, contains('No releases'));
    });

    test('a pre-release channel is selectable', () {
      final result = cli([
        'plan',
        '-C',
        fixturePath('dart_single'),
        '--bump',
        'sample_cli:minor',
        '--channel',
        'beta',
        '--json',
      ]);
      expect(result.json['channel'], 'beta');
      final releases = result.json['releases']! as List<Object?>;
      expect(
        (releases.single as Map<String, Object?>)['proposedVersion'],
        '1.3.0-beta.0',
      );
    });
  });
}
