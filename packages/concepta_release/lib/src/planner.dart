import 'package:pub_semver/pub_semver.dart';

import 'config.dart';
import 'diagnostics.dart';
import 'plan.dart';
import 'versioning.dart';
import 'workspace.dart';

/// What the caller asked for. Nothing here is discovered from Git or a
/// registry; adapters translate their own signals into this request.
class ReleaseRequest {
  const ReleaseRequest({
    this.channel = ReleaseChannel.stable,
    this.bumps = const {},
    this.versionOverrides = const {},
    this.source = const PlanSource(),
  });

  final ReleaseChannel channel;

  /// Requested bump per package. A group member's bump applies to its group.
  final Map<String, BumpLevel> bumps;

  /// Exact versions that override computed proposals.
  final Map<String, Version> versionOverrides;

  final PlanSource source;
}

/// External state the planner is told about rather than looking up itself.
class RemoteState {
  const RemoteState({
    this.existingTags = const {},
    this.publishedVersions = const {},
  });

  /// Tags that already exist. A plan never proposes one of these again.
  final Set<String> existingTags;

  /// Versions already on the registry, per package.
  final Map<String, Set<Version>> publishedVersions;
}

/// A release unit: one synchronized group, or one independent package.
class _Unit {
  _Unit({required this.key, required this.members, required this.group});

  final String key;
  final List<String> members;
  final ReleaseGroup? group;

  BumpLevel bump = BumpLevel.none;
  final Map<String, List<String>> reasons = {};
  Version? override;

  /// Name to report in diagnostics. Never the internal key.
  String get label => group?.name ?? members.first;

  /// Readable form for diagnostic sentences.
  String get description =>
      group == null ? 'package "${members.first}"' : 'group "${group!.name}"';
}

/// Plans a release without touching Git, the network, the file system, or any
/// credential. The same inputs always produce the same plan.
ReleasePlan planRelease({
  required Workspace workspace,
  required ReleaseConfig config,
  ReleaseRequest request = const ReleaseRequest(),
  RemoteState remote = const RemoteState(),
}) {
  final diagnostics = <Diagnostic>[
    ...validateConfiguration(workspace: workspace, config: config),
  ];
  final deployments = [
    for (final d in config.deployments)
      PlannedDeployment(
        name: d.name,
        provider: d.provider,
        source: d.source,
        environment: d.environment,
        package: d.package,
      ),
  ];

  if (diagnostics.hasErrors) {
    return ReleasePlan(
      channel: request.channel,
      source: request.source,
      releases: const [],
      tags: const [],
      metadata: const [],
      deployments: deployments,
      diagnostics: diagnostics,
    );
  }

  final units = <String, _Unit>{};
  _Unit? unitFor(String package) {
    final group = config.groupOf(package);
    final key = group == null ? 'package:$package' : 'group:${group.name}';
    return units.putIfAbsent(
      key,
      () => _Unit(
        key: key,
        members: group == null ? [package] : [...group.packages],
        group: group,
      ),
    );
  }

  void select(String package, BumpLevel bump, String reason) {
    final unit = unitFor(package)!;
    unit.bump = unit.bump.max(bump);
    final reasons = unit.reasons[package] ??= [];
    if (!reasons.contains(reason)) reasons.add(reason);
  }

  // Seed from the request.
  for (final name in {
    ...request.bumps.keys,
    ...request.versionOverrides.keys,
  }.toList()..sort()) {
    if (config.rule(name) == null) {
      diagnostics.add(
        Diagnostic.error(
          'unknown-request-target',
          'Package "$name" is not declared in release.yaml, so it cannot be '
              'released. Declare it before requesting a version.',
          target: name,
        ),
      );
      continue;
    }
    final bump = request.bumps[name] ?? BumpLevel.none;
    final override = request.versionOverrides[name];
    select(
      name,
      bump,
      override != null
          ? 'requested version $override'
          : 'requested ${bump.name}',
    );
    if (override != null) {
      final unit = unitFor(name)!;
      if (unit.override != null && unit.override != override) {
        diagnostics.add(
          Diagnostic.error(
            'conflicting-group-override',
            'Members of ${unit.description} were given different explicit '
                'versions: ${unit.override} and $override.',
            target: unit.label,
          ),
        );
      }
      unit.override = override;
    }
  }

  if (diagnostics.hasErrors) {
    return ReleasePlan(
      channel: request.channel,
      source: request.source,
      releases: const [],
      tags: const [],
      metadata: const [],
      deployments: deployments,
      diagnostics: diagnostics,
    );
  }

  // Resolve versions, then pull in dependents whose floors must move, until
  // the selection stops growing.
  final proposals = <String, Version>{};
  final updates = <String, List<DependencyUpdate>>{};
  final metadata = <PlannedMetadataUpdate>[];

  // Each pass recomputes from scratch. Only the final pass's findings are
  // kept: an earlier pass can report a package as unreleased that a later one
  // selects, and that intermediate state is not part of the answer.
  var passDiagnostics = <Diagnostic>[];
  for (var pass = 0; pass < workspace.packages.length + 2; pass++) {
    passDiagnostics = <Diagnostic>[];
    proposals.clear();
    updates.clear();
    metadata.clear();

    final unitKeys = units.keys.toList()..sort();
    for (final key in unitKeys) {
      final unit = units[key]!;
      final current = _currentVersion(unit, workspace, passDiagnostics);
      if (current == null) continue;
      final proposed = _proposeUnitVersion(
        unit: unit,
        current: current,
        channel: request.channel,
        diagnostics: passDiagnostics,
      );
      if (proposed == null) continue;
      for (final member in unit.members) {
        if (workspace.contains(member)) proposals[member] = proposed;
      }
    }

    if (passDiagnostics.hasErrors) break;

    final added = _applyDependencyFloors(
      workspace: workspace,
      config: config,
      proposals: proposals,
      updates: updates,
      metadata: metadata,
      diagnostics: passDiagnostics,
      select: select,
    );
    if (!added || passDiagnostics.hasErrors) break;
  }
  diagnostics.addAll(passDiagnostics);

  if (diagnostics.hasErrors) {
    return ReleasePlan(
      channel: request.channel,
      source: request.source,
      releases: const [],
      tags: const [],
      metadata: const [],
      deployments: deployments,
      diagnostics: diagnostics,
    );
  }

  // Tags, one per unit, checked against tags that already exist.
  final tagOwners = <String, List<String>>{};
  final tagForPackage = <String, String>{};
  for (final key in units.keys.toList()..sort()) {
    final unit = units[key]!;
    final released =
        unit.members.where((m) => proposals.containsKey(m)).toList()..sort();
    if (released.isEmpty) continue;
    final version = proposals[released.first]!;
    final template = unit.group != null
        ? (unit.group!.tagTemplate ?? config.defaultGroupTagTemplate)
        : (config.rule(released.first)?.tagTemplate ??
              config.defaultTagTemplate);
    final tag = renderTag(
      template,
      package: unit.group == null ? released.first : null,
      version: version,
    );
    if (remote.existingTags.contains(tag)) {
      diagnostics.add(
        Diagnostic.error(
          'tag-exists',
          'Tag "$tag" already exists. Releases never move a published tag; '
              'choose a new version.',
          target: unit.label,
        ),
      );
      continue;
    }
    if (tagOwners.containsKey(tag)) {
      diagnostics.add(
        Diagnostic.error(
          'duplicate-tag',
          'Tag "$tag" would be created for more than one release unit.',
          target: unit.label,
        ),
      );
      continue;
    }
    tagOwners[tag] = [
      for (final member in released)
        if (_isPublishable(config, workspace, member)) member,
    ];
    for (final member in released) {
      tagForPackage[member] = tag;
    }
  }

  // Registry checks and publish-time rules.
  for (final name in proposals.keys.toList()..sort()) {
    if (!_isPublishable(config, workspace, name)) continue;
    final published = remote.publishedVersions[name];
    if (published != null && published.contains(proposals[name])) {
      diagnostics.add(
        Diagnostic.error(
          'version-already-published',
          '${proposals[name]} of "$name" is already on the registry. '
              'Existence alone is not proof the release is correct; review it '
              'before reusing the version.',
          target: name,
        ),
      );
    }
    diagnostics.addAll(_publishRules(workspace, config, name, proposals));
  }

  final stages = _computeStages(
    workspace: workspace,
    config: config,
    proposals: proposals,
    diagnostics: diagnostics,
  );

  // A dev dependency floor pointing at a later stage is not a cycle, but the
  // earlier package is published while that version does not exist yet.
  for (final name in proposals.keys.toList()..sort()) {
    for (final edge in workspace[name]!.dependencies) {
      if (edge.section != DependencySection.devDependencies) continue;
      final otherStage = stages[edge.name];
      if (otherStage == null || otherStage <= (stages[name] ?? 0)) continue;
      diagnostics.add(
        Diagnostic.warning(
          'dev-dependency-published-later',
          '"$name" publishes in stage ${stages[name]} but dev-depends on '
              '"${edge.name}", which publishes in stage $otherStage. Its '
              'raised floor will not resolve until that release lands.',
          target: name,
        ),
      );
    }
  }

  final releases = <ReleaseTarget>[];
  for (final name in proposals.keys.toList()..sort()) {
    final manifest = workspace[name]!;
    final group = config.groupOf(name);
    final publishable = _isPublishable(config, workspace, name);
    final unit =
        units[group == null ? 'package:$name' : 'group:${group.name}']!;
    final reasons =
        unit.reasons[name] ??
        [
          if (group != null)
            'synchronized with group "${group.name}"'
          else
            'selected by the release request',
        ];
    releases.add(
      ReleaseTarget(
        package: name,
        path: manifest.path,
        action: publishable ? ReleaseAction.publish : ReleaseAction.versionOnly,
        currentVersion: manifest.version!,
        proposedVersion: proposals[name]!,
        bump: unit.bump,
        group: group?.name,
        tag: publishable ? tagForPackage[name] : null,
        stage: stages[name] ?? 0,
        reasons: reasons,
        dependencyUpdates: updates[name] ?? const [],
      ),
    );
  }

  if (releases.isEmpty) {
    diagnostics.add(
      const Diagnostic.note(
        'no-release',
        'Nothing was selected for release. This is a no-op plan.',
      ),
    );
  }

  return ReleasePlan(
    channel: request.channel,
    source: request.source,
    releases: releases,
    tags: [
      for (final entry in tagOwners.entries)
        PlannedTag(tag: entry.key, packages: entry.value),
    ],
    metadata: metadata,
    deployments: deployments,
    diagnostics: diagnostics,
  );
}

/// Cross-checks `release.yaml` against the real workspace.
///
/// `doctor` reports exactly this list; `plan` refuses to continue when it
/// contains an error.
List<Diagnostic> validateConfiguration({
  required Workspace workspace,
  required ReleaseConfig config,
}) {
  final diagnostics = <Diagnostic>[];

  final seen = <String>{};
  for (final rule in config.packages) {
    if (!seen.add(rule.name)) {
      diagnostics.add(
        Diagnostic.error(
          'duplicate-package-rule',
          'Package "${rule.name}" is declared more than once.',
          target: rule.name,
        ),
      );
      continue;
    }
    final manifest = workspace[rule.name];
    if (manifest == null) {
      diagnostics.add(
        Diagnostic.error(
          'unknown-package',
          'Package "${rule.name}" is not a member of this workspace.',
          target: rule.name,
        ),
      );
      continue;
    }
    if (rule.publish && manifest.isPrivate) {
      diagnostics.add(
        Diagnostic.error(
          'private-package-publish',
          'Package "${rule.name}" sets publish_to: none but release.yaml marks '
              'it publish: true. A private package can deploy, never publish.',
          target: rule.name,
        ),
      );
    }
    if (manifest.version == null) {
      diagnostics.add(
        Diagnostic.error(
          'package-missing-version',
          'Package "${rule.name}" has no version in its pubspec, so no release '
              'can be proposed for it.',
          target: rule.name,
        ),
      );
    }
    if (rule.tagTemplate != null) {
      diagnostics.addAll(
        _tagTemplateProblems(rule.tagTemplate!, rule.name, isGroup: false),
      );
    }
  }

  diagnostics.addAll(
    _tagTemplateProblems(
      config.defaultTagTemplate,
      'defaults.tag',
      isGroup: false,
    ),
  );
  diagnostics.addAll(
    _tagTemplateProblems(
      config.defaultGroupTagTemplate,
      'defaults.group_tag',
      isGroup: true,
    ),
  );

  // Two independently versioned packages must not resolve to the same tag.
  // Substituting the package name is enough to tell them apart; a template
  // without {package} collides only when several packages share it verbatim.
  final tagShapes = <String, List<String>>{};
  for (final rule in config.packages) {
    // Only publish targets get a tag, so only they can collide.
    if (!rule.publish || config.groupOf(rule.name) != null) continue;
    final template = rule.tagTemplate ?? config.defaultTagTemplate;
    (tagShapes[template.replaceAll('{package}', rule.name)] ??= []).add(
      rule.name,
    );
  }
  for (final entry in tagShapes.entries) {
    if (entry.value.length < 2) continue;
    diagnostics.add(
      Diagnostic.warning(
        'tag-template-collision',
        'Packages ${(entry.value..sort()).join(', ')} all resolve to the tag '
            'shape "${entry.key}", so their releases would fight over one tag. '
            'Add {package} to the template or give each package its own.',
        target: entry.value.first,
      ),
    );
  }

  final groupNames = <String>{};
  final memberOwner = <String, String>{};
  for (final group in config.groups) {
    if (!groupNames.add(group.name)) {
      diagnostics.add(
        Diagnostic.error(
          'duplicate-group',
          'Group "${group.name}" is declared more than once.',
          target: group.name,
        ),
      );
      continue;
    }
    if (group.tagTemplate != null) {
      diagnostics.addAll(
        _tagTemplateProblems(group.tagTemplate!, group.name, isGroup: true),
      );
    }
    for (final member in group.packages) {
      final owner = memberOwner[member];
      if (owner != null) {
        diagnostics.add(
          Diagnostic.error(
            'overlapping-groups',
            'Package "$member" belongs to both "$owner" and "${group.name}". '
                'A package can synchronize with at most one group.',
            target: member,
          ),
        );
        continue;
      }
      memberOwner[member] = group.name;
      if (config.rule(member) == null) {
        diagnostics.add(
          Diagnostic.error(
            'group-member-not-declared',
            'Group "${group.name}" lists "$member", which is not declared under '
                'packages.',
            target: member,
          ),
        );
      }
    }
  }

  for (final deployment in config.deployments) {
    if (!_isContainedRelativePath(deployment.source)) {
      diagnostics.add(
        Diagnostic.error(
          'deployment-source-escapes',
          'Deployment "${deployment.name}" source "${deployment.source}" must be '
              'a relative path inside the workspace.',
          target: deployment.name,
        ),
      );
    }
    final package = deployment.package;
    if (package != null && !workspace.contains(package)) {
      diagnostics.add(
        Diagnostic.error(
          'unknown-package',
          'Deployment "${deployment.name}" names package "$package", which is '
              'not a member of this workspace.',
          target: deployment.name,
        ),
      );
    }
  }

  for (final manifest in workspace.packages) {
    if (config.rule(manifest.name) == null) {
      diagnostics.add(
        Diagnostic.note(
          'package-undeclared',
          'Workspace member "${manifest.name}" is not declared in release.yaml '
              'and can never be released. Declare it when that changes.',
          target: manifest.name,
        ),
      );
    }
  }

  return diagnostics;
}

List<Diagnostic> _tagTemplateProblems(
  String template,
  String owner, {
  required bool isGroup,
}) {
  final problems = <Diagnostic>[];
  if (!template.contains('{version}')) {
    problems.add(
      Diagnostic.error(
        'tag-template-missing-version',
        'Tag template "$template" has no {version} placeholder, so every '
            'release would map to the same tag.',
        target: owner,
      ),
    );
  }
  if (isGroup && template.contains('{package}')) {
    problems.add(
      Diagnostic.error(
        'group-tag-template-package',
        'Group tag template "$template" uses {package}, but a synchronized '
            'group creates one shared tag.',
        target: owner,
      ),
    );
  }
  return problems;
}

bool _isContainedRelativePath(String value) {
  if (value.startsWith('/') || value.contains('\\')) return false;
  final segments = value.split('/');
  return segments.isNotEmpty &&
      segments.every((s) => s.isNotEmpty && s != '..' && s != '.');
}

bool _isPublishable(ReleaseConfig config, Workspace workspace, String name) {
  final rule = config.rule(name);
  final manifest = workspace[name];
  return rule != null &&
      rule.publish &&
      manifest != null &&
      !manifest.isPrivate;
}

Version? _currentVersion(
  _Unit unit,
  Workspace workspace,
  List<Diagnostic> diagnostics,
) {
  Version? highest;
  final seen = <Version>{};
  for (final member in unit.members) {
    final version = workspace[member]?.version;
    if (version == null) continue;
    seen.add(version);
    if (highest == null || version > highest) highest = version;
  }
  if (highest == null) {
    diagnostics.add(
      Diagnostic.error(
        'package-missing-version',
        'No member of ${unit.description} declares a version.',
        target: unit.label,
      ),
    );
    return null;
  }
  if (unit.group != null && seen.length > 1) {
    diagnostics.add(
      Diagnostic.warning(
        'group-version-drift',
        'Group "${unit.group!.name}" members are at different versions '
            '(${(seen.map((v) => v.toString()).toList()..sort()).join(', ')}). '
            'They will all move to the proposed version.',
        target: unit.group!.name,
      ),
    );
  }
  return highest;
}

Version? _proposeUnitVersion({
  required _Unit unit,
  required Version current,
  required ReleaseChannel channel,
  required List<Diagnostic> diagnostics,
}) {
  final override = unit.override;
  if (override != null) {
    if (override <= current) {
      diagnostics.add(
        Diagnostic.error(
          'version-would-go-backwards',
          'Requested version $override is not higher than the current $current.',
          target: unit.label,
        ),
      );
      return null;
    }
    return override;
  }
  final proposal = proposeVersion(
    current: current,
    bump: unit.bump,
    channel: channel,
  );
  if (!proposal.isSuccess) {
    final severity = proposal.errorCode == 'no-version-change'
        ? DiagnosticSeverity.note
        : DiagnosticSeverity.error;
    diagnostics.add(
      Diagnostic(
        severity,
        proposal.errorCode!,
        proposal.errorMessage!,
        target: unit.label,
      ),
    );
    return null;
  }
  if (proposal.note != null) {
    diagnostics.add(
      Diagnostic.note(
        'prerelease-graduation',
        proposal.note!,
        target: unit.label,
      ),
    );
  }
  return proposal.version;
}

/// Raises declared floors for released dependencies and, when policy allows,
/// selects publishable dependents. Returns true when new packages were added.
bool _applyDependencyFloors({
  required Workspace workspace,
  required ReleaseConfig config,
  required Map<String, Version> proposals,
  required Map<String, List<DependencyUpdate>> updates,
  required List<PlannedMetadataUpdate> metadata,
  required List<Diagnostic> diagnostics,
  required void Function(String, BumpLevel, String) select,
}) {
  var added = false;
  for (final dependent in workspace.packages) {
    for (final edge in dependent.dependencies) {
      final released = proposals[edge.name];
      if (released == null || !edge.carriesVersionFloor) continue;
      final result = raiseDependencyFloor(edge.rawConstraint!, released);
      switch (result.outcome) {
        case FloorOutcome.unchanged:
          continue;
        case FloorOutcome.unbounded:
          diagnostics.add(
            Diagnostic.warning(
              'dependency-floor-unbounded',
              '"${dependent.name}" depends on "${edge.name}" without a version '
                  'floor, so releasing $released does not update it.',
              target: dependent.name,
            ),
          );
          continue;
        case FloorOutcome.conflict:
          diagnostics.add(
            Diagnostic.error(
              'dependency-floor-conflict',
              '"${dependent.name}" constrains "${edge.name}" to '
                  '"${edge.rawConstraint}", which excludes the proposed '
                  '$released. Widen it deliberately rather than automatically.',
              target: dependent.name,
            ),
          );
          continue;
        case FloorOutcome.raised:
          break;
      }
      final update = DependencyUpdate(
        dependency: edge.name,
        section: edge.section.key,
        from: edge.rawConstraint!,
        to: result.constraint!,
      );
      if (proposals.containsKey(dependent.name)) {
        (updates[dependent.name] ??= []).add(update);
        continue;
      }
      metadata.add(
        PlannedMetadataUpdate(
          package: dependent.name,
          path: dependent.path,
          update: update,
        ),
      );
      final publishable = _isPublishable(config, workspace, dependent.name);
      if (publishable &&
          config.bumpDependents != BumpLevel.none &&
          edge.section == DependencySection.dependencies) {
        select(
          dependent.name,
          config.bumpDependents,
          'dependency floor: ${edge.name} $released',
        );
        added = true;
      } else if (publishable) {
        diagnostics.add(
          Diagnostic.warning(
            'unreleased-dependency-floor',
            '"${dependent.name}" needs "${edge.name}" raised to '
                '"${result.constraint}" but is not being released. Publish it '
                'separately or the hosted package stays on the old floor.',
            target: dependent.name,
          ),
        );
      }
    }
  }
  return added;
}

List<Diagnostic> _publishRules(
  Workspace workspace,
  ReleaseConfig config,
  String name,
  Map<String, Version> proposals,
) {
  final problems = <Diagnostic>[];
  final manifest = workspace[name]!;
  for (final edge in manifest.dependencies) {
    if (edge.section != DependencySection.dependencies) continue;
    if (!workspace.contains(edge.name)) continue;
    if (edge.kind == DependencyKind.path) {
      problems.add(
        Diagnostic.error(
          'publish-path-dependency',
          '"$name" is a publish target but depends on "${edge.name}" by path. '
              'pub.dev rejects path dependencies.',
          target: name,
        ),
      );
      continue;
    }
    if (!_isPublishable(config, workspace, edge.name)) {
      problems.add(
        Diagnostic.error(
          'publish-depends-on-private',
          '"$name" is a publish target but depends on "${edge.name}", which is '
              'never published from this workspace.',
          target: name,
        ),
      );
    }
  }
  return problems;
}

/// Groups targets into publication stages using runtime dependencies only.
///
/// Dev dependencies are excluded on purpose: they create cycles that do not
/// affect the order a registry needs.
Map<String, int> _computeStages({
  required Workspace workspace,
  required ReleaseConfig config,
  required Map<String, Version> proposals,
  required List<Diagnostic> diagnostics,
}) {
  final targets = proposals.keys.toList()..sort();
  final needs = <String, Set<String>>{
    for (final name in targets)
      name: {
        for (final edge in workspace[name]!.dependencies)
          if (edge.section == DependencySection.dependencies &&
              proposals.containsKey(edge.name) &&
              edge.name != name)
            edge.name,
      },
  };

  final stages = <String, int>{};
  var stage = 0;
  while (stages.length < targets.length) {
    final ready = targets
        .where(
          (name) =>
              !stages.containsKey(name) &&
              needs[name]!.every(stages.containsKey),
        )
        .toList();
    if (ready.isEmpty) {
      final blocked = targets.where((n) => !stages.containsKey(n)).toList()
        ..sort();
      diagnostics.add(
        Diagnostic.error(
          'dependency-cycle',
          'These packages depend on each other and cannot be ordered for '
              'publication: ${blocked.join(', ')}.',
        ),
      );
      for (final name in blocked) {
        stages[name] = stage;
      }
      break;
    }
    for (final name in ready) {
      stages[name] = stage;
    }
    stage++;
  }
  return stages;
}
