/* tx-vsock-bridge — the guest half of TermX's localhost proxy.
 *
 * A service listening on 127.0.0.1:PORT inside the TermX guest is
 * not reachable from the iPhone: the guest sits behind slirp NAT,
 * outbound only, and the runtime's public API has no port-forward
 * call. But the runtime does expose a vsock stream to the guest, and
 * the guest kernel has virtio-vsock. So this bridge listens on a
 * well-known vsock port; the TermX app listens on 127.0.0.1:PORT on
 * the iPhone and proxies each connection here over vsock, and this
 * bridge forwards it to 127.0.0.1:PORT in the guest. The result is
 * that a guest localhost service answers at the iPhone's localhost,
 * the way it would on a native OS — for any port, any tool, any
 * agent, with no per-service configuration in the guest.
 *
 * Protocol (app -> bridge, over one vsock stream per TCP connection):
 *   2 bytes, big-endian uint16_t: the target TCP port.
 * Then both sides shuttle bytes until either closes. If the TCP
 * connect fails the bridge closes the vsock stream at once, so the
 * app sees EOF and the iPhone side gets a refused connection.
 *
 * Vsock port 5999: one listener handles every forwarded port, so
 * the app never needs a new guest listener per port. The bridge
 * binds VMADDR_CID_ANY, so it answers the host whatever CID the
 * guest was given.
 *
 * Build (static, no dependencies beyond libc):
 *   aarch64-linux-gnu-gcc -static -O2 -o tx-vsock-bridge tx-vsock-bridge.c
 * The vsock ABI is defined here by hand (AF_VSOCK, sockaddr_vm):
 * the cross toolchain's headers may not carry linux/vm_sockets.h,
 * and the ABI is stable, so there is nothing to gain from the header.
 *
 * Runs as a systemd service (tx-vsock-bridge.service), started at
 * boot, restarted always. Logs only startup and errors, to stderr.
 * SPDX-License-Identifier: GPL-2.0-or-later
 */
#define _GNU_SOURCE
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <signal.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

/* Vsock ABI (linux/vm_sockets.h), by hand so the build does not need
 * the kernel header. AF_VSOCK is 40 on every Linux architecture. */
#ifndef AF_VSOCK
#define AF_VSOCK 40
#endif
#ifndef VMADDR_CID_ANY
#define VMADDR_CID_ANY ((unsigned int)-1)
#endif
#ifndef VMADDR_CID_HOST
#define VMADDR_CID_HOST 2
#endif

struct sockaddr_vm {
    unsigned short svm_family;
    unsigned short svm_reserved1;
    unsigned int svm_port;
    unsigned int svm_cid;
    unsigned char svm_zero[4];
};

/* The one vsock port the bridge listens on. The app connects here
 * and sends the target TCP port in the first two bytes. */
#define TX_BRIDGE_VSOCK_PORT 5999

/* A connection's two sockets: the vsock stream from the app, and the
 * TCP stream to the guest localhost service. */
#define TX_BUF_SIZE 16384

static void tx_log(const char *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);
    va_end(ap);
    fputc('\n', stderr);
    fflush(stderr);
}

/* Shuttle bytes between two fds until both sides are done. A half
 * close on one side shuts the write side of the other, so a service
 * that closes after its reply still lets the reply through, and a
 * client that half-closes still gets the response. Returns when
 * both directions are finished or an error hits. */
static void tx_shuttle(int a, int b) {
    char buf[TX_BUF_SIZE];
    struct pollfd pfd[2];
    bool a_open = true, b_open = true;
    bool a_writable = true, b_writable = true;

    pfd[0].fd = a;
    pfd[1].fd = b;
    while (a_open || b_open) {
        pfd[0].events = (a_open && b_writable) ? POLLIN : 0;
        pfd[1].events = (b_open && a_writable) ? POLLIN : 0;
        /* A side whose peer is gone still needs POLLIN to drain what
         * is already queued, so do not drop it while it is open. */
        if (!a_open && !b_open) break;
        int n = poll(pfd, 2, -1);
        if (n < 0) {
            if (errno == EINTR) continue;
            break;
        }
        if ((pfd[0].revents & (POLLIN | POLLHUP | POLLERR)) && a_open && b_writable) {
            ssize_t r = read(a, buf, sizeof(buf));
            if (r > 0) {
                ssize_t off = 0;
                while (off < r) {
                    ssize_t w = write(b, buf + off, (size_t)(r - off));
                    if (w < 0) {
                        if (errno == EINTR) continue;
                        b_writable = false;
                        break;
                    }
                    off += w;
                }
                if (!b_writable) {
                    shutdown(a, SHUT_RD);
                    a_open = false;
                }
            } else if (r == 0) {
                /* a closed its write side: no more bytes from a. */
                shutdown(b, SHUT_WR);
                a_open = false;
            } else if (errno != EINTR) {
                shutdown(b, SHUT_WR);
                a_open = false;
            }
        }
        if ((pfd[1].revents & (POLLIN | POLLHUP | POLLERR)) && b_open && a_writable) {
            ssize_t r = read(b, buf, sizeof(buf));
            if (r > 0) {
                ssize_t off = 0;
                while (off < r) {
                    ssize_t w = write(a, buf + off, (size_t)(r - off));
                    if (w < 0) {
                        if (errno == EINTR) continue;
                        a_writable = false;
                        break;
                    }
                    off += w;
                }
                if (!a_writable) {
                    shutdown(b, SHUT_RD);
                    b_open = false;
                }
            } else if (r == 0) {
                shutdown(a, SHUT_WR);
                b_open = false;
            } else if (errno != EINTR) {
                shutdown(a, SHUT_WR);
                b_open = false;
            }
        }
        /* A side that errored out with nothing left to read is done. */
        if ((pfd[0].revents & (POLLERR | POLLNVAL)) && !a_open) {
            shutdown(b, SHUT_WR);
        }
        if ((pfd[1].revents & (POLLERR | POLLNVAL)) && !b_open) {
            shutdown(a, SHUT_WR);
        }
        if ((pfd[0].revents & POLLERR) && a_open) {
            /* Read whatever is queued, then treat it as closed. */
            ssize_t r = read(a, buf, sizeof(buf));
            if (r <= 0) {
                shutdown(b, SHUT_WR);
                a_open = false;
            } else {
                ssize_t off = 0;
                while (off < r) {
                    ssize_t w = write(b, buf + off, (size_t)(r - off));
                    if (w <= 0) break;
                    off += w;
                }
                shutdown(b, SHUT_WR);
                a_open = false;
            }
        }
        if ((pfd[1].revents & POLLERR) && b_open) {
            ssize_t r = read(b, buf, sizeof(buf));
            if (r <= 0) {
                shutdown(a, SHUT_WR);
                b_open = false;
            } else {
                ssize_t off = 0;
                while (off < r) {
                    ssize_t w = write(a, buf + off, (size_t)(r - off));
                    if (w <= 0) break;
                    off += w;
                }
                shutdown(a, SHUT_WR);
                b_open = false;
            }
        }
    }
}

/* Close a stream cleanly: discard whatever the peer already sent
 * (a client sends its request right after the port bytes, and it
 * may still be in flight when the target connect fails), so the
 * close sends FIN instead of RST. A close with unread received
 * data sends RST, which the iPhone side reports as "connection
 * reset" instead of a clean end of stream. A short grace drain is
 * enough: the peer is on the same machine, so its bytes arrive
 * within a millisecond or two. */
static void tx_close_cleanly(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    char buf[4096];
    for (int round = 0; round < 3; round++) {
        for (;;) {
            ssize_t r = read(fd, buf, sizeof(buf));
            if (r > 0) continue;
            break;
        }
        /* Give in-flight bytes a moment to arrive, then drain again. */
        struct timespec ts = {0, 5 * 1000 * 1000};
        nanosleep(&ts, NULL);
    }
    close(fd);
}

/* One proxied connection: read the 2-byte target port, connect to
 * guest localhost, shuttle until both sides close. */
static void tx_handle(int vsock_fd) {
    unsigned char port_bytes[2];
    size_t got = 0;
    while (got < sizeof(port_bytes)) {
        ssize_t r = read(vsock_fd, port_bytes + got, sizeof(port_bytes) - got);
        if (r <= 0) {
            /* The app went away before naming a port. */
            tx_close_cleanly(vsock_fd);
            return;
        }
        got += (size_t)r;
    }
    uint16_t target_port = (uint16_t)((port_bytes[0] << 8) | port_bytes[1]);
    if (target_port == 0) {
        tx_close_cleanly(vsock_fd);
        return;
    }

    int tcp_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (tcp_fd < 0) {
        tx_log("tx-vsock-bridge: socket(AF_INET) failed: %s", strerror(errno));
        tx_close_cleanly(vsock_fd);
        return;
    }
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    addr.sin_port = htons(target_port);
    if (connect(tcp_fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        /* Nothing listens on that guest localhost port: close the
         * vsock stream cleanly so the app side sees EOF, not RST. */
        close(tcp_fd);
        tx_close_cleanly(vsock_fd);
        return;
    }
    tx_shuttle(vsock_fd, tcp_fd);
    close(tcp_fd);
    close(vsock_fd);
}

int main(void) {
    /* Children are reaped automatically; a forked handler that exits
     * never becomes a zombie. */
    signal(SIGCHLD, SIG_IGN);
    /* A write to a dead peer must not kill the bridge. */
    signal(SIGPIPE, SIG_IGN);

    int listen_fd;
#ifdef TX_TEST_TCP_LISTEN
    /* Test-only: listen on TCP 127.0.0.1:5999 instead of vsock, so
     * the shuttle and handle logic can be exercised end to end on a
     * machine with no vsock transport. The production build never
     * defines this; the vsock path below is what ships. */
    listen_fd = socket(AF_INET, SOCK_STREAM, 0);
    if (listen_fd < 0) {
        tx_log("tx-vsock-bridge: socket(AF_INET) failed: %s", strerror(errno));
        return 1;
    }
    struct sockaddr_in tcp_addr;
    memset(&tcp_addr, 0, sizeof(tcp_addr));
    tcp_addr.sin_family = AF_INET;
    tcp_addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    tcp_addr.sin_port = htons(TX_BRIDGE_VSOCK_PORT);
    if (bind(listen_fd, (struct sockaddr *)&tcp_addr, sizeof(tcp_addr)) != 0) {
        tx_log("tx-vsock-bridge: bind TCP %u failed: %s",
               TX_BRIDGE_VSOCK_PORT, strerror(errno));
        close(listen_fd);
        return 1;
    }
#else
    listen_fd = socket(AF_VSOCK, SOCK_STREAM, 0);
    if (listen_fd < 0) {
        tx_log("tx-vsock-bridge: socket(AF_VSOCK) failed: %s", strerror(errno));
        return 1;
    }
    struct sockaddr_vm addr;
    memset(&addr, 0, sizeof(addr));
    addr.svm_family = AF_VSOCK;
    addr.svm_cid = VMADDR_CID_ANY;
    addr.svm_port = TX_BRIDGE_VSOCK_PORT;
    if (bind(listen_fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        tx_log("tx-vsock-bridge: bind vsock %u failed: %s",
               TX_BRIDGE_VSOCK_PORT, strerror(errno));
        close(listen_fd);
        return 1;
    }
#endif
    if (listen(listen_fd, 64) != 0) {
        tx_log("tx-vsock-bridge: listen failed: %s", strerror(errno));
        close(listen_fd);
        return 1;
    }
    tx_log("tx-vsock-bridge: listening on vsock %u", TX_BRIDGE_VSOCK_PORT);

    for (;;) {
        int conn = accept(listen_fd, NULL, NULL);
        if (conn < 0) {
            if (errno == EINTR) continue;
            tx_log("tx-vsock-bridge: accept failed: %s", strerror(errno));
            continue;
        }
        pid_t pid = fork();
        if (pid < 0) {
            tx_log("tx-vsock-bridge: fork failed: %s", strerror(errno));
            close(conn);
            continue;
        }
        if (pid == 0) {
            /* Child: one connection, then exit. */
            close(listen_fd);
            tx_handle(conn);
            _exit(0);
        }
        /* Parent: keep accepting. */
        close(conn);
    }
    return 0;
}
