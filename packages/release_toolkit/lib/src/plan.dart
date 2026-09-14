import 'dart:convert';

import 'package:pub_semver/pub_semver.dart';

import 'config.dart';
import 'diagnostics.dart';
import 'version.dart';

/// What a plan authorizes for one package.
enum ReleaseAction {
  /// Upload to pub.dev after the tag for this release exists.
  publish,

  /// Advance the version in the manifest only. Private packages and
  /// synchronized non-publishable members use this.
  versionOnly,
}

/// One dependency constraint that has to change because a dependency releases.
class DependencyUpdate implements Comparable<DependencyUpdate> {
  const DependencyUpdate({
    required this.dependency,
    required this.section,
    required this.from,
    required this.to,
  });

  final String dependency;
  final String section;
  final String from;
  final String to;

  Map<String, Object?> toJson() => {
    'dependency': dependency,
    'section': section,
    'from': from,
    'to': to,
  };

  @override
  int compareTo(DependencyUpdate other) {
    final byName = dependency.compareTo(other.dependency);
    return byName != 0 ? byName : section.compareTo(other.section);
  }
}

/// One package selected for release, with the reasons it was selected.
class ReleaseTarget implements Comparable<ReleaseTarget> {
  ReleaseTarget({
    required this.package,
    required this.path,
    required this.action,
    required this.currentVersion,
    required this.proposedVersion,
    required this.bump,
    required this.group,
    required this.tag,
    required this.stage,
    required List<String> reasons,
    required List<DependencyUpdate> dependencyUpdates,
  }) : reasons = List.unmodifiable(<String>[...reasons]..sort()),
       dependencyUpdates = List.unmodifiable(
         <DependencyUpdate>[...dependencyUpdates]..sort(),
       );

  final String package;
  final String path;
  final ReleaseAction action;
  final Version currentVersion;
  final Version proposedVersion;
  final BumpLevel bump;

  /// Synchronized group this package belongs to, if any.
  final String? group;

  /// Tag that authorizes this release. Group members share one tag.
  final String? tag;

  /// Zero-based publication stage. Everything in stage N may run in parallel
  /// once every stage below N has been published and verified.
  final int stage;

  final List<String> reasons;
  final List<DependencyUpdate> dependencyUpdates;

  Map<String, Object?> toJson() => {
    'package': package,
    'path': path,
    'action': action == ReleaseAction.publish ? 'publish' : 'version-only',
    if (group != null) 'group': group,
    'currentVersion': currentVersion.toString(),
    'proposedVersion': proposedVersion.toString(),
    'bump': bump.name,
    if (tag != null) 'tag': tag,
    'stage': stage,
    'reasons': reasons,
    'dependencyUpdates': dependencyUpdates
        .map((u) => u.toJson())
        .toList(growable: false),
  };

  @override
  int compareTo(ReleaseTarget other) => package.compareTo(other.package);
}

/// A dependency floor edit on a package that is *not* being released.
///
/// Preparation still has to apply the edit so the workspace resolves, but this
/// plan does not authorize a release of that package.
class PlannedMetadataUpdate implements Comparable<PlannedMetadataUpdate> {
  const PlannedMetadataUpdate({
    required this.package,
    required this.path,
    required this.update,
  });

  final String package;
  final String path;
  final DependencyUpdate update;

  Map<String, Object?> toJson() => {
    'package': package,
    'path': path,
    ...update.toJson(),
  };

  @override
  int compareTo(PlannedMetadataUpdate other) {
    final byPackage = package.compareTo(other.package);
    return byPackage != 0 ? byPackage : update.compareTo(other.update);
  }
}

/// A tag the release must create, and the packages it authorizes.
class PlannedTag implements Comparable<PlannedTag> {
  PlannedTag({required this.tag, required List<String> packages})
    : packages = List.unmodifiable(<String>[...packages]..sort());

  final String tag;
  final List<String> packages;

  Map<String, Object?> toJson() => {'tag': tag, 'packages': packages};

  @override
  int compareTo(PlannedTag other) => tag.compareTo(other.tag);
}

/// A deployment the plan records. Deployments never change package versions.
class PlannedDeployment implements Comparable<PlannedDeployment> {
  const PlannedDeployment({
    required this.name,
    required this.provider,
    required this.source,
    this.environment,
    this.package,
  });

  final String name;
  final String provider;
  final String source;
  final String? environment;
  final String? package;

  Map<String, Object?> toJson() => {
    'name': name,
    'provider': provider,
    'source': source,
    if (environment != null) 'environment': environment,
    if (package != null) 'package': package,
  };

  @override
  int compareTo(PlannedDeployment other) => name.compareTo(other.name);
}

/// Caller-supplied identity of the tree the plan describes.
///
/// The planner never reads Git. Workflows pass `github.sha` and `github.ref`
/// so a plan can be rebound to the final reviewed merge commit later.
class PlanSource {
  const PlanSource({this.repository, this.ref, this.revision});

  final String? repository;
  final String? ref;
  final String? revision;

  bool get isEmpty => repository == null && ref == null && revision == null;

  Map<String, Object?> toJson() => {
    if (repository != null) 'repository': repository,
    if (ref != null) 'ref': ref,
    if (revision != null) 'revision': revision,
  };
}

/// A complete, read-only release proposal.
///
/// Producing one never writes a file, creates a tag, contacts a registry, or
/// reads a credential.
class ReleasePlan {
  ReleasePlan({
    required this.channel,
    required this.source,
    required List<ReleaseTarget> releases,
    required List<PlannedTag> tags,
    required List<PlannedMetadataUpdate> metadata,
    required List<PlannedDeployment> deployments,
    required List<Diagnostic> diagnostics,
  }) : releases = List.unmodifiable(<ReleaseTarget>[...releases]..sort()),
       tags = List.unmodifiable(<PlannedTag>[...tags]..sort()),
       metadata = List.unmodifiable(
         <PlannedMetadataUpdate>[...metadata]..sort(),
       ),
       deployments = List.unmodifiable(
         <PlannedDeployment>[...deployments]..sort(),
       ),
       diagnostics = List.unmodifiable(diagnostics.sorted());

  /// Schema version of the serialized plan.
  static const schemaVersion = 1;

  final ReleaseChannel channel;
  final PlanSource source;
  final List<ReleaseTarget> releases;
  final List<PlannedTag> tags;

  /// Floor edits on packages that are not themselves released.
  final List<PlannedMetadataUpdate> metadata;

  final List<PlannedDeployment> deployments;
  final List<Diagnostic> diagnostics;

  /// True when nothing needs to be released.
  bool get isNoop => releases.isEmpty;

  bool get hasErrors => diagnostics.hasErrors;

  /// Package names grouped by publication stage, lowest dependency first.
  List<List<String>> get stages {
    if (releases.isEmpty) return const [];
    final highest = releases
        .map((r) => r.stage)
        .reduce((a, b) => a > b ? a : b);
    return List.generate(
      highest + 1,
      (stage) => releases
          .where((r) => r.stage == stage)
          .map((r) => r.package)
          .toList(growable: false),
      growable: false,
    );
  }

  Map<String, Object?> toJson() => {
    'schemaVersion': schemaVersion,
    'toolkitVersion': toolkitVersion,
    'channel': channel.name,
    if (!source.isEmpty) 'source': source.toJson(),
    'noop': isNoop,
    'releases': releases.map((r) => r.toJson()).toList(growable: false),
    'tags': tags.map((t) => t.toJson()).toList(growable: false),
    'stages': stages,
    'metadataUpdates': metadata.map((m) => m.toJson()).toList(growable: false),
    'deployments': deployments.map((d) => d.toJson()).toList(growable: false),
    'diagnostics': diagnostics.map((d) => d.toJson()).toList(growable: false),
  };

  /// Stable JSON. Identical inputs always produce identical bytes.
  String toJsonString() =>
      '${const JsonEncoder.withIndent('  ').convert(toJson())}\n';

  /// Human-readable summary for local use and workflow logs.
  String toReport() {
    final buffer = StringBuffer()
      ..writeln('Release Toolkit plan (channel: ${channel.name})');
    if (!source.isEmpty) {
      final parts = [
        if (source.repository != null) source.repository,
        if (source.ref != null) source.ref,
        if (source.revision != null) source.revision,
      ];
      buffer.writeln('Source: ${parts.join(' @ ')}');
    }
    if (isNoop) {
      buffer.writeln('No releases. Nothing to prepare, tag, or publish.');
    } else {
      for (final (index, stage) in stages.indexed) {
        buffer.writeln('Stage $index:');
        for (final name in stage) {
          final target = releases.firstWhere((r) => r.package == name);
          final label = target.action == ReleaseAction.publish
              ? 'publish'
              : 'version only';
          buffer
            ..writeln(
              '  $name  ${target.currentVersion} -> '
              '${target.proposedVersion}  (${target.bump.name}, $label)',
            )
            ..writeln('    reasons: ${target.reasons.join('; ')}');
          if (target.group != null) {
            buffer.writeln('    group: ${target.group}');
          }
          for (final update in target.dependencyUpdates) {
            buffer.writeln(
              '    ${update.section}: ${update.dependency} '
              '${update.from} -> ${update.to}',
            );
          }
        }
      }
      buffer.writeln('Tags:');
      for (final tag in tags) {
        buffer.writeln('  ${tag.tag}  (${tag.packages.join(', ')})');
      }
    }
    if (metadata.isNotEmpty) {
      buffer.writeln('Metadata updates without a release:');
      for (final entry in metadata) {
        buffer.writeln(
          '  ${entry.package}: ${entry.update.section} '
          '${entry.update.dependency} ${entry.update.from} -> '
          '${entry.update.to}',
        );
      }
    }
    if (deployments.isNotEmpty) {
      buffer.writeln('Deployments:');
      for (final deployment in deployments) {
        final environment = deployment.environment == null
            ? ''
            : ' [${deployment.environment}]';
        buffer.writeln(
          '  ${deployment.name} -> ${deployment.provider}'
          '$environment from ${deployment.source}',
        );
      }
    }
    if (diagnostics.isNotEmpty) {
      buffer.writeln('Diagnostics:');
      for (final diagnostic in diagnostics) {
        buffer.writeln('  $diagnostic');
      }
    }
    return buffer.toString();
  }
}
