<p align="center">
  <img src="Ghostly/Ghostly/Assets.xcassets/AppIcon.appiconset/icon_128x128.png" alt="Ghostly" width="96">
</p>

<h1 align="center">Ghostly</h1>

<p align="center">
  <a href="https://github.com/genomewalker/ghostly/actions/workflows/build-macos.yml"><img src="https://github.com/genomewalker/ghostly/actions/workflows/build-macos.yml/badge.svg" alt="Build macOS App"></a>
  <a href="https://github.com/genomewalker/ghostly/actions/workflows/build-session.yml"><img src="https://github.com/genomewalker/ghostly/actions/workflows/build-session.yml/badge.svg" alt="Build ghostly-session"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green.svg" alt="License: MIT"></a>
  <img src="https://img.shields.io/badge/macOS-14%2B-blue.svg" alt="macOS 14+">
</p>

<p align="center"><strong><a href="https://genomewalker.github.io/ghostly">Documentation</a></strong></p>

Persistent SSH sessions from your menu bar.

Ghostly is a macOS menu bar app that manages persistent SSH sessions across all your remote hosts. It pairs with **ghostly-session**, a single-file C++ daemon that replaces tmux/screen with zero configuration.

## Quick Install (remote hosts)

```bash
curl -sSL https://raw.githubusercontent.com/genomewalker/ghostly/main/install.sh | bash
```

This downloads, compiles, and installs `ghostly-session` to `~/.local/bin`. Requires a C++ compiler (g++ 4.8+ or clang++).

## How It Works

```
Ghostly.app (macOS) ──ssh──▶ ghostly-session (daemon) ──pty──▶ bash -l
                                    │
                              Unix domain socket
                           /tmp/ghostly-<UID>/<name>.sock
```

1. Click a host in the menu bar
2. Ghostly opens your terminal with an SSH session managed by ghostly-session
3. Close your laptop, change networks, whatever — the session persists
4. Reattach anytime from the menu bar

## Features

- **Menu bar app** — always accessible, shows host status at a glance
- **Auto-install** — ghostly-session compiles from source on any remote host via SSH
- **Multi-terminal** — Ghostty, iTerm2, Terminal.app with window/tab/split modes
- **Tiled layouts** — tile all sessions in a grid (2=side-by-side, 3=2+1, 4=2x2, etc.)
- **Smart window focus** — reattach focuses existing terminal instead of opening a new one
- **Session persistence** — sessions survive disconnects, network changes, lid close
- **Smart fallback** — prefers ghostly-session, falls back to tmux/screen
- **Scrollback replay** — 128KB buffer, reattach shows recent output (alt-screen aware)
- **CLI tool** — `ghostly connect`, `ghostly sessions`, shell completions
- **System info** — CPU load, disk usage, conda env, SLURM jobs
- **Favorites** — pin frequently used hosts to the top
- **Log console** — built-in console for debugging connections
- **Modifier keys** — Option+click = new tab, Shift+click = split pane

## Project Structure

```
ghostly/
├── Ghostly/                  # macOS SwiftUI menu bar app (Xcode project)
│   ├── Ghostly/
│   │   ├── Models/           # SSHHost, Session, ConnectionStatus
│   │   ├── ViewModels/       # ConnectionManager, NetworkMonitor
│   │   ├── Views/            # MenuBarView, ConsoleView, SettingsView
│   │   ├── Services/         # SSH, GhosttyService, SessionService
│   │   └── Helpers/          # ShellCommand, AppLog, BatteryMonitor
│   └── ghostly-cli/          # CLI companion tool (ghostly command)
├── ghostly-session/          # C++ remote session daemon
│   ├── ghostly-session.cpp   # Single-file implementation
│   └── Makefile
├── docs/                     # GitHub Pages website
└── install.sh                # One-liner installer for remote hosts
```

## Building

### macOS App

Open `Ghostly/Ghostly.xcodeproj` in Xcode, or:

```bash
xcodebuild -project Ghostly/Ghostly.xcodeproj -scheme Ghostly build
```

Requires macOS 14+ and Xcode 15+.

### ghostly-session

```bash
cd ghostly-session
make
make install  # installs to ~/.local/bin
```

Requires C++11 (g++ 4.8+ or clang++). No external dependencies.

## ghostly-session Usage

```bash
ghostly-session open mywork          # create or attach to session
ghostly-session list --json          # list active sessions
ghostly-session info --json          # system info (load, disk, conda, SLURM)
ghostly-session attach mywork        # reattach to existing session
ghostly-session kill mywork          # terminate a session
```

Detach key: `Ctrl+\`

## CLI Tool (`ghostly`)

A standalone command-line companion for terminal usage.

### Install

From the Ghostly Settings window, click **Install CLI**, or build from source:

```bash
cd Ghostly/ghostly-cli
make install  # installs to /usr/local/bin
```

### Usage

```bash
ghostly connect myhost              # Connect (creates/attaches default session)
ghostly connect myhost -s coding    # Connect to named session
ghostly attach myhost coding        # Reattach to existing session
ghostly ssh myhost                  # Plain SSH (no session manager)
ghostly list                        # List all SSH hosts from config
ghostly sessions                    # List sessions on all hosts
ghostly sessions myhost             # List sessions on specific host
ghostly status                      # Show connection status
ghostly setup myhost                # Install ghostly-session on remote
ghostly version                     # Show version info
```

### Shell Completions

```bash
eval "$(ghostly completions bash)"  # bash
eval "$(ghostly completions zsh)"   # zsh
```

## Recommended SSH Config

Add these lines to the **top** of your `~/.ssh/config` (before any `Host` blocks) so SSH detects dead connections quickly:

```
ServerAliveInterval 15
ServerAliveCountMax 3
```

This sends a keepalive probe every 15 seconds and disconnects after 3 missed responses (~45s). Without this, a network drop (WiFi loss, laptop sleep) can leave stale "attached" sessions on the remote for minutes until TCP times out.

## Architecture

- **Wire protocol**: 5-byte framed `[1B type][4B length][payload]` — DATA, WINCH, DETACH, EXIT, HELLO
- **Event loop**: single-threaded `poll()` — fully event-driven, no polling, no threads
- **Multi-attach**: up to 16 simultaneous clients per session
- **Socket dir**: `/tmp/ghostly-<UID>/` — NFS-safe, auto-cleaned on reboot
- **Daemon**: double-fork with setsid, proper lifecycle management

## License

MIT
