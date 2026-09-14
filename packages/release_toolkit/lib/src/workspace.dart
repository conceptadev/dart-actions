import 'package:pub_semver/pub_semver.dart';

/// Where a dependency is declared in a pubspec.
enum DependencySection {
  dependencies,
  devDependencies;

  /// The pubspec key this section is written under.
  String get key => switch (this) {
    DependencySection.dependencies => 'dependencies',
    DependencySection.devDependencies => 'dev_dependencies',
  };
}

/// How a dependency resolves today.
///
/// Workspace members usually depend on each other through [path] or bare
/// [hosted] constraints; only [hosted] constraints have a floor to raise.
enum DependencyKind { hosted, path, git, sdk, unknown }

/// One dependency edge declared by a workspace member.
class PackageDependency {
  const PackageDependency({
    required this.name,
    required this.section,
    required this.kind,
    this.constraint,
    this.rawConstraint,
  });

  final String name;
  final DependencySection section;
  final DependencyKind kind;

  /// Parsed version constraint, when the declaration carries one.
  final VersionConstraint? constraint;

  /// Constraint exactly as written, so edits can preserve the author's style.
  final String? rawConstraint;

  /// Whether raising a published version floor on this edge is meaningful.
  bool get carriesVersionFloor =>
      kind == DependencyKind.hosted && rawConstraint != null;
}

/// A single resolved pubspec inside the workspace.
///
/// [path] is always relative to the workspace root and uses forward slashes so
/// plans are identical on every platform.
class PackageManifest {
  PackageManifest({
    required this.name,
    required this.path,
    required this.version,
    required this.isPrivate,
    required this.usesFlutter,
    required List<PackageDependency> dependencies,
    this.sdkConstraint,
    this.flutterConstraint,
  }) : dependencies = List.unmodifiable(dependencies);

  final String name;
  final String path;

  /// `null` when the pubspec declares no version, which pub allows for
  /// private packages and application entrypoints.
  final Version? version;

  /// True when the pubspec sets `publish_to: none`.
  final bool isPrivate;

  /// True when the package depends on the Flutter SDK.
  final bool usesFlutter;

  /// Declared `environment.sdk` constraint. Release tooling reports this but
  /// never raises it; consumer SDK floors are a deliberate product decision.
  final VersionConstraint? sdkConstraint;

  /// Declared `environment.flutter` constraint, when present.
  final VersionConstraint? flutterConstraint;

  final List<PackageDependency> dependencies;

  Iterable<PackageDependency> dependenciesOn(String other) =>
      dependencies.where((d) => d.name == other);
}

/// The set of packages the planner is allowed to reason about.
class Workspace {
  Workspace({required this.rootName, required List<PackageManifest> packages})
    : packages = List.unmodifiable(
        <PackageManifest>[...packages]
          ..sort((a, b) => a.name.compareTo(b.name)),
      ),
      _byName = {for (final p in packages) p.name: p};

  final String rootName;
  final List<PackageManifest> packages;

  /// Root package, which pub always treats as a workspace member.
  PackageManifest get root => _byName[rootName]!;
  final Map<String, PackageManifest> _byName;

  PackageManifest? operator [](String name) => _byName[name];

  bool contains(String name) => _byName.containsKey(name);

  Iterable<String> get names => packages.map((p) => p.name);
}
