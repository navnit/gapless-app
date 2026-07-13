import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gapless/core/process/native_process_host.dart';
import 'package:path/path.dart' as p;

import '../../helpers/native_process_host_test_support.dart';

void main() {
  test('resolves only deterministic bundle-relative host paths', () {
    expect(
      NativeProcessHost.resolveBundledExecutable(
        operatingSystem: 'macos',
        resolvedExecutable: '/Applications/gapless.app/Contents/MacOS/gapless',
      ),
      '/Applications/gapless.app/Contents/Resources/gapless_process_host',
    );
    expect(
      NativeProcessHost.resolveBundledExecutable(
        operatingSystem: 'linux',
        resolvedExecutable: '/opt/gapless/gapless',
      ),
      '/opt/gapless/lib/gapless_process_host',
    );
    expect(
      NativeProcessHost.resolveBundledExecutable(
        operatingSystem: 'windows',
        resolvedExecutable: r'C:\Program Files\Gapless\gapless.exe',
      ),
      r'C:\Program Files\Gapless\gapless_process_host.exe',
    );
  });

  test(
    'native source builds with strict warnings on the current platform',
    () async {
      if (!supportsNativeHostTests) return;
      final temp = Directory.systemTemp.createTempSync('gapless-host-build-');
      addTearDown(() => temp.deleteSync(recursive: true));

      final executable = await compileNativeProcessHost(temp);

      expect(File(executable).existsSync(), isTrue);
    },
  );

  test(
    'native host rejects a relative target without searching PATH',
    () async {
      if (!supportsNativeHostTests) return;
      final temp = Directory.systemTemp.createTempSync('gapless-host-path-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final hostPath = await compileNativeProcessHost(temp);
      final marker = p.join(temp.path, 'relative-target.json');

      final host = await Process.start(
        hostPath,
        [
          '--grace-ms',
          '100',
          '--force-ms',
          '1000',
          '--',
          p.basename(_dartExecutable),
          _fixturePath('capture_args.dart'),
          marker,
        ],
        environment: {'PATH': p.dirname(_dartExecutable)},
        includeParentEnvironment: true,
        runInShell: false,
      );
      final diagnostics = await host.stderr.transform(utf8.decoder).join();

      expect(await host.exitCode, isNot(0));
      expect(diagnostics, contains('target executable must be absolute'));
      expect(File(marker).existsSync(), isFalse);
    },
  );

  test(
    'POSIX cancellation before parent acknowledgment never execs target',
    () async {
      if (!supportsPosixNativeHostTests) return;
      final temp = Directory.systemTemp.createTempSync('gapless-pre-ack-');
      addTearDown(() => temp.deleteSync(recursive: true));
      final hostPath = await compilePosixProcessHost(
        temp,
        enableTestHooks: true,
      );
      final gateReady = p.join(temp.path, 'pre-ack-ready');
      final gateRelease = p.join(temp.path, 'pre-ack-release');
      final targetMarker = p.join(temp.path, 'target-started.json');
      final host = await Process.start(
        hostPath,
        [
          '--grace-ms',
          '100',
          '--force-ms',
          '1000',
          '--',
          _dartExecutable,
          _fixturePath('capture_args.dart'),
          targetMarker,
        ],
        environment: {
          'GPH_TEST_PRE_ACK_READY': gateReady,
          'GPH_TEST_PRE_ACK_RELEASE': gateRelease,
        },
        includeParentEnvironment: true,
        runInShell: false,
      );
      addTearDown(() {
        host.kill(ProcessSignal.sigkill);
      });

      final enteredGate = await Future.any<bool>([
        waitUntil(
          () => File(gateReady).exists(),
          timeout: const Duration(seconds: 2),
        ).then((_) => true),
        host.exitCode.then((_) => false),
      ]);
      expect(enteredGate, isTrue);

      await host.stdin.close();

      expect(await host.exitCode.timeout(const Duration(seconds: 5)), 125);
      expect(File(targetMarker).existsSync(), isFalse);
    },
  );

  test('POSIX host establishes the process group before target exec', () {
    final source = _source('native/process_host/posix/process_host.c');
    final setGroup = source.indexOf('setpgid(0, 0)');
    final ready = source.indexOf('write_ready_message(ready_fd, 0)', setGroup);
    final acknowledgment = source.indexOf(
      'await_parent_acknowledgment(acknowledgment_fd)',
      ready,
    );
    final exec = source.indexOf('execv(', acknowledgment);

    expect(setGroup, greaterThanOrEqualTo(0));
    expect(ready, greaterThan(setGroup));
    expect(acknowledgment, greaterThan(ready));
    expect(exec, greaterThan(acknowledgment));
    expect(source, contains('CLOCK_MONOTONIC'));
    expect(source, contains('EINTR'));
    expect(source, contains('signal_pipe'));
    expect(source, contains('kill(-process_group'));
    expect(source, contains('wait_for_startup_event'));
    expect(source, contains('terminate_starting_child'));
    expect(source, contains('cleanup_deadline'));
  });

  test('POSIX signal and startup failure paths preserve lifecycle safety', () {
    final source = _source('native/process_host/posix/process_host.c');

    expect(source, contains('int saved_error = errno;'));
    expect(source, contains('errno = saved_error;'));
    expect(source, contains('kill_and_reap_child(target);'));
    final clockFailure = source.indexOf('if (start_now < 0)');
    expect(
      source.indexOf('kill_and_reap_child(target);', clockFailure),
      greaterThan(clockFailure),
    );
  });

  test('Windows host owns the target before it can execute', () {
    final source = _source('native/process_host/windows/process_host.cpp');
    final jobAttribute = source.indexOf('PROC_THREAD_ATTRIBUTE_JOB_LIST');
    final createSuspended = source.indexOf('CREATE_SUSPENDED');
    final create = source.indexOf('CreateProcessW');
    final resume = source.indexOf('ResumeThread');

    expect(source, contains('CreateJobObjectW'));
    expect(source, contains('JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE'));
    expect(source, contains('SetInformationJobObject'));
    expect(source, contains('STARTUPINFOEXW'));
    expect(source, contains('EXTENDED_STARTUPINFO_PRESENT'));
    expect(jobAttribute, greaterThanOrEqualTo(0));
    expect(createSuspended, greaterThanOrEqualTo(0));
    expect(create, greaterThan(jobAttribute));
    expect(resume, greaterThan(create));
    expect(source, isNot(contains('AssignProcessToJobObject')));
    expect(source, contains('TerminateJobObject'));
  });

  test('Windows target inherits only its three standard handles', () {
    final source = _source('native/process_host/windows/process_host.cpp');

    expect(
      source,
      contains('SetHandleInformation(input, HANDLE_FLAG_INHERIT, 0)'),
    );
    expect(source, contains('PROC_THREAD_ATTRIBUTE_HANDLE_LIST'));
    expect(source, contains('HANDLE inherited_handles[]'));
    expect(source, contains('null_input.Get()'));
    expect(source, contains('child_output.Get()'));
    expect(source, contains('child_error.Get()'));
  });

  test('Windows timeout parsing and deadlines reject unsafe arithmetic', () {
    final source = _source('native/process_host/windows/process_host.cpp');

    expect(source, contains('wcstoull'));
    expect(source, contains('errno = 0'));
    expect(source, contains("value[0] == L'-'"));
    expect(source, contains('CheckedAdd'));
    expect(source, contains('DeadlineFromNow'));
    expect(source, contains('RemainingWaitMilliseconds'));
    expect(source, contains('kTimeoutGoldenCases'));
    expect(source, contains('ValidateTimeoutGoldenCases()'));
    expect(source, contains('UINT64_MAX'));
  });

  test('Windows quoting has executable golden coverage for edge cases', () {
    final source = _source('native/process_host/windows/process_host.cpp');

    expect(source, contains('kQuoteGoldenCases'));
    expect(source, contains(r'{L"", L"\"\""}'));
    expect(source, contains(r'{L"plain", L"plain"}'));
    expect(source, contains(r'{L"two words", L"\"two words\""}'));
    expect(source, contains(r'{L"a\\\"b", L"\"a\\\\\\\"b\""}'));
    expect(
      source,
      contains(r'{L"C:\\Program Files\\", L"\"C:\\Program Files\\\\\""}'),
    );
    expect(source, contains('ValidateQuoteGoldenCases()'));
  });

  test('build files bundle the host at the resolver paths', () {
    final linux = _source('linux/CMakeLists.txt');
    final windows = _source('windows/CMakeLists.txt');
    final macos = _source('macos/Runner.xcodeproj/project.pbxproj');

    expect(linux, contains('native/process_host/posix/process_host.c'));
    expect(linux, contains('INSTALL_BUNDLE_LIB_DIR'));
    expect(linux, contains('gapless_process_host'));
    expect(windows, contains('native/process_host/windows/process_host.cpp'));
    expect(windows, contains('gapless_process_host'));
    expect(windows, contains(r'DESTINATION "${CMAKE_INSTALL_PREFIX}"'));
    expect(macos, contains('gapless_process_host'));
    expect(macos, contains('native/process_host/posix/process_host.c'));
    expect(macos, contains('CodeSignOnCopy'));
    expect(macos, contains('dstSubfolderSpec = 7'));
  });

  test('Windows CI runs native lifecycle tests and verifies bundle path', () {
    final workflowFile = File(
      p.join(
        Directory.current.path,
        '.github',
        'workflows',
        'windows-process-host.yml',
      ),
    );
    expect(workflowFile.existsSync(), isTrue);
    if (!workflowFile.existsSync()) return;
    final workflow = workflowFile.readAsStringSync();

    expect(workflow, contains('windows-latest'));
    expect(workflow, contains('flutter-version: 3.44.4'));
    expect(workflow, contains('flutter test test/core/process'));
    expect(workflow, contains('flutter build windows --debug'));
    expect(
      workflow,
      contains(r'build\windows\x64\runner\Debug\gapless_process_host.exe'),
    );
  });

  test('production code contains no shell or process-table helpers', () {
    final production = [
      _source('lib/core/process/io_process_runner.dart'),
      _source('lib/core/process/native_process_host.dart'),
      _source('native/process_host/posix/process_host.c'),
      _source('native/process_host/windows/process_host.cpp'),
    ].join('\n');

    for (final forbidden in [
      'taskkill',
      'tasklist',
      'wmic',
      'powershell',
      'cmd.exe',
      '/bin/ps',
      'Process.killPid',
      'runInShell: true',
      'system(',
      'popen(',
    ]) {
      expect(
        production.toLowerCase(),
        isNot(contains(forbidden.toLowerCase())),
      );
    }
  });
}

String _source(String relativePath) => File(
  p.joinAll([Directory.current.path, ...p.posix.split(relativePath)]),
).readAsStringSync();

String _fixturePath(String name) =>
    p.join(Directory.current.path, 'test', 'fixtures', 'process', name);

String get _dartExecutable {
  final resolved = Platform.resolvedExecutable;
  if (p.basenameWithoutExtension(resolved) == 'dart') return resolved;

  final executableName = Platform.isWindows ? 'dart.exe' : 'dart';
  final flutterRoot = Platform.environment['FLUTTER_ROOT'];
  if (flutterRoot != null) {
    final fromEnvironment = p.join(
      flutterRoot,
      'bin',
      'cache',
      'dart-sdk',
      'bin',
      executableName,
    );
    if (File(fromEnvironment).existsSync()) return fromEnvironment;
  }

  var directory = File(resolved).parent;
  while (directory.parent.path != directory.path) {
    if (p.basename(directory.path) == 'cache') {
      final besideFlutterEngine = p.join(
        directory.path,
        'dart-sdk',
        'bin',
        executableName,
      );
      if (File(besideFlutterEngine).existsSync()) return besideFlutterEngine;
    }
    directory = directory.parent;
  }
  throw StateError('Could not locate the Dart executable from $resolved');
}
