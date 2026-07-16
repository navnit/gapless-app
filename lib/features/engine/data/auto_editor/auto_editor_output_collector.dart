/// Collects process output without retaining unbounded diagnostic streams.
///
/// Probe and levels operations opt into complete stdout retention because their
/// stdout is a machine-readable result. Detect and render leave it disabled.
final class AutoEditorOutputCollector {
  AutoEditorOutputCollector({required bool retainStdout})
    : _stdout = retainStdout ? StringBuffer() : null;

  static const _maxDiagnosticLines = 40;
  static const _maxDiagnosticCharacters = 8192;

  final StringBuffer? _stdout;
  final List<_DiagnosticLine> _diagnostics = [];
  var _diagnosticCharacters = 0;
  var _hasStdoutLine = false;

  void addStdout(String line) {
    final stdout = _stdout;
    if (stdout != null) {
      if (_hasStdoutLine) stdout.writeln();
      stdout.write(line);
      _hasStdoutLine = true;
    }
    _addDiagnostic(line, isStderr: false);
  }

  void addStderr(String line) => _addDiagnostic(line, isStderr: true);

  String get stdout => _stdout?.toString() ?? '';

  List<String> get diagnostics => List.unmodifiable([
    for (final entry in _diagnostics)
      if (entry.isStderr) entry.text,
    for (final entry in _diagnostics)
      if (!entry.isStderr) entry.text,
  ]);

  void _addDiagnostic(String raw, {required bool isStderr}) {
    final line = raw.replaceAll(RegExp(r'[\r\n]+'), ' ');
    if (isStderr) {
      while (_cannotRetainEntire(line) && _removeLastStdoutDiagnostic()) {}
    }
    if (_diagnostics.length == _maxDiagnosticLines ||
        _diagnosticCharacters == _maxDiagnosticCharacters) {
      return;
    }
    final available = _maxDiagnosticCharacters - _diagnosticCharacters;
    final bounded = line.length <= available
        ? line
        : '${line.substring(0, available > 1 ? available - 1 : 0)}…';
    _diagnostics.add(_DiagnosticLine(bounded, isStderr: isStderr));
    _diagnosticCharacters += bounded.length;
  }

  bool _cannotRetainEntire(String line) =>
      _diagnostics.length == _maxDiagnosticLines ||
      _diagnosticCharacters + line.length > _maxDiagnosticCharacters;

  bool _removeLastStdoutDiagnostic() {
    final index = _diagnostics.lastIndexWhere((entry) => !entry.isStderr);
    if (index < 0) return false;
    _diagnosticCharacters -= _diagnostics.removeAt(index).text.length;
    return true;
  }
}

final class _DiagnosticLine {
  const _DiagnosticLine(this.text, {required this.isStderr});

  final String text;
  final bool isStderr;
}
