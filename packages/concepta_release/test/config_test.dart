import 'package:concepta_release/concepta_release.dart';
import 'package:test/test.dart';

(ReleaseConfig?, List<Diagnostic>) parse(String source) =>
    ReleaseConfig.parse(source);

List<String> codes(List<Diagnostic> diagnostics) =>
    diagnostics.map((d) => d.code).toList();

void main() {
  test('parses a complete configuration', () {
    final (config, diagnostics) = parse('''
version: 1
defaults:
  tag: "{package}@{version}"
  group_tag: "release-{version}"
  bump_dependents: minor
groups:
  - name: core
    packages: [b, a]
packages:
  - name: a
    publish: true
  - name: b
    publish: true
  - name: demo
    publish: false
deployments:
  - name: site
    provider: github-pages
    source: apps/site
''');
    expect(diagnostics, isEmpty);
    expect(config!.defaultTagTemplate, '{package}@{version}');
    expect(config.defaultGroupTagTemplate, 'release-{version}');
    expect(config.bumpDependents, BumpLevel.minor);
    expect(
      config.groups.single.packages,
      ['a', 'b'],
      reason: 'group members are sorted so plans are order-independent',
    );
    expect(config.packages.map((p) => p.name), ['a', 'b', 'demo']);
    expect(config.rule('demo')!.publish, isFalse);
    expect(config.groupOf('a')!.name, 'core');
    expect(config.deployments.single.provider, 'github-pages');
  });

  test('defaults to not publishing anything', () {
    final (config, diagnostics) = parse('''
version: 1
packages:
  - name: a
''');
    expect(diagnostics, isEmpty);
    expect(
      config!.rule('a')!.publish,
      isFalse,
      reason: 'discovery must never authorize an upload on its own',
    );
  });

  test('rejects unknown fields anywhere', () {
    expect(
      codes(parse('version: 1\nunexpected: true\n').$2),
      contains('config-unknown-field'),
    );
    expect(
      codes(
        parse('''
version: 1
defaults:
  tag_prefix: v
''').$2,
      ),
      contains('config-unknown-field'),
    );
    expect(
      codes(
        parse('''
version: 1
packages:
  - name: a
    publish_to: none
''').$2,
      ),
      contains('config-unknown-field'),
    );
  });

  test('rejects an unsupported schema version', () {
    expect(
      codes(parse('version: 99\n').$2),
      contains('config-version-unsupported'),
    );
    expect(codes(parse('packages: []\n').$2), contains('config-missing-field'));
  });

  test('rejects wrong types instead of coercing them', () {
    expect(codes(parse('version: "1"\n').$2), contains('config-invalid-type'));
    expect(
      codes(
        parse('version: 1\npackages:\n  - name: a\n    publish: "yes"\n').$2,
      ),
      contains('config-invalid-type'),
    );
    expect(
      codes(parse('version: 1\ngroups:\n  - name: g\n    packages: []\n').$2),
      contains('config-invalid-type'),
    );
    expect(
      codes(parse('version: 1\npackages:\n  - a\n').$2),
      contains('config-invalid-type'),
    );
  });

  test('rejects an unknown bump level', () {
    expect(
      codes(parse('version: 1\ndefaults:\n  bump_dependents: huge\n').$2),
      contains('config-invalid-bump'),
    );
  });

  test('throws only when the document is not a map', () {
    expect(() => parse('- 1\n- 2\n'), throwsA(isA<ReleaseConfigException>()));
    expect(() => parse('a: [1,\n'), throwsA(isA<ReleaseConfigException>()));
  });

  test('returns no config when any error was recorded', () {
    final (config, diagnostics) = parse('version: 1\nnope: 1\n');
    expect(config, isNull);
    expect(diagnostics.hasErrors, isTrue);
  });
}
