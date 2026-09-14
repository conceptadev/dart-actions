import 'dart:io';

import 'package:concepta_release/concepta_release.dart';

void main(List<String> arguments) {
  final out = StringBuffer();
  final err = StringBuffer();
  final code = run(arguments, out: out, err: err);
  if (out.isNotEmpty) stdout.write(out);
  if (err.isNotEmpty) stderr.write(err);
  exitCode = code;
}
