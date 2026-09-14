/// Deterministic release planning for Concepta Dart and Flutter workspaces.
///
/// The planner is pure: [planRelease] never reads Git, contacts a registry,
/// mutates a file, or acquires a credential. External facts reach it through
/// [ReleaseRequest] and [RemoteState], which makes plans reproducible and
/// testable. File system access is confined to [WorkspaceLoader] and
/// [loadReleaseConfig].
library;

export 'src/cli.dart' show ExitCodes, run;
export 'src/config.dart'
    show
        BumpLevel,
        DeploymentTarget,
        PackageRule,
        ReleaseChannel,
        ReleaseConfig,
        ReleaseGroup;
export 'src/diagnostics.dart'
    show Diagnostic, DiagnosticList, DiagnosticSeverity, ReleaseConfigException;
export 'src/loader.dart' show WorkspaceLoader, loadReleaseConfig;
export 'src/plan.dart'
    show
        DependencyUpdate,
        PlanSource,
        PlannedDeployment,
        PlannedMetadataUpdate,
        PlannedTag,
        ReleaseAction,
        ReleasePlan,
        ReleaseTarget;
export 'src/planner.dart'
    show ReleaseRequest, RemoteState, planRelease, validateConfiguration;
export 'src/version.dart' show toolkitVersion;
export 'src/versioning.dart'
    show
        FloorOutcome,
        FloorResult,
        VersionProposal,
        proposeVersion,
        raiseDependencyFloor,
        renderTag;
export 'src/workspace.dart'
    show
        DependencyKind,
        DependencySection,
        PackageDependency,
        PackageManifest,
        Workspace;
