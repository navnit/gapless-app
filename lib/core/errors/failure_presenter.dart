import 'package:flutter/foundation.dart';
import 'package:gapless/core/errors/app_failure.dart';

enum FailureAction {
  retry,
  relocate,
  useMotion,
  chooseDestination,
  saveAs,
  copyDiagnostics,
  reinstall,
}

@immutable
final class FailurePresentation {
  const FailurePresentation({
    required this.title,
    required this.body,
    required this.primaryAction,
    this.secondaryAction,
    this.destructive = false,
  });

  final String title;
  final String body;
  final FailureAction primaryAction;
  final FailureAction? secondaryAction;
  final bool destructive;
}

abstract final class FailurePresenter {
  static FailurePresentation present(AppFailure failure) => switch (failure) {
    ProjectFormatFailure() => const FailurePresentation(
      title: 'Project could not be opened',
      body:
          'This project file is invalid or unsupported. Try opening it again.',
      primaryAction: FailureAction.retry,
      secondaryAction: FailureAction.copyDiagnostics,
    ),
    ProjectSaveFailure() => const FailurePresentation(
      title: 'Project could not be saved',
      body:
          'Your edits are still here. Choose a new place to save the project.',
      primaryAction: FailureAction.saveAs,
      secondaryAction: FailureAction.copyDiagnostics,
    ),
    SourceMissingFailure() => const FailurePresentation(
      title: 'Source video not found',
      body: 'Locate the original video to continue editing this project.',
      primaryAction: FailureAction.relocate,
    ),
    SourceChangedFailure() => const FailurePresentation(
      title: 'Source video changed',
      body: 'Locate the original video or a matching copy to continue safely.',
      primaryAction: FailureAction.relocate,
      secondaryAction: FailureAction.copyDiagnostics,
    ),
    EngineMissingFailure() => const FailurePresentation(
      title: 'Editing engine is missing',
      body: 'Reinstall the bundled editing engine, then try again.',
      primaryAction: FailureAction.reinstall,
      secondaryAction: FailureAction.copyDiagnostics,
    ),
    EngineChecksumFailure() => const FailurePresentation(
      title: 'Editing engine could not be verified',
      body: 'Reinstall the bundled editing engine before continuing.',
      primaryAction: FailureAction.reinstall,
      secondaryAction: FailureAction.copyDiagnostics,
    ),
    EngineContractFailure(reason: EngineContractReason.unsupportedSources) =>
      const FailurePresentation(
        title: 'A video file is required',
        body:
            'Audio-only files are not supported yet. Choose a video file and '
            'try again.',
        primaryAction: FailureAction.retry,
        secondaryAction: FailureAction.copyDiagnostics,
      ),
    EngineContractFailure() => const FailurePresentation(
      title: 'Editing engine could not finish',
      body:
          'Your project is safe. Try again or copy diagnostics for more detail.',
      primaryAction: FailureAction.retry,
      secondaryAction: FailureAction.copyDiagnostics,
    ),
    MediaReadFailure(:final reason) => _presentMediaRead(reason),
    DiskFullFailure() => const FailurePresentation(
      title: 'Not enough free space',
      body:
          'Choose another MP4 destination or free some space, then try again.',
      primaryAction: FailureAction.chooseDestination,
      secondaryAction: FailureAction.copyDiagnostics,
    ),
    OperationCancelled() => throw StateError(
      'Cancellation is handled as a ready state',
    ),
  };

  static String formatDiagnostics({
    required String appVersion,
    required String engineVersion,
    required String platform,
    required String stage,
    required AppFailure failure,
  }) {
    final lines = <String>[
      'Gapless diagnostics',
      'App: ${_boundedValue(appVersion, _fieldLimit)}',
      'Engine: ${_boundedValue(engineVersion, _fieldLimit)}',
      'Platform: ${_boundedValue(platform, _fieldLimit)}',
      'Stage: ${_boundedValue(stage, _fieldLimit)}',
      'Failure: ${_failureName(failure)}',
      'Facts:',
      ..._failureFacts(failure),
      'Diagnostics:',
      ..._failureDiagnostics(
        failure,
      ).map((entry) => '- ${_boundedValue(entry, _entryLimit)}'),
    ];
    return _boundFinalCopy(lines.join('\n'));
  }
}

FailurePresentation _presentMediaRead(
  MediaReadReason reason,
) => switch (reason) {
  MediaReadReason.unreadable => const FailurePresentation(
    title: 'Video could not be read',
    body: 'Check that the file is available, then try again.',
    primaryAction: FailureAction.retry,
    secondaryAction: FailureAction.copyDiagnostics,
  ),
  MediaReadReason.corrupt => const FailurePresentation(
    title: 'Video appears to be damaged',
    body: 'Try another copy of the video or copy diagnostics for more detail.',
    primaryAction: FailureAction.retry,
    secondaryAction: FailureAction.copyDiagnostics,
  ),
  MediaReadReason.unsupported => const FailurePresentation(
    title: 'Video format is not supported',
    body: 'Try another MP4 file or copy diagnostics for more detail.',
    primaryAction: FailureAction.retry,
    secondaryAction: FailureAction.copyDiagnostics,
  ),
  MediaReadReason.noAudio => const FailurePresentation(
    title: 'This video has no audio track',
    body: 'Use motion detection to find inactive sections instead.',
    primaryAction: FailureAction.useMotion,
  ),
};

const _fieldLimit = 160;
const _entryLimit = 320;
const _finalLimit = 4096;
const _truncatedMarker = '\n[diagnostics truncated]';

String _failureName(AppFailure failure) => switch (failure) {
  ProjectFormatFailure() => 'ProjectFormatFailure',
  ProjectSaveFailure() => 'ProjectSaveFailure',
  SourceMissingFailure() => 'SourceMissingFailure',
  SourceChangedFailure() => 'SourceChangedFailure',
  EngineMissingFailure() => 'EngineMissingFailure',
  EngineChecksumFailure() => 'EngineChecksumFailure',
  EngineContractFailure() => 'EngineContractFailure',
  MediaReadFailure() => 'MediaReadFailure',
  DiskFullFailure() => 'DiskFullFailure',
  OperationCancelled() => 'OperationCancelled',
};

List<String> _failureFacts(AppFailure failure) {
  final facts = <String>[];
  void add(String label, Object? value) {
    if (value == null) return;
    facts.add('- $label: ${_boundedValue(value.toString(), _entryLimit)}');
  }

  switch (failure) {
    case ProjectFormatFailure(:final reason):
      add('Reason', reason);
    case ProjectSaveFailure(:final path, :final cause):
      add('Path', path);
      add('Cause', cause);
    case SourceMissingFailure(:final source):
      add('Source', source);
    case SourceChangedFailure(
      :final source,
      :final expectedFingerprint,
      :final actualFingerprint,
    ):
      add('Source', source);
      add('Expected fingerprint', expectedFingerprint);
      add('Actual fingerprint', actualFingerprint);
    case EngineMissingFailure(:final expectedLocation):
      add('Expected location', expectedLocation);
    case EngineChecksumFailure(:final expectedSha256, :final actualSha256):
      add('Expected SHA-256', expectedSha256);
      add('Actual SHA-256', actualSha256);
    case EngineContractFailure(
      :final operation,
      :final reason,
      :final exitCode,
    ):
      add('Operation', operation);
      add('Reason', reason.name);
      add('Exit code', exitCode);
    case MediaReadFailure(:final source, :final reason):
      add('Source', source);
      add('Reason', reason.name);
    case DiskFullFailure(
      :final destination,
      :final requiredBytes,
      :final availableBytes,
    ):
      add('Destination', destination);
      add('Required bytes', requiredBytes);
      add('Available bytes', availableBytes);
    case OperationCancelled(:final operation):
      add('Operation', operation);
  }
  return facts;
}

List<String> _failureDiagnostics(AppFailure failure) => switch (failure) {
  EngineContractFailure(:final diagnostics) => diagnostics,
  MediaReadFailure(:final diagnostics) => diagnostics,
  _ => const <String>[],
};

String _boundedValue(String value, int limit) {
  final sanitized = _redact(value)
      .replaceAll(RegExp(r'[\r\n\t]+'), ' ')
      .replaceAll(RegExp(r'\s{2,}'), ' ')
      .trim();
  final safe = sanitized.isEmpty ? '[not provided]' : sanitized;
  if (safe.length <= limit) return safe;
  return '${safe.substring(0, limit - 1)}…';
}

String _redact(String value) {
  var redacted = value;
  redacted = redacted.replaceAllMapped(
    RegExp(r'\b([a-z][a-z0-9+.-]*://)[^@\s/?#]+@', caseSensitive: false),
    (match) => '${match[1] ?? ''}[userinfo]@',
  );
  redacted = redacted.replaceAllMapped(
    RegExp(r'\b([a-z][a-z0-9+.-]*://[^\s?#]+)[?#][^\s]*', caseSensitive: false),
    (match) => '${match[1] ?? ''}?[redacted]',
  );
  redacted = redacted.replaceAll(
    RegExp(r'\bauthorization\s*[:=]\s*[^\r\n,]+', caseSensitive: false),
    '[authorization]=[redacted]',
  );
  redacted = redacted.replaceAll(
    RegExp(r'\bbearer\s+[A-Za-z0-9._~+/=-]+', caseSensitive: false),
    'Bearer [redacted]',
  );
  redacted = redacted.replaceAll(
    RegExp(r'\b(?:set-cookie|cookie)\s*[:=]\s*[^\r\n]+', caseSensitive: false),
    '[cookie]=[redacted]',
  );
  redacted = redacted.replaceAllMapped(
    RegExp(
      r'(^|[\s,;])(?:PATH|HOME|USER|USERNAME|USERPROFILE|APPDATA|'
      r'LOCALAPPDATA|TEMP|TMP|SHELL)\s*=\s*'
      r'''(?:"[^"]*"|'[^']*'|[^\s,;]+)''',
      caseSensitive: false,
      multiLine: true,
    ),
    (match) => '${match[1] ?? ''}[environment]=[redacted]',
  );
  redacted = redacted.replaceAll(
    RegExp(
      r'\b[A-Za-z0-9_-]*(?:api[_-]?key|token|access|secret|private|'
      r'credential|session|password|passwd|client[_-]?secret)'
      r'[A-Za-z0-9_-]*\b\s*[:=]\s*'
      r'''(?:"[^"]*"|'[^']*'|[^\s,;]+)''',
      caseSensitive: false,
    ),
    '[secret]=[redacted]',
  );
  redacted = redacted.replaceAll(
    RegExp(
      r'\b(?:gh[pousr]_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9_-]{16,}|eyJ[A-Za-z0-9._-]{20,})\b',
    ),
    '[redacted]',
  );
  redacted = redacted.replaceAll(
    RegExp(
      r'"(?:file:///|~[\\/]|[A-Za-z]:[\\/]|\\\\|/)[^"\r\n]*"',
      caseSensitive: false,
    ),
    '"[path]"',
  );
  redacted = redacted.replaceAll(
    RegExp(
      r"'(?:file:///|~[\\/]|[A-Za-z]:[\\/]|\\\\|/)[^'\r\n]*'",
      caseSensitive: false,
    ),
    "'[path]'",
  );
  redacted = redacted.replaceAll(
    RegExp(
      r'\[(?:file:///|~[\\/]|[A-Za-z]:[\\/]|\\\\|/)[^\]\r\n]*\]',
      caseSensitive: false,
    ),
    '[[path]]',
  );
  redacted = redacted.replaceAll(
    RegExp(r'''\bfile:///[^,\r\n;)\]}'"]*''', caseSensitive: false),
    'file://[path]',
  );
  redacted = _redactPath(
    redacted,
    RegExp(r'''(^|[\s(=:])~[\\/][^,\r\n;)\]}'"]*'''),
  );
  redacted = _redactPath(
    redacted,
    RegExp(r'''(^|[\s(=:])(?:[A-Za-z]:[\\/]|\\\\)[^,\r\n;)\]}'"]*'''),
  );
  return _redactPath(redacted, RegExp(r'''(^|[\s(=:])/(?:[^,\r\n;)\]}'"]*)'''));
}

String _redactPath(String value, RegExp pattern) =>
    value.replaceAllMapped(pattern, (match) => '${match[1] ?? ''}[path]');

String _boundFinalCopy(String value) {
  if (value.length <= _finalLimit) return value;
  final keep = _finalLimit - _truncatedMarker.length;
  return '${value.substring(0, keep)}$_truncatedMarker';
}
