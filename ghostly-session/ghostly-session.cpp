// ghostly-session: Remote session manager for Ghostly
// Single-file C++ binary. Zero external dependencies.
// Compiles with: g++ -O2 -std=c++11 -o ghostly-session ghostly-session.cpp [-lutil]
//
// Architecture:
//   Client mode  --Unix socket-->  Server/daemon  --PTY-->  child process (bash -l)
//   Socket path: /tmp/ghostly-<UID>/<name>.sock

// ============================================================================
// 1. Platform includes & compat macros
// ============================================================================

#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <cerrno>
#include <csignal>
#include <ctime>
#include <string>
#include <vector>

#include <unistd.h>
#include <fcntl.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <sys/ioctl.h>
#include <sys/time.h>
#include <termios.h>
#include <poll.h>
#include <dirent.h>

#ifdef __APPLE__
#include <sys/mount.h>
#include <util.h>
#else
#include <sys/statvfs.h>
#include <pty.h>
#endif

// For getloadavg
#include <cstdlib>

#define GHOSTLY_VERSION "1.0.1"

// ============================================================================
// 2. Constants, types, protocol definitions
// ============================================================================

static const char DETACH_KEY = 0x1C; // Ctrl+backslash

// Wire protocol message types (5-byte header: [1B type][4B length BE][payload])
enum MsgType : uint8_t {
    MSG_DATA   = 0x01,
    MSG_WINCH  = 0x02,
    MSG_DETACH = 0x03,
    MSG_EXIT   = 0x04,
    MSG_HELLO  = 0x05,
};

// Max clients per session
static const int MAX_CLIENTS = 16;
// Buffer sizes
static const int BUF_SIZE = 8192;
// Max session name length
static const int MAX_NAME_LEN = 64;
// Socket read timeout for client connections (seconds)
static const int CLIENT_RECV_TIMEOUT = 30;

// ============================================================================
// 3. Utility functions
// ============================================================================

static uid_t my_uid() { return getuid(); }

static std::string socket_dir() {
    char buf[128];
    snprintf(buf, sizeof(buf), "/tmp/ghostly-%u", (unsigned)my_uid());
    return buf;
}

// [FIX #1] Strict session name validation: alphanumeric, dash, underscore, dot only.
// Rejects names containing /, .., or any path-escape characters.
static bool valid_session_name(const std::string &name) {
    if (name.empty() || name.size() > MAX_NAME_LEN) return false;
    if (name == "." || name == "..") return false;
    for (char c : name) {
        if (c >= 'a' && c <= 'z') continue;
        if (c >= 'A' && c <= 'Z') continue;
        if (c >= '0' && c <= '9') continue;
        if (c == '-' || c == '_' || c == '.') continue;
        return false;
    }
    return true;
}

static std::string socket_path(const std::string &name) {
    return socket_dir() + "/" + name + ".sock";
}

static std::string pid_path(const std::string &name) {
    return socket_dir() + "/" + name + ".pid";
}

static std::string info_path(const std::string &name) {
    return socket_dir() + "/" + name + ".info";
}

// [FIX #2] Hardened socket directory creation with symlink protection.
// Refuses to use the directory if it's a symlink or not owned by us.
static bool ensure_socket_dir() {
    std::string dir = socket_dir();
    mkdir(dir.c_str(), 0700);

    // Verify directory: must be a real directory, owned by us, not a symlink
    struct stat st;
    if (lstat(dir.c_str(), &st) != 0) {
        fprintf(stderr, "Cannot stat socket directory: %s\n", dir.c_str());
        return false;
    }
    if (S_ISLNK(st.st_mode)) {
        fprintf(stderr, "Socket directory is a symlink (possible attack): %s\n", dir.c_str());
        return false;
    }
    if (!S_ISDIR(st.st_mode)) {
        fprintf(stderr, "Socket path is not a directory: %s\n", dir.c_str());
        return false;
    }
    if (st.st_uid != my_uid()) {
        fprintf(stderr, "Socket directory not owned by us (uid %u, owner %u): %s\n",
                (unsigned)my_uid(), (unsigned)st.st_uid, dir.c_str());
        return false;
    }
    // Enforce permissions
    chmod(dir.c_str(), 0700);
    return true;
}

// Validate that a socket path fits in sockaddr_un.sun_path
static bool socket_path_fits(const std::string &path) {
    struct sockaddr_un addr;
    return path.size() < sizeof(addr.sun_path);
}

static std::string json_escape(const std::string &s) {
    std::string out;
    out.reserve(s.size() + 8);
    for (char c : s) {
        switch (c) {
            case '"':  out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n";  break;
            case '\r': out += "\\r";  break;
            case '\t': out += "\\t";  break;
            default:   out += c;
        }
    }
    return out;
}

// Write all bytes, handling partial writes and EAGAIN [FIX #6]
static bool write_all(int fd, const void *buf, size_t len) {
    const uint8_t *p = (const uint8_t *)buf;
    while (len > 0) {
        ssize_t n = write(fd, p, len);
        if (n < 0) {
            if (errno == EINTR) continue;
            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                // Brief spin-wait for non-blocking fds (PTY master)
                struct pollfd pfd = {fd, POLLOUT, 0};
                int r = poll(&pfd, 1, 1000); // 1s timeout
                if (r <= 0) return false;     // timeout or error
                continue;
            }
            return false;
        }
        p += n;
        len -= n;
    }
    return true;
}

// Read exactly len bytes
static bool read_all(int fd, void *buf, size_t len) {
    uint8_t *p = (uint8_t *)buf;
    while (len > 0) {
        ssize_t n = read(fd, p, len);
        if (n <= 0) {
            if (n < 0 && errno == EINTR) continue;
            return false;
        }
        p += n;
        len -= n;
    }
    return true;
}

static bool file_exists(const std::string &path) {
    struct stat st;
    return stat(path.c_str(), &st) == 0;
}

static bool process_alive(pid_t pid) {
    return kill(pid, 0) == 0;
}

static pid_t read_pid_file(const std::string &path) {
    FILE *f = fopen(path.c_str(), "r");
    if (!f) return 0;
    pid_t pid = 0;
    if (fscanf(f, "%d", &pid) != 1) pid = 0;
    fclose(f);
    return pid;
}

static void write_pid_file(const std::string &path, pid_t pid) {
    FILE *f = fopen(path.c_str(), "w");
    if (f) {
        fprintf(f, "%d\n", (int)pid);
        fclose(f);
    }
}

static void write_info_file(const std::string &path, pid_t pid, int clients,
                            time_t created, const std::string &cmd) {
    FILE *f = fopen(path.c_str(), "w");
    if (f) {
        fprintf(f, "pid=%d\nclients=%d\ncreated=%ld\ncmd=%s\n",
                (int)pid, clients, (long)created, cmd.c_str());
        fclose(f);
    }
}

static void cleanup_session_files(const std::string &name) {
    unlink(socket_path(name).c_str());
    unlink(pid_path(name).c_str());
    unlink(info_path(name).c_str());
}

// Set fd to non-blocking
static void set_nonblock(int fd) {
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

// ============================================================================
// 4. Protocol framing
// ============================================================================

static bool send_msg(int fd, MsgType type, const void *data, uint32_t len) {
    uint8_t hdr[5];
    hdr[0] = (uint8_t)type;
    hdr[1] = (len >> 24) & 0xFF;
    hdr[2] = (len >> 16) & 0xFF;
    hdr[3] = (len >>  8) & 0xFF;
    hdr[4] = len & 0xFF;
    if (!write_all(fd, hdr, 5)) return false;
    if (len > 0 && !write_all(fd, data, len)) return false;
    return true;
}

// Returns false on disconnect. Caller must free *out_data if *out_len > 0.
static bool recv_msg(int fd, MsgType *out_type, uint8_t **out_data, uint32_t *out_len) {
    uint8_t hdr[5];
    if (!read_all(fd, hdr, 5)) return false;
    *out_type = (MsgType)hdr[0];
    *out_len = ((uint32_t)hdr[1] << 24) | ((uint32_t)hdr[2] << 16) |
               ((uint32_t)hdr[3] << 8)  | (uint32_t)hdr[4];
    if (*out_len == 0) { *out_data = NULL; return true; }
    if (*out_len > 1024*1024) return false; // sanity
    *out_data = (uint8_t *)malloc(*out_len);
    if (!*out_data) return false;
    if (!read_all(fd, *out_data, *out_len)) { free(*out_data); *out_data = NULL; return false; }
    return true;
}

// ============================================================================
// 5. Terminal raw mode
// ============================================================================

static struct termios saved_termios;
static bool termios_saved = false;

static void term_raw() {
    if (!isatty(STDIN_FILENO)) return;
    struct termios t;
    if (tcgetattr(STDIN_FILENO, &saved_termios) < 0) return;
    termios_saved = true;
    t = saved_termios;
    cfmakeraw(&t);
    tcsetattr(STDIN_FILENO, TCSANOW, &t);
}

static void term_restore() {
    if (termios_saved)
        tcsetattr(STDIN_FILENO, TCSANOW, &saved_termios);
    termios_saved = false;
}

// [FIX #4 partial] atexit handler to restore terminal on unexpected exit
static void atexit_restore() {
    term_restore();
}

// ============================================================================
// 6. Server: PTY, daemon fork, poll() event loop, multi-client broadcast
// ============================================================================

struct ServerState {
    std::string name;
    std::string command;
    int pty_master;
    pid_t child_pid;
    int listen_fd;
    int client_fds[MAX_CLIENTS];
    int num_clients;
    time_t created;
    int child_exit_code; // [FIX #7] saved when child is first reaped
    volatile bool running;
};

static ServerState *g_server = NULL;

static void server_sigchld(int) {
    // Child exited — reap immediately and save exit code [FIX #7]
    if (g_server && g_server->child_pid > 0) {
        int wstatus;
        pid_t wp = waitpid(g_server->child_pid, &wstatus, WNOHANG);
        if (wp > 0) {
            if (WIFEXITED(wstatus))
                g_server->child_exit_code = WEXITSTATUS(wstatus);
            else if (WIFSIGNALED(wstatus))
                g_server->child_exit_code = 128 + WTERMSIG(wstatus);
            g_server->child_pid = -1; // mark as reaped
        }
        g_server->running = false;
    }
}

static void server_sigterm(int) {
    if (g_server) g_server->running = false;
}

static void server_remove_client(ServerState &srv, int idx) {
    close(srv.client_fds[idx]);
    srv.client_fds[idx] = srv.client_fds[srv.num_clients - 1];
    srv.num_clients--;
    write_info_file(info_path(srv.name), getpid(), srv.num_clients,
                    srv.created, srv.command);
}

static void server_broadcast(ServerState &srv, MsgType type,
                             const void *data, uint32_t len) {
    for (int i = srv.num_clients - 1; i >= 0; i--) {
        if (!send_msg(srv.client_fds[i], type, data, len)) {
            server_remove_client(srv, i);
        }
    }
}

static int create_listen_socket(const std::string &path) {
    // [FIX #2 cont.] Validate path length
    if (!socket_path_fits(path)) {
        fprintf(stderr, "Socket path too long: %s\n", path.c_str());
        return -1;
    }

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, path.c_str(), sizeof(addr.sun_path) - 1);

    unlink(path.c_str());
    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(fd);
        return -1;
    }
    if (listen(fd, 4) < 0) {
        close(fd);
        return -1;
    }
    chmod(path.c_str(), 0600);
    return fd;
}

// Set a receive timeout on a client socket [FIX #5]
static void set_recv_timeout(int fd, int seconds) {
    struct timeval tv;
    tv.tv_sec = seconds;
    tv.tv_usec = 0;
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));
}

static int run_server(const std::string &name, const std::string &cmd) {
    if (!ensure_socket_dir()) return 1;

    // Fork PTY
    int pty_master;
    pid_t child = forkpty(&pty_master, NULL, NULL, NULL);
    if (child < 0) {
        perror("forkpty");
        return 1;
    }
    if (child == 0) {
        // Child: exec shell
        const char *shell = getenv("SHELL");
        if (!shell) shell = "/bin/bash";
        if (cmd.empty()) {
            execlp(shell, shell, "-l", (char *)NULL);
        } else {
            execlp(shell, shell, "-l", "-c", cmd.c_str(), (char *)NULL);
        }
        perror("exec");
        _exit(127);
    }

    // Parent: server daemon
    set_nonblock(pty_master);

    std::string spath = socket_path(name);
    int listen_fd = create_listen_socket(spath);
    if (listen_fd < 0) {
        fprintf(stderr, "Failed to create socket: %s\n", spath.c_str());
        kill(child, SIGTERM);
        waitpid(child, NULL, 0);
        return 1;
    }

    ServerState srv;
    srv.name = name;
    srv.command = cmd.empty() ? "bash" : cmd;
    srv.pty_master = pty_master;
    srv.child_pid = child;
    srv.listen_fd = listen_fd;
    srv.num_clients = 0;
    srv.created = time(NULL);
    srv.child_exit_code = 0;
    srv.running = true;
    g_server = &srv;

    write_pid_file(pid_path(name), getpid());
    write_info_file(info_path(name), getpid(), 0, srv.created, srv.command);

    signal(SIGCHLD, server_sigchld);
    signal(SIGTERM, server_sigterm);
    signal(SIGPIPE, SIG_IGN);

    // Event loop with poll()
    while (srv.running) {
        // Build pollfd array: [listen_fd, pty_master, client0, client1, ...]
        std::vector<struct pollfd> fds;
        fds.resize(2 + srv.num_clients);

        fds[0].fd = listen_fd;
        fds[0].events = POLLIN;
        fds[1].fd = pty_master;
        fds[1].events = POLLIN;
        for (int i = 0; i < srv.num_clients; i++) {
            fds[2 + i].fd = srv.client_fds[i];
            fds[2 + i].events = POLLIN;
        }

        int ret = poll(fds.data(), fds.size(), 1000);
        if (ret < 0) {
            if (errno == EINTR) continue;
            break;
        }

        // Check for new client connections
        if (fds[0].revents & POLLIN) {
            int cfd = accept(listen_fd, NULL, NULL);
            if (cfd >= 0) {
                if (srv.num_clients >= MAX_CLIENTS) {
                    close(cfd);
                } else {
                    // [FIX #3] Read HELLO with proper error handling
                    MsgType type;
                    uint8_t *data = NULL;
                    uint32_t len = 0;
                    bool hello_ok = false;

                    // Set short timeout for hello handshake
                    struct timeval tv;
                    tv.tv_sec = 2;
                    tv.tv_usec = 0;
                    setsockopt(cfd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof(tv));

                    if (recv_msg(cfd, &type, &data, &len)) {
                        if (type == MSG_HELLO && len == 4) {
                            uint16_t cols = ((uint16_t)data[0] << 8) | data[1];
                            uint16_t rows = ((uint16_t)data[2] << 8) | data[3];
                            struct winsize ws;
                            ws.ws_col = cols;
                            ws.ws_row = rows;
                            ws.ws_xpixel = 0;
                            ws.ws_ypixel = 0;
                            ioctl(pty_master, TIOCSWINSZ, &ws);
                            hello_ok = true;
                        }
                        // Free data regardless of type/len match
                        if (data) free(data);
                    }

                    if (hello_ok) {
                        // Set operational recv timeout [FIX #5]
                        set_recv_timeout(cfd, CLIENT_RECV_TIMEOUT);

                        srv.client_fds[srv.num_clients++] = cfd;
                        write_info_file(info_path(name), getpid(), srv.num_clients,
                                        srv.created, srv.command);
                    } else {
                        // Failed handshake — reject client
                        close(cfd);
                    }
                }
            }
        }

        // PTY output → broadcast to all clients
        if (fds[1].revents & POLLIN) {
            uint8_t buf[BUF_SIZE];
            ssize_t n = read(pty_master, buf, sizeof(buf));
            if (n > 0) {
                server_broadcast(srv, MSG_DATA, buf, (uint32_t)n);
            } else if (n == 0 || (n < 0 && errno != EAGAIN && errno != EINTR)) {
                srv.running = false;
            }
        }
        if (fds[1].revents & (POLLHUP | POLLERR)) {
            srv.running = false;
        }

        // Client input
        for (int i = srv.num_clients - 1; i >= 0; i--) {
            if (fds[2 + i].revents & (POLLIN | POLLHUP | POLLERR)) {
                MsgType type;
                uint8_t *data = NULL;
                uint32_t len = 0;

                if (fds[2 + i].revents & POLLIN) {
                    if (!recv_msg(srv.client_fds[i], &type, &data, &len)) {
                        server_remove_client(srv, i);
                        continue;
                    }

                    switch (type) {
                    case MSG_DATA:
                        if (len > 0) {
                            write_all(pty_master, data, len);
                        }
                        break;
                    case MSG_WINCH:
                        if (len == 4) {
                            struct winsize ws;
                            ws.ws_col = ((uint16_t)data[0] << 8) | data[1];
                            ws.ws_row = ((uint16_t)data[2] << 8) | data[3];
                            ws.ws_xpixel = 0;
                            ws.ws_ypixel = 0;
                            ioctl(pty_master, TIOCSWINSZ, &ws);
                        }
                        break;
                    case MSG_DETACH:
                        server_remove_client(srv, i);
                        if (data) free(data);
                        continue;
                    default:
                        break;
                    }
                    if (data) free(data);
                } else {
                    // POLLHUP/POLLERR
                    server_remove_client(srv, i);
                }
            }
        }
    }

    // [FIX #8] Kill child process on shutdown if still alive
    if (srv.child_pid > 0) {
        kill(srv.child_pid, SIGHUP);
        usleep(50000);
        int wstatus;
        if (waitpid(srv.child_pid, &wstatus, WNOHANG) == 0) {
            kill(srv.child_pid, SIGTERM);
            usleep(100000);
            if (waitpid(srv.child_pid, &wstatus, WNOHANG) == 0) {
                kill(srv.child_pid, SIGKILL);
                waitpid(srv.child_pid, &wstatus, 0);
            }
        }
        // Capture exit code if not already set
        if (srv.child_exit_code == 0 && WIFEXITED(wstatus)) {
            srv.child_exit_code = WEXITSTATUS(wstatus);
        }
    }

    // [FIX #7] Send EXIT with correct exit code
    uint8_t ec = (uint8_t)srv.child_exit_code;
    server_broadcast(srv, MSG_EXIT, &ec, 1);

    // Cleanup
    for (int i = 0; i < srv.num_clients; i++)
        close(srv.client_fds[i]);
    close(listen_fd);
    close(pty_master);
    cleanup_session_files(name);
    g_server = NULL;

    return srv.child_exit_code;
}

static int cmd_create(const std::string &name, const std::string &cmd) {
    // [FIX #1] Validate session name
    if (!valid_session_name(name)) {
        fprintf(stderr, "Invalid session name '%s': use alphanumeric, dash, underscore, dot (max %d chars)\n",
                name.c_str(), MAX_NAME_LEN);
        return 1;
    }

    if (!ensure_socket_dir()) return 1;

    // Check for existing session
    std::string spath = socket_path(name);
    if (file_exists(spath)) {
        pid_t pid = read_pid_file(pid_path(name));
        if (pid > 0 && process_alive(pid)) {
            fprintf(stderr, "Session '%s' already exists (pid %d)\n",
                    name.c_str(), (int)pid);
            return 1;
        }
        // Stale, clean up
        cleanup_session_files(name);
    }

    // Daemonize: double-fork
    pid_t p1 = fork();
    if (p1 < 0) { perror("fork"); return 1; }
    if (p1 > 0) {
        // Parent: wait briefly for socket to appear
        for (int i = 0; i < 20; i++) {
            usleep(50000);
            if (file_exists(spath)) return 0;
        }
        return 0;
    }

    // First child
    setsid();
    pid_t p2 = fork();
    if (p2 < 0) _exit(1);
    if (p2 > 0) _exit(0);

    // Daemon: redirect stdio
    int devnull = open("/dev/null", O_RDWR);
    if (devnull >= 0) {
        dup2(devnull, STDIN_FILENO);
        dup2(devnull, STDOUT_FILENO);
        dup2(devnull, STDERR_FILENO);
        if (devnull > 2) close(devnull);
    }

    _exit(run_server(name, cmd));
}

// ============================================================================
// 7. Client: connect, raw mode, poll() loop, detach key, SIGWINCH
// ============================================================================

static volatile sig_atomic_t got_winch = 0;

static void client_sigwinch(int) {
    got_winch = 1;
}

static void send_window_size(int sock_fd) {
    struct winsize ws;
    if (ioctl(STDIN_FILENO, TIOCGWINSZ, &ws) < 0) return;
    uint8_t buf[4];
    buf[0] = (ws.ws_col >> 8) & 0xFF;
    buf[1] = ws.ws_col & 0xFF;
    buf[2] = (ws.ws_row >> 8) & 0xFF;
    buf[3] = ws.ws_row & 0xFF;
    send_msg(sock_fd, MSG_WINCH, buf, 4);
}

static int connect_to_session(const std::string &name) {
    std::string spath = socket_path(name);

    if (!socket_path_fits(spath)) {
        fprintf(stderr, "Socket path too long: %s\n", spath.c_str());
        return -1;
    }

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, spath.c_str(), sizeof(addr.sun_path) - 1);

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static int cmd_attach(const std::string &name) {
    // [FIX #1] Validate session name
    if (!valid_session_name(name)) {
        fprintf(stderr, "Invalid session name '%s'\n", name.c_str());
        return 1;
    }

    // [FIX #4] Ignore SIGPIPE so writes to dead socket don't kill us
    signal(SIGPIPE, SIG_IGN);

    int sock_fd = connect_to_session(name);
    if (sock_fd < 0) {
        fprintf(stderr, "Cannot attach to session '%s': not running\n", name.c_str());
        return 1;
    }

    // Send HELLO with window size
    struct winsize ws;
    if (ioctl(STDIN_FILENO, TIOCGWINSZ, &ws) < 0) {
        // Not a TTY? Use defaults
        ws.ws_col = 80;
        ws.ws_row = 24;
    }
    uint8_t hello[4];
    hello[0] = (ws.ws_col >> 8) & 0xFF;
    hello[1] = ws.ws_col & 0xFF;
    hello[2] = (ws.ws_row >> 8) & 0xFF;
    hello[3] = ws.ws_row & 0xFF;
    if (!send_msg(sock_fd, MSG_HELLO, hello, 4)) {
        fprintf(stderr, "Failed to send HELLO to session '%s'\n", name.c_str());
        close(sock_fd);
        return 1;
    }

    // Raw terminal mode + atexit restore
    atexit(atexit_restore);
    term_raw();
    signal(SIGWINCH, client_sigwinch);

    int exit_code = 0;
    bool running = true;

    while (running) {
        struct pollfd fds[2];
        fds[0].fd = STDIN_FILENO;
        fds[0].events = POLLIN;
        fds[1].fd = sock_fd;
        fds[1].events = POLLIN;

        int ret = poll(fds, 2, 500);
        if (ret < 0) {
            if (errno == EINTR) {
                if (got_winch) {
                    got_winch = 0;
                    send_window_size(sock_fd);
                }
                continue;
            }
            break;
        }

        // Handle SIGWINCH between polls
        if (got_winch) {
            got_winch = 0;
            send_window_size(sock_fd);
        }

        // Stdin → server
        if (fds[0].revents & POLLIN) {
            uint8_t buf[BUF_SIZE];
            ssize_t n = read(STDIN_FILENO, buf, sizeof(buf));
            if (n > 0) {
                // Check for detach key
                bool detached = false;
                for (ssize_t i = 0; i < n; i++) {
                    if (buf[i] == DETACH_KEY) {
                        send_msg(sock_fd, MSG_DETACH, NULL, 0);
                        running = false;
                        detached = true;
                        // Restore before printing
                        term_restore();
                        fprintf(stderr, "\r\n[detached from '%s']\r\n", name.c_str());
                        break;
                    }
                }
                if (!detached && running) {
                    if (!send_msg(sock_fd, MSG_DATA, buf, (uint32_t)n)) {
                        running = false;
                    }
                }
            } else if (n == 0) {
                running = false;
            }
        }

        // Server → stdout
        if (running && (fds[1].revents & POLLIN)) {
            MsgType type;
            uint8_t *data = NULL;
            uint32_t len = 0;

            if (!recv_msg(sock_fd, &type, &data, &len)) {
                running = false;
                continue;
            }

            switch (type) {
            case MSG_DATA:
                if (len > 0) write_all(STDOUT_FILENO, data, len);
                break;
            case MSG_EXIT:
                if (len >= 1) exit_code = data[0];
                running = false;
                break;
            default:
                break;
            }
            if (data) free(data);
        }
        if (fds[1].revents & (POLLHUP | POLLERR)) {
            running = false;
        }
    }

    term_restore();
    close(sock_fd);
    return exit_code;
}

// ============================================================================
// 8. open command: create-or-attach
// ============================================================================

static int cmd_open(const std::string &name, const std::string &cmd) {
    // [FIX #1] Validate session name
    if (!valid_session_name(name)) {
        fprintf(stderr, "Invalid session name '%s': use alphanumeric, dash, underscore, dot (max %d chars)\n",
                name.c_str(), MAX_NAME_LEN);
        return 1;
    }

    // Try to attach first
    std::string spath = socket_path(name);
    if (file_exists(spath)) {
        pid_t pid = read_pid_file(pid_path(name));
        if (pid > 0 && process_alive(pid)) {
            return cmd_attach(name);
        }
        // Stale
        cleanup_session_files(name);
    }

    // Create and then attach
    int rc = cmd_create(name, cmd);
    if (rc != 0) return rc;
    // Small delay for daemon startup
    usleep(100000);
    return cmd_attach(name);
}

// ============================================================================
// 9. list command: enumerate sockets, stale detection, JSON output
// ============================================================================

struct SessionInfo {
    std::string name;
    pid_t pid;
    int clients;
    time_t created;
    std::string command;
    bool alive;
};

static std::vector<SessionInfo> enumerate_sessions() {
    std::vector<SessionInfo> result;
    std::string dir = socket_dir();
    DIR *d = opendir(dir.c_str());
    if (!d) return result;

    struct dirent *ent;
    while ((ent = readdir(d)) != NULL) {
        std::string fname = ent->d_name;
        // Look for .sock files
        size_t pos = fname.rfind(".sock");
        if (pos == std::string::npos || pos + 5 != fname.size()) continue;

        std::string name = fname.substr(0, pos);

        // Skip invalid names (shouldn't exist, but be safe)
        if (!valid_session_name(name)) continue;

        SessionInfo si;
        si.name = name;
        si.pid = read_pid_file(pid_path(name));
        si.clients = 0;
        si.created = 0;
        si.command = "bash";
        si.alive = (si.pid > 0 && process_alive(si.pid));

        // Parse info file
        FILE *f = fopen(info_path(name).c_str(), "r");
        if (f) {
            char line[512];
            while (fgets(line, sizeof(line), f)) {
                if (strncmp(line, "clients=", 8) == 0)
                    si.clients = atoi(line + 8);
                else if (strncmp(line, "created=", 8) == 0)
                    si.created = (time_t)atol(line + 8);
                else if (strncmp(line, "cmd=", 4) == 0) {
                    si.command = line + 4;
                    // trim newline
                    while (!si.command.empty() && (si.command.back() == '\n' || si.command.back() == '\r'))
                        si.command.pop_back();
                }
            }
            fclose(f);
        }

        if (!si.alive) {
            // Auto-clean stale session
            cleanup_session_files(name);
            continue;
        }

        result.push_back(si);
    }
    closedir(d);
    return result;
}

static int cmd_list(bool json) {
    auto sessions = enumerate_sessions();

    if (json) {
        printf("{\"sessions\":[");
        for (size_t i = 0; i < sessions.size(); i++) {
            if (i > 0) printf(",");
            printf("{\"name\":\"%s\",\"clients\":%d,\"created\":%ld,\"command\":\"%s\",\"pid\":%d}",
                   json_escape(sessions[i].name).c_str(),
                   sessions[i].clients,
                   (long)sessions[i].created,
                   json_escape(sessions[i].command).c_str(),
                   (int)sessions[i].pid);
        }
        printf("]}\n");
    } else {
        if (sessions.empty()) {
            printf("No active sessions.\n");
        } else {
            printf("Active sessions:\n");
            for (auto &s : sessions) {
                printf("  %-20s  pid=%-6d  clients=%d  cmd=%s\n",
                       s.name.c_str(), (int)s.pid, s.clients, s.command.c_str());
            }
        }
    }
    return 0;
}

// ============================================================================
// 10. info command: system info (load, disk, conda, SLURM)
// ============================================================================

static int cmd_info(bool json) {
    // User
    const char *user = getenv("USER");
    if (!user) user = "unknown";

    // Conda
    const char *conda = getenv("CONDA_DEFAULT_ENV");
    if (!conda) conda = "none";

    // Load average
    double loadavg[3] = {0, 0, 0};
    char load_str[64] = "N/A";
    if (getloadavg(loadavg, 3) >= 1) {
        snprintf(load_str, sizeof(load_str), "%.2f", loadavg[0]);
    }

    // Disk usage of home dir
    char disk_str[64] = "N/A";
#ifdef __APPLE__
    struct statfs sfs;
    const char *home = getenv("HOME");
    if (home && statfs(home, &sfs) == 0) {
        unsigned long long total = (unsigned long long)sfs.f_blocks * sfs.f_bsize;
        unsigned long long avail = (unsigned long long)sfs.f_bavail * sfs.f_bsize;
        if (total > 0) {
            int pct = (int)(100 * (total - avail) / total);
            snprintf(disk_str, sizeof(disk_str), "%d%%", pct);
        }
    }
#else
    struct statvfs svfs;
    const char *home = getenv("HOME");
    if (home && statvfs(home, &svfs) == 0) {
        unsigned long long total = (unsigned long long)svfs.f_blocks * svfs.f_frsize;
        unsigned long long avail = (unsigned long long)svfs.f_bavail * svfs.f_frsize;
        if (total > 0) {
            int pct = (int)(100 * (total - avail) / total);
            snprintf(disk_str, sizeof(disk_str), "%d%%", pct);
        }
    }
#endif

    // [FIX #9] SLURM jobs — avoid shell injection from $USER
    char slurm_str[64] = "N/A";
    {
        // Build command safely: check for squeue, use getenv directly
        const char *slurm_user = user; // already from getenv("USER")
        // Validate user string doesn't contain shell metacharacters
        bool user_safe = true;
        for (const char *p = slurm_user; *p; p++) {
            char c = *p;
            if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
                  (c >= '0' && c <= '9') || c == '_' || c == '-' || c == '.')) {
                user_safe = false;
                break;
            }
        }
        if (user_safe) {
            char squeue_cmd[256];
            snprintf(squeue_cmd, sizeof(squeue_cmd),
                     "command -v squeue >/dev/null 2>&1 && squeue -u '%s' -h 2>/dev/null | wc -l",
                     slurm_user);
            FILE *fp = popen(squeue_cmd, "r");
            if (fp) {
                char buf[64];
                if (fgets(buf, sizeof(buf), fp)) {
                    char *p = buf;
                    while (*p == ' ') p++;
                    char *end = p + strlen(p) - 1;
                    while (end > p && (*end == '\n' || *end == ' ')) *end-- = '\0';
                    if (*p) snprintf(slurm_str, sizeof(slurm_str), "%s", p);
                }
                pclose(fp);
            }
        }
    }

    // Session count
    auto sessions = enumerate_sessions();
    int session_count = (int)sessions.size();

    if (json) {
        printf("{\"user\":\"%s\",\"conda\":\"%s\",\"load\":\"%s\",\"disk\":\"%s\","
               "\"slurm_jobs\":\"%s\",\"sessions\":%d,\"backend\":\"ghostly\"}\n",
               json_escape(user).c_str(),
               json_escape(conda).c_str(),
               json_escape(load_str).c_str(),
               json_escape(disk_str).c_str(),
               json_escape(slurm_str).c_str(),
               session_count);
    } else {
        // KEY:VALUE format for backward compatibility
        printf("USER:%s\n", user);
        printf("CONDA:%s\n", conda);
        printf("LOAD:%s\n", load_str);
        printf("DISK:%s\n", disk_str);
        printf("JOBS:%s\n", slurm_str);
        printf("MUX:ghostly\n");
        printf("SESSIONS:%d\n", session_count);
    }
    return 0;
}

// ============================================================================
// 11. kill command
// ============================================================================

static int cmd_kill(const std::string &name) {
    // [FIX #1] Validate session name
    if (!valid_session_name(name)) {
        fprintf(stderr, "Invalid session name '%s'\n", name.c_str());
        return 1;
    }

    pid_t pid = read_pid_file(pid_path(name));
    if (pid <= 0 || !process_alive(pid)) {
        // Try to clean stale files anyway
        cleanup_session_files(name);
        fprintf(stderr, "Session '%s' not found or already dead.\n", name.c_str());
        return 1;
    }

    // SIGTERM first
    kill(pid, SIGTERM);
    for (int i = 0; i < 10; i++) {
        usleep(100000);
        if (!process_alive(pid)) {
            cleanup_session_files(name);
            printf("Session '%s' killed.\n", name.c_str());
            return 0;
        }
    }

    // SIGKILL
    kill(pid, SIGKILL);
    usleep(100000);
    cleanup_session_files(name);
    printf("Session '%s' killed (SIGKILL).\n", name.c_str());
    return 0;
}

// ============================================================================
// 12. Argument parsing & main
// ============================================================================

static void print_usage() {
    fprintf(stderr,
        "ghostly-session %s - remote session manager\n"
        "\n"
        "Usage:\n"
        "  ghostly-session create <name> [-- cmd...]   Create session (daemonizes)\n"
        "  ghostly-session attach <name>               Attach to session\n"
        "  ghostly-session open <name> [-- cmd...]     Create-or-attach\n"
        "  ghostly-session list [--json]               List sessions\n"
        "  ghostly-session info [--json]               System info\n"
        "  ghostly-session kill <name>                 Kill session\n"
        "  ghostly-session version                     Version info\n"
        "\n"
        "Session names: alphanumeric, dash, underscore, dot (max %d chars)\n"
        "Detach key: Ctrl+\\ (0x1C)\n",
        GHOSTLY_VERSION, MAX_NAME_LEN);
}

// Collect arguments after "--" as a command string
static std::string collect_cmd(int argc, char **argv, int start) {
    std::string cmd;
    for (int i = start; i < argc; i++) {
        if (!cmd.empty()) cmd += ' ';
        cmd += argv[i];
    }
    return cmd;
}

int main(int argc, char **argv) {
    if (argc < 2) {
        print_usage();
        return 1;
    }

    std::string subcmd = argv[1];

    if (subcmd == "create") {
        if (argc < 3) {
            fprintf(stderr, "Usage: ghostly-session create <name> [-- cmd...]\n");
            return 1;
        }
        std::string name = argv[2];
        std::string cmd;
        // Find "--" separator
        for (int i = 3; i < argc; i++) {
            if (strcmp(argv[i], "--") == 0) {
                cmd = collect_cmd(argc, argv, i + 1);
                break;
            }
        }
        return cmd_create(name, cmd);

    } else if (subcmd == "attach") {
        if (argc < 3) {
            fprintf(stderr, "Usage: ghostly-session attach <name>\n");
            return 1;
        }
        return cmd_attach(argv[2]);

    } else if (subcmd == "open") {
        if (argc < 3) {
            fprintf(stderr, "Usage: ghostly-session open <name> [-- cmd...]\n");
            return 1;
        }
        std::string name = argv[2];
        std::string cmd;
        for (int i = 3; i < argc; i++) {
            if (strcmp(argv[i], "--") == 0) {
                cmd = collect_cmd(argc, argv, i + 1);
                break;
            }
        }
        return cmd_open(name, cmd);

    } else if (subcmd == "list") {
        bool json = (argc >= 3 && strcmp(argv[2], "--json") == 0);
        return cmd_list(json);

    } else if (subcmd == "info") {
        bool json = (argc >= 3 && strcmp(argv[2], "--json") == 0);
        return cmd_info(json);

    } else if (subcmd == "kill") {
        if (argc < 3) {
            fprintf(stderr, "Usage: ghostly-session kill <name>\n");
            return 1;
        }
        return cmd_kill(argv[2]);

    } else if (subcmd == "version" || subcmd == "--version" || subcmd == "-v") {
        printf("ghostly-session %s\n", GHOSTLY_VERSION);
        return 0;

    } else if (subcmd == "-h" || subcmd == "--help" || subcmd == "help") {
        print_usage();
        return 0;

    } else {
        fprintf(stderr, "Unknown command: %s\n", subcmd.c_str());
        print_usage();
        return 1;
    }
}
