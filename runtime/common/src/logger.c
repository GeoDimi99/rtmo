#include "logger.h"
#include <stdio.h>
#include <time.h>
#include <stdarg.h>
#include <errno.h>
#include <limits.h>     /* PIPE_BUF */
#include <unistd.h>     /* write, STDOUT_FILENO */

/* One log line, newline included; longer messages are truncated. It must stay
 * <= PIPE_BUF so that a single write() to a pipe is atomic (POSIX), and small
 * because it lives on the stack of task threads created with PTHREAD_STACK_MIN.
 * A [PERF] line is about 250 bytes. */
#define LOG_LINE_MAX 1024
_Static_assert(LOG_LINE_MAX <= PIPE_BUF, "a log line must fit in one atomic pipe write");

/* Get timestamp in "YYYY-MM-DD HH:MM:SS,mmm" format */
static void get_timestamp(char *buffer, size_t len) {
    struct timespec ts;
    struct tm tm_info;

    clock_gettime(CLOCK_REALTIME, &ts);
    localtime_r(&ts.tv_sec, &tm_info);

    int ms = ts.tv_nsec / 1000000;

    snprintf(buffer, len, "%04d-%02d-%02d %02d:%02d:%02d,%03d",
             tm_info.tm_year + 1900,
             tm_info.tm_mon + 1,
             tm_info.tm_mday,
             tm_info.tm_hour,
             tm_info.tm_min,
             tm_info.tm_sec,
             ms);
}

void log_message(log_level_t level, const char *component, const char *fmt, ...) {
    static const char *level_str[] = {"DEBUG", "INFO", "WARN", "ERROR", "PERF"};

    char timestamp[32];
    get_timestamp(timestamp, sizeof(timestamp));

    /* Format the whole line in a local buffer, then send it with ONE write():
     *  - no user-space lock: the former flockfile(stdout) was shared by every thread
     *    of the process, without priority inheritance; a task thread blocked on it
     *    went to the tail of its SCHED_FIFO priority list and waited for a whole task
     *    of the same priority on its core (~86 ms outliers in q_tw_em_ms);
     *  - still one line at a time: a write() of at most PIPE_BUF bytes to a pipe
     *    (docker logs) is atomic, so lines are never interleaved or glued together;
     *  - no stdio buffer, so nothing to flush and the order is the order of write(). */
    char line[LOG_LINE_MAX];
    int n = snprintf(line, sizeof(line), "%s [%s] %s: ", timestamp, level_str[level], component);
    if (n < 0) return;
    size_t len = (size_t)n < sizeof(line) ? (size_t)n : sizeof(line) - 1;

    va_list args;
    va_start(args, fmt);
    n = vsnprintf(line + len, sizeof(line) - len, fmt, args);
    va_end(args);
    if (n > 0) {
        len += (size_t)n < sizeof(line) - len ? (size_t)n : sizeof(line) - len - 1;
    }

    /* Too long: truncate, keeping room for the newline */
    if (len > sizeof(line) - 2) len = sizeof(line) - 2;
    line[len++] = '\n';

    const char *p = line;
    while (len > 0) {
        ssize_t w = write(STDOUT_FILENO, p, len);
        if (w < 0) {
            if (errno == EINTR) continue;
            return;     /* nowhere to report a logging failure */
        }
        p += w;
        len -= (size_t)w;
    }
}

void log_perf(const char *component, int iteration, unsigned int task_id,
              long start_req_ns, long end_req_ns, long start_res_ns, long end_res_ns,
              int core_id) {
    double q_em_tw_ms = (end_req_ns - start_req_ns) / 1e6;
    double t_in_tw_ms  = (start_res_ns - end_req_ns) / 1e6;
    double q_tw_em_ms  = (end_res_ns - start_res_ns) / 1e6;
    double total_ms    = (end_res_ns - start_req_ns) / 1e6;

    log_message(LOG_PERF, component,
        "iteration=%d task_id=%u start_req_ns=%ld end_req_ns=%ld start_res_ns=%ld end_res_ns=%ld "
        "q_em_tw_ms=%.3f t_in_tw_ms=%.3f q_tw_em_ms=%.3f total_ms=%.3f core_id=%d",
        iteration, task_id, start_req_ns, end_req_ns, start_res_ns, end_res_ns,
        q_em_tw_ms, t_in_tw_ms, q_tw_em_ms, total_ms, core_id);
}
