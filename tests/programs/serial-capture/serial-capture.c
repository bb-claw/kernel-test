/*
 * serial-capture.c — copy raw serial port output to a logfile.
 *
 * Usage:
 *   ./serial-capture <device> <baud> <logfile>
 *   ./serial-capture /dev/ttyUSB0 115200 console.log
 *
 * Design:
 *   - Puts the tty into raw mode (no line discipline, no echo, no
 *     signal-generating control chars) so every byte the board sends
 *     — including partial lines, binary garbage during a crash, etc.
 *     — is captured verbatim.
 *   - VMIN=1, VTIME=0: read() blocks until at least one byte arrives.
 *     sigaction() with SA_RESTART cleared ensures SIGTERM interrupts
 *     read() with EINTR immediately, so the capture loop exits without
 *     any polling delay.
 *   - Writes go straight to the file descriptor (no stdio buffering)
 *     so bytes land on disk as soon as the kernel accepts the write;
 *     fdatasync() is called periodically and on exit so a crash of the
 *     capture host can't lose data sitting in the page cache.
 *   - Truncates the logfile on start: one logfile per run, not appended.
 */

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <termios.h>
#include <unistd.h>

#define BUF_SIZE 4096
#define SYNC_EVERY_N_WRITES 8

static volatile sig_atomic_t running = 1;

static void handle_sigterm(int sig) {
    (void)sig;
    running = 0;
}

static speed_t baud_to_speed(int baud) {
    switch (baud) {
        case 9600:    return B9600;
        case 19200:   return B19200;
        case 38400:   return B38400;
        case 57600:   return B57600;
        case 115200:  return B115200;
        case 230400:  return B230400;
        case 460800:  return B460800;
        case 921600:  return B921600;
        case 1000000: return B1000000;
        case 1500000: return B1500000;
        default:      return 0;
    }
}

static int open_serial(const char *device, int baud) {
    int fd;
    struct termios tty;
    speed_t speed = baud_to_speed(baud);

    if (speed == 0) {
        fprintf(stderr, "serial-capture: unsupported baud rate: %d\n", baud);
        return -1;
    }

    /* O_NOCTTY: don't let this become our controlling terminal.
     * O_RDWR: needed even though we only read; some USB-serial adapters
     * misbehave when opened read-only. */
    fd = open(device, O_RDWR | O_NOCTTY);
    if (fd < 0) {
        perror("serial-capture: open serial device");
        return -1;
    }

    if (tcgetattr(fd, &tty) < 0) {
        perror("serial-capture: tcgetattr");
        close(fd);
        return -1;
    }

    cfmakeraw(&tty);
    cfsetispeed(&tty, speed);
    cfsetospeed(&tty, speed);

    /* (tcflag_t) casts: termios constants are int; c_cflag is tcflag_t (unsigned). */
    tty.c_cflag |= (tcflag_t)(CLOCAL | CREAD);
    tty.c_cflag &= (tcflag_t)~CSTOPB;
    tty.c_cflag &= (tcflag_t)~CRTSCTS;

    /* Block until at least one byte arrives. SIGTERM interrupts read() with
     * EINTR immediately because sigaction() below clears SA_RESTART. */
    tty.c_cc[VMIN]  = 1;
    tty.c_cc[VTIME] = 0;

    if (tcsetattr(fd, TCSANOW, &tty) < 0) {
        perror("serial-capture: tcsetattr");
        close(fd);
        return -1;
    }

    tcflush(fd, TCIOFLUSH);
    return fd;
}

int main(int argc, char *argv[]) {
    const char *device;
    const char *logpath;
    int baud;
    int serial_fd;
    int log_fd;
    char buf[BUF_SIZE];
    int writes_since_sync;
    struct sigaction sa;
    char *end;
    long baud_l;

    if (argc != 4) {
        fprintf(stderr, "usage: %s <device> <baud> <logfile>\n", argv[0]);
        return 1;
    }

    device  = argv[1];
    logpath = argv[3];

    errno  = 0;
    baud_l = strtol(argv[2], &end, 10);
    if (errno != 0 || end == argv[2] || *end != '\0' || baud_l <= 0 || baud_l > INT_MAX) {
        fprintf(stderr, "serial-capture: invalid baud rate: %s\n", argv[2]);
        return 1;
    }
    baud = (int)baud_l;

    /* SA_RESTART intentionally absent: SIGTERM/SIGINT interrupts read() with EINTR. */
    sa.sa_handler = handle_sigterm;
    sigemptyset(&sa.sa_mask);
    sa.sa_flags   = 0;
    sigaction(SIGTERM, &sa, NULL);
    sigaction(SIGINT,  &sa, NULL);

    serial_fd = open_serial(device, baud);
    if (serial_fd < 0)
        return 1;

    log_fd = open(logpath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (log_fd < 0) {
        perror("serial-capture: open logfile");
        close(serial_fd);
        return 1;
    }

    fprintf(stderr, "serial-capture: %s @ %d -> %s\n", device, baud, logpath);

    writes_since_sync = 0;

    while (running) {
        ssize_t n = read(serial_fd, buf, BUF_SIZE);
        if (n < 0) {
            if (errno == EINTR) continue;
            perror("serial-capture: read");
            break;
        }
        if (n == 0)
            break; /* EOF: peer closed or device disconnected */

        ssize_t off = 0;
        while (off < n) {
            ssize_t w = write(log_fd, buf + off, (size_t)(n - off));
            if (w < 0) {
                if (errno == EINTR) continue;
                perror("serial-capture: write");
                goto done;
            }
            off += w;
        }

        if (++writes_since_sync >= SYNC_EVERY_N_WRITES) {
            fdatasync(log_fd);
            writes_since_sync = 0;
        }
    }

done:
    fdatasync(log_fd);
    close(log_fd);
    close(serial_fd);
    return 0;
}
