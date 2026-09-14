/// Severity of a single planning diagnostic.
///
/// Only [DiagnosticSeverity.error] blocks a plan from being acted on. Warnings
/// and notes are recorded so a reviewer can see why the planner made a choice.
enum DiagnosticSeverity { note, warning, error }

/// A machine-readable finding about configuration, workspace, or plan.
///
/// [code] is a stable identifier that tests and callers can match on. [target]
/// names the package, group, or file the finding is about, when there is one.
class Diagnostic implements Comparable<Diagnostic> {
  const Diagnostic(this.severity, this.code, this.message, {this.target});

  const Diagnostic.error(String code, String message, {String? target})
    : this(DiagnosticSeverity.error, code, message, target: target);

  const Diagnostic.warning(String code, String message, {String? target})
    : this(DiagnosticSeverity.warning, code, message, target: target);

  const Diagnostic.note(String code, String message, {String? target})
    : this(DiagnosticSeverity.note, code, message, target: target);

  final DiagnosticSeverity severity;
  final String code;
  final String message;
  final String? target;

  Map<String, Object?> toJson() => {
    'severity': severity.name,
    'code': code,
    if (target != null) 'target': target,
    'message': message,
  };

  /// Orders errors first, then by code and target, so output is stable.
  @override
  int compareTo(Diagnostic other) {
    final bySeverity = other.severity.index.compareTo(severity.index);
    if (bySeverity != 0) return bySeverity;
    final byCode = code.compareTo(other.code);
    if (byCode != 0) return byCode;
    final byTarget = (target ?? '').compareTo(other.target ?? '');
    if (byTarget != 0) return byTarget;
    return message.compareTo(other.message);
  }

  @override
  String toString() =>
      '${severity.name}: $code${target == null ? '' : ' ($target)'}: $message';
}

extension DiagnosticList on List<Diagnostic> {
  bool get hasErrors => any((d) => d.severity == DiagnosticSeverity.error);

  /// Returns a sorted copy. The planner never depends on discovery order.
  List<Diagnostic> sorted() => <Diagnostic>[...this]..sort();
}

/// Thrown when input is too malformed to turn into a model at all.
///
/// Recoverable problems are reported as [Diagnostic]s instead.
class ReleaseConfigException implements Exception {
  ReleaseConfigException(this.diagnostics);

  final List<Diagnostic> diagnostics;

  @override
  String toString() => diagnostics.map((d) => d.toString()).join('\n');
}
