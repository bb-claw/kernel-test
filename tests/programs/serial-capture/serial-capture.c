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
 *     — is captured verbatim. Cooked mode would mangle or drop this.
 *   - Writes go straight to the file descriptor (no stdio buffering)
 *     so bytes land on disk as soon as the kernel accepts the write;
 *     fdatasync() is called periodically so a crash/power-cycle of
 *     the *capture host* can't lose data sitting in the page cache.
 *   - Truncates the logfile on start: this is meant to be run fresh
 *     per test run (one logfile per run), not appended across runs.
 *     Change the open() flags below if you want append semantics.
 */

#include <errno.h>
#include <fcntl.h>
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
        case 9600:   return B9600;
        case 19200:  return B19200;
        case 38400:  return B38400;
        case 57600:  return B57600;
        case 115200: return B115200;
        case 230400: return B230400;
        default:     return 0;
    }
}

static int open_serial(const char *device, int baud) {
    speed_t speed = baud_to_speed(baud);
    if (speed == 0) {
        fprintf(stderr, "unsupported baud rate: %d\n", baud);
        return -1;
    }

    /* O_NOCTTY: don't let this become our controlling terminal.
     * O_RDWR: needed even though we only read, some USB-serial
     * adapters misbehave when opened read-only. */
    int fd = open(device, O_RDWR | O_NOCTTY);
    if (fd < 0) {
        perror("open serial device");
        return -1;
    }

    struct termios tty;
    if (tcgetattr(fd, &tty) < 0) {
        perror("tcgetattr");
        close(fd);
        return -1;
    }

    cfmakeraw(&tty);              /* no echo, no line editing, no signal chars */
    cfsetispeed(&tty, speed);
    cfsetospeed(&tty, speed);

    tty.c_cflag |= (CLOCAL | CREAD); /* ignore modem control lines, enable receiver */
    tty.c_cflag &= ~CSTOPB;          /* 1 stop bit */
    tty.c_cflag &= ~CRTSCTS;         /* no hardware flow control */

    /* Non-canonical read: return as soon as >=1 byte is available,
     * or after 1 decisecond with nothing — keeps us responsive
     * without busy-polling. */
    tty.c_cc[VMIN]  = 1;
    tty.c_cc[VTIME] = 1;

    if (tcsetattr(fd, TCSANOW, &tty) < 0) {
        perror("tcsetattr");
        close(fd);
        return -1;
    }

    tcflush(fd, TCIOFLUSH); /* drop any stale buffered bytes from before we opened */
    return fd;
}

int main(int argc, char *argv[]) {
    if (argc != 4) {
        fprintf(stderr, "usage: %s <device> <baud> <logfile>\n", argv[0]);
        return 1;
    }
    const char *device = argv[1];
    int baud = atoi(argv[2]);
    const char *logpath = argv[3];

    signal(SIGTERM, handle_sigterm);
    signal(SIGINT, handle_sigterm);

    int serial_fd = open_serial(device, baud);
    if (serial_fd < 0) return 1;

    int log_fd = open(logpath, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (log_fd < 0) {
        perror("open logfile");
        close(serial_fd);
        return 1;
    }

    fprintf(stderr, "serial-capture: %s @ %d -> %s\n", device, baud, logpath);

    char buf[BUF_SIZE];
    int writes_since_sync = 0;

    while (running) {
        ssize_t n = read(serial_fd, buf, sizeof(buf));
        if (n < 0) {
            if (errno == EINTR) continue;
            perror("read");
            break;
        }
        if (n == 0) continue; /* VTIME timeout, no data — loop and check `running` */

        ssize_t off = 0;
        while (off < n) {
            ssize_t w = write(log_fd, buf + off, (size_t)(n - off));
            if (w < 0) {
                if (errno == EINTR) continue;
                perror("write");
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
