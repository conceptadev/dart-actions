import 'dart:convert';

import 'package:args/args.dart';
import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';

import 'config.dart';
import 'diagnostics.dart';
import 'loader.dart';
import 'plan.dart';
import 'planner.dart';
import 'preparation.dart';
import 'version.dart';
import 'workspace.dart';

/// Process exit codes. Callers and workflows depend on these values.
abstract final class ExitCodes {
  /// The command produced a usable result.
  static const ok = 0;

  /// The command could not be understood.
  static const usage = 2;

  /// The command ran and reported at least one error diagnostic.
  static const diagnosticsFailed = 3;
}

/// Runs the `release_toolkit` CLI.
///
/// Planning and diagnostics are read-only. Preparation writes only to a new,
/// isolated checkout and never publishes, pushes, or creates a tag.
int run(
  List<String> arguments, {
  required StringSink out,
  required StringSink err,
}) {
  final parser = _buildParser();
  final ArgResults results;
  try {
    results = parser.parse(arguments);
  } on FormatException catch (error) {
    err
      ..writeln(error.message)
      ..writeln(_usage(parser));
    return ExitCodes.usage;
  }

  if (results.flag('version')) {
    out.writeln(toolkitVersion);
    return ExitCodes.ok;
  }
  if (results.flag('help') || results.command == null) {
    out.writeln(_usage(parser));
    return results.flag('help') ? ExitCodes.ok : ExitCodes.usage;
  }

  final command = results.command!;
  return switch (command.name) {
    'doctor' => _doctor(command, out: out, err: err),
    'plan' => _plan(command, out: out, err: err),
    'prepare' => _prepare(command, out: out, err: err),
    _ => () {
      err.writeln(_usage(parser));
      return ExitCodes.usage;
    }(),
  };
}

ArgParser _buildParser() {
  ArgParser shared() => ArgParser()
    ..addOption(
      'directory',
      abbr: 'C',
      defaultsTo: '.',
      help: 'Workspace root to read.',
    )
    ..addOption(
      'config',
      help: 'Release configuration path. Defaults to <directory>/release.yaml.',
    )
    ..addFlag('json', negatable: false, help: 'Emit machine-readable JSON.');

  final plan = shared()
    ..addOption(
      'channel',
      allowed: ReleaseChannel.values.map((c) => c.name),
      defaultsTo: ReleaseChannel.stable.name,
      help: 'Release channel for proposed versions.',
    )
    ..addMultiOption(
      'bump',
      help: 'Requested bump as <package>:<none|patch|minor|major>.',
    )
    ..addMultiOption(
      'set-version',
      help: 'Exact version as <package>:<version>.',
    )
    ..addMultiOption(
      'existing-tag',
      help: 'A tag that already exists. Repeat for each tag.',
    )
    ..addMultiOption(
      'published',
      help: 'A version already on the registry, as <package>:<version>.',
    )
    ..addOption('source-repository', help: 'Recorded source repository.')
    ..addOption('source-ref', help: 'Recorded source ref.')
    ..addOption('source-revision', help: 'Recorded source commit.');

  final prepare = ArgParser()
    ..addOption('plan', mandatory: true, help: 'JSON release plan to apply.')
    ..addOption(
      'directory',
      abbr: 'C',
      mandatory: true,
      help: 'Clean source Git checkout recorded by the plan.',
    )
    ..addOption(
      'output',
      mandatory: true,
      help: 'Previously nonexistent directory for the prepared checkout.',
    )
    ..addFlag('json', negatable: false, help: 'Emit machine-readable JSON.');

  return ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false)
    ..addFlag('version', negatable: false, help: 'Print the toolkit version.')
    ..addCommand('doctor', shared())
    ..addCommand('plan', plan)
    ..addCommand('prepare', prepare);
}

String _usage(ArgParser parser) =>
    '''
release_toolkit $toolkitVersion

Usage: release_toolkit <command> [options]

Commands:
  doctor    Validate the workspace and release.yaml. Reports problems only.
  plan      Produce a deterministic, read-only release plan.
  prepare   Apply an approved plan in a new isolated checkout.

Global options:
${parser.usage}

doctor options:
${parser.commands['doctor']!.usage}

plan options:
${parser.commands['plan']!.usage}

prepare options:
${parser.commands['prepare']!.usage}
''';

String _configPath(ArgResults results) {
  final directory = results.option('directory')!;
  return results.option('config') ?? p.join(directory, 'release.yaml');
}

/// Loads the workspace and configuration, returning diagnostics on failure.
({Workspace? workspace, ReleaseConfig? config, List<Diagnostic> diagnostics})
_loadInputs(ArgResults results) {
  final diagnostics = <Diagnostic>[];
  final (workspace, workspaceDiagnostics) = WorkspaceLoader(
    results.option('directory')!,
  ).load();
  diagnostics.addAll(workspaceDiagnostics);
  final (config, configDiagnostics) = loadReleaseConfig(_configPath(results));
  diagnostics.addAll(configDiagnostics);
  return (workspace: workspace, config: config, diagnostics: diagnostics);
}

int _doctor(
  ArgResults results, {
  required StringSink out,
  required StringSink err,
}) {
  final inputs = _loadInputs(results);
  final diagnostics = [...inputs.diagnostics];
  final workspace = inputs.workspace;
  final config = inputs.config;

  if (workspace != null && config != null) {
    diagnostics.addAll(
      validateConfiguration(workspace: workspace, config: config),
    );
  }

  final sorted = diagnostics.sorted();
  if (results.flag('json')) {
    out.write(
      _jsonDocument({
        'schemaVersion': ReleasePlan.schemaVersion,
        'toolkitVersion': toolkitVersion,
        'workspace': workspace == null
            ? null
            : {
                'root': workspace.rootName,
                'packages': [
                  for (final package in workspace.packages)
                    {
                      'name': package.name,
                      'path': package.path,
                      'version': package.version?.toString(),
                      'private': package.isPrivate,
                      'flutter': package.usesFlutter,
                      'declared': config?.rule(package.name) != null,
                      'publish': config?.rule(package.name)?.publish ?? false,
                      'group': config?.groupOf(package.name)?.name,
                    },
                ],
              },
        'diagnostics': [for (final d in sorted) d.toJson()],
        'ok': !sorted.hasErrors,
      }),
    );
  } else {
    if (workspace != null) {
      out.writeln(
        'Workspace "${workspace.rootName}" '
        '(${workspace.packages.length} package'
        '${workspace.packages.length == 1 ? '' : 's'})',
      );
      for (final package in workspace.packages) {
        final rule = config?.rule(package.name);
        final group = config?.groupOf(package.name);
        final labels = [
          package.version?.toString() ?? 'no version',
          if (package.isPrivate) 'private',
          if (package.usesFlutter) 'flutter',
          if (rule == null)
            'undeclared'
          else if (rule.publish)
            'publish'
          else
            'version only',
          if (group != null) 'group:${group.name}',
        ];
        out.writeln(
          '  ${package.name}  ${package.path}  '
          '[${labels.join(', ')}]',
        );
      }
    }
    if (sorted.isEmpty) {
      out.writeln('No problems found.');
    } else {
      out.writeln('Diagnostics:');
      for (final diagnostic in sorted) {
        (diagnostic.severity == DiagnosticSeverity.error ? err : out).writeln(
          '  $diagnostic',
        );
      }
    }
  }
  return sorted.hasErrors ? ExitCodes.diagnosticsFailed : ExitCodes.ok;
}

int _plan(
  ArgResults results, {
  required StringSink out,
  required StringSink err,
}) {
  final inputs = _loadInputs(results);
  final workspace = inputs.workspace;
  final config = inputs.config;
  if (workspace == null || config == null) {
    for (final diagnostic in inputs.diagnostics.sorted()) {
      err.writeln('  $diagnostic');
    }
    return ExitCodes.diagnosticsFailed;
  }

  final usageErrors = <String>[];
  final bumps = <String, BumpLevel>{};
  for (final entry in results.multiOption('bump')) {
    final (name, value) = _split(entry, usageErrors, '--bump');
    if (name == null) continue;
    final level = BumpLevel.parse(value!);
    if (level == null) {
      usageErrors.add('Unknown bump level "$value" in --bump $entry.');
      continue;
    }
    bumps[name] = level.max(bumps[name] ?? BumpLevel.none);
  }

  final overrides = <String, Version>{};
  for (final entry in results.multiOption('set-version')) {
    final (name, value) = _split(entry, usageErrors, '--set-version');
    if (name == null) continue;
    final version = _tryVersion(value!);
    if (version == null) {
      usageErrors.add('Invalid version "$value" in --set-version $entry.');
      continue;
    }
    overrides[name] = version;
  }

  final published = <String, Set<Version>>{};
  for (final entry in results.multiOption('published')) {
    final (name, value) = _split(entry, usageErrors, '--published');
    if (name == null) continue;
    final version = _tryVersion(value!);
    if (version == null) {
      usageErrors.add('Invalid version "$value" in --published $entry.');
      continue;
    }
    (published[name] ??= {}).add(version);
  }

  if (usageErrors.isNotEmpty) {
    for (final message in usageErrors) {
      err.writeln(message);
    }
    return ExitCodes.usage;
  }

  final plan = planRelease(
    workspace: workspace,
    config: config,
    request: ReleaseRequest(
      channel: ReleaseChannel.parse(results.option('channel')!)!,
      bumps: bumps,
      versionOverrides: overrides,
      source: PlanSource(
        repository: results.option('source-repository'),
        ref: results.option('source-ref'),
        revision: results.option('source-revision'),
      ),
    ),
    remote: RemoteState(
      existingTags: results.multiOption('existing-tag').toSet(),
      publishedVersions: published,
    ),
  );

  final loadDiagnostics = inputs.diagnostics.sorted();
  if (results.flag('json')) {
    out.write(plan.toJsonString());
  } else {
    for (final diagnostic in loadDiagnostics) {
      out.writeln('  $diagnostic');
    }
    out.write(plan.toReport());
  }
  return plan.hasErrors || loadDiagnostics.hasErrors
      ? ExitCodes.diagnosticsFailed
      : ExitCodes.ok;
}

int _prepare(
  ArgResults results, {
  required StringSink out,
  required StringSink err,
}) {
  final result = prepareRelease(
    planPath: results.option('plan')!,
    sourceDirectory: results.option('directory')!,
    outputDirectory: results.option('output')!,
  );
  if (results.flag('json')) {
    out.write(result.toJsonString());
  } else {
    out.write(result.toReport());
  }
  return result.success ? ExitCodes.ok : ExitCodes.diagnosticsFailed;
}

(String?, String?) _split(String entry, List<String> errors, String flag) {
  final index = entry.indexOf(':');
  if (index <= 0 || index == entry.length - 1) {
    errors.add('Expected <package>:<value> for $flag, got "$entry".');
    return (null, null);
  }
  return (entry.substring(0, index), entry.substring(index + 1));
}

Version? _tryVersion(String value) {
  try {
    return Version.parse(value);
  } on FormatException {
    return null;
  }
}

String _jsonDocument(Map<String, Object?> value) =>
    '${const JsonEncoder.withIndent('  ').convert(value)}\n';
