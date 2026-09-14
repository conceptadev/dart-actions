import 'package:yaml/yaml.dart';

import 'diagnostics.dart';

/// How much to raise a version.
enum BumpLevel {
  none,
  patch,
  minor,
  major;

  static BumpLevel? parse(String value) =>
      BumpLevel.values.where((b) => b.name == value).firstOrNull;

  /// The larger of two requested bumps. Used when several reasons ask for a
  /// release of the same package or synchronized group.
  BumpLevel max(BumpLevel other) => index >= other.index ? this : other;
}

/// The release channel a plan proposes versions for.
enum ReleaseChannel {
  stable,
  beta,
  rc;

  static ReleaseChannel? parse(String value) =>
      ReleaseChannel.values.where((c) => c.name == value).firstOrNull;

  /// Pre-release identifier written into proposed versions, if any.
  String? get preReleaseId => this == ReleaseChannel.stable ? null : name;
}

/// Declared release settings for one workspace member.
class PackageRule {
  const PackageRule({
    required this.name,
    required this.publish,
    this.tagTemplate,
  });

  final String name;

  /// Only an explicit `publish: true` authorizes a pub.dev upload. Discovery
  /// never grants this.
  final bool publish;

  /// Overrides `defaults.tag` for this package when it releases independently.
  final String? tagTemplate;
}

/// A set of packages that always advance to the same version together.
class ReleaseGroup {
  ReleaseGroup({
    required this.name,
    required List<String> packages,
    this.tagTemplate,
  }) : packages = List.unmodifiable(<String>[...packages]..sort());

  final String name;
  final List<String> packages;

  /// Overrides `defaults.group_tag`. Must not contain `{package}`.
  final String? tagTemplate;
}

/// A deployment target. Deployments never bump or publish a package version.
class DeploymentTarget {
  const DeploymentTarget({
    required this.name,
    required this.provider,
    required this.source,
    this.environment,
    this.package,
  });

  final String name;
  final String provider;

  /// Workspace-relative directory that produces the deployable artifact.
  final String source;

  /// Protected GitHub environment the deploy job must run in, when declared.
  final String? environment;

  /// Workspace member that owns this deployment, when there is one.
  final String? package;
}

/// Parsed, validated-in-shape `release.yaml`.
///
/// Shape validation happens here. Cross-checks against the real workspace
/// happen in the planner so both can report diagnostics together.
class ReleaseConfig {
  ReleaseConfig({
    required this.configVersion,
    required this.defaultTagTemplate,
    required this.defaultGroupTagTemplate,
    required this.bumpDependents,
    required List<ReleaseGroup> groups,
    required List<PackageRule> packages,
    required List<DeploymentTarget> deployments,
  }) : groups = List.unmodifiable(
         <ReleaseGroup>[...groups]..sort((a, b) => a.name.compareTo(b.name)),
       ),
       packages = List.unmodifiable(
         <PackageRule>[...packages]..sort((a, b) => a.name.compareTo(b.name)),
       ),
       deployments = List.unmodifiable(
         <DeploymentTarget>[...deployments]
           ..sort((a, b) => a.name.compareTo(b.name)),
       );

  /// Schema version of `release.yaml`. Only version 1 exists today.
  static const supportedConfigVersion = 1;

  final int configVersion;
  final String defaultTagTemplate;
  final String defaultGroupTagTemplate;

  /// Bump applied to a publishable package when a dependency floor it declares
  /// has to be raised. `none` records the edit without releasing the dependent.
  final BumpLevel bumpDependents;

  final List<ReleaseGroup> groups;
  final List<PackageRule> packages;
  final List<DeploymentTarget> deployments;

  PackageRule? rule(String name) =>
      packages.where((p) => p.name == name).firstOrNull;

  ReleaseGroup? groupOf(String package) =>
      groups.where((g) => g.packages.contains(package)).firstOrNull;

  /// Parses [source]. Throws [ReleaseConfigException] only when the document is
  /// not a YAML map; every other problem is returned as a diagnostic list.
  static (ReleaseConfig?, List<Diagnostic>) parse(
    String source, {
    String origin = 'release.yaml',
  }) {
    final diagnostics = <Diagnostic>[];
    final Object? document;
    try {
      document = loadYaml(source);
    } on YamlException catch (error) {
      throw ReleaseConfigException([
        Diagnostic.error('config-unparsable', error.message, target: origin),
      ]);
    }
    if (document is! YamlMap) {
      throw ReleaseConfigException([
        Diagnostic.error(
          'config-not-a-map',
          'release.yaml must contain a YAML map at the top level.',
          target: origin,
        ),
      ]);
    }

    final reader = _Reader(document, origin, diagnostics);
    reader.rejectUnknownKeys(const {
      'version',
      'defaults',
      'groups',
      'packages',
      'deployments',
    });

    final configVersion = reader.requiredInt('version') ?? 0;
    if (configVersion != supportedConfigVersion) {
      diagnostics.add(
        Diagnostic.error(
          'config-version-unsupported',
          'Unsupported release.yaml version $configVersion. '
              'This toolkit understands version $supportedConfigVersion.',
          target: origin,
        ),
      );
    }

    var defaultTag = '{package}-v{version}';
    var defaultGroupTag = 'v{version}';
    var bumpDependents = BumpLevel.patch;

    final defaults = reader.optionalMap('defaults');
    if (defaults != null) {
      final d = _Reader(defaults, '$origin#defaults', diagnostics);
      d.rejectUnknownKeys(const {'tag', 'group_tag', 'bump_dependents'});
      defaultTag = d.optionalString('tag') ?? defaultTag;
      defaultGroupTag = d.optionalString('group_tag') ?? defaultGroupTag;
      final declared = d.optionalString('bump_dependents');
      if (declared != null) {
        final parsed = BumpLevel.parse(declared);
        if (parsed == null) {
          diagnostics.add(
            Diagnostic.error(
              'config-invalid-bump',
              'Unknown bump_dependents "$declared". '
                  'Use one of: ${BumpLevel.values.map((b) => b.name).join(', ')}.',
              target: '$origin#defaults',
            ),
          );
        } else {
          bumpDependents = parsed;
        }
      }
    }

    final packages = <PackageRule>[];
    for (final (index, entry) in reader.mapList('packages').indexed) {
      final p = _Reader(entry, '$origin#packages[$index]', diagnostics);
      p.rejectUnknownKeys(const {'name', 'publish', 'tag'});
      final name = p.requiredString('name');
      if (name == null) continue;
      packages.add(
        PackageRule(
          name: name,
          publish: p.optionalBool('publish') ?? false,
          tagTemplate: p.optionalString('tag'),
        ),
      );
    }

    final groups = <ReleaseGroup>[];
    for (final (index, entry) in reader.mapList('groups').indexed) {
      final g = _Reader(entry, '$origin#groups[$index]', diagnostics);
      g.rejectUnknownKeys(const {'name', 'packages', 'tag'});
      final name = g.requiredString('name');
      final members = g.requiredStringList('packages');
      if (name == null || members == null) continue;
      groups.add(
        ReleaseGroup(
          name: name,
          packages: members,
          tagTemplate: g.optionalString('tag'),
        ),
      );
    }

    final deployments = <DeploymentTarget>[];
    for (final (index, entry) in reader.mapList('deployments').indexed) {
      final d = _Reader(entry, '$origin#deployments[$index]', diagnostics);
      d.rejectUnknownKeys(const {
        'name',
        'provider',
        'source',
        'environment',
        'package',
      });
      final name = d.requiredString('name');
      final provider = d.requiredString('provider');
      final source = d.requiredString('source');
      if (name == null || provider == null || source == null) continue;
      deployments.add(
        DeploymentTarget(
          name: name,
          provider: provider,
          source: source,
          environment: d.optionalString('environment'),
          package: d.optionalString('package'),
        ),
      );
    }

    final config = ReleaseConfig(
      configVersion: configVersion,
      defaultTagTemplate: defaultTag,
      defaultGroupTagTemplate: defaultGroupTag,
      bumpDependents: bumpDependents,
      groups: groups,
      packages: packages,
      deployments: deployments,
    );
    return (diagnostics.hasErrors ? null : config, diagnostics);
  }
}

/// Reads typed values from a [YamlMap], recording a diagnostic per problem
/// instead of throwing, so one run reports every configuration mistake.
class _Reader {
  _Reader(this.map, this.origin, this.diagnostics);

  final YamlMap map;
  final String origin;
  final List<Diagnostic> diagnostics;

  void rejectUnknownKeys(Set<String> allowed) {
    final unknown =
        map.keys
            .map((k) => k.toString())
            .where((k) => !allowed.contains(k))
            .toList()
          ..sort();
    for (final key in unknown) {
      diagnostics.add(
        Diagnostic.error(
          'config-unknown-field',
          'Unknown field "$key". Allowed: ${(allowed.toList()..sort()).join(', ')}.',
          target: origin,
        ),
      );
    }
  }

  void _wrongType(String key, String expected) {
    diagnostics.add(
      Diagnostic.error(
        'config-invalid-type',
        'Field "$key" must be $expected.',
        target: origin,
      ),
    );
  }

  int? requiredInt(String key) {
    final value = map[key];
    if (value is int) return value;
    if (value == null) {
      diagnostics.add(
        Diagnostic.error(
          'config-missing-field',
          'Field "$key" is required.',
          target: origin,
        ),
      );
      return null;
    }
    _wrongType(key, 'an integer');
    return null;
  }

  String? optionalString(String key) {
    final value = map[key];
    if (value == null) return null;
    if (value is String && value.isNotEmpty) return value;
    _wrongType(key, 'a non-empty string');
    return null;
  }

  String? requiredString(String key) {
    if (map[key] == null) {
      diagnostics.add(
        Diagnostic.error(
          'config-missing-field',
          'Field "$key" is required.',
          target: origin,
        ),
      );
      return null;
    }
    return optionalString(key);
  }

  bool? optionalBool(String key) {
    final value = map[key];
    if (value == null) return null;
    if (value is bool) return value;
    _wrongType(key, 'true or false');
    return null;
  }

  List<String>? requiredStringList(String key) {
    final value = map[key];
    if (value is! YamlList || value.isEmpty) {
      _wrongType(key, 'a non-empty list of package names');
      return null;
    }
    final items = <String>[];
    for (final item in value) {
      if (item is String && item.isNotEmpty) {
        items.add(item);
      } else {
        _wrongType(key, 'a non-empty list of package names');
        return null;
      }
    }
    return items;
  }

  /// Returns the maps in list-valued [key], reporting non-map entries.
  List<YamlMap> mapList(String key) {
    final value = map[key];
    if (value == null) return const [];
    if (value is! YamlList) {
      _wrongType(key, 'a list');
      return const [];
    }
    final entries = <YamlMap>[];
    for (final (index, item) in value.indexed) {
      if (item is YamlMap) {
        entries.add(item);
      } else {
        diagnostics.add(
          Diagnostic.error(
            'config-invalid-type',
            'Entry $index of "$key" must be a map.',
            target: origin,
          ),
        );
      }
    }
    return entries;
  }

  YamlMap? optionalMap(String key) {
    final value = map[key];
    if (value == null) return null;
    if (value is YamlMap) return value;
    _wrongType(key, 'a map');
    return null;
  }
}
