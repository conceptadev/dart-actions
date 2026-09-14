import 'dart:io';

import 'package:release_toolkit/release_toolkit.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Absolute path of a checked-in fixture workspace.
String fixturePath(String name) =>
    p.join(Directory.current.path, 'test', 'fixtures', name);

(Workspace?, List<Diagnostic>) loadFixture(String name) =>
    WorkspaceLoader(fixturePath(name)).load();

/// Loads a fixture's workspace and `release.yaml`, failing the test if either
/// cannot be read. Use this when the fixture itself is not under test.
({Workspace workspace, ReleaseConfig config}) loadFixtureInputs(String name) {
  final (workspace, workspaceDiagnostics) = loadFixture(name);
  final (config, configDiagnostics) = loadReleaseConfig(
    p.join(fixturePath(name), 'release.yaml'),
  );
  expect(workspace, isNotNull, reason: '$workspaceDiagnostics');
  expect(config, isNotNull, reason: '$configDiagnostics');
  return (workspace: workspace!, config: config!);
}

/// Writes a throwaway workspace under the test's temporary directory.
///
/// Keys are repository-relative paths; parent directories are created.
String scratchWorkspace(Map<String, String> files) {
  final root = Directory.systemTemp.createTempSync('release_toolkit_test_');
  addTearDown(() => root.deleteSync(recursive: true));
  files.forEach((relative, contents) {
    final file = File(p.join(root.path, p.joinAll(p.posix.split(relative))));
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(contents);
  });
  return root.path;
}
