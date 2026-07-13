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
    'POSIX source builds with strict warnings on the current platform',
    () async {
      if (!supportsPosixNativeHostTests) return;
      final temp = Directory.systemTemp.createTempSync('gapless-host-build-');
      addTearDown(() => temp.deleteSync(recursive: true));

      final executable = await compilePosixProcessHost(temp);

      expect(File(executable).existsSync(), isTrue);
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
    final exec = source.indexOf('execvp(', acknowledgment);

    expect(setGroup, greaterThanOrEqualTo(0));
    expect(ready, greaterThan(setGroup));
    expect(acknowledgment, greaterThan(ready));
    expect(exec, greaterThan(acknowledgment));
    expect(source, contains('CLOCK_MONOTONIC'));
    expect(source, contains('EINTR'));
    expect(source, contains('signal_pipe'));
    expect(source, contains('kill(-process_group'));
  });

  test('Windows host owns the target before it can execute', () {
    final source = _source('native/process_host/windows/process_host.cpp');
    final createSuspended = source.indexOf('CREATE_SUSPENDED');
    final assign = source.indexOf('AssignProcessToJobObject');
    final resume = source.indexOf('ResumeThread');

    expect(source, contains('CreateJobObjectW'));
    expect(source, contains('JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE'));
    expect(source, contains('SetInformationJobObject'));
    expect(createSuspended, greaterThanOrEqualTo(0));
    expect(assign, greaterThan(createSuspended));
    expect(resume, greaterThan(assign));
    expect(source, contains('TerminateJobObject'));
  });

  test('Windows target cannot inherit the private control channel', () {
    final source = _source('native/process_host/windows/process_host.cpp');

    expect(
      source,
      contains('SetHandleInformation(input, HANDLE_FLAG_INHERIT, 0)'),
    );
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
