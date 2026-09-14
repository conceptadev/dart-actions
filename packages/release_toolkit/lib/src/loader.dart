import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:pub_semver/pub_semver.dart';
import 'package:yaml/yaml.dart';

import 'config.dart';
import 'diagnostics.dart';
import 'workspace.dart';

/// Reads pubspecs and `release.yaml` from disk.
///
/// This is the only part of the toolkit that touches the file system. The
/// planner receives the result as plain data.
class WorkspaceLoader {
  const WorkspaceLoader(this.rootDirectory);

  final String rootDirectory;

  /// Loads the root pubspec and every declared workspace member.
  ///
  /// A repository without a `workspace:` key is treated as a one-member
  /// workspace containing its root package.
  (Workspace?, List<Diagnostic>) load() {
    final diagnostics = <Diagnostic>[];
    final rootPubspec = File(p.join(rootDirectory, 'pubspec.yaml'));
    if (!rootPubspec.existsSync()) {
      diagnostics.add(
        const Diagnostic.error(
          'missing-root-pubspec',
          'No pubspec.yaml at the workspace root.',
          target: 'pubspec.yaml',
        ),
      );
      return (null, diagnostics);
    }

    final root = _readManifest(rootPubspec, '.', diagnostics);
    if (root == null) return (null, diagnostics);

    final manifests = <PackageManifest>[root];
    for (final relative in _memberPaths(
      rootPubspec,
      root.sdkConstraint,
      diagnostics,
    )) {
      final file = File(p.join(rootDirectory, relative, 'pubspec.yaml'));
      if (!file.existsSync()) {
        diagnostics.add(
          Diagnostic.error(
            'missing-member-pubspec',
            'Workspace member "$relative" has no pubspec.yaml.',
            target: relative,
          ),
        );
        continue;
      }
      final manifest = _readManifest(file, relative, diagnostics);
      if (manifest != null) manifests.add(manifest);
    }

    final byName = <String, String>{};
    for (final manifest in manifests) {
      final existing = byName[manifest.name];
      if (existing != null) {
        diagnostics.add(
          Diagnostic.error(
            'duplicate-package-name',
            'Package "${manifest.name}" is declared at both "$existing" and '
                '"${manifest.path}".',
            target: manifest.name,
          ),
        );
        continue;
      }
      byName[manifest.name] = manifest.path;
    }
    if (diagnostics.hasErrors) return (null, diagnostics);

    return (Workspace(rootName: root.name, packages: manifests), diagnostics);
  }

  /// Expands the `workspace:` list, including simple `dir/*` patterns.
  List<String> _memberPaths(
    File rootPubspec,
    VersionConstraint? rootSdk,
    List<Diagnostic> diagnostics,
  ) {
    final Object? document = _parseYaml(rootPubspec, diagnostics);
    if (document is! YamlMap) return const [];
    final declared = document['workspace'];
    if (declared == null) return const [];
    if (declared is! YamlList) {
      diagnostics.add(
        const Diagnostic.error(
          'invalid-workspace-field',
          'The pubspec "workspace" field must be a list of directories.',
          target: 'pubspec.yaml',
        ),
      );
      return const [];
    }

    final members = <String>{};
    for (final entry in declared) {
      if (entry is! String || entry.isEmpty) {
        diagnostics.add(
          const Diagnostic.error(
            'invalid-workspace-field',
            'Every "workspace" entry must be a non-empty relative directory.',
            target: 'pubspec.yaml',
          ),
        );
        continue;
      }
      final normalized = p.posix.normalize(entry.replaceAll('\\', '/'));
      if (p.posix.isAbsolute(normalized) ||
          normalized.split('/').contains('..')) {
        diagnostics.add(
          Diagnostic.error(
            'workspace-path-escapes',
            'Workspace member "$entry" must stay inside the repository.',
            target: 'pubspec.yaml',
          ),
        );
        continue;
      }
      if (!normalized.contains('*')) {
        members.add(normalized);
        continue;
      }
      if (!_supportsWorkspaceGlobs(rootSdk)) {
        diagnostics.add(
          Diagnostic.error(
            'workspace-glob-language-version',
            'Workspace pattern "$entry" needs language version 3.11 or later. '
                'pub reports "No workspace packages matching" below that. Raise '
                'the root environment.sdk lower bound or list members '
                'explicitly.',
            target: 'pubspec.yaml',
          ),
        );
        continue;
      }
      members.addAll(_expandGlob(normalized, diagnostics));
    }
    return members.toList()..sort();
  }

  /// Supports only a trailing `*` segment, which is the pattern real
  /// repositories use. Anything else is rejected rather than half-supported.
  List<String> _expandGlob(String pattern, List<Diagnostic> diagnostics) {
    final segments = pattern.split('/');
    if (segments.where((s) => s.contains('*')).length != 1 ||
        segments.last != '*') {
      diagnostics.add(
        Diagnostic.error(
          'unsupported-workspace-pattern',
          'Workspace pattern "$pattern" is not supported. Use explicit paths or '
              'a single trailing "*".',
          target: 'pubspec.yaml',
        ),
      );
      return const [];
    }
    final parent = Directory(
      p.join(
        rootDirectory,
        p.joinAll(segments.sublist(0, segments.length - 1)),
      ),
    );
    if (!parent.existsSync()) return const [];
    final found = <String>[];
    for (final entity in parent.listSync()) {
      if (entity is! Directory) continue;
      if (!File(p.join(entity.path, 'pubspec.yaml')).existsSync()) continue;
      found.add(
        '${segments.sublist(0, segments.length - 1).join('/')}/'
        '${p.basename(entity.path)}',
      );
    }
    return found..sort();
  }

  /// pub added `workspace:` glob support in language version 3.11. Below that
  /// it fails resolution instead of matching anything.
  static bool _supportsWorkspaceGlobs(VersionConstraint? rootSdk) {
    if (rootSdk is! VersionRange || rootSdk.min == null) return false;
    return rootSdk.min! >= Version(3, 11, 0);
  }

  Object? _parseYaml(File file, List<Diagnostic> diagnostics) {
    try {
      return loadYaml(file.readAsStringSync());
    } on YamlException catch (error) {
      diagnostics.add(
        Diagnostic.error(
          'unparsable-pubspec',
          error.message,
          target: p.relative(file.path, from: rootDirectory),
        ),
      );
      return null;
    }
  }

  PackageManifest? _readManifest(
    File file,
    String relativePath,
    List<Diagnostic> diagnostics,
  ) {
    final Object? document = _parseYaml(file, diagnostics);
    if (document is! YamlMap) {
      diagnostics.add(
        Diagnostic.error(
          'unparsable-pubspec',
          'pubspec.yaml must contain a YAML map.',
          target: relativePath,
        ),
      );
      return null;
    }

    final name = document['name'];
    if (name is! String || name.isEmpty) {
      diagnostics.add(
        Diagnostic.error(
          'pubspec-missing-name',
          'pubspec.yaml has no package name.',
          target: relativePath,
        ),
      );
      return null;
    }

    Version? version;
    final declaredVersion = document['version'];
    if (declaredVersion != null) {
      try {
        version = Version.parse(declaredVersion.toString());
      } on FormatException {
        diagnostics.add(
          Diagnostic.error(
            'invalid-package-version',
            'Version "$declaredVersion" is not valid semver.',
            target: name,
          ),
        );
      }
    }

    final environment = document['environment'];
    final sdkConstraint = _environmentConstraint(environment, 'sdk');
    final flutterConstraint = _environmentConstraint(environment, 'flutter');
    final dependencies = <PackageDependency>[];
    for (final section in DependencySection.values) {
      final declared = document[section.key];
      if (declared == null) continue;
      if (declared is! YamlMap) {
        diagnostics.add(
          Diagnostic.error(
            'invalid-dependency-section',
            '"${section.key}" must be a map.',
            target: name,
          ),
        );
        continue;
      }
      for (final entry in declared.entries) {
        final dependencyName = entry.key.toString();
        dependencies.add(_readDependency(dependencyName, entry.value, section));
      }
    }

    final usesFlutter =
        (environment is YamlMap && environment.containsKey('flutter')) ||
        dependencies.any(
          (d) => d.name == 'flutter' && d.kind == DependencyKind.sdk,
        );

    return PackageManifest(
      name: name,
      path: relativePath == '.' ? '.' : p.posix.normalize(relativePath),
      version: version,
      isPrivate: document['publish_to']?.toString() == 'none',
      usesFlutter: usesFlutter,
      dependencies: dependencies,
      sdkConstraint: sdkConstraint,
      flutterConstraint: flutterConstraint,
    );
  }

  VersionConstraint? _environmentConstraint(Object? environment, String key) {
    if (environment is! YamlMap) return null;
    final declared = environment[key];
    return declared is String ? _tryConstraint(declared) : null;
  }

  PackageDependency _readDependency(
    String name,
    Object? declaration,
    DependencySection section,
  ) {
    if (declaration == null) {
      return PackageDependency(
        name: name,
        section: section,
        kind: DependencyKind.hosted,
      );
    }
    if (declaration is String) {
      return PackageDependency(
        name: name,
        section: section,
        kind: DependencyKind.hosted,
        constraint: _tryConstraint(declaration),
        rawConstraint: declaration,
      );
    }
    if (declaration is YamlMap) {
      if (declaration.containsKey('path')) {
        return PackageDependency(
          name: name,
          section: section,
          kind: DependencyKind.path,
        );
      }
      if (declaration.containsKey('git')) {
        return PackageDependency(
          name: name,
          section: section,
          kind: DependencyKind.git,
        );
      }
      if (declaration.containsKey('sdk')) {
        return PackageDependency(
          name: name,
          section: section,
          kind: DependencyKind.sdk,
        );
      }
      final declaredVersion = declaration['version'];
      if (declaredVersion is String) {
        return PackageDependency(
          name: name,
          section: section,
          kind: DependencyKind.hosted,
          constraint: _tryConstraint(declaredVersion),
          rawConstraint: declaredVersion,
        );
      }
      return PackageDependency(
        name: name,
        section: section,
        kind: DependencyKind.hosted,
      );
    }
    return PackageDependency(
      name: name,
      section: section,
      kind: DependencyKind.unknown,
    );
  }

  VersionConstraint? _tryConstraint(String raw) {
    try {
      return VersionConstraint.parse(raw);
    } on FormatException {
      return null;
    }
  }
}

/// Reads `release.yaml` from [path].
(ReleaseConfig?, List<Diagnostic>) loadReleaseConfig(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    return (
      null,
      [
        Diagnostic.error(
          'missing-release-config',
          'No release configuration at "$path". Releases are opt-in: create it '
              'to declare which packages may be released.',
          target: path,
        ),
      ],
    );
  }
  try {
    return ReleaseConfig.parse(
      file.readAsStringSync(),
      origin: p.basename(path),
    );
  } on ReleaseConfigException catch (error) {
    return (null, error.diagnostics);
  }
}
