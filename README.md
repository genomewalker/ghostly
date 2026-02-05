# Ghostly

[![Build macOS App](https://github.com/genomewalker/ghostly/actions/workflows/build-macos.yml/badge.svg)](https://github.com/genomewalker/ghostly/actions/workflows/build-macos.yml)
[![Build ghostly-session](https://github.com/genomewalker/ghostly/actions/workflows/build-session.yml/badge.svg)](https://github.com/genomewalker/ghostly/actions/workflows/build-session.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)
[![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue.svg)]()

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
- **Session persistence** — sessions survive disconnects, network changes, lid close
- **Smart fallback** — prefers ghostly-session, falls back to tmux/screen
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
│   └── ghostly-cli/          # CLI companion tool
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

## Architecture

- **Wire protocol**: 5-byte framed `[1B type][4B length][payload]` — DATA, WINCH, DETACH, EXIT, HELLO
- **Event loop**: single-threaded `poll()` — fully event-driven, no polling, no threads
- **Multi-attach**: up to 16 simultaneous clients per session
- **Socket dir**: `/tmp/ghostly-<UID>/` — NFS-safe, auto-cleaned on reboot
- **Daemon**: double-fork with setsid, proper lifecycle management

## License

MIT
