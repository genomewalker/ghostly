#!/usr/bin/env bash
# ghostly-session installer
# Usage: curl -sSL https://raw.githubusercontent.com/genomewalker/ghostly/main/install.sh | bash
#
# Or with a specific version:
#   curl -sSL https://raw.githubusercontent.com/genomewalker/ghostly/main/install.sh | bash -s -- --version v1.0.0

set -euo pipefail

REPO="genomewalker/ghostly"
BRANCH="main"
INSTALL_DIR="${HOME}/.local/bin"
TMP_DIR=""

# Colors (if terminal supports it)
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' CYAN='' BOLD='' RESET=''
fi

info()  { echo -e "${CYAN}::${RESET} $*"; }
ok()    { echo -e "${GREEN}OK${RESET} $*"; }
warn()  { echo -e "${YELLOW}!!${RESET} $*"; }
fail()  { echo -e "${RED}ERROR${RESET} $*" >&2; cleanup; exit 1; }

cleanup() {
    [ -n "${TMP_DIR}" ] && rm -rf "${TMP_DIR}"
}
trap cleanup EXIT

# Parse args
VERSION=""
while [ $# -gt 0 ]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --prefix)  INSTALL_DIR="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: install.sh [--version TAG] [--prefix DIR]"
            echo "  --version TAG   Install a specific release (default: latest from main)"
            echo "  --prefix DIR    Install directory (default: ~/.local/bin)"
            exit 0
            ;;
        *) shift ;;
    esac
done

echo ""
echo -e "${BOLD}  ghostly-session installer${RESET}"
echo -e "  ${CYAN}https://github.com/${REPO}${RESET}"
echo ""

# 1. Check for C++ compiler
info "Checking for C++ compiler..."
CXX=""
if command -v g++ >/dev/null 2>&1; then
    CXX="g++"
elif command -v clang++ >/dev/null 2>&1; then
    CXX="clang++"
elif command -v c++ >/dev/null 2>&1; then
    CXX="c++"
fi

[ -z "$CXX" ] && fail "No C++ compiler found. Install g++ or clang++ first.
  Ubuntu/Debian: sudo apt install g++
  RHEL/CentOS:   sudo yum install gcc-c++
  macOS:         xcode-select --install"

CXX_VERSION=$($CXX --version 2>&1 | head -1)
ok "Found $CXX ($CXX_VERSION)"

# 2. Check for download tool
FETCH=""
if command -v curl >/dev/null 2>&1; then
    FETCH="curl -fsSL"
elif command -v wget >/dev/null 2>&1; then
    FETCH="wget -qO-"
fi

[ -z "$FETCH" ] && fail "Neither curl nor wget found. Install one of them first."

# 3. Download source
TMP_DIR=$(mktemp -d)
SRC="${TMP_DIR}/ghostly-session.cpp"

if [ -n "$VERSION" ]; then
    URL="https://raw.githubusercontent.com/${REPO}/${VERSION}/ghostly-session/ghostly-session.cpp"
else
    URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}/ghostly-session/ghostly-session.cpp"
fi

info "Downloading ghostly-session.cpp..."
if ! $FETCH "$URL" > "$SRC" 2>/dev/null; then
    fail "Failed to download from ${URL}
  Check your internet connection and that the repository exists."
fi

# Sanity check
if [ ! -s "$SRC" ]; then
    fail "Downloaded file is empty. Check the URL: ${URL}"
fi

ok "Downloaded $(wc -c < "$SRC" | tr -d ' ') bytes"

# 4. Compile
info "Compiling with ${CXX}..."

LDFLAGS=""
case "$(uname -s)" in
    Linux)  LDFLAGS="-lutil" ;;
    Darwin) LDFLAGS="" ;;
esac

BIN="${TMP_DIR}/ghostly-session"
if ! $CXX -O2 -std=c++11 -o "$BIN" "$SRC" $LDFLAGS 2>"${TMP_DIR}/compile.log"; then
    warn "Compilation output:"
    cat "${TMP_DIR}/compile.log" >&2
    fail "Compilation failed. See errors above."
fi

ok "Compiled successfully"

# 5. Install
info "Installing to ${INSTALL_DIR}..."
mkdir -p "$INSTALL_DIR"
mv "$BIN" "${INSTALL_DIR}/ghostly-session"
chmod 755 "${INSTALL_DIR}/ghostly-session"

ok "Installed ${INSTALL_DIR}/ghostly-session"

# 6. PATH check
if ! echo "$PATH" | tr ':' '\n' | grep -q "${INSTALL_DIR}"; then
    warn "${INSTALL_DIR} is not in your PATH"

    SHELL_NAME=$(basename "${SHELL:-/bin/bash}")
    case "$SHELL_NAME" in
        zsh)  RC_FILE="$HOME/.zshrc" ;;
        fish) RC_FILE="$HOME/.config/fish/config.fish" ;;
        *)    RC_FILE="$HOME/.bashrc" ;;
    esac

    PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
    if [ "$SHELL_NAME" = "fish" ]; then
        PATH_LINE='set -gx PATH $HOME/.local/bin $PATH'
    fi

    if [ -f "$RC_FILE" ] && grep -q '.local/bin' "$RC_FILE" 2>/dev/null; then
        info "PATH entry already in ${RC_FILE} (restart your shell)"
    else
        echo "$PATH_LINE" >> "$RC_FILE"
        ok "Added to ${RC_FILE}"
        info "Run: source ${RC_FILE}  (or restart your shell)"
    fi
fi

# 7. Verify
if command -v ghostly-session >/dev/null 2>&1; then
    INSTALLED_VERSION=$(ghostly-session version 2>/dev/null || echo "unknown")
    ok "ghostly-session is ready (${INSTALLED_VERSION})"
elif [ -x "${INSTALL_DIR}/ghostly-session" ]; then
    INSTALLED_VERSION=$("${INSTALL_DIR}/ghostly-session" version 2>/dev/null || echo "unknown")
    ok "ghostly-session installed (${INSTALLED_VERSION})"
    info "Restart your shell or run: export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

echo ""
echo -e "${GREEN}${BOLD}  Installation complete!${RESET}"
echo ""
echo "  Usage:"
echo "    ghostly-session open mywork      # create or attach to session"
echo "    ghostly-session list             # list sessions"
echo "    ghostly-session info --json      # system info"
echo ""
echo "  Detach: Ctrl+\\"
echo ""
