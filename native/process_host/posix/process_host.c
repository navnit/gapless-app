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

static int remaining_milliseconds(int64_t deadline) {
  int64_t now = monotonic_milliseconds();
  if (now < 0 || now >= deadline) {
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

static int read_exact_before_deadline(int descriptor, void *buffer,
                                      size_t length, int64_t deadline,
                                      int allow_eof) {
  char *cursor = (char *)buffer;
  size_t received = 0;
  while (received < length) {
    struct pollfd item = {descriptor, POLLIN | POLLHUP, 0};
    int timeout = remaining_milliseconds(deadline);
    if (timeout == 0) {
      errno = ETIMEDOUT;
      return -1;
    }
    int poll_result;
    do {
      poll_result = poll(&item, 1, timeout);
    } while (poll_result == -1 && errno == EINTR);
    if (poll_result <= 0) {
      if (poll_result == 0) {
        errno = ETIMEDOUT;
      }
      return -1;
    }
    ssize_t read_count;
    do {
      read_count = read(descriptor, cursor + received, length - received);
    } while (read_count == -1 && errno == EINTR);
    if (read_count > 0) {
      received += (size_t)read_count;
      continue;
    }
    if (read_count == 0 && allow_eof && received == 0) {
      return 0;
    }
    errno = EPIPE;
    return -1;
  }
  return 1;
}

static void cancellation_signal_handler(int signal_number) {
  cancellation_signal = signal_number;
  if (signal_pipe[1] >= 0) {
    const unsigned char byte = 1;
    ssize_t ignored = write(signal_pipe[1], &byte, sizeof(byte));
    (void)ignored;
  }
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

  execvp(target_arguments[0], target_arguments);
  int child_error = errno;
  (void)write_all(exec_error_fd, &child_error, sizeof(child_error));
  _exit(kTargetStartFailureExitCode);
}

static int parse_milliseconds(const char *value, int *result) {
  if (value == NULL || *value == '\0') {
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
  int result;
  do {
    result = poll(&item, 1, milliseconds);
  } while (result == -1 && errno == EINTR);
  if (result > 0 && (item.revents & POLLIN) != 0) {
    unsigned char bytes[32];
    ssize_t ignored = read(signal_pipe[0], bytes, sizeof(bytes));
    (void)ignored;
  }
}

static int wait_for_group_exit(pid_t process_group, pid_t target,
                               int *target_reaped, int *target_status,
                               int64_t deadline) {
  while (group_exists(process_group)) {
    reap_target_nonblocking(target, target_reaped, target_status);
    int remaining = remaining_milliseconds(deadline);
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
  if (group_exists(process_group) && kill(-process_group, SIGTERM) == -1 &&
      errno != ESRCH) {
    fprintf(stderr,
            "gapless_process_host: could not terminate owned process group "
            "(%d)\n",
            errno);
  }
  int64_t now = monotonic_milliseconds();
  if (now >= 0 && wait_for_group_exit(process_group, target, target_reaped,
                                      target_status,
                                      now + grace_milliseconds)) {
    return 1;
  }

  if (group_exists(process_group) && kill(-process_group, SIGKILL) == -1 &&
      errno != ESRCH) {
    fprintf(stderr,
            "gapless_process_host: could not force-kill owned process group "
            "(%d)\n",
            errno);
  }
  now = monotonic_milliseconds();
  if (now >= 0 && wait_for_group_exit(process_group, target, target_reaped,
                                      target_status,
                                      now + force_milliseconds)) {
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

static int control_requests_cancellation(void) {
  char buffer[64];
  ssize_t count;
  do {
    count = read(STDIN_FILENO, buffer, sizeof(buffer));
  } while (count == -1 && errno == EINTR);
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
    (void)kill(target, SIGKILL);
    return kHostFailureExitCode;
  }
  int64_t start_deadline = start_now + kStartDeadlineMilliseconds;
  struct start_message message = {0, 0};
  if (read_exact_before_deadline(ready_pipe[0], &message, sizeof(message),
                                 start_deadline, 0) != 1 ||
      message.state != 'R') {
    int child_error = message.state == 'E' ? message.error_number : errno;
    fprintf(stderr,
            "gapless_process_host: target process-group setup failed (%d)\n",
            child_error);
    (void)kill(target, SIGKILL);
    (void)waitpid(target, NULL, 0);
    return kTargetStartFailureExitCode;
  }
  close_if_open(ready_pipe[0]);

  pid_t process_group = getpgid(target);
  if (process_group != target) {
    fprintf(stderr, "gapless_process_host: process-group verification failed\n");
    (void)kill(target, SIGKILL);
    (void)waitpid(target, NULL, 0);
    return kTargetStartFailureExitCode;
  }
  const unsigned char acknowledgment = 1;
  if (write_all(acknowledgment_pipe[1], &acknowledgment,
                sizeof(acknowledgment)) == -1) {
    (void)kill(-process_group, SIGKILL);
    (void)waitpid(target, NULL, 0);
    return kTargetStartFailureExitCode;
  }
  close_if_open(acknowledgment_pipe[1]);

  int exec_error = 0;
  int exec_result = read_exact_before_deadline(
      exec_error_pipe[0], &exec_error, sizeof(exec_error), start_deadline, 1);
  close_if_open(exec_error_pipe[0]);
  if (exec_result != 0) {
    fprintf(stderr, "gapless_process_host: target exec failed (%d: %.160s)\n",
            exec_error, strerror(exec_error));
    (void)kill(-process_group, SIGKILL);
    (void)waitpid(target, NULL, 0);
    return kTargetStartFailureExitCode;
  }

  int target_reaped = 0;
  int target_status = 0;
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
    int poll_result;
    do {
      poll_result = poll(items, 2, kPollIntervalMilliseconds);
    } while (poll_result == -1 && errno == EINTR);
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
