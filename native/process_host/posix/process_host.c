#define _POSIX_C_SOURCE 200809L

#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

enum {
  kCancelledExitCode = 125,
  kHostFailureExitCode = 126,
  kTargetStartFailureExitCode = 127,
  kPollIntervalMilliseconds = 20,
  kStartDeadlineMilliseconds = 10000,
};

enum startup_event_result {
  kStartupEventFailure = -1,
  kStartupEventCancelled = -2,
  kStartupEventEof = 0,
  kStartupEventData = 1,
};

struct start_message {
  char state;
  int error_number;
};

static int signal_pipe[2] = {-1, -1};
static volatile sig_atomic_t cancellation_signal = 0;

static void close_if_open(int descriptor) {
  if (descriptor >= 0) {
    while (close(descriptor) == -1 && errno == EINTR) {
    }
  }
}

static int set_close_on_exec(int descriptor) {
  int flags;
  do {
    flags = fcntl(descriptor, F_GETFD);
  } while (flags == -1 && errno == EINTR);
  if (flags == -1) {
    return -1;
  }
  int result;
  do {
    result = fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC);
  } while (result == -1 && errno == EINTR);
  return result;
}

static int set_nonblocking(int descriptor) {
  int flags;
  do {
    flags = fcntl(descriptor, F_GETFL);
  } while (flags == -1 && errno == EINTR);
  if (flags == -1) {
    return -1;
  }
  int result;
  do {
    result = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK);
  } while (result == -1 && errno == EINTR);
  return result;
}

static int create_pipe(int descriptors[2], int nonblocking_write) {
  if (pipe(descriptors) == -1) {
    return -1;
  }
  if (set_close_on_exec(descriptors[0]) == -1 ||
      set_close_on_exec(descriptors[1]) == -1 ||
      (nonblocking_write && set_nonblocking(descriptors[1]) == -1)) {
    int saved_error = errno;
    close_if_open(descriptors[0]);
    close_if_open(descriptors[1]);
    descriptors[0] = -1;
    descriptors[1] = -1;
    errno = saved_error;
    return -1;
  }
  return 0;
}

static int64_t monotonic_milliseconds(void) {
  struct timespec value;
  if (clock_gettime(CLOCK_MONOTONIC, &value) == -1) {
    return -1;
  }
  return ((int64_t)value.tv_sec * 1000) + (value.tv_nsec / 1000000);
}

static int checked_deadline(int64_t start, int milliseconds,
                            int64_t *deadline) {
  if (milliseconds < 0 || start < 0 ||
      start > INT64_MAX - (int64_t)milliseconds) {
    errno = EOVERFLOW;
    return -1;
  }
  *deadline = start + milliseconds;
  return 0;
}

static int remaining_milliseconds(int64_t deadline) {
  int64_t now = monotonic_milliseconds();
  if (now < 0) {
    return -1;
  }
  if (now >= deadline) {
    return 0;
  }
  int64_t remaining = deadline - now;
  return remaining > INT32_MAX ? INT32_MAX : (int)remaining;
}

static int write_all(int descriptor, const void *buffer, size_t length) {
  const char *cursor = (const char *)buffer;
  while (length > 0) {
    ssize_t written = write(descriptor, cursor, length);
    if (written > 0) {
      cursor += written;
      length -= (size_t)written;
      continue;
    }
    if (written == -1 && errno == EINTR) {
      continue;
    }
    return -1;
  }
  return 0;
}

static void drain_signal_pipe(void) {
  unsigned char bytes[32];
  ssize_t ignored = read(signal_pipe[0], bytes, sizeof(bytes));
  (void)ignored;
}

static void cancellation_signal_handler(int signal_number) {
  int saved_error = errno;
  cancellation_signal = signal_number;
  if (signal_pipe[1] >= 0) {
    const unsigned char byte = 1;
    ssize_t ignored = write(signal_pipe[1], &byte, sizeof(byte));
    (void)ignored;
  }
  errno = saved_error;
}

static int install_signal_handlers(void) {
  struct sigaction action;
  memset(&action, 0, sizeof(action));
  action.sa_handler = cancellation_signal_handler;
  sigemptyset(&action.sa_mask);
  if (sigaction(SIGTERM, &action, NULL) == -1 ||
      sigaction(SIGINT, &action, NULL) == -1 ||
      sigaction(SIGHUP, &action, NULL) == -1) {
    return -1;
  }
  struct sigaction ignore;
  memset(&ignore, 0, sizeof(ignore));
  ignore.sa_handler = SIG_IGN;
  sigemptyset(&ignore.sa_mask);
  return sigaction(SIGPIPE, &ignore, NULL);
}

static void restore_child_signals(void) {
  struct sigaction action;
  memset(&action, 0, sizeof(action));
  action.sa_handler = SIG_DFL;
  sigemptyset(&action.sa_mask);
  (void)sigaction(SIGTERM, &action, NULL);
  (void)sigaction(SIGINT, &action, NULL);
  (void)sigaction(SIGHUP, &action, NULL);
  (void)sigaction(SIGPIPE, &action, NULL);
}

static int control_requests_cancellation(void) {
  char buffer[64];
  ssize_t count = read(STDIN_FILENO, buffer, sizeof(buffer));
  if (count == -1 && errno == EINTR) {
    return cancellation_signal != 0;
  }
  if (count == 0) {
    return 1;
  }
  if (count < 0) {
    return errno == EAGAIN || errno == EWOULDBLOCK ? 0 : 1;
  }
  static const char expected[] = "GPH1 CANCEL\n";
  if ((size_t)count != sizeof(expected) - 1 ||
      memcmp(buffer, expected, sizeof(expected) - 1) != 0) {
    fprintf(stderr, "gapless_process_host: invalid control message\n");
  }
  return 1;
}

static int wait_for_startup_control(int timeout_milliseconds) {
  for (;;) {
    if (cancellation_signal != 0) {
      return 1;
    }
    struct pollfd items[2] = {
        {STDIN_FILENO, POLLIN | POLLHUP, 0},
        {signal_pipe[0], POLLIN, 0},
    };
    int result = poll(items, 2, timeout_milliseconds);
    if (result == -1 && errno == EINTR) {
      continue;
    }
    if (result == -1) {
      return -1;
    }
    if ((items[1].revents & POLLIN) != 0) {
      drain_signal_pipe();
      return 1;
    }
    if ((items[0].revents & (POLLIN | POLLHUP | POLLERR | POLLNVAL)) != 0) {
      return control_requests_cancellation();
    }
    return 0;
  }
}

static int wait_for_startup_event(int descriptor, void *buffer, size_t length,
                                  int64_t deadline, int allow_eof) {
  char *cursor = (char *)buffer;
  size_t received = 0;
  while (received < length) {
    int timeout = remaining_milliseconds(deadline);
    if (timeout < 0) {
      return kStartupEventFailure;
    }
    if (timeout == 0) {
      errno = ETIMEDOUT;
      return kStartupEventFailure;
    }
    struct pollfd items[3] = {
        {descriptor, POLLIN | POLLHUP, 0},
        {STDIN_FILENO, POLLIN | POLLHUP, 0},
        {signal_pipe[0], POLLIN, 0},
    };
    int poll_result = poll(items, 3, timeout);
    if (poll_result == -1 && errno == EINTR) {
      continue;
    }
    if (poll_result <= 0) {
      if (poll_result == 0) {
        errno = ETIMEDOUT;
      }
      return kStartupEventFailure;
    }
    if (cancellation_signal != 0 || (items[2].revents & POLLIN) != 0) {
      if ((items[2].revents & POLLIN) != 0) {
        drain_signal_pipe();
      }
      return kStartupEventCancelled;
    }
    if ((items[1].revents & (POLLIN | POLLHUP | POLLERR | POLLNVAL)) != 0 &&
        control_requests_cancellation()) {
      return kStartupEventCancelled;
    }
    if ((items[0].revents & (POLLIN | POLLHUP | POLLERR | POLLNVAL)) == 0) {
      continue;
    }
    ssize_t read_count =
        read(descriptor, cursor + received, length - received);
    if (read_count == -1 && errno == EINTR) {
      continue;
    }
    if (read_count > 0) {
      received += (size_t)read_count;
      continue;
    }
    if (read_count == 0 && allow_eof && received == 0) {
      return kStartupEventEof;
    }
    errno = EPIPE;
    return kStartupEventFailure;
  }
  return kStartupEventData;
}

static void write_ready_message(int descriptor, int error_number) {
  struct start_message message;
  message.state = error_number == 0 ? 'R' : 'E';
  message.error_number = error_number;
  (void)write_all(descriptor, &message, sizeof(message));
}

static int await_parent_acknowledgment(int descriptor) {
  unsigned char acknowledgment = 0;
  ssize_t result;
  do {
    result = read(descriptor, &acknowledgment, sizeof(acknowledgment));
  } while (result == -1 && errno == EINTR);
  return result == 1 && acknowledgment == 1 ? 0 : -1;
}

static void child_main(int ready_fd, int acknowledgment_fd, int exec_error_fd,
                       char *const target_arguments[]) {
  restore_child_signals();
  close_if_open(signal_pipe[0]);
  close_if_open(signal_pipe[1]);

  if (setpgid(0, 0) == -1) {
    write_ready_message(ready_fd, errno);
    _exit(kTargetStartFailureExitCode);
  }
  write_ready_message(ready_fd, 0);
  close_if_open(ready_fd);
  if (await_parent_acknowledgment(acknowledgment_fd) == -1) {
    _exit(kTargetStartFailureExitCode);
  }
  close_if_open(acknowledgment_fd);

  int null_input;
  do {
    null_input = open("/dev/null", O_RDONLY);
  } while (null_input == -1 && errno == EINTR);
  if (null_input == -1 || dup2(null_input, STDIN_FILENO) == -1) {
    int child_error = errno;
    (void)write_all(exec_error_fd, &child_error, sizeof(child_error));
    _exit(kTargetStartFailureExitCode);
  }
  if (null_input != STDIN_FILENO) {
    close_if_open(null_input);
  }

  execv(target_arguments[0], target_arguments);
  int child_error = errno;
  (void)write_all(exec_error_fd, &child_error, sizeof(child_error));
  _exit(kTargetStartFailureExitCode);
}

static int parse_milliseconds(const char *value, int *result) {
  if (value == NULL || *value == '\0' || *value == '-') {
    return -1;
  }
  errno = 0;
  char *end = NULL;
  unsigned long parsed = strtoul(value, &end, 10);
  if (errno != 0 || *end != '\0' || parsed > INT32_MAX) {
    return -1;
  }
  *result = (int)parsed;
  return 0;
}

static int group_exists(pid_t process_group) {
  if (kill(-process_group, 0) == 0) {
    return 1;
  }
  return errno == EPERM;
}

static void reap_target_nonblocking(pid_t target, int *reaped, int *status) {
  if (*reaped) {
    return;
  }
  pid_t result;
  do {
    result = waitpid(target, status, WNOHANG);
  } while (result == -1 && errno == EINTR);
  if (result == target || (result == -1 && errno == ECHILD)) {
    *reaped = 1;
  }
}

static void wait_for_target(pid_t target, int *reaped, int *status) {
  if (*reaped) {
    return;
  }
  pid_t result;
  do {
    result = waitpid(target, status, 0);
  } while (result == -1 && errno == EINTR);
  if (result == target || (result == -1 && errno == ECHILD)) {
    *reaped = 1;
  }
}

static void wait_cleanup_tick(int milliseconds) {
  struct pollfd item = {signal_pipe[0], POLLIN, 0};
  int result = poll(&item, 1, milliseconds);
  if (result > 0 && (item.revents & POLLIN) != 0) {
    drain_signal_pipe();
  }
}

static int wait_for_group_exit(pid_t process_group, pid_t target,
                               int *target_reaped, int *target_status,
                               int64_t deadline) {
  while (group_exists(process_group)) {
    reap_target_nonblocking(target, target_reaped, target_status);
    int remaining = remaining_milliseconds(deadline);
    if (remaining < 0) {
      return -1;
    }
    if (remaining == 0) {
      return 0;
    }
    wait_cleanup_tick(remaining < kPollIntervalMilliseconds
                          ? remaining
                          : kPollIntervalMilliseconds);
  }
  wait_for_target(target, target_reaped, target_status);
  return 1;
}

static int cleanup_group(pid_t process_group, pid_t target, int *target_reaped,
                         int *target_status, int grace_milliseconds,
                         int force_milliseconds) {
  int64_t cleanup_started = monotonic_milliseconds();
  int64_t grace_deadline = -1;
  int64_t cleanup_deadline = -1;
  if (checked_deadline(cleanup_started, grace_milliseconds, &grace_deadline) ==
          -1 ||
      checked_deadline(grace_deadline, force_milliseconds,
                       &cleanup_deadline) == -1) {
    (void)kill(-process_group, SIGKILL);
    wait_for_target(target, target_reaped, target_status);
    return !group_exists(process_group);
  }

  if (group_exists(process_group) && kill(-process_group, SIGTERM) == -1 &&
      errno != ESRCH) {
    fprintf(stderr,
            "gapless_process_host: could not terminate owned process group "
            "(%d)\n",
            errno);
  }
  int grace_result = wait_for_group_exit(process_group, target, target_reaped,
                                         target_status, grace_deadline);
  if (grace_result == 1) {
    return 1;
  }

  if (group_exists(process_group) && kill(-process_group, SIGKILL) == -1 &&
      errno != ESRCH) {
    fprintf(stderr,
            "gapless_process_host: could not force-kill owned process group "
            "(%d)\n",
            errno);
  }
  int force_result = wait_for_group_exit(process_group, target, target_reaped,
                                         target_status, cleanup_deadline);
  if (force_result == 1) {
    return 1;
  }

  (void)kill(-process_group, SIGKILL);
  reap_target_nonblocking(target, target_reaped, target_status);
  return !group_exists(process_group);
}

static int target_exit_code(int status) {
  if (WIFEXITED(status)) {
    return WEXITSTATUS(status);
  }
  if (WIFSIGNALED(status)) {
    int code = 128 + WTERMSIG(status);
    return code > 255 ? 255 : code;
  }
  return kHostFailureExitCode;
}

static void kill_and_reap_child(pid_t target) {
  (void)kill(target, SIGKILL);
  pid_t result;
  do {
    result = waitpid(target, NULL, 0);
  } while (result == -1 && errno == EINTR);
}

static void terminate_starting_child(pid_t target, int cleanup_milliseconds) {
  (void)kill(target, SIGTERM);
  int64_t started = monotonic_milliseconds();
  int64_t deadline = -1;
  if (checked_deadline(started, cleanup_milliseconds, &deadline) == 0) {
    for (;;) {
      pid_t result = waitpid(target, NULL, WNOHANG);
      if (result == target || (result == -1 && errno == ECHILD)) {
        return;
      }
      if (result == -1 && errno != EINTR) {
        break;
      }
      int remaining = remaining_milliseconds(deadline);
      if (remaining <= 0) {
        break;
      }
      wait_cleanup_tick(remaining < kPollIntervalMilliseconds
                            ? remaining
                            : kPollIntervalMilliseconds);
    }
  }
  kill_and_reap_child(target);
}

static int wait_before_launch_for_test(void) {
#if defined(GAPLESS_PROCESS_HOST_TESTING) && GAPLESS_PROCESS_HOST_TESTING
  const char *ready_path = getenv("GPH_TEST_PRE_ACK_READY");
  const char *release_path = getenv("GPH_TEST_PRE_ACK_RELEASE");
  if (ready_path == NULL && release_path == NULL) {
    return 0;
  }
  if (ready_path == NULL || release_path == NULL) {
    errno = EINVAL;
    return -1;
  }
  int ready_fd = open(ready_path, O_WRONLY | O_CREAT | O_TRUNC, 0600);
  if (ready_fd == -1) {
    return -1;
  }
  static const char ready[] = "ready";
  int write_result = write_all(ready_fd, ready, sizeof(ready) - 1);
  close_if_open(ready_fd);
  if (write_result == -1) {
    return -1;
  }
  while (access(release_path, F_OK) == -1) {
    if (errno != ENOENT) {
      return -1;
    }
    int control = wait_for_startup_control(kPollIntervalMilliseconds);
    if (control != 0) {
      return control;
    }
  }
#endif
  return 0;
}

int main(int argc, char *argv[]) {
  int grace_milliseconds = -1;
  int force_milliseconds = -1;
  if (argc < 7 || strcmp(argv[1], "--grace-ms") != 0 ||
      parse_milliseconds(argv[2], &grace_milliseconds) == -1 ||
      strcmp(argv[3], "--force-ms") != 0 ||
      parse_milliseconds(argv[4], &force_milliseconds) == -1 ||
      strcmp(argv[5], "--") != 0 || argv[6][0] == '\0') {
    fprintf(stderr, "gapless_process_host: invalid arguments\n");
    return kHostFailureExitCode;
  }
  if (argv[6][0] != '/') {
    fprintf(stderr,
            "gapless_process_host: target executable must be absolute\n");
    return kHostFailureExitCode;
  }
  if (grace_milliseconds > INT32_MAX - force_milliseconds) {
    fprintf(stderr, "gapless_process_host: cleanup budget overflow\n");
    return kHostFailureExitCode;
  }
  int cleanup_milliseconds = grace_milliseconds + force_milliseconds;

  if (create_pipe(signal_pipe, 1) == -1 || install_signal_handlers() == -1) {
    fprintf(stderr, "gapless_process_host: signal setup failed (%d)\n", errno);
    return kHostFailureExitCode;
  }

  int ready_pipe[2] = {-1, -1};
  int acknowledgment_pipe[2] = {-1, -1};
  int exec_error_pipe[2] = {-1, -1};
  if (create_pipe(ready_pipe, 0) == -1 ||
      create_pipe(acknowledgment_pipe, 0) == -1 ||
      create_pipe(exec_error_pipe, 0) == -1) {
    fprintf(stderr, "gapless_process_host: startup pipe failed (%d)\n", errno);
    return kHostFailureExitCode;
  }

  pid_t target = fork();
  if (target == -1) {
    fprintf(stderr, "gapless_process_host: fork failed (%d)\n", errno);
    return kHostFailureExitCode;
  }
  if (target == 0) {
    close_if_open(ready_pipe[0]);
    close_if_open(acknowledgment_pipe[1]);
    close_if_open(exec_error_pipe[0]);
    child_main(ready_pipe[1], acknowledgment_pipe[0], exec_error_pipe[1],
               &argv[6]);
  }

  close_if_open(ready_pipe[1]);
  close_if_open(acknowledgment_pipe[0]);
  close_if_open(exec_error_pipe[1]);
  int64_t start_now = monotonic_milliseconds();
  if (start_now < 0) {
    kill_and_reap_child(target);
    return kHostFailureExitCode;
  }
  int64_t start_deadline = -1;
  if (checked_deadline(start_now, kStartDeadlineMilliseconds,
                       &start_deadline) == -1) {
    kill_and_reap_child(target);
    return kHostFailureExitCode;
  }

  struct start_message message = {0, 0};
  int ready_result = wait_for_startup_event(
      ready_pipe[0], &message, sizeof(message), start_deadline, 0);
  close_if_open(ready_pipe[0]);
  if (ready_result == kStartupEventCancelled) {
    terminate_starting_child(target, cleanup_milliseconds);
    return kCancelledExitCode;
  }
  if (ready_result != kStartupEventData || message.state != 'R') {
    int child_error = message.state == 'E' ? message.error_number : errno;
    fprintf(stderr,
            "gapless_process_host: target process-group setup failed (%d)\n",
            child_error);
    kill_and_reap_child(target);
    return kTargetStartFailureExitCode;
  }

  pid_t process_group = getpgid(target);
  if (process_group != target) {
    fprintf(stderr, "gapless_process_host: process-group verification failed\n");
    kill_and_reap_child(target);
    return kTargetStartFailureExitCode;
  }
  int target_reaped = 0;
  int target_status = 0;
  int pre_ack = wait_before_launch_for_test();
  if (pre_ack == 0) {
    pre_ack = wait_for_startup_control(0);
  }
  if (pre_ack != 0) {
    int cleaned = cleanup_group(process_group, target, &target_reaped,
                                &target_status, grace_milliseconds,
                                force_milliseconds);
    if (pre_ack < 0 || !cleaned) {
      return kHostFailureExitCode;
    }
    return kCancelledExitCode;
  }

  const unsigned char acknowledgment = 1;
  if (write_all(acknowledgment_pipe[1], &acknowledgment,
                sizeof(acknowledgment)) == -1) {
    kill_and_reap_child(target);
    return kTargetStartFailureExitCode;
  }
  close_if_open(acknowledgment_pipe[1]);

  int exec_error = 0;
  int exec_result = wait_for_startup_event(
      exec_error_pipe[0], &exec_error, sizeof(exec_error), start_deadline, 1);
  close_if_open(exec_error_pipe[0]);
  if (exec_result == kStartupEventCancelled) {
    int cleaned = cleanup_group(process_group, target, &target_reaped,
                                &target_status, grace_milliseconds,
                                force_milliseconds);
    return cleaned ? kCancelledExitCode : kHostFailureExitCode;
  }
  if (exec_result != kStartupEventEof) {
    if (exec_result == kStartupEventData) {
      fprintf(stderr, "gapless_process_host: target exec failed (%d: %.160s)\n",
              exec_error, strerror(exec_error));
    } else {
      fprintf(stderr, "gapless_process_host: target exec status failed (%d)\n",
              errno);
    }
    kill_and_reap_child(target);
    return kTargetStartFailureExitCode;
  }

  for (;;) {
    reap_target_nonblocking(target, &target_reaped, &target_status);
    if (target_reaped) {
      int code = target_exit_code(target_status);
      if (group_exists(process_group) &&
          !cleanup_group(process_group, target, &target_reaped, &target_status,
                         grace_milliseconds, force_milliseconds)) {
        fprintf(stderr,
                "gapless_process_host: lingering process group exceeded "
                "cleanup deadline\n");
        return kHostFailureExitCode;
      }
      return code;
    }

    struct pollfd items[2] = {
        {STDIN_FILENO, POLLIN | POLLHUP, 0},
        {signal_pipe[0], POLLIN, 0},
    };
    int poll_result = poll(items, 2, kPollIntervalMilliseconds);
    if (poll_result == -1 && errno == EINTR) {
      continue;
    }
    if (poll_result == -1) {
      fprintf(stderr, "gapless_process_host: control wait failed (%d)\n",
              errno);
      cancellation_signal = SIGTERM;
    }
    int cancel = cancellation_signal != 0;
    if ((items[0].revents & (POLLIN | POLLHUP | POLLERR | POLLNVAL)) != 0) {
      cancel = control_requests_cancellation();
    }
    if ((items[1].revents & POLLIN) != 0) {
      drain_signal_pipe();
      cancel = 1;
    }
    if (cancel) {
      int cleaned = cleanup_group(
          process_group, target, &target_reaped, &target_status,
          grace_milliseconds, force_milliseconds);
      if (!cleaned) {
        fprintf(stderr,
                "gapless_process_host: cancellation cleanup deadline "
                "expired\n");
        return kHostFailureExitCode;
      }
      return kCancelledExitCode;
    }
  }
}
