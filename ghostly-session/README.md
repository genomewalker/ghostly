# ghostly-session

Remote session manager for [Ghostly](../Ghostly/) -- a single-file C++ binary that replaces tmux/screen/abduco with a custom, zero-dependency session daemon + system info agent.

## Architecture

```
Ghostly macOS App --ssh--> ghostly-session (client mode)
                               | Unix domain socket
                               | /tmp/ghostly-<UID>/<name>.sock
                           ghostly-session (server/daemon)
                               | PTY master
                           child process (bash -l)
```

The server daemon runs a `poll()` event loop -- fully event-driven, no polling:

- **PTY output** --> instant broadcast to all connected clients
- **Client keystroke** --> forwarded to PTY immediately
- **Window resize** --> `SIGWINCH` triggers `MSG_WINCH` --> server applies `ioctl(TIOCSWINSZ)`
- **Multi-attach**: Up to 16 simultaneous clients per session

## Build

```bash
# macOS
make

# Linux
make          # auto-adds -lutil

# Install to ~/.local/bin
make install
```

Requirements: C++11 compiler (g++ 4.8+ or clang++). No external libraries.

## Usage

```bash
# Create-or-attach (main entry point)
ghostly-session open <name> [-- cmd...]

# Create session (daemonizes, returns immediately)
ghostly-session create <name> [-- cmd...]

# Attach to existing session
ghostly-session attach <name>

# List active sessions
ghostly-session list [--json]

# System info (load, disk, conda, SLURM)
ghostly-session info [--json]

# Kill a session
ghostly-session kill <name>

# Version
ghostly-session version
```

**Detach key**: `Ctrl+\` (0x1C)

## Wire Protocol

5-byte header: `[1B type][4B length big-endian][payload]`

| Type | Name   | Payload                          |
|------|--------|----------------------------------|
| 0x01 | DATA   | Raw terminal I/O bytes           |
| 0x02 | WINCH  | 4 bytes: cols(u16) + rows(u16)   |
| 0x03 | DETACH | (empty)                          |
| 0x04 | EXIT   | 1 byte: exit status              |
| 0x05 | HELLO  | 4 bytes: cols(u16) + rows(u16)   |

## JSON Output

### `ghostly-session list --json`

```json
{
  "sessions": [
    {
      "name": "mywork",
      "clients": 2,
      "created": 1706900000,
      "command": "bash",
      "pid": 12345
    }
  ]
}
```

### `ghostly-session info --json`

```json
{
  "user": "kbd606",
  "conda": "base",
  "load": "0.45",
  "disk": "67%",
  "slurm_jobs": "3",
  "sessions": 2,
  "backend": "ghostly"
}
```

Plain-text mode outputs `KEY:VALUE` lines for backward compatibility with the Ghostly macOS app's `RemoteInfoService.parseInfo` format.

## Auto-Install

The Ghostly macOS app and CLI can auto-install ghostly-session on remote hosts:

1. Detects if `ghostly-session` is in `PATH` on the remote
2. If missing, uploads `ghostly-session.cpp` source via SSH
3. Compiles remotely with `g++` or `clang++`
4. Installs to `~/.local/bin/ghostly-session`
5. Adds `~/.local/bin` to `PATH` in `.bashrc` if needed

This works on any Linux/macOS system with a C++ compiler -- including old HPC clusters with GCC 4.8.

## Design Decisions

- **Socket dir**: `/tmp/ghostly-<UID>/` -- always local filesystem (NFS-safe), auto-cleaned on reboot
- **Metadata files**: `<name>.pid` and `<name>.info` track server state; updated on client connect/disconnect
- **Stale detection**: PID liveness check + `connect()` test; auto-cleaned on `list`
- **Double-fork daemonization**: Proper daemon lifecycle (setsid, /dev/null redirection)
- **C++11**: Maximum compatibility with old systems (GCC 4.8+)
- **No threads**: Single-threaded `poll()` loop -- simple, debuggable, no locking needed

## Comparison

| Feature | ghostly-session | abduco | tmux | screen |
|---------|:-:|:-:|:-:|:-:|
| Multi-attach | Yes (16) | No | Yes | Yes |
| JSON API | Yes | No | No | No |
| System info | Yes | No | No | No |
| Zero dependencies | Yes | Yes | No | No |
| Auto-install | Yes | No | No | No |
| Single binary | Yes | Yes | No | No |
| Detach key | Ctrl+\ | Ctrl+\ | Ctrl+b d | Ctrl+a d |
