import 'dart:async';

import 'package:gapless/core/process/process_runner.dart';

final class FakeProcessRunner implements ProcessRunner {
  final List<ProcessRequest> requests = [];
  final List<FakeRunningProcess> _queued = [];

  ProcessRequest get lastRequest => requests.last;

  void enqueue(FakeRunningProcess process) => _queued.add(process);

  @override
  Future<FakeRunningProcess> start(ProcessRequest request) async {
    requests.add(request);
    if (_queued.isEmpty) {
      throw StateError('No fake process was queued');
    }
    return _queued.removeAt(0);
  }
}

final class FakeRunningProcess implements RunningProcess {
  FakeRunningProcess({this.pid = 1});

  @override
  final int pid;
  final StreamController<String> _stdout = StreamController();
  final StreamController<String> _stderr = StreamController();
  final Completer<int> _exitCode = Completer();
  Future<void>? _cancellation;

  var cancelCount = 0;
  bool get isCancelled => _cancellation != null;

  @override
  Stream<String> get stdoutLines => _stdout.stream;

  @override
  Stream<String> get stderrLines => _stderr.stream;

  @override
  Future<int> get exitCode => _exitCode.future;

  void addStdout(String line) => _stdout.add(line);

  void addStderr(String line) => _stderr.add(line);

  Future<void> complete(int code) async {
    if (!_exitCode.isCompleted) _exitCode.complete(code);
    await Future.wait([_stdout.close(), _stderr.close()]);
  }

  @override
  Future<void> cancel() => _cancellation ??= _cancel();

  Future<void> _cancel() async {
    cancelCount++;
    await complete(-1);
  }
}
