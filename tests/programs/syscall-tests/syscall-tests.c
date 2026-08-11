/*
 * syscall-tests: in-VM syscall correctness tests for kernel-test.
 *
 * Usage: syscall-tests <subcommand>
 *   32bit    — lseek64 >4 GiB + large mmap boundary
 *   seccomp  — seccomp-filter enforcement (blocks a single syscall)
 *   io_uring — raw io_uring NOP round-trip (SQE→CQE)
 *   fds      — timerfd + eventfd + signalfd
 *   unix     — AF_UNIX socketpair send/recv
 *   landlock — landlock ruleset enforcement
 *
 * Output: ok:/FAIL:/skip: lines on stdout; exit 0 on pass/skip, 1 on fail.
 * Each subcommand runs as a separate process (one per test script invocation).
 */

#define _LARGEFILE64_SOURCE 1

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/prctl.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/un.h>
#include <unistd.h>

/* timerfd / eventfd / signalfd */
#include <sys/eventfd.h>
#include <sys/signalfd.h>
#include <sys/timerfd.h>

/* seccomp BPF */
#include <linux/filter.h>
#include <linux/seccomp.h>
#include <stddef.h>     /* offsetof */

/* O_PATH is a Linux extension; glibc requires _GNU_SOURCE or kernel >= 2.6.39 */
#ifndef O_PATH
#  define O_PATH 010000000
#endif

/* io_uring */
#include <linux/io_uring.h>

/* landlock — guarded because it was added in kernel 5.13 headers */
#if defined(__has_include) && __has_include(<linux/landlock.h>)
#  include <linux/landlock.h>
#else
   /* Inline minimal definitions for systems with older kernel headers */
#  define LANDLOCK_CREATE_RULESET_VERSION (1U << 0)
#  define LANDLOCK_ACCESS_FS_READ_FILE    (1ULL << 2)
#  define LANDLOCK_RULE_PATH_BENEATH      1
   struct landlock_ruleset_attr { uint64_t handled_access_fs; };
   struct landlock_path_beneath_attr { uint64_t allowed_access; int parent_fd; };
#endif

/* ── Syscall number fallbacks ───────────────────────────────────────────── */

#ifndef SYS_seccomp
#  if   defined(__x86_64__)
#    define SYS_seccomp 317
#  elif defined(__i386__)
#    define SYS_seccomp 354
#  elif defined(__aarch64__) || defined(__riscv)
#    define SYS_seccomp 277
#  endif
#endif

#ifndef SYS_io_uring_setup
#  define SYS_io_uring_setup  425
#  define SYS_io_uring_enter  426
#endif

#ifndef SYS_landlock_create_ruleset
#  define SYS_landlock_create_ruleset 444
#  define SYS_landlock_add_rule       445
#  define SYS_landlock_restrict_self  446
#endif

/* ── Output helpers ─────────────────────────────────────────────────────── */

static int g_fails;

static void ok(const char *m)   { printf("ok: %s\n",   m); }
static void fail(const char *m) { printf("FAIL: %s\n", m); g_fails++; }
static void skip(const char *m) { printf("skip: %s\n", m); }

/* ── 32-bit boundary ────────────────────────────────────────────────────── */

static int test_32bit(void)
{
    /* lseek64 to 5 GiB on a tmpfs file — tests VFS off_t handling */
    off64_t target = (off64_t)5 * 1024 * 1024 * 1024;
    int fd = open("/tmp/st-32bit.tmp", O_CREAT | O_RDWR | O_TRUNC, 0600);
    if (fd < 0) {
        skip("no writable /tmp — skipping lseek64 test");
    } else {
        off64_t got = lseek64(fd, target, SEEK_SET);
        if (got < 0) {
            skip("lseek64 to 5 GiB failed — filesystem may not support large offsets");
        } else if (got != target) {
            fail("lseek64 returned wrong position");
        } else {
            ok("lseek64: seeked to 5 GiB offset");
            char byte = 'X';
            ssize_t n = write(fd, &byte, 1);
            if (n < 0) {
                int e = errno;
                if (e == EFBIG || e == ENOSPC)
                    skip("tmpfs too small for 5 GiB sparse file");
                else
                    fail("write at 5 GiB offset failed");
            } else {
                ok("write: byte written at 5 GiB offset");
                off64_t cur = lseek64(fd, 0, SEEK_CUR);
                if (cur == target + 1)
                    ok("position: 5 GiB + 1 after write");
                else
                    fail("position mismatch after write at 5 GiB");
            }
        }
        close(fd);
        unlink("/tmp/st-32bit.tmp");
    }

    /* 128 MiB anonymous mmap — tests vm_area_struct address arithmetic */
    size_t sz = (size_t)128 * 1024 * 1024;
    void *p = mmap(NULL, sz, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (p == MAP_FAILED) {
        skip("mmap 128 MiB failed");
    } else {
        unsigned char *b = (unsigned char *)p;
        b[0]      = 0xAB;
        b[sz - 1] = 0xCD;
        if (b[0] == 0xAB && b[sz - 1] == 0xCD)
            ok("mmap: 128 MiB anonymous write-read-back verified");
        else
            fail("mmap: 128 MiB write-read-back mismatch");
        munmap(p, sz);
    }

    return g_fails ? 1 : 0;
}

/* ── seccomp ────────────────────────────────────────────────────────────── */

static int test_seccomp(void)
{
    /* Check seccomp is available */
    if (prctl(PR_GET_SECCOMP) < 0) {
        skip("prctl(PR_GET_SECCOMP) failed — seccomp not available");
        return 0;
    }

    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) < 0) {
        skip("PR_SET_NO_NEW_PRIVS not supported");
        return 0;
    }
    ok("PR_SET_NO_NEW_PRIVS set");

    /* BPF filter: block SYS_getpid, allow everything else */
    struct sock_filter filter[] = {
        BPF_STMT(BPF_LD  | BPF_W | BPF_ABS, (unsigned)offsetof(struct seccomp_data, nr)),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, (unsigned)SYS_getpid, 0, 1),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | (ENOSYS & SECCOMP_RET_DATA)),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW),
    };
    struct sock_fprog prog = {
        .len    = (unsigned short)(sizeof(filter) / sizeof(filter[0])),
        .filter = filter,
    };

    long r = syscall(SYS_seccomp, SECCOMP_SET_MODE_FILTER, 0, &prog);
    if (r < 0) {
        int e = errno;
        if (e == ENOSYS || e == EINVAL) {
            skip("seccomp(SECCOMP_SET_MODE_FILTER) not available");
            return 0;
        }
        fail("seccomp filter install failed");
        return 1;
    }
    ok("seccomp filter installed (blocks SYS_getpid)");

    errno = 0;
    long pid = syscall(SYS_getpid);
    if (pid < 0 && errno == ENOSYS)
        ok("seccomp: SYS_getpid blocked (ENOSYS)");
    else {
        fail("seccomp: SYS_getpid not blocked");
        return 1;
    }

    return 0;
}

/* ── io_uring ───────────────────────────────────────────────────────────── */

/*
 * Read/write uint32 through a void* base + byte offset.
 * Avoids strict-aliasing and alignment casts.
 */
static uint32_t rd32(const void *base, size_t off)
{
    uint32_t v;
    memcpy(&v, (const char *)base + off, sizeof(v));
    return v;
}

static void wr32(void *base, size_t off, uint32_t v)
{
    memcpy((char *)base + off, &v, sizeof(v));
}

static int test_io_uring(void)
{
    struct io_uring_params p;
    memset(&p, 0, sizeof(p));

    long rfd = syscall(SYS_io_uring_setup, (unsigned)8, &p);
    if (rfd < 0) {
        int e = errno;
        if (e == ENOSYS || e == EPERM || e == EINVAL) {
            skip("io_uring_setup not available");
            return 0;
        }
        fail("io_uring_setup failed");
        return 1;
    }
    int ring_fd = (int)rfd;
    printf("ok: io_uring_setup: sq_entries=%u cq_entries=%u\n",
           p.sq_entries, p.cq_entries);

    /* Map SQ ring */
    size_t sq_sz = (size_t)p.sq_off.array + (size_t)p.sq_entries * sizeof(uint32_t);
    void *sq = mmap(NULL, sq_sz, PROT_READ | PROT_WRITE,
                    MAP_SHARED | MAP_POPULATE, ring_fd, IORING_OFF_SQ_RING);
    if (sq == MAP_FAILED) { fail("mmap SQ ring"); close(ring_fd); return 1; }

    /* Map CQ ring */
    size_t cq_sz = (size_t)p.cq_off.cqes +
                   (size_t)p.cq_entries * sizeof(struct io_uring_cqe);
    void *cq = mmap(NULL, cq_sz, PROT_READ | PROT_WRITE,
                    MAP_SHARED | MAP_POPULATE, ring_fd, IORING_OFF_CQ_RING);
    if (cq == MAP_FAILED) {
        fail("mmap CQ ring");
        munmap(sq, sq_sz); close(ring_fd); return 1;
    }

    /* Map SQE array */
    size_t sqe_sz = (size_t)p.sq_entries * sizeof(struct io_uring_sqe);
    void *sqes_raw = mmap(NULL, sqe_sz, PROT_READ | PROT_WRITE,
                          MAP_SHARED | MAP_POPULATE, ring_fd, IORING_OFF_SQES);
    if (sqes_raw == MAP_FAILED) {
        fail("mmap SQEs");
        munmap(cq, cq_sz); munmap(sq, sq_sz); close(ring_fd); return 1;
    }
    ok("io_uring rings mapped");

    /* Fill one NOP SQE */
    uint32_t tail  = rd32(sq, p.sq_off.tail);
    uint32_t idx   = tail & (p.sq_entries - 1);
    struct io_uring_sqe sqe;
    memset(&sqe, 0, sizeof(sqe));
    sqe.opcode    = IORING_OP_NOP;
    sqe.user_data = 0x42;
    memcpy((char *)sqes_raw + idx * sizeof(sqe), &sqe, sizeof(sqe));
    wr32(sq, p.sq_off.array + idx * sizeof(uint32_t), idx);
    wr32(sq, p.sq_off.tail, tail + 1);

    /* Submit + wait for 1 completion */
    long ret = syscall(SYS_io_uring_enter, ring_fd, (unsigned)1, (unsigned)1,
                       (unsigned)IORING_ENTER_GETEVENTS, (void *)NULL, (size_t)0);
    if (ret < 0) {
        fail("io_uring_enter failed");
        munmap(sqes_raw, sqe_sz);
        munmap(cq, cq_sz); munmap(sq, sq_sz); close(ring_fd); return 1;
    }
    printf("ok: io_uring_enter submitted %ld\n", ret);

    /* Read CQE */
    uint32_t cq_h = rd32(cq, p.cq_off.head);
    uint32_t cq_t = rd32(cq, p.cq_off.tail);
    int ok_flag = 0;
    if (cq_t - cq_h >= 1) {
        size_t cqe_off = (size_t)p.cq_off.cqes +
                         (cq_h & (p.cq_entries - 1)) * sizeof(struct io_uring_cqe);
        struct io_uring_cqe cqe;
        memcpy(&cqe, (const char *)cq + cqe_off, sizeof(cqe));
        if (cqe.user_data == 0x42 && cqe.res == 0) {
            ok("CQE: NOP completed res=0 user_data=0x42");
            ok_flag = 1;
        } else {
            printf("FAIL: CQE: res=%d user_data=%llu\n",
                   cqe.res, (unsigned long long)cqe.user_data);
            g_fails++;
        }
        wr32(cq, p.cq_off.head, cq_h + 1);
    } else {
        fail("CQ empty after wait");
    }

    munmap(sqes_raw, sqe_sz);
    munmap(cq, cq_sz);
    munmap(sq, sq_sz);
    close(ring_fd);

    return (g_fails || !ok_flag) ? 1 : 0;
}

/* ── timerfd + eventfd + signalfd ───────────────────────────────────────── */

static int test_fds(void)
{
    /* timerfd */
    int tfd = timerfd_create(CLOCK_MONOTONIC, 0);
    if (tfd < 0) {
        skip("timerfd_create failed");
    } else {
        struct itimerspec ts;
        memset(&ts, 0, sizeof(ts));
        ts.it_value.tv_nsec = 1;
        if (timerfd_settime(tfd, 0, &ts, NULL) < 0) {
            /* EINVAL/ENOSYS: timer clock unavailable on this config (e.g. 32-bit allnoconfig) */
            printf("skip: timerfd_settime failed (errno %d)\n", errno);
        } else {
            uint64_t exp = 0;
            ssize_t n = read(tfd, &exp, sizeof(exp));
            if (n == (ssize_t)sizeof(exp) && exp >= 1)
                ok("timerfd: expired at least once");
            else {
                printf("FAIL: timerfd read n=%zd exp=%llu\n",
                       n, (unsigned long long)exp);
                g_fails++;
            }
        }
        close(tfd);
    }

    /* eventfd */
    int efd = eventfd(0, 0);
    if (efd < 0) {
        skip("eventfd failed");
    } else {
        uint64_t wval = 7;
        if (write(efd, &wval, sizeof(wval)) != (ssize_t)sizeof(wval)) {
            fail("eventfd write");
        } else {
            uint64_t rval = 0;
            if (read(efd, &rval, sizeof(rval)) != (ssize_t)sizeof(rval) || rval != 7) {
                printf("FAIL: eventfd read rval=%llu\n", (unsigned long long)rval);
                g_fails++;
            } else {
                ok("eventfd: write/read 7");
            }
        }
        close(efd);
    }

    /* signalfd */
    sigset_t mask;
    sigemptyset(&mask);
    sigaddset(&mask, SIGUSR1);
    sigprocmask(SIG_BLOCK, &mask, NULL);
    int sfd = signalfd(-1, &mask, 0);
    if (sfd < 0) {
        skip("signalfd failed");
    } else {
        kill(getpid(), SIGUSR1);
        struct signalfd_siginfo si;
        ssize_t n = read(sfd, &si, sizeof(si));
        if (n == (ssize_t)sizeof(si) && si.ssi_signo == SIGUSR1)
            ok("signalfd: received SIGUSR1");
        else {
            printf("FAIL: signalfd n=%zd signo=%u\n", n, si.ssi_signo);
            g_fails++;
        }
        close(sfd);
    }

    return g_fails ? 1 : 0;
}

/* ── AF_UNIX sockets ────────────────────────────────────────────────────── */

static int test_unix(void)
{
    int sv[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) < 0) {
        int e = errno;
        /* ENOSYS: CONFIG_NET=n (no socket subsystem at all)
         * EAFNOSUPPORT/EPROTONOSUPPORT: CONFIG_UNIX=n (sockets exist, AF_UNIX not registered) */
        if (e == ENOSYS || e == EAFNOSUPPORT || e == EPROTONOSUPPORT) {
            skip("AF_UNIX not supported");
            return 0;
        }
        fail("socketpair AF_UNIX");
        return 1;
    }
    ok("AF_UNIX socketpair created");

    const char msg[] = "kernel-test";
    size_t mlen = sizeof(msg) - 1;

    ssize_t n = write(sv[0], msg, mlen);
    if (n != (ssize_t)mlen) { fail("AF_UNIX write"); goto cleanup; }

    char buf[32];
    memset(buf, 0, sizeof(buf));
    n = read(sv[1], buf, sizeof(buf) - 1);
    if (n != (ssize_t)mlen || memcmp(buf, msg, mlen) != 0) {
        printf("FAIL: AF_UNIX read: got '%s'\n", buf);
        g_fails++;
    } else {
        printf("ok: AF_UNIX send/recv '%s'\n", buf);
    }

cleanup:
    close(sv[0]);
    close(sv[1]);
    return g_fails ? 1 : 0;
}

/* ── landlock ───────────────────────────────────────────────────────────── */

static int test_landlock(void)
{
    /* Check ABI version — ENOSYS means landlock not compiled in */
    long abi = syscall(SYS_landlock_create_ruleset, (void *)NULL, (size_t)0,
                       (unsigned)LANDLOCK_CREATE_RULESET_VERSION);
    if (abi < 0) {
        int e = errno;
        if (e == ENOSYS || e == EOPNOTSUPP) {
            skip("landlock not available");
            return 0;
        }
        fail("landlock_create_ruleset version check");
        return 1;
    }
    if (abi < 1) { skip("landlock ABI too old"); return 0; }
    printf("ok: landlock ABI version %ld\n", abi);

    /* Create ruleset: handle file reads */
    struct landlock_ruleset_attr rattr;
    memset(&rattr, 0, sizeof(rattr));
    rattr.handled_access_fs = LANDLOCK_ACCESS_FS_READ_FILE;

    long rfd = syscall(SYS_landlock_create_ruleset, &rattr, sizeof(rattr), (unsigned)0);
    if (rfd < 0) { fail("landlock_create_ruleset"); return 1; }
    int ruleset_fd = (int)rfd;
    ok("landlock ruleset created");

    /* Rule: allow read access under /tmp */
    int tmp_fd = open("/tmp", O_PATH | O_RDONLY);
    if (tmp_fd < 0) {
        skip("cannot open /tmp O_PATH");
        close(ruleset_fd);
        return 0;
    }
    struct landlock_path_beneath_attr pattr;
    memset(&pattr, 0, sizeof(pattr));
    pattr.allowed_access = LANDLOCK_ACCESS_FS_READ_FILE;
    pattr.parent_fd = tmp_fd;

    long ar = syscall(SYS_landlock_add_rule, ruleset_fd,
                      (unsigned)LANDLOCK_RULE_PATH_BENEATH, &pattr, (unsigned)0);
    close(tmp_fd);
    if (ar < 0) { fail("landlock_add_rule"); close(ruleset_fd); return 1; }
    ok("landlock rule: allow read under /tmp");

    /* Restrict self */
    if (prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) < 0) {
        skip("PR_SET_NO_NEW_PRIVS failed");
        close(ruleset_fd);
        return 0;
    }
    if (syscall(SYS_landlock_restrict_self, ruleset_fd, (unsigned)0) < 0) {
        fail("landlock_restrict_self");
        close(ruleset_fd);
        return 1;
    }
    close(ruleset_fd);
    ok("landlock restriction applied");

    /* /proc/version is outside /tmp — should be denied */
    int fd = open("/proc/version", O_RDONLY);
    if (fd >= 0) {
        close(fd);
        fail("landlock did not block /proc/version read");
        return 1;
    }
    if (errno == EACCES || errno == EPERM)
        ok("landlock blocked /proc/version read (EACCES)");
    else
        skip("unexpected errno for /proc/version — landlock may not cover procfs");

    return g_fails ? 1 : 0;
}

/* ── Dispatcher ─────────────────────────────────────────────────────────── */

int main(int argc, char *argv[])
{
    if (argc != 2) {
        fprintf(stderr, "usage: syscall-tests <32bit|seccomp|io_uring|fds|unix|landlock>\n");
        return 1;
    }
    const char *cmd = argv[1];
    if (strcmp(cmd, "32bit")    == 0) return test_32bit();
    if (strcmp(cmd, "seccomp")  == 0) return test_seccomp();
    if (strcmp(cmd, "io_uring") == 0) return test_io_uring();
    if (strcmp(cmd, "fds")      == 0) return test_fds();
    if (strcmp(cmd, "unix")     == 0) return test_unix();
    if (strcmp(cmd, "landlock") == 0) return test_landlock();
    fprintf(stderr, "unknown subcommand: %s\n", cmd);
    return 1;
}
