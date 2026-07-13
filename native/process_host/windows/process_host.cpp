#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <cstring>
#include <cwchar>
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

bool ParseMilliseconds(const wchar_t* value, DWORD* result) {
  if (value == nullptr || *value == L'\0') {
    return false;
  }
  wchar_t* end = nullptr;
  unsigned long parsed = wcstoul(value, &end, 10);
  if (*end != L'\0') {
    return false;
  }
  *result = static_cast<DWORD>(parsed);
  return true;
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

bool ConfigureInheritedHandle(HANDLE handle) {
  return handle != nullptr && handle != INVALID_HANDLE_VALUE &&
         SetHandleInformation(handle, HANDLE_FLAG_INHERIT,
                              HANDLE_FLAG_INHERIT) != FALSE;
}

bool JobIsEmpty(HANDLE job) {
  JOBOBJECT_BASIC_ACCOUNTING_INFORMATION accounting{};
  if (!QueryInformationJobObject(job, JobObjectBasicAccountingInformation,
                                 &accounting, sizeof(accounting), nullptr)) {
    return false;
  }
  return accounting.ActiveProcesses == 0;
}

bool WaitForEmptyJob(HANDLE job, DWORD timeout_milliseconds) {
  const ULONGLONG deadline = GetTickCount64() + timeout_milliseconds;
  while (!JobIsEmpty(job)) {
    const ULONGLONG now = GetTickCount64();
    if (now >= deadline) {
      return false;
    }
    DWORD remaining = static_cast<DWORD>(deadline - now);
    Sleep(remaining < kPollIntervalMilliseconds ? remaining
                                                : kPollIntervalMilliseconds);
  }
  return true;
}

bool ControlChannelRequestsCancellation() {
  HANDLE input = GetStdHandle(STD_INPUT_HANDLE);
  if (input == nullptr || input == INVALID_HANDLE_VALUE) {
    return true;
  }

  DWORD available = 0;
  if (!PeekNamedPipe(input, nullptr, 0, nullptr, &available, nullptr)) {
    return GetLastError() == ERROR_NO_DATA ||
           GetLastError() == ERROR_BROKEN_PIPE ||
           GetLastError() == ERROR_INVALID_HANDLE;
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

int ReportWindowsError(const wchar_t* operation, DWORD exit_code) {
  fwprintf(stderr, L"gapless_process_host: %ls failed (%lu)\n", operation,
           static_cast<unsigned long>(GetLastError()));
  return static_cast<int>(exit_code);
}

}  // namespace

int wmain(int argc, wchar_t* argv[]) {
  DWORD grace_milliseconds = 0;
  DWORD force_milliseconds = 0;
  if (argc < 7 || wcscmp(argv[1], L"--grace-ms") != 0 ||
      !ParseMilliseconds(argv[2], &grace_milliseconds) ||
      wcscmp(argv[3], L"--force-ms") != 0 ||
      !ParseMilliseconds(argv[4], &force_milliseconds) ||
      wcscmp(argv[5], L"--") != 0 || argv[6][0] == L'\0') {
    fwprintf(stderr, L"gapless_process_host: invalid arguments\n");
    return static_cast<int>(kHostFailureExitCode);
  }
  if (!ValidateQuoteGoldenCases()) {
    fwprintf(stderr, L"gapless_process_host: argument quoting self-test failed\n");
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
  HANDLE output = GetStdHandle(STD_OUTPUT_HANDLE);
  HANDLE error = GetStdHandle(STD_ERROR_HANDLE);
  if (!null_input.IsValid() || !ConfigureInheritedHandle(output) ||
      !ConfigureInheritedHandle(error)) {
    return ReportWindowsError(L"standard handle setup", kHostFailureExitCode);
  }

  STARTUPINFOW startup{};
  startup.cb = sizeof(startup);
  startup.dwFlags = STARTF_USESTDHANDLES;
  startup.hStdInput = null_input.Get();
  startup.hStdOutput = output;
  startup.hStdError = error;
  PROCESS_INFORMATION process{};
  std::wstring command_line = BuildCommandLine(argc, argv, 6);
  std::vector<wchar_t> mutable_command_line(command_line.begin(),
                                             command_line.end());
  mutable_command_line.push_back(L'\0');

  if (!CreateProcessW(argv[6], mutable_command_line.data(), nullptr, nullptr,
                      TRUE, CREATE_SUSPENDED, nullptr, nullptr, &startup,
                      &process)) {
    return ReportWindowsError(L"target CreateProcessW",
                              kTargetStartFailureExitCode);
  }
  UniqueHandle target_process(process.hProcess);
  UniqueHandle target_thread(process.hThread);
  if (!AssignProcessToJobObject(job.Get(), target_process.Get())) {
    DWORD saved_error = GetLastError();
    TerminateProcess(target_process.Get(), kTargetStartFailureExitCode);
    WaitForSingleObject(target_process.Get(), force_milliseconds);
    SetLastError(saved_error);
    return ReportWindowsError(L"AssignProcessToJobObject",
                              kTargetStartFailureExitCode);
  }
  if (ResumeThread(target_thread.Get()) == static_cast<DWORD>(-1)) {
    DWORD saved_error = GetLastError();
    TerminateJobObject(job.Get(), kTargetStartFailureExitCode);
    WaitForSingleObject(target_process.Get(), force_milliseconds);
    SetLastError(saved_error);
    return ReportWindowsError(L"ResumeThread", kTargetStartFailureExitCode);
  }
  target_thread.Reset();

  for (;;) {
    DWORD target_wait =
        WaitForSingleObject(target_process.Get(), kPollIntervalMilliseconds);
    if (target_wait == WAIT_FAILED) {
      InterlockedExchange(&cancellation_requested, 1);
    }
    if (target_wait == WAIT_OBJECT_0) {
      DWORD target_exit = kHostFailureExitCode;
      if (!GetExitCodeProcess(target_process.Get(), &target_exit)) {
        return ReportWindowsError(L"GetExitCodeProcess", kHostFailureExitCode);
      }
      if (!JobIsEmpty(job.Get())) {
        if (!TerminateJobObject(job.Get(), kCancelledExitCode) ||
            !WaitForEmptyJob(job.Get(),
                             grace_milliseconds + force_milliseconds)) {
          return ReportWindowsError(L"lingering job cleanup",
                                    kHostFailureExitCode);
        }
      }
      return static_cast<int>(target_exit);
    }

    if (InterlockedCompareExchange(&cancellation_requested, 0, 0) != 0 ||
        ControlChannelRequestsCancellation()) {
      if (!TerminateJobObject(job.Get(), kCancelledExitCode)) {
        return ReportWindowsError(L"TerminateJobObject", kHostFailureExitCode);
      }
      WaitForSingleObject(target_process.Get(),
                          grace_milliseconds + force_milliseconds);
      if (!WaitForEmptyJob(job.Get(), force_milliseconds)) {
        fwprintf(stderr,
                 L"gapless_process_host: cancellation cleanup deadline "
                 L"expired\n");
        return static_cast<int>(kHostFailureExitCode);
      }
      return static_cast<int>(kCancelledExitCode);
    }
  }
}
