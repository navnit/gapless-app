#define WIN32_LEAN_AND_MEAN
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#include <windows.h>

#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cwchar>
#include <cwctype>
#include <string>
#include <vector>

namespace {

constexpr DWORD kCancelledExitCode = 125;
constexpr DWORD kHostFailureExitCode = 126;
constexpr DWORD kTargetStartFailureExitCode = 127;
constexpr DWORD kPollIntervalMilliseconds = 20;
volatile LONG cancellation_requested = 0;

class UniqueHandle {
 public:
  UniqueHandle() = default;
  explicit UniqueHandle(HANDLE value) : value_(value) {}
  ~UniqueHandle() { Reset(); }

  UniqueHandle(const UniqueHandle&) = delete;
  UniqueHandle& operator=(const UniqueHandle&) = delete;

  HANDLE Get() const { return value_; }
  bool IsValid() const {
    return value_ != nullptr && value_ != INVALID_HANDLE_VALUE;
  }
  void Reset(HANDLE value = nullptr) {
    if (IsValid()) {
      CloseHandle(value_);
    }
    value_ = value;
  }

 private:
  HANDLE value_ = nullptr;
};

class AttributeList {
 public:
  AttributeList() = default;
  ~AttributeList() {
    if (list_ != nullptr) {
      DeleteProcThreadAttributeList(list_);
      HeapFree(GetProcessHeap(), 0, list_);
    }
  }

  AttributeList(const AttributeList&) = delete;
  AttributeList& operator=(const AttributeList&) = delete;

  bool Initialize(DWORD attribute_count) {
    SIZE_T bytes = 0;
    (void)InitializeProcThreadAttributeList(nullptr, attribute_count, 0,
                                            &bytes);
    if (bytes == 0 || GetLastError() != ERROR_INSUFFICIENT_BUFFER) {
      return false;
    }
    list_ = reinterpret_cast<LPPROC_THREAD_ATTRIBUTE_LIST>(
        HeapAlloc(GetProcessHeap(), 0, bytes));
    if (list_ == nullptr) {
      SetLastError(ERROR_OUTOFMEMORY);
      return false;
    }
    if (!InitializeProcThreadAttributeList(list_, attribute_count, 0,
                                           &bytes)) {
      DWORD saved_error = GetLastError();
      HeapFree(GetProcessHeap(), 0, list_);
      list_ = nullptr;
      SetLastError(saved_error);
      return false;
    }
    return true;
  }

  bool Update(DWORD_PTR attribute, void* value, SIZE_T bytes) {
    return UpdateProcThreadAttribute(list_, 0, attribute, value, bytes,
                                     nullptr, nullptr) != FALSE;
  }

  LPPROC_THREAD_ATTRIBUTE_LIST Get() const { return list_; }

 private:
  LPPROC_THREAD_ATTRIBUTE_LIST list_ = nullptr;
};

std::wstring QuoteArgument(const std::wstring& argument) {
  if (argument.empty()) {
    return L"\"\"";
  }
  if (argument.find_first_of(L" \t\n\v\"") == std::wstring::npos) {
    return argument;
  }

  std::wstring quoted(1, L'\"');
  size_t backslashes = 0;
  for (wchar_t character : argument) {
    if (character == L'\\') {
      ++backslashes;
      continue;
    }
    if (character == L'\"') {
      quoted.append((backslashes * 2) + 1, L'\\');
      quoted.push_back(L'\"');
      backslashes = 0;
      continue;
    }
    quoted.append(backslashes, L'\\');
    backslashes = 0;
    quoted.push_back(character);
  }
  quoted.append(backslashes * 2, L'\\');
  quoted.push_back(L'\"');
  return quoted;
}

struct QuoteGoldenCase {
  const wchar_t* input;
  const wchar_t* expected;
};

constexpr QuoteGoldenCase kQuoteGoldenCases[] = {
    {L"", L"\"\""},
    {L"plain", L"plain"},
    {L"two words", L"\"two words\""},
    {L"a\\\"b", L"\"a\\\\\\\"b\""},
    {L"C:\\Program Files\\", L"\"C:\\Program Files\\\\\""},
};

bool ValidateQuoteGoldenCases() {
  for (const QuoteGoldenCase& test_case : kQuoteGoldenCases) {
    if (QuoteArgument(test_case.input) != test_case.expected) {
      return false;
    }
  }
  return true;
}

std::wstring BuildCommandLine(int argc, wchar_t* argv[], int target_index) {
  std::wstring command_line;
  for (int index = target_index; index < argc; ++index) {
    if (!command_line.empty()) {
      command_line.push_back(L' ');
    }
    command_line.append(QuoteArgument(argv[index]));
  }
  return command_line;
}

bool ParseMilliseconds(const wchar_t* value, uint64_t* result) {
  if (value == nullptr || value[0] == L'\0' || value[0] == L'-' ||
      value[0] == L'+') {
    return false;
  }
  errno = 0;
  wchar_t* end = nullptr;
  unsigned long long parsed = wcstoull(value, &end, 10);
  if (errno == ERANGE || end == value || *end != L'\0') {
    return false;
  }
  *result = static_cast<uint64_t>(parsed);
  return true;
}

struct TimeoutGoldenCase {
  const wchar_t* input;
  bool valid;
  uint64_t expected;
};

constexpr TimeoutGoldenCase kTimeoutGoldenCases[] = {
    {L"0", true, 0},
    {L"1250", true, 1250},
    {L"18446744073709551615", true, UINT64_MAX},
    {L"", false, 0},
    {L"-1", false, 0},
    {L"+1", false, 0},
    {L"1ms", false, 0},
    {L"18446744073709551616", false, 0},
};

bool ValidateTimeoutGoldenCases() {
  for (const TimeoutGoldenCase& test_case : kTimeoutGoldenCases) {
    uint64_t parsed = 0;
    bool valid = ParseMilliseconds(test_case.input, &parsed);
    if (valid != test_case.valid || (valid && parsed != test_case.expected)) {
      return false;
    }
  }
  return true;
}

bool CheckedAdd(uint64_t left, uint64_t right, uint64_t* result) {
  if (left > UINT64_MAX - right) {
    return false;
  }
  *result = left + right;
  return true;
}

bool DeadlineFromNow(uint64_t duration_milliseconds, uint64_t* deadline) {
  return CheckedAdd(static_cast<uint64_t>(GetTickCount64()),
                    duration_milliseconds, deadline);
}

DWORD RemainingWaitMilliseconds(uint64_t deadline) {
  const uint64_t now = static_cast<uint64_t>(GetTickCount64());
  if (now >= deadline) {
    return 0;
  }
  const uint64_t remaining = deadline - now;
  constexpr uint64_t kMaximumFiniteWait =
      static_cast<uint64_t>(INFINITE) - 1;
  return remaining > kMaximumFiniteWait
             ? static_cast<DWORD>(kMaximumFiniteWait)
             : static_cast<DWORD>(remaining);
}

bool IsPathSeparator(wchar_t character) {
  return character == L'\\' || character == L'/';
}

bool IsAbsoluteWindowsPath(const wchar_t* path) {
  if (path == nullptr) {
    return false;
  }
  const size_t length = wcslen(path);
  if (length >= 3 && iswalpha(path[0]) != 0 && path[1] == L':' &&
      IsPathSeparator(path[2])) {
    return true;
  }
  return length >= 3 && IsPathSeparator(path[0]) &&
         IsPathSeparator(path[1]);
}

BOOL WINAPI ControlHandler(DWORD control_type) {
  switch (control_type) {
    case CTRL_C_EVENT:
    case CTRL_BREAK_EVENT:
    case CTRL_CLOSE_EVENT:
    case CTRL_LOGOFF_EVENT:
    case CTRL_SHUTDOWN_EVENT:
      InterlockedExchange(&cancellation_requested, 1);
      return TRUE;
    default:
      return FALSE;
  }
}

bool DuplicateInheritableHandle(HANDLE source, UniqueHandle* duplicate) {
  if (source == nullptr || source == INVALID_HANDLE_VALUE) {
    SetLastError(ERROR_INVALID_HANDLE);
    return false;
  }
  HANDLE value = nullptr;
  if (!DuplicateHandle(GetCurrentProcess(), source, GetCurrentProcess(), &value,
                       0, TRUE, DUPLICATE_SAME_ACCESS)) {
    return false;
  }
  duplicate->Reset(value);
  return true;
}

bool JobIsEmpty(HANDLE job, bool* empty) {
  JOBOBJECT_BASIC_ACCOUNTING_INFORMATION accounting{};
  if (!QueryInformationJobObject(job, JobObjectBasicAccountingInformation,
                                 &accounting, sizeof(accounting), nullptr)) {
    return false;
  }
  *empty = accounting.ActiveProcesses == 0;
  return true;
}

bool WaitForOwnedCleanup(HANDLE job, HANDLE target, uint64_t deadline) {
  for (;;) {
    DWORD target_wait = WaitForSingleObject(target, 0);
    if (target_wait == WAIT_FAILED) {
      return false;
    }
    bool job_empty = false;
    if (!JobIsEmpty(job, &job_empty)) {
      return false;
    }
    if (target_wait == WAIT_OBJECT_0 && job_empty) {
      return true;
    }
    DWORD remaining = RemainingWaitMilliseconds(deadline);
    if (remaining == 0) {
      SetLastError(WAIT_TIMEOUT);
      return false;
    }
    DWORD wait_slice = remaining < kPollIntervalMilliseconds
                           ? remaining
                           : kPollIntervalMilliseconds;
    if (target_wait == WAIT_OBJECT_0) {
      Sleep(wait_slice);
    } else if (WaitForSingleObject(target, wait_slice) == WAIT_FAILED) {
      return false;
    }
  }
}

bool TerminateAndWaitForJob(HANDLE job, HANDLE target, DWORD exit_code,
                            uint64_t cleanup_milliseconds) {
  uint64_t cleanup_deadline = 0;
  if (!DeadlineFromNow(cleanup_milliseconds, &cleanup_deadline)) {
    SetLastError(ERROR_ARITHMETIC_OVERFLOW);
    return false;
  }
  if (!TerminateJobObject(job, exit_code)) {
    return false;
  }
  return WaitForOwnedCleanup(job, target, cleanup_deadline);
}

bool ControlChannelRequestsCancellation() {
  HANDLE input = GetStdHandle(STD_INPUT_HANDLE);
  if (input == nullptr || input == INVALID_HANDLE_VALUE) {
    return true;
  }

  DWORD available = 0;
  if (!PeekNamedPipe(input, nullptr, 0, nullptr, &available, nullptr)) {
    return true;
  }
  if (available == 0) {
    return false;
  }

  char buffer[64]{};
  DWORD read_count = 0;
  if (!ReadFile(input, buffer, sizeof(buffer), &read_count, nullptr)) {
    return true;
  }
  static constexpr char expected[] = "GPH1 CANCEL\n";
  if (read_count != sizeof(expected) - 1 ||
      memcmp(buffer, expected, sizeof(expected) - 1) != 0) {
    fwprintf(stderr, L"gapless_process_host: invalid control message\n");
  }
  return true;
}

int ReportWindowsError(const wchar_t* operation, DWORD exit_code,
                       DWORD error = GetLastError()) {
  fwprintf(stderr, L"gapless_process_host: %ls failed (%lu)\n", operation,
           static_cast<unsigned long>(error));
  return static_cast<int>(exit_code);
}

}  // namespace

int wmain(int argc, wchar_t* argv[]) {
  uint64_t grace_milliseconds = 0;
  uint64_t force_milliseconds = 0;
  if (argc < 7 || wcscmp(argv[1], L"--grace-ms") != 0 ||
      !ParseMilliseconds(argv[2], &grace_milliseconds) ||
      wcscmp(argv[3], L"--force-ms") != 0 ||
      !ParseMilliseconds(argv[4], &force_milliseconds) ||
      wcscmp(argv[5], L"--") != 0 || argv[6][0] == L'\0') {
    fwprintf(stderr, L"gapless_process_host: invalid arguments\n");
    return static_cast<int>(kHostFailureExitCode);
  }
  if (!IsAbsoluteWindowsPath(argv[6])) {
    fwprintf(stderr,
             L"gapless_process_host: target executable must be absolute\n");
    return static_cast<int>(kHostFailureExitCode);
  }
  uint64_t cleanup_milliseconds = 0;
  if (!CheckedAdd(grace_milliseconds, force_milliseconds,
                  &cleanup_milliseconds)) {
    fwprintf(stderr, L"gapless_process_host: cleanup budget overflow\n");
    return static_cast<int>(kHostFailureExitCode);
  }
  uint64_t cleanup_deadline_check = 0;
  if (!DeadlineFromNow(cleanup_milliseconds, &cleanup_deadline_check)) {
    fwprintf(stderr, L"gapless_process_host: cleanup deadline overflow\n");
    return static_cast<int>(kHostFailureExitCode);
  }
  (void)cleanup_deadline_check;
  if (!ValidateQuoteGoldenCases() || !ValidateTimeoutGoldenCases()) {
    fwprintf(stderr, L"gapless_process_host: startup self-test failed\n");
    return static_cast<int>(kHostFailureExitCode);
  }
  if (!SetConsoleCtrlHandler(ControlHandler, TRUE)) {
    return ReportWindowsError(L"SetConsoleCtrlHandler", kHostFailureExitCode);
  }
  HANDLE input = GetStdHandle(STD_INPUT_HANDLE);
  if (input == nullptr || input == INVALID_HANDLE_VALUE ||
      !SetHandleInformation(input, HANDLE_FLAG_INHERIT, 0)) {
    return ReportWindowsError(L"control handle setup", kHostFailureExitCode);
  }

  UniqueHandle job(CreateJobObjectW(nullptr, nullptr));
  if (!job.IsValid()) {
    return ReportWindowsError(L"CreateJobObjectW", kHostFailureExitCode);
  }
  JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
  limits.BasicLimitInformation.LimitFlags =
      JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
  if (!SetInformationJobObject(job.Get(), JobObjectExtendedLimitInformation,
                               &limits, sizeof(limits))) {
    return ReportWindowsError(L"SetInformationJobObject",
                              kHostFailureExitCode);
  }

  SECURITY_ATTRIBUTES security{};
  security.nLength = sizeof(security);
  security.bInheritHandle = TRUE;
  UniqueHandle null_input(CreateFileW(
      L"NUL", GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, &security,
      OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr));
  UniqueHandle child_output;
  UniqueHandle child_error;
  if (!null_input.IsValid() ||
      !DuplicateInheritableHandle(GetStdHandle(STD_OUTPUT_HANDLE),
                                  &child_output) ||
      !DuplicateInheritableHandle(GetStdHandle(STD_ERROR_HANDLE),
                                  &child_error)) {
    return ReportWindowsError(L"standard handle setup", kHostFailureExitCode);
  }

#if defined(GAPLESS_PROCESS_HOST_TESTING) && GAPLESS_PROCESS_HOST_TESTING
  UniqueHandle unrelated_inheritable(CreateEventW(&security, TRUE, FALSE,
                                                   nullptr));
  if (GetEnvironmentVariableW(L"GPH_TEST_CREATE_UNRELATED_HANDLE", nullptr,
                              0) != 0) {
    if (!unrelated_inheritable.IsValid()) {
      return ReportWindowsError(L"test handle setup", kHostFailureExitCode);
    }
    wchar_t handle_value[32]{};
    int printed = _snwprintf_s(
        handle_value, sizeof(handle_value) / sizeof(handle_value[0]), _TRUNCATE,
        L"%llu", static_cast<unsigned long long>(
                       reinterpret_cast<uintptr_t>(unrelated_inheritable.Get())));
    if (printed < 0 ||
        _wputenv_s(L"GPH_TEST_UNRELATED_HANDLE", handle_value) != 0) {
      SetLastError(ERROR_INVALID_DATA);
      return ReportWindowsError(L"test handle publication",
                                kHostFailureExitCode);
    }
  }
#endif

  STARTUPINFOEXW startup{};
  startup.StartupInfo.cb = sizeof(startup);
  startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES;
  startup.StartupInfo.hStdInput = null_input.Get();
  startup.StartupInfo.hStdOutput = child_output.Get();
  startup.StartupInfo.hStdError = child_error.Get();

  AttributeList attributes;
  if (!attributes.Initialize(2)) {
    return ReportWindowsError(L"InitializeProcThreadAttributeList",
                              kHostFailureExitCode);
  }
  HANDLE job_handles[] = {job.Get()};
  if (!attributes.Update(PROC_THREAD_ATTRIBUTE_JOB_LIST, job_handles,
                         sizeof(job_handles))) {
    return ReportWindowsError(L"job attribute setup", kHostFailureExitCode);
  }
  HANDLE inherited_handles[] = {
      null_input.Get(), child_output.Get(), child_error.Get()};
  if (!attributes.Update(PROC_THREAD_ATTRIBUTE_HANDLE_LIST, inherited_handles,
                         sizeof(inherited_handles))) {
    return ReportWindowsError(L"handle attribute setup", kHostFailureExitCode);
  }
  startup.lpAttributeList = attributes.Get();

  PROCESS_INFORMATION process{};
  std::wstring command_line = BuildCommandLine(argc, argv, 6);
  std::vector<wchar_t> mutable_command_line(command_line.begin(),
                                             command_line.end());
  mutable_command_line.push_back(L'\0');

  constexpr DWORD creation_flags =
      CREATE_SUSPENDED | EXTENDED_STARTUPINFO_PRESENT;
  if (!CreateProcessW(argv[6], mutable_command_line.data(), nullptr, nullptr,
                      TRUE, creation_flags, nullptr, nullptr,
                      &startup.StartupInfo, &process)) {
    return ReportWindowsError(L"target CreateProcessW",
                              kTargetStartFailureExitCode);
  }
  UniqueHandle target_process(process.hProcess);
  UniqueHandle target_thread(process.hThread);
  if (ResumeThread(target_thread.Get()) == static_cast<DWORD>(-1)) {
    DWORD saved_error = GetLastError();
    (void)TerminateAndWaitForJob(job.Get(), target_process.Get(),
                                 kTargetStartFailureExitCode,
                                 cleanup_milliseconds);
    return ReportWindowsError(L"ResumeThread", kTargetStartFailureExitCode,
                              saved_error);
  }
  target_thread.Reset();

  for (;;) {
    DWORD target_wait =
        WaitForSingleObject(target_process.Get(), kPollIntervalMilliseconds);
    if (target_wait == WAIT_FAILED) {
      DWORD saved_error = GetLastError();
      (void)TerminateAndWaitForJob(job.Get(), target_process.Get(),
                                   kHostFailureExitCode,
                                   cleanup_milliseconds);
      return ReportWindowsError(L"target wait", kHostFailureExitCode,
                                saved_error);
    }
    if (target_wait == WAIT_OBJECT_0) {
      DWORD target_exit = kHostFailureExitCode;
      if (!GetExitCodeProcess(target_process.Get(), &target_exit)) {
        return ReportWindowsError(L"GetExitCodeProcess", kHostFailureExitCode);
      }
      bool job_empty = false;
      if (!JobIsEmpty(job.Get(), &job_empty)) {
        return ReportWindowsError(L"QueryInformationJobObject",
                                  kHostFailureExitCode);
      }
      if (!job_empty &&
          !TerminateAndWaitForJob(job.Get(), target_process.Get(),
                                  kCancelledExitCode,
                                  cleanup_milliseconds)) {
        return ReportWindowsError(L"lingering job cleanup",
                                  kHostFailureExitCode);
      }
      return static_cast<int>(target_exit);
    }

    if (InterlockedCompareExchange(&cancellation_requested, 0, 0) != 0 ||
        ControlChannelRequestsCancellation()) {
      if (!TerminateAndWaitForJob(job.Get(), target_process.Get(),
                                  kCancelledExitCode,
                                  cleanup_milliseconds)) {
        return ReportWindowsError(L"cancellation job cleanup",
                                  kHostFailureExitCode);
      }
      return static_cast<int>(kCancelledExitCode);
    }
  }
}
