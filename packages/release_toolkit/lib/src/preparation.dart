import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:yaml/yaml.dart';
import 'package:yaml_edit/yaml_edit.dart';

import 'config.dart';
import 'diagnostics.dart';
import 'loader.dart';
import 'plan.dart';
import 'planner.dart';
import 'version.dart';
import 'workspace.dart';

/// One file in a prepared release diff and the approved reasons it changed.
class PreparationChangedFile implements Comparable<PreparationChangedFile> {
  PreparationChangedFile({
    required this.path,
    required Iterable<String> reasons,
  }) : reasons = List.unmodifiable(<String>{...reasons}.toList()..sort());

  final String path;
  final List<String> reasons;

  Map<String, Object?> toJson() => {'path': path, 'reasons': reasons};

  @override
  int compareTo(PreparationChangedFile other) => path.compareTo(other.path);
}

/// Result of preparing an approved release plan in an isolated checkout.
class PreparationResult {
  PreparationResult({
    required this.success,
    required this.usable,
    required this.preparedDirectory,
    required this.sourceRevision,
    required this.melosVersion,
    required Iterable<PreparationChangedFile> changedFiles,
    required Iterable<Diagnostic> diagnostics,
  }) : changedFiles = List.unmodifiable(
         <PreparationChangedFile>[...changedFiles]..sort(),
       ),
       diagnostics = List.unmodifiable(<Diagnostic>[...diagnostics]..sort());

  final bool success;
  final bool usable;
  final String preparedDirectory;
  final String? sourceRevision;
  final String? melosVersion;
  final List<PreparationChangedFile> changedFiles;
  final List<Diagnostic> diagnostics;

  Map<String, Object?> toJson() => {
    'schemaVersion': 1,
    'toolkitVersion': toolkitVersion,
    'status': success ? 'success' : 'failure',
    'usable': usable,
    'preparedDirectory': preparedDirectory,
    if (sourceRevision != null) 'sourceRevision': sourceRevision,
    if (melosVersion != null) 'melosVersion': melosVersion,
    'changedFiles': [for (final file in changedFiles) file.toJson()],
    'diagnostics': [for (final diagnostic in diagnostics) diagnostic.toJson()],
  };

  String toJsonString() =>
      '${const JsonEncoder.withIndent('  ').convert(toJson())}\n';

  String toReport() {
    final buffer = StringBuffer()
      ..writeln(
        success
            ? 'Release preparation succeeded.'
            : 'Release preparation failed.',
      )
      ..writeln('Prepared directory: $preparedDirectory');
    if (sourceRevision != null) {
      buffer.writeln('Source revision: $sourceRevision');
    }
    if (melosVersion != null) buffer.writeln('Melos: $melosVersion');
    if (changedFiles.isNotEmpty) {
      buffer.writeln('Changed files:');
      for (final file in changedFiles) {
        buffer.writeln('  ${file.path}: ${file.reasons.join('; ')}');
      }
    }
    if (diagnostics.isNotEmpty) {
      buffer.writeln('Diagnostics:');
      for (final diagnostic in diagnostics) {
        buffer.writeln('  $diagnostic');
      }
    }
    if (!usable) {
      buffer.writeln('The isolated checkout is marked unusable for release.');
    }
    return buffer.toString();
  }
}

const _supportedMelosVersions = {'7.8.1'};
const _unusableMarker = '.release_toolkit_unusable.json';

class _PlanUpdate implements Comparable<_PlanUpdate> {
  const _PlanUpdate({
    required this.package,
    required this.path,
    required this.dependency,
    required this.section,
    required this.from,
    required this.to,
  });

  final String package;
  final String path;
  final String dependency;
  final String section;
  final String from;
  final String to;

  String get key => '$package\u0000$section\u0000$dependency';

  @override
  int compareTo(_PlanUpdate other) => key.compareTo(other.key);
}

class _PlanTarget implements Comparable<_PlanTarget> {
  _PlanTarget({
    required this.package,
    required this.path,
    required this.action,
    required this.currentVersion,
    required this.proposedVersion,
    required this.group,
    required this.tag,
    required this.stage,
    required this.updates,
  });

  final String package;
  final String path;
  final ReleaseAction action;
  final Version currentVersion;
  final Version proposedVersion;
  final String? group;
  final String? tag;
  final int stage;
  final List<_PlanUpdate> updates;

  @override
  int compareTo(_PlanTarget other) => package.compareTo(other.package);
}

class _ApprovedPlan {
  _ApprovedPlan({
    required this.revision,
    required this.targets,
    required this.metadata,
    required this.tags,
  });

  final String revision;
  final List<_PlanTarget> targets;
  final List<PlannedTag> tags;
  final List<_PlanUpdate> metadata;

  Iterable<_PlanUpdate> get updates sync* {
    for (final target in targets) {
      yield* target.updates;
    }
    yield* metadata;
  }
}

/// Applies [planPath] only inside a new clone at [outputDirectory].
///
/// The source checkout must be clean and at the plan's full revision. Melos is
/// resolved from that repository and must be one of the exact versions this
/// toolkit has verified. This function never publishes, pushes, or creates a
/// tag.
PreparationResult prepareRelease({
  required String planPath,
  required String sourceDirectory,
  required String outputDirectory,
}) {
  final source = p.normalize(p.absolute(sourceDirectory));
  final output = p.normalize(p.absolute(outputDirectory));
  final diagnostics = <Diagnostic>[];
  final approved = _loadApprovedPlan(p.absolute(planPath), diagnostics);

  String? revision = approved?.revision;
  String? melosVersion;
  var aggregateChangelogPaths = <String>{'CHANGELOG.md'};
  var outputCreated = false;

  PreparationResult failure() {
    if (outputCreated) {
      _markUnusable(output, revision, melosVersion, diagnostics);
    }
    final changedFiles = <PreparationChangedFile>[];
    if (outputCreated && Directory(p.join(output, '.git')).existsSync()) {
      final approvedReasons = approved == null
          ? const <String, List<String>>{}
          : _approvedChangedFiles(approved, output, aggregateChangelogPaths);
      for (final path in _changedPaths(output, diagnostics)) {
        changedFiles.add(
          PreparationChangedFile(
            path: path,
            reasons:
                approvedReasons[path] ??
                [
                  path == _unusableMarker
                      ? 'marks this failed checkout as unusable'
                      : 'unexpected change in a failed preparation',
                ],
          ),
        );
      }
    }
    return PreparationResult(
      success: false,
      usable: false,
      preparedDirectory: output,
      sourceRevision: revision,
      melosVersion: melosVersion,
      changedFiles: changedFiles,
      diagnostics: diagnostics,
    );
  }

  if (approved == null) return failure();
  if (p.equals(source, output) || p.isWithin(source, output)) {
    diagnostics.add(
      Diagnostic.error(
        'output-inside-source',
        'The output directory must be outside the source checkout so creating '
            'it cannot dirty the approved source.',
        target: output,
      ),
    );
    return failure();
  }
  if (FileSystemEntity.typeSync(output, followLinks: false) !=
      FileSystemEntityType.notFound) {
    diagnostics.add(
      Diagnostic.error(
        'output-exists',
        'The preparation output must not already exist.',
        target: output,
      ),
    );
    return failure();
  }
  if (FileSystemEntity.typeSync(
        p.join(source, _unusableMarker),
        followLinks: false,
      ) !=
      FileSystemEntityType.notFound) {
    diagnostics.add(
      Diagnostic.error(
        'reserved-marker-exists',
        'The source contains the reserved preparation failure marker.',
        target: _unusableMarker,
      ),
    );
    return failure();
  }

  final sourceHead = _git(source, ['rev-parse', 'HEAD']);
  if (!sourceHead.succeeded) {
    diagnostics.add(
      Diagnostic.error(
        'source-not-git-checkout',
        'Cannot resolve the source Git revision: ${sourceHead.details}',
        target: source,
      ),
    );
    return failure();
  }
  if (sourceHead.stdout.trim() != approved.revision) {
    diagnostics.add(
      Diagnostic.error(
        'source-revision-mismatch',
        'The source is at ${sourceHead.stdout.trim()}, but the plan records '
            '${approved.revision}. Check out the approved revision first.',
        target: source,
      ),
    );
    return failure();
  }
  final sourceStatus = _git(source, [
    'status',
    '--porcelain',
    '--untracked-files=all',
  ]);
  if (!sourceStatus.succeeded || sourceStatus.stdout.trim().isNotEmpty) {
    diagnostics.add(
      Diagnostic.error(
        'source-not-clean',
        'The source checkout must have no tracked or untracked changes.',
        target: source,
      ),
    );
    return failure();
  }
  final sourceTags = _git(source, ['tag', '--list']);

  final clone = _process('git', [
    'clone',
    '--no-hardlinks',
    '--quiet',
    source,
    output,
  ]);
  outputCreated = Directory(output).existsSync();
  if (!clone.succeeded) {
    diagnostics.add(
      Diagnostic.error(
        'isolated-checkout-failed',
        'Git could not create the isolated checkout: ${clone.details}',
        target: output,
      ),
    );
    return failure();
  }

  final cloneHead = _git(output, ['rev-parse', 'HEAD']);
  if (!cloneHead.succeeded || cloneHead.stdout.trim() != approved.revision) {
    diagnostics.add(
      Diagnostic.error(
        'isolated-revision-mismatch',
        'The isolated checkout was not created at ${approved.revision}.',
        target: output,
      ),
    );
    return failure();
  }

  final initialHead = cloneHead.stdout.trim();
  final initialTags = _git(output, ['tag', '--list']);
  final melos = _process('dart', ['run', 'melos', '--version'], cwd: output);
  if (!melos.succeeded) {
    diagnostics.add(
      Diagnostic.error(
        'melos-not-resolved',
        'Run `dart pub get` in the source repository and declare Melos as a '
            'repository dependency. Resolution failed: ${melos.details}',
        target: p.join(output, 'pubspec.yaml'),
      ),
    );
    return failure();
  }
  melosVersion = _extractVersion(melos.stdout);
  if (melosVersion == null || !_supportedMelosVersions.contains(melosVersion)) {
    diagnostics.add(
      Diagnostic.error(
        'melos-version-unsupported',
        'Resolved Melos ${melosVersion ?? '(unknown)'}. Supported exact '
            'versions: ${_supportedMelosVersions.join(', ')}.',
        target: p.join(output, 'pubspec.yaml'),
      ),
    );
    return failure();
  }

  final resolutionStatus = _git(output, [
    'status',
    '--porcelain',
    '--untracked-files=all',
  ]);
  if (!resolutionStatus.succeeded ||
      resolutionStatus.stdout.trim().isNotEmpty) {
    diagnostics.add(
      Diagnostic.error(
        'repository-resolution-changed-files',
        'Resolving repository Melos changed tracked or untracked files. Run '
            '`dart pub get`, review the result, and commit required lockfiles '
            'before preparing.',
        target: output,
      ),
    );
    return failure();
  }

  aggregateChangelogPaths = _validateMelosConfiguration(output, diagnostics);
  if (diagnostics.hasErrors) return failure();

  final inputs = _loadPreparationInputs(output, diagnostics);
  if (inputs == null) return failure();
  _revalidatePlan(approved, inputs.workspace, inputs.config, diagnostics);
  if (diagnostics.hasErrors) return failure();

  final melosList = _process('dart', [
    'run',
    'melos',
    'list',
    '--json',
  ], cwd: output);
  final melosPackages = _melosPackageNames(melosList, diagnostics);
  if (melosPackages == null) return failure();
  for (final target in approved.targets) {
    if (!melosPackages.contains(target.package)) {
      diagnostics.add(
        Diagnostic.error(
          'package-excluded-by-melos',
          'Selected package "${target.package}" is excluded by Melos. Check '
              'workspace membership, ignore rules, and useRootAsPackage for a '
              'root package.',
          target: target.package,
        ),
      );
    }
  }
  if (diagnostics.hasErrors) return failure();
  _validateWriteTargets(output, approved, aggregateChangelogPaths, diagnostics);
  if (diagnostics.hasErrors) return failure();

  final baselinePubspecs = <String, String>{};
  final baselineChangelogs = <String, String>{};
  for (final package in inputs.workspace.packages) {
    final pubspecPath = _packageFile(output, package.path, 'pubspec.yaml');
    baselinePubspecs[package.name] = File(pubspecPath).readAsStringSync();
    final changelogPath = _packageFile(output, package.path, 'CHANGELOG.md');
    final changelog = File(changelogPath);
    if (changelog.existsSync()) {
      baselineChangelogs[_relative(output, changelogPath)] = changelog
          .readAsStringSync();
    }
  }
  for (final relative in aggregateChangelogPaths) {
    final changelog = File(p.join(output, p.joinAll(p.posix.split(relative))));
    if (changelog.existsSync()) {
      baselineChangelogs[relative] = changelog.readAsStringSync();
    }
  }

  if (approved.targets.isNotEmpty) {
    final arguments = <String>[
      'run',
      'melos',
      'version',
      for (final target in approved.targets) ...[
        '--manual-version',
        '${target.package}:${target.proposedVersion}',
      ],
      for (final target in approved.targets) ...['--scope', target.package],
      if (approved.targets.any(
        (target) => target.action == ReleaseAction.versionOnly,
      ))
        '--all',
      '--changelog',
      '--no-dependent-constraints',
      '--no-dependent-versions',
      '--no-git-tag-version',
      '--no-git-commit-version',
      '--no-release-url',
      '--yes',
    ];
    final version = _process('dart', arguments, cwd: output);
    if (!version.succeeded) {
      diagnostics.add(
        Diagnostic.error(
          'melos-version-failed',
          'Melos 7.8.1 could not apply the approved explicit versions: '
              '${version.details}',
          target: output,
        ),
      );
      return failure();
    }
    _normalizeAggregateChangelogDates(
      output,
      aggregateChangelogPaths,
      approved.revision,
      diagnostics,
    );
    if (diagnostics.hasErrors) return failure();
  }

  for (final update in approved.updates.toList()..sort()) {
    final path = _packageFile(output, update.path, 'pubspec.yaml');
    try {
      _applyDependencyUpdate(path, update);
    } on Object catch (error) {
      diagnostics.add(
        Diagnostic.error(
          'dependency-edit-failed',
          'Could not apply ${update.section}.${update.dependency}: $error',
          target: update.package,
        ),
      );
      return failure();
    }
  }

  final expectedPubspecs = <String, String>{};
  for (final package in inputs.workspace.packages) {
    final editor = YamlEditor(baselinePubspecs[package.name]!);
    final target = approved.targets
        .where((t) => t.package == package.name)
        .firstOrNull;
    if (target != null) {
      editor.update(['version'], target.proposedVersion.toString());
    }
    for (final update
        in approved.updates.where((u) => u.package == package.name).toList()
          ..sort()) {
      _updateDependencyEditor(editor, update);
    }
    expectedPubspecs[package.name] = editor.toString();
  }

  for (final package in inputs.workspace.packages) {
    final path = _packageFile(output, package.path, 'pubspec.yaml');
    final actual = File(path).readAsStringSync();
    if (actual != expectedPubspecs[package.name]) {
      diagnostics.add(
        Diagnostic.error(
          'unexpected-pubspec-edit',
          'The pubspec differs from the exact planned version and dependency '
              'edits. A Melos hook or tool changed additional YAML.',
          target: package.name,
        ),
      );
    }
  }

  for (final target in approved.targets) {
    final changelogPath = _packageFile(output, target.path, 'CHANGELOG.md');
    final relative = _relative(output, changelogPath);
    final file = File(changelogPath);
    if (!file.existsSync() ||
        !file.readAsStringSync().contains(target.proposedVersion.toString())) {
      diagnostics.add(
        Diagnostic.error(
          'missing-changelog-entry',
          'Melos did not generate a changelog entry for the approved version '
              '${target.proposedVersion}.',
          target: target.package,
        ),
      );
      continue;
    }
    final historical = baselineChangelogs[relative];
    if (historical != null && !file.readAsStringSync().endsWith(historical)) {
      diagnostics.add(
        Diagnostic.error(
          'historical-changelog-changed',
          'Existing changelog content was changed instead of being preserved.',
          target: relative,
        ),
      );
    }
  }
  for (final entry in baselineChangelogs.entries) {
    final file = File(p.join(output, p.joinAll(p.posix.split(entry.key))));
    if (file.existsSync() &&
        approved.targets.every(
          (target) =>
              _relative(
                output,
                _packageFile(output, target.path, 'CHANGELOG.md'),
              ) !=
              entry.key,
        ) &&
        !aggregateChangelogPaths.contains(entry.key) &&
        file.readAsStringSync() != entry.value) {
      diagnostics.add(
        Diagnostic.error(
          'historical-changelog-changed',
          'An unrelated changelog was modified.',
          target: entry.key,
        ),
      );
    }
  }
  for (final relative in aggregateChangelogPaths) {
    final historical = baselineChangelogs[relative];
    if (historical == null) continue;
    final changelog = File(p.join(output, p.joinAll(p.posix.split(relative))));
    if (!changelog.existsSync() ||
        !changelog.readAsStringSync().endsWith(historical)) {
      diagnostics.add(
        Diagnostic.error(
          'historical-changelog-changed',
          'Existing aggregate changelog content was changed instead of being '
              'preserved.',
          target: relative,
        ),
      );
    }
  }

  final finalInputs = _loadPreparationInputs(output, diagnostics);
  if (finalInputs != null) {
    _verifyFinalWorkspace(
      approved,
      inputs.workspace,
      finalInputs.workspace,
      diagnostics,
    );
  }

  final changedPaths = _changedPaths(output, diagnostics);
  final reasons = _approvedChangedFiles(
    approved,
    output,
    aggregateChangelogPaths,
  );
  final allowedPaths = reasons.keys.toSet();
  for (final path in changedPaths) {
    if (!allowedPaths.contains(path)) {
      diagnostics.add(
        Diagnostic.error(
          'unexpected-file-change',
          'Preparation changed a file outside the approved release diff.',
          target: path,
        ),
      );
    }
  }
  for (final path in reasons.keys) {
    if (!changedPaths.contains(path) &&
        !aggregateChangelogPaths.contains(path)) {
      diagnostics.add(
        Diagnostic.error(
          'expected-file-unchanged',
          'An approved release file was not changed.',
          target: path,
        ),
      );
    }
  }

  final finalHead = _git(output, ['rev-parse', 'HEAD']);
  final finalTags = _git(output, ['tag', '--list']);
  if (!finalHead.succeeded || finalHead.stdout.trim() != initialHead) {
    diagnostics.add(
      Diagnostic.error(
        'unexpected-release-commit',
        'Preparation created or moved a commit.',
        target: output,
      ),
    );
  }
  if (!initialTags.succeeded ||
      !finalTags.succeeded ||
      initialTags.stdout != finalTags.stdout) {
    diagnostics.add(
      Diagnostic.error(
        'unexpected-release-tag',
        'Preparation created, removed, or moved a Git tag.',
        target: output,
      ),
    );
  }

  final sourceHeadAfter = _git(source, ['rev-parse', 'HEAD']);
  final sourceStatusAfter = _git(source, [
    'status',
    '--porcelain',
    '--untracked-files=all',
  ]);
  final sourceTagsAfter = _git(source, ['tag', '--list']);
  if (!sourceHeadAfter.succeeded ||
      sourceHeadAfter.stdout != sourceHead.stdout ||
      !sourceStatusAfter.succeeded ||
      sourceStatusAfter.stdout.trim().isNotEmpty ||
      !sourceTags.succeeded ||
      !sourceTagsAfter.succeeded ||
      sourceTags.stdout != sourceTagsAfter.stdout) {
    diagnostics.add(
      Diagnostic.error(
        'source-checkout-changed',
        'The original checkout changed during isolated preparation.',
        target: source,
      ),
    );
  }

  if (diagnostics.hasErrors) return failure();
  return PreparationResult(
    success: true,
    usable: true,
    preparedDirectory: output,
    sourceRevision: approved.revision,
    melosVersion: melosVersion,
    changedFiles: [
      for (final path in changedPaths)
        PreparationChangedFile(path: path, reasons: reasons[path] ?? const []),
    ],
    diagnostics: diagnostics,
  );
}

_ApprovedPlan? _loadApprovedPlan(String path, List<Diagnostic> diagnostics) {
  final file = File(path);
  if (!file.existsSync()) {
    diagnostics.add(
      Diagnostic.error(
        'plan-not-found',
        'No release plan exists at this path.',
        target: path,
      ),
    );
    return null;
  }
  try {
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! Map<String, Object?>) {
      throw const FormatException(
        'The top-level JSON value must be an object.',
      );
    }
    if (decoded['schemaVersion'] != ReleasePlan.schemaVersion) {
      throw FormatException(
        'Unsupported plan schema ${decoded['schemaVersion']}; expected ${ReleasePlan.schemaVersion}.',
      );
    }
    if (decoded['toolkitVersion'] != toolkitVersion) {
      throw FormatException(
        'Plan toolkit version ${decoded['toolkitVersion']} is unsupported; expected $toolkitVersion.',
      );
    }
    final channel = _string(decoded['channel'], 'channel');
    if (ReleaseChannel.parse(channel) == null) {
      throw FormatException('Unsupported release channel "$channel".');
    }
    final source = _map(decoded['source'], 'source');
    final revision = _string(source['revision'], 'source.revision');
    if (!RegExp(r'^[0-9a-fA-F]{40}([0-9a-fA-F]{24})?$').hasMatch(revision)) {
      throw const FormatException(
        'source.revision must be a full Git object ID.',
      );
    }
    final planDiagnostics = _list(decoded['diagnostics'], 'diagnostics');
    for (final (index, value) in planDiagnostics.indexed) {
      final diagnostic = _map(value, 'diagnostics[$index]');
      final severity = _string(
        diagnostic['severity'],
        'diagnostics[$index].severity',
      );
      if (!DiagnosticSeverity.values.any((value) => value.name == severity)) {
        throw FormatException('Unsupported diagnostic severity "$severity".');
      }
      _string(diagnostic['code'], 'diagnostics[$index].code');
      _string(diagnostic['message'], 'diagnostics[$index].message');
      if (severity == DiagnosticSeverity.error.name) {
        throw const FormatException(
          'The release plan contains error diagnostics.',
        );
      }
    }

    final targets = <_PlanTarget>[];
    final packageNames = <String>{};
    for (final (index, value) in _list(
      decoded['releases'],
      'releases',
    ).indexed) {
      final map = _map(value, 'releases[$index]');
      final package = _string(map['package'], 'releases[$index].package');
      if (!packageNames.add(package)) {
        throw FormatException('Package "$package" appears more than once.');
      }
      final packagePath = _safePath(map['path'], 'releases[$index].path');
      final actionValue = _string(map['action'], 'releases[$index].action');
      final action = switch (actionValue) {
        'publish' => ReleaseAction.publish,
        'version-only' => ReleaseAction.versionOnly,
        _ => throw FormatException(
          'Unsupported release action "$actionValue".',
        ),
      };
      final current = Version.parse(
        _string(map['currentVersion'], 'releases[$index].currentVersion'),
      );
      final proposed = Version.parse(
        _string(map['proposedVersion'], 'releases[$index].proposedVersion'),
      );
      if (proposed <= current) {
        throw FormatException(
          'Package "$package" does not move to a higher version.',
        );
      }
      final updates = _parseUpdates(
        package,
        packagePath,
        _list(map['dependencyUpdates'], 'releases[$index].dependencyUpdates'),
      );
      targets.add(
        _PlanTarget(
          package: package,
          path: packagePath,
          action: action,
          currentVersion: current,
          proposedVersion: proposed,
          group: _optionalString(map['group'], 'releases[$index].group'),
          tag: _optionalString(map['tag'], 'releases[$index].tag'),
          stage: _int(map['stage'], 'releases[$index].stage'),
          updates: updates,
        ),
      );
    }
    targets.sort();
    if (decoded['noop'] != targets.isEmpty) {
      throw const FormatException('noop must mean that releases is empty.');
    }

    final metadata = <_PlanUpdate>[];
    for (final (index, value) in _list(
      decoded['metadataUpdates'],
      'metadataUpdates',
    ).indexed) {
      final map = _map(value, 'metadataUpdates[$index]');
      final package = _string(
        map['package'],
        'metadataUpdates[$index].package',
      );
      final packagePath = _safePath(
        map['path'],
        'metadataUpdates[$index].path',
      );
      metadata.add(
        _parseUpdate(package, packagePath, map, 'metadataUpdates[$index]'),
      );
    }
    metadata.sort();
    final updateKeys = <String>{};
    for (final update in [
      ...targets.expand((target) => target.updates),
      ...metadata,
    ]) {
      if (!updateKeys.add(update.key)) {
        throw FormatException(
          'Dependency ${update.section}.${update.dependency} for '
          '${update.package} appears more than once.',
        );
      }
    }

    final tags = <PlannedTag>[];
    for (final (index, value) in _list(decoded['tags'], 'tags').indexed) {
      final map = _map(value, 'tags[$index]');
      tags.add(
        PlannedTag(
          tag: _string(map['tag'], 'tags[$index].tag'),
          packages: _list(
            map['packages'],
            'tags[$index].packages',
          ).map((value) => _string(value, 'tags[$index].packages[]')).toList(),
        ),
      );
    }
    tags.sort();
    return _ApprovedPlan(
      revision: revision.toLowerCase(),
      targets: targets,
      metadata: metadata,
      tags: tags,
    );
  } on Object catch (error) {
    diagnostics.add(
      Diagnostic.error(
        'plan-invalid',
        'The plan is not a valid supported release plan: $error',
        target: path,
      ),
    );
    return null;
  }
}

List<_PlanUpdate> _parseUpdates(
  String package,
  String packagePath,
  List<Object?> values,
) => [
  for (final (index, value) in values.indexed)
    _parseUpdate(
      package,
      packagePath,
      _map(value, 'dependencyUpdates[$index]'),
      'dependencyUpdates[$index]',
    ),
]..sort();

_PlanUpdate _parseUpdate(
  String package,
  String packagePath,
  Map<String, Object?> map,
  String origin,
) {
  final section = _string(map['section'], '$origin.section');
  if (section != 'dependencies' && section != 'dev_dependencies') {
    throw FormatException('$origin.section must name a dependency section.');
  }
  final from = _string(map['from'], '$origin.from');
  final to = _string(map['to'], '$origin.to');
  VersionConstraint.parse(from);
  VersionConstraint.parse(to);
  return _PlanUpdate(
    package: package,
    path: packagePath,
    dependency: _string(map['dependency'], '$origin.dependency'),
    section: section,
    from: from,
    to: to,
  );
}

({Workspace workspace, ReleaseConfig config})? _loadPreparationInputs(
  String root,
  List<Diagnostic> diagnostics,
) {
  final (workspace, workspaceDiagnostics) = WorkspaceLoader(root).load();
  diagnostics.addAll(workspaceDiagnostics);
  final (config, configDiagnostics) = loadReleaseConfig(
    p.join(root, 'release.yaml'),
  );
  diagnostics.addAll(configDiagnostics);
  if (workspace == null || config == null) return null;
  diagnostics.addAll(
    validateConfiguration(workspace: workspace, config: config),
  );
  return diagnostics.hasErrors ? null : (workspace: workspace, config: config);
}

void _revalidatePlan(
  _ApprovedPlan approved,
  Workspace workspace,
  ReleaseConfig config,
  List<Diagnostic> diagnostics,
) {
  for (final target in approved.targets) {
    final manifest = workspace[target.package];
    if (manifest == null || manifest.path != target.path) {
      diagnostics.add(
        Diagnostic.error(
          'stale-plan-package',
          'Package path no longer matches the approved plan.',
          target: target.package,
        ),
      );
      continue;
    }
    if (manifest.version != target.currentVersion) {
      diagnostics.add(
        Diagnostic.error(
          'stale-plan-version',
          'Current version ${manifest.version} does not match the plan value '
              '${target.currentVersion}.',
          target: target.package,
        ),
      );
    }
    final publishable =
        config.rule(target.package)?.publish == true && !manifest.isPrivate;
    final expectedAction = publishable
        ? ReleaseAction.publish
        : ReleaseAction.versionOnly;
    if (target.action != expectedAction) {
      diagnostics.add(
        Diagnostic.error(
          'stale-plan-action',
          'Release authorization no longer matches release.yaml and pubspec.yaml.',
          target: target.package,
        ),
      );
    }
  }
  for (final update in approved.updates) {
    final manifest = workspace[update.package];
    final section = update.section == 'dependencies'
        ? DependencySection.dependencies
        : DependencySection.devDependencies;
    final edge = manifest?.dependencies
        .where(
          (edge) => edge.name == update.dependency && edge.section == section,
        )
        .firstOrNull;
    if (manifest == null ||
        manifest.path != update.path ||
        edge?.rawConstraint != update.from) {
      diagnostics.add(
        Diagnostic.error(
          'stale-plan-dependency',
          'The dependency input no longer equals the approved "${update.from}".',
          target: '${update.package}:${update.section}.${update.dependency}',
        ),
      );
    }
  }
  if (diagnostics.hasErrors) return;

  final regenerated = planRelease(
    workspace: workspace,
    config: config,
    request: ReleaseRequest(
      versionOverrides: {
        for (final target in approved.targets)
          target.package: target.proposedVersion,
      },
      source: PlanSource(revision: approved.revision),
    ),
  );
  if (regenerated.hasErrors) {
    diagnostics.add(
      const Diagnostic.error(
        'plan-revalidation-failed',
        'The approved operations no longer produce an error-free plan in the '
            'isolated checkout.',
      ),
    );
    diagnostics.addAll(
      regenerated.diagnostics.where(
        (diagnostic) => diagnostic.severity == DiagnosticSeverity.error,
      ),
    );
    return;
  }

  final generatedTargets = {
    for (final target in regenerated.releases) target.package: target,
  };
  final generatedMetadata = <String, DependencyUpdate>{
    for (final update in regenerated.metadata)
      '${update.package}\u0000${update.update.section}\u0000${update.update.dependency}':
          update.update,
  };
  var mismatch =
      generatedTargets.length != approved.targets.length ||
      generatedMetadata.length != approved.metadata.length;
  for (final target in approved.targets) {
    final generated = generatedTargets[target.package];
    final updates = {
      for (final update
          in generated?.dependencyUpdates ?? const <DependencyUpdate>[])
        '${update.section}\u0000${update.dependency}':
            '${update.from}\u0000${update.to}',
    };
    mismatch =
        mismatch ||
        generated == null ||
        generated.proposedVersion != target.proposedVersion ||
        generated.action != target.action ||
        generated.group != target.group ||
        generated.tag != target.tag ||
        generated.stage != target.stage ||
        updates.length != target.updates.length ||
        target.updates.any(
          (update) =>
              updates['${update.section}\u0000${update.dependency}'] !=
              '${update.from}\u0000${update.to}',
        );
  }
  for (final update in approved.metadata) {
    final generated = generatedMetadata[update.key];
    mismatch =
        mismatch ||
        generated == null ||
        generated.from != update.from ||
        generated.to != update.to;
  }
  final generatedTags =
      regenerated.tags.map((tag) => jsonEncode(tag.toJson())).toList()..sort();
  final approvedTags =
      approved.tags.map((tag) => jsonEncode(tag.toJson())).toList()..sort();
  mismatch = mismatch || jsonEncode(generatedTags) != jsonEncode(approvedTags);
  if (mismatch) {
    diagnostics.add(
      const Diagnostic.error(
        'plan-operations-mismatch',
        'Package selection, versions, dependency edits, tags, or publication '
            'stages no longer match the approved plan.',
      ),
    );
  }
}

Set<String> _validateMelosConfiguration(
  String root,
  List<Diagnostic> diagnostics,
) {
  final document = loadYaml(
    File(p.join(root, 'pubspec.yaml')).readAsStringSync(),
  );
  if (document is! YamlMap) return {'CHANGELOG.md'};
  final melos = document['melos'];
  if (melos == null) return {'CHANGELOG.md'};
  if (melos is! YamlMap) {
    diagnostics.add(
      const Diagnostic.error(
        'melos-configuration-invalid',
        'The root pubspec melos configuration must be a YAML map.',
        target: 'pubspec.yaml#melos',
      ),
    );
    return {'CHANGELOG.md'};
  }
  final versioning = melos['versioning'];
  final fixed =
      versioning == 'fixed' ||
      (versioning is YamlMap && versioning['mode'] == 'fixed');
  if (fixed) {
    diagnostics.add(
      const Diagnostic.error(
        'melos-fixed-versioning-conflict',
        'Melos fixed versioning conflicts with the package selection and exact '
            'versions owned by the approved release plan.',
        target: 'pubspec.yaml#melos.versioning',
      ),
    );
  }
  final command = melos['command'];
  final version = command is YamlMap ? command['version'] : null;
  final hooks = version is YamlMap ? version['hooks'] : null;
  if (hooks is YamlMap && hooks.isNotEmpty) {
    diagnostics.add(
      const Diagnostic.error(
        'melos-version-hooks-unsupported',
        'Melos version lifecycle hooks are not allowed during isolated '
            'preparation because arbitrary hook commands could write outside '
            'the reviewable release diff or contact a remote system.',
        target: 'pubspec.yaml#melos.command.version.hooks',
      ),
    );
  }
  final changelogFormat = version is YamlMap
      ? version['changelogFormat']
      : null;
  if (changelogFormat is YamlMap && changelogFormat['includeDate'] == true) {
    diagnostics.add(
      const Diagnostic.error(
        'melos-date-changelog-conflict',
        'Package changelog dates derived from the wall clock would make '
            'repeated preparation non-deterministic. Disable '
            'melos.command.version.changelogFormat.includeDate.',
        target:
            'pubspec.yaml#melos.command.version.changelogFormat.includeDate',
      ),
    );
  }
  final changelogPaths = <String>{};
  if (version is! YamlMap || version['workspaceChangelog'] != false) {
    changelogPaths.add('CHANGELOG.md');
  }
  final changelogs = version is YamlMap ? version['changelogs'] : null;
  if (changelogs is YamlList) {
    for (final (index, value) in changelogs.indexed) {
      final path = value is YamlMap ? value['path'] : null;
      if (path is! String || !_isSafeRepositoryPath(path) || path == '.') {
        diagnostics.add(
          Diagnostic.error(
            'melos-changelog-path-unsafe',
            'Aggregate changelog paths must be normalized relative paths '
                'inside the isolated checkout.',
            target: 'pubspec.yaml#melos.command.version.changelogs[$index]',
          ),
        );
        continue;
      }
      changelogPaths.add(path);
    }
  }
  return changelogPaths;
}

Set<String>? _melosPackageNames(
  _ProcessOutput result,
  List<Diagnostic> diagnostics,
) {
  if (!result.succeeded) {
    diagnostics.add(
      Diagnostic.error(
        'melos-list-failed',
        'Melos could not enumerate its selected workspace: ${result.details}',
      ),
    );
    return null;
  }
  try {
    final decoded = jsonDecode(result.stdout) as List<Object?>;
    return {
      for (final value in decoded)
        _string(_map(value, 'melos list entry')['name'], 'melos package name'),
    };
  } on Object catch (error) {
    diagnostics.add(
      Diagnostic.error(
        'melos-list-invalid',
        'Melos returned invalid package JSON: $error',
      ),
    );
    return null;
  }
}

void _validateWriteTargets(
  String root,
  _ApprovedPlan approved,
  Set<String> aggregateChangelogPaths,
  List<Diagnostic> diagnostics,
) {
  final targets = <String>{
    for (final target in approved.targets)
      _relative(root, _packageFile(root, target.path, 'pubspec.yaml')),
    for (final target in approved.targets)
      _relative(root, _packageFile(root, target.path, 'CHANGELOG.md')),
    for (final update in approved.updates)
      _relative(root, _packageFile(root, update.path, 'pubspec.yaml')),
    if (approved.targets.isNotEmpty) ...aggregateChangelogPaths,
  };
  for (final relative in targets) {
    var current = root;
    for (final segment in p.posix.split(relative)) {
      current = p.join(current, segment);
      if (FileSystemEntity.typeSync(current, followLinks: false) ==
          FileSystemEntityType.link) {
        diagnostics.add(
          Diagnostic.error(
            'release-write-target-symlink',
            'Preparation refuses to write through a symbolic link because it '
                'could escape the isolated checkout.',
            target: relative,
          ),
        );
        break;
      }
    }
  }
}

void _normalizeAggregateChangelogDates(
  String root,
  Set<String> changelogPaths,
  String revision,
  List<Diagnostic> diagnostics,
) {
  if (changelogPaths.isEmpty) return;
  final commitDate = _git(root, ['show', '-s', '--format=%cs', revision]);
  if (!commitDate.succeeded ||
      !RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(commitDate.stdout.trim())) {
    diagnostics.add(
      const Diagnostic.error(
        'source-commit-date-unreadable',
        'Git could not provide a stable source commit date for aggregate '
            'changelog generation.',
      ),
    );
    return;
  }
  final heading = RegExp(r'^## \d{4}-\d{2}-\d{2}$', multiLine: true);
  for (final relative in changelogPaths) {
    final file = File(p.join(root, p.joinAll(p.posix.split(relative))));
    if (!file.existsSync()) {
      diagnostics.add(
        Diagnostic.error(
          'missing-aggregate-changelog',
          'Melos did not generate the configured aggregate changelog.',
          target: relative,
        ),
      );
      continue;
    }
    final contents = file.readAsStringSync();
    if (!heading.hasMatch(contents)) {
      diagnostics.add(
        Diagnostic.error(
          'aggregate-changelog-date-missing',
          'Melos did not generate the expected dated aggregate entry.',
          target: relative,
        ),
      );
      continue;
    }
    file.writeAsStringSync(
      contents.replaceFirst(heading, '## ${commitDate.stdout.trim()}'),
    );
  }
}

void _applyDependencyUpdate(String pubspecPath, _PlanUpdate update) {
  final editor = YamlEditor(File(pubspecPath).readAsStringSync());
  _updateDependencyEditor(editor, update);
  File(pubspecPath).writeAsStringSync(editor.toString());
}

void _updateDependencyEditor(YamlEditor editor, _PlanUpdate update) {
  final document = loadYaml(editor.toString()) as YamlMap;
  final section = document[update.section] as YamlMap;
  final declaration = section[update.dependency];
  if (declaration is String) {
    if (declaration != update.from) {
      throw StateError('Expected ${update.from}, found $declaration.');
    }
    editor.update([update.section, update.dependency], update.to);
    return;
  }
  if (declaration is YamlMap && declaration['version'] == update.from) {
    editor.update([update.section, update.dependency, 'version'], update.to);
    return;
  }
  throw StateError(
    'The dependency declaration is not a supported hosted constraint.',
  );
}

void _verifyFinalWorkspace(
  _ApprovedPlan approved,
  Workspace before,
  Workspace after,
  List<Diagnostic> diagnostics,
) {
  final targets = {
    for (final target in approved.targets) target.package: target,
  };
  for (final package in after.packages) {
    final original = before[package.name];
    final expected =
        targets[package.name]?.proposedVersion ?? original?.version;
    if (original == null || package.version != expected) {
      diagnostics.add(
        Diagnostic.error(
          'unexpected-package-version',
          'Expected version $expected after preparation, found ${package.version}.',
          target: package.name,
        ),
      );
    }
  }
  final expectedUpdates = {
    for (final update in approved.updates) update.key: update.to,
  };
  for (final package in after.packages) {
    final original = before[package.name];
    if (original == null) continue;
    for (final edge in package.dependencies) {
      final key = '${package.name}\u0000${edge.section.key}\u0000${edge.name}';
      final beforeEdge = original.dependencies
          .where(
            (candidate) =>
                candidate.name == edge.name &&
                candidate.section == edge.section,
          )
          .firstOrNull;
      final expected = expectedUpdates[key] ?? beforeEdge?.rawConstraint;
      if (edge.rawConstraint != expected) {
        diagnostics.add(
          Diagnostic.error(
            'unplanned-dependency-edit',
            'Expected constraint $expected, found ${edge.rawConstraint}.',
            target: '${package.name}:${edge.section.key}.${edge.name}',
          ),
        );
      }
    }
  }
}

Map<String, List<String>> _approvedChangedFiles(
  _ApprovedPlan approved,
  String root,
  Set<String> aggregateChangelogPaths,
) {
  final reasons = <String, List<String>>{};
  void add(String path, String reason) => (reasons[path] ??= []).add(reason);
  for (final target in approved.targets) {
    add(
      _relative(root, _packageFile(root, target.path, 'pubspec.yaml')),
      'version ${target.currentVersion} -> ${target.proposedVersion}',
    );
    add(
      _relative(root, _packageFile(root, target.path, 'CHANGELOG.md')),
      'Melos conventional-commit changelog for ${target.proposedVersion}',
    );
  }
  for (final update in approved.updates) {
    add(
      _relative(root, _packageFile(root, update.path, 'pubspec.yaml')),
      '${update.section}.${update.dependency}: ${update.from} -> ${update.to}',
    );
  }
  if (approved.targets.isNotEmpty) {
    for (final path in aggregateChangelogPaths) {
      add(path, 'Melos aggregate release changelog');
    }
  }
  return reasons;
}

Set<String> _changedPaths(String root, List<Diagnostic> diagnostics) {
  final tracked = _git(root, [
    'diff',
    '--name-only',
    '-z',
    '--no-renames',
    'HEAD',
  ]);
  final untracked = _git(root, [
    'ls-files',
    '--others',
    '--exclude-standard',
    '-z',
  ]);
  if (!tracked.succeeded || !untracked.succeeded) {
    diagnostics.add(
      const Diagnostic.error(
        'release-diff-unreadable',
        'Git could not enumerate the prepared release diff.',
      ),
    );
    return const {};
  }
  return {
    ...tracked.stdout.split('\u0000').where((path) => path.isNotEmpty),
    ...untracked.stdout.split('\u0000').where((path) => path.isNotEmpty),
  };
}

void _markUnusable(
  String output,
  String? revision,
  String? melosVersion,
  List<Diagnostic> diagnostics,
) {
  try {
    final marker = File(p.join(output, _unusableMarker));
    if (FileSystemEntity.typeSync(marker.path, followLinks: false) !=
        FileSystemEntityType.notFound) {
      return;
    }
    marker.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert({
        'usable': false,
        if (revision != null) 'sourceRevision': revision,
        if (melosVersion != null) 'melosVersion': melosVersion,
        'diagnostics': [for (final diagnostic in diagnostics.sorted()) diagnostic.toJson()],
      })}\n',
    );
  } on FileSystemException {
    // The result still reports unusable when a partially-created directory is
    // not writable enough to hold the inspection marker.
  }
}

String? _extractVersion(String output) {
  final match = RegExp(
    r'^([0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?)\s*$',
    multiLine: true,
  ).firstMatch(output);
  return match?.group(1);
}

String _packageFile(String root, String packagePath, String name) =>
    packagePath == '.'
    ? p.join(root, name)
    : p.join(root, p.joinAll(p.posix.split(packagePath)), name);

String _relative(String root, String path) =>
    p.posix.joinAll(p.split(p.relative(path, from: root)));

class _ProcessOutput {
  const _ProcessOutput(this.exitCode, this.stdout, this.stderr);

  final int exitCode;
  final String stdout;
  final String stderr;

  bool get succeeded => exitCode == 0;
  String get details {
    final combined = [
      stdout.trim(),
      stderr.trim(),
    ].where((part) => part.isNotEmpty).join('\n');
    return combined.isEmpty ? 'exit code $exitCode' : combined;
  }
}

_ProcessOutput _git(String cwd, List<String> arguments) =>
    _process('git', arguments, cwd: cwd);

_ProcessOutput _process(
  String executable,
  List<String> arguments, {
  String? cwd,
}) {
  try {
    final result = Process.runSync(
      executable,
      arguments,
      workingDirectory: cwd,
      environment: executable == 'dart' ? const {'CI': 'true'} : null,
    );
    return _ProcessOutput(
      result.exitCode,
      (result.stdout as Object?).toString(),
      (result.stderr as Object?).toString(),
    );
  } on ProcessException catch (error) {
    return _ProcessOutput(127, '', error.toString());
  }
}

Map<String, Object?> _map(Object? value, String name) {
  if (value is Map<String, Object?>) return value;
  throw FormatException('$name must be an object.');
}

List<Object?> _list(Object? value, String name) {
  if (value is List<Object?>) return value;
  throw FormatException('$name must be a list.');
}

String _string(Object? value, String name) {
  if (value is String && value.isNotEmpty) return value;
  throw FormatException('$name must be a non-empty string.');
}

String? _optionalString(Object? value, String name) {
  if (value == null) return null;
  return _string(value, name);
}

int _int(Object? value, String name) {
  if (value is int && value >= 0) return value;
  throw FormatException('$name must be a non-negative integer.');
}

String _safePath(Object? value, String name) {
  final path = _string(value, name);
  if (!_isSafeRepositoryPath(path)) {
    throw FormatException('$name must stay inside the repository.');
  }
  return path;
}

bool _isSafeRepositoryPath(String path) =>
    !path.contains('\\') &&
    !p.posix.isAbsolute(path) &&
    (path == '.' || p.posix.normalize(path) == path) &&
    !p.posix.split(path).contains('..');
