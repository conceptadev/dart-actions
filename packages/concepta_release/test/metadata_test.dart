import 'dart:io';

import 'package:concepta_release/concepta_release.dart';
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

void main() {
  test('the reported toolkit version matches pubspec.yaml', () {
    final pubspec =
        loadYaml(File('pubspec.yaml').readAsStringSync()) as YamlMap;
    expect(
      pubspec['version'],
      toolkitVersion,
      reason:
          'every plan reports toolkitVersion; a stale constant would '
          'misidentify which toolkit produced a release',
    );
  });

  test('the package is not publishable until its name is secured', () {
    final pubspec =
        loadYaml(File('pubspec.yaml').readAsStringSync()) as YamlMap;
    expect(
      pubspec['publish_to'],
      'none',
      reason:
          'concepta_release is a proposed package name, not a reserved '
          'one. Distribution is a separate reviewed step.',
    );
  });

  test('the CHANGELOG documents the current version', () {
    expect(
      File('CHANGELOG.md').readAsStringSync(),
      contains('## $toolkitVersion'),
    );
  });
}
