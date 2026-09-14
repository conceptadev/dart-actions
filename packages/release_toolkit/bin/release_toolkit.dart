import 'dart:io';

import 'package:release_toolkit/release_toolkit.dart';

void main(List<String> arguments) {
  final out = StringBuffer();
  final err = StringBuffer();
  final code = run(arguments, out: out, err: err);
  if (out.isNotEmpty) stdout.write(out);
  if (err.isNotEmpty) stderr.write(err);
  exitCode = code;
}
