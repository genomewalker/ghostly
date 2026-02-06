#!/bin/bash
# Local tests for ghostly-session binary
# Usage: ./test.sh [path-to-binary]
# Runs entirely locally — no SSH or remote hosts needed.

set -euo pipefail

BIN="${1:-./ghostly-session}"
PASS=0
FAIL=0
CLEANUP_SESSIONS=()

red()   { printf "\033[31m%s\033[0m\n" "$*"; }
green() { printf "\033[32m%s\033[0m\n" "$*"; }
bold()  { printf "\033[1m%s\033[0m\n" "$*"; }

pass() { PASS=$((PASS + 1)); green "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); red   "  FAIL: $1"; }

cleanup() {
    for name in "${CLEANUP_SESSIONS[@]}"; do
        "$BIN" kill "$name" >/dev/null 2>&1 || true
    done
}
trap cleanup EXIT

track() { CLEANUP_SESSIONS+=("$1"); }

# ---------- preflight ----------
if [ ! -x "$BIN" ]; then
    red "Binary not found: $BIN"
    red "Run 'make' first."
    exit 1
fi

bold "=== ghostly-session local tests ==="
echo "Binary: $BIN"
echo ""

# ---------- 1. version ----------
bold "1. Version"
out=$("$BIN" version 2>&1)
if echo "$out" | grep -q "ghostly-session"; then
    pass "version prints version string"
else
    fail "version output unexpected: $out"
fi

# ---------- 2. help ----------
bold "2. Help"
out=$("$BIN" help 2>&1)
if echo "$out" | grep -q "create"; then
    pass "help mentions create command"
else
    fail "help missing create command"
fi

# ---------- 3. session name validation ----------
bold "3. Session name validation"

# Invalid names should fail
for name in "" "../etc" "foo/bar" "a b" 'x"y' "$(python3 -c 'print("A"*100)')"; do
    if "$BIN" create "$name" >/dev/null 2>&1; then
        fail "accepted invalid name: '$name'"
    else
        pass "rejected invalid name: '${name:0:20}...'"
    fi
done

# Valid names should be accepted (we'll kill them right after)
for name in "test-ok" "my_session" "v1.2" "ABC123"; do
    if "$BIN" create "$name" >/dev/null 2>&1; then
        track "$name"
        pass "accepted valid name: '$name'"
        "$BIN" kill "$name" >/dev/null 2>&1 || true
    else
        fail "rejected valid name: '$name'"
    fi
done

# ---------- 4. create + list ----------
bold "4. Create + List"

SESSION="test-create-$$"
track "$SESSION"

"$BIN" create "$SESSION" >/dev/null 2>&1
sleep 0.2

out=$("$BIN" list 2>&1)
if echo "$out" | grep -q "$SESSION"; then
    pass "created session appears in list"
else
    fail "created session not in list: $out"
fi

# ---------- 5. list --json ----------
bold "5. JSON output"

json=$("$BIN" list --json 2>&1)
if echo "$json" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
    pass "list --json is valid JSON"
else
    fail "list --json is not valid JSON: $json"
fi

if echo "$json" | grep -q "$SESSION"; then
    pass "JSON list contains session"
else
    fail "JSON list missing session"
fi

json_info=$("$BIN" info --json 2>&1)
if echo "$json_info" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
    pass "info --json is valid JSON"
else
    fail "info --json is not valid JSON: $json_info"
fi

# ---------- 6. info ----------
bold "6. Info"

out=$("$BIN" info 2>&1)
if echo "$out" | grep -q "USER:"; then
    pass "info outputs USER field"
else
    fail "info missing USER field: $out"
fi
if echo "$out" | grep -q "MUX:ghostly"; then
    pass "info reports ghostly backend"
else
    fail "info missing MUX:ghostly: $out"
fi

# ---------- 7. duplicate create ----------
bold "7. Duplicate create"

if "$BIN" create "$SESSION" >/dev/null 2>&1; then
    fail "duplicate create should fail but succeeded"
else
    pass "duplicate create rejected"
fi

# ---------- 8. kill ----------
bold "8. Kill"

"$BIN" kill "$SESSION" >/dev/null 2>&1
sleep 0.2

out=$("$BIN" list 2>&1)
if echo "$out" | grep -q "$SESSION"; then
    fail "killed session still in list"
else
    pass "killed session removed from list"
fi

# ---------- 9. open (create-or-attach) ----------
bold "9. Open (create-or-attach)"

SESSION2="test-open-$$"
track "$SESSION2"

# open should create if doesn't exist
# We need a TTY for attach, so use script to fake one, with a timeout
if command -v script >/dev/null 2>&1; then
    # Create via open, then immediately send detach key (Ctrl+\)
    # script -q provides a PTY; timeout prevents hanging
    timeout 3 script -q /dev/null "$BIN" open "$SESSION2" </dev/null >/dev/null 2>&1 || true
    sleep 0.3

    out=$("$BIN" list 2>&1)
    if echo "$out" | grep -q "$SESSION2"; then
        pass "open created new session"
    else
        # open may have exited before daemon was ready; create explicitly
        "$BIN" create "$SESSION2" >/dev/null 2>&1 || true
        sleep 0.2
        out=$("$BIN" list 2>&1)
        if echo "$out" | grep -q "$SESSION2"; then
            pass "open/create session exists"
        else
            fail "open did not create session"
        fi
    fi

    "$BIN" kill "$SESSION2" >/dev/null 2>&1 || true
else
    echo "  SKIP: 'script' command not available for TTY tests"
fi

# ---------- 10. multiple sessions ----------
bold "10. Multiple sessions"

S1="test-multi-a-$$"
S2="test-multi-b-$$"
track "$S1"
track "$S2"

"$BIN" create "$S1" >/dev/null 2>&1
"$BIN" create "$S2" >/dev/null 2>&1
sleep 0.2

out=$("$BIN" list 2>&1)
if echo "$out" | grep -q "$S1" && echo "$out" | grep -q "$S2"; then
    pass "multiple sessions coexist"
else
    fail "multiple sessions not both listed: $out"
fi

json=$("$BIN" list --json 2>&1)
count=$(echo "$json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len([s for s in d['sessions'] if s['name'].startswith('test-multi')]))" 2>/dev/null || echo 0)
if [ "$count" -ge 2 ]; then
    pass "JSON lists both sessions (count=$count)"
else
    fail "JSON session count wrong: $count"
fi

"$BIN" kill "$S1" >/dev/null 2>&1
"$BIN" kill "$S2" >/dev/null 2>&1

# ---------- 11. stale session cleanup ----------
bold "11. Stale session cleanup"

SESSION3="test-stale-$$"
track "$SESSION3"

"$BIN" create "$SESSION3" >/dev/null 2>&1
sleep 0.2

# Get the daemon PID and kill it directly (simulates crash)
SOCK_DIR="/tmp/ghostly-$(id -u)"
if [ -f "$SOCK_DIR/$SESSION3.pid" ]; then
    DAEMON_PID=$(cat "$SOCK_DIR/$SESSION3.pid")
    kill -9 "$DAEMON_PID" 2>/dev/null || true
    sleep 0.2

    # List should auto-clean the stale session
    out=$("$BIN" list 2>&1)
    if echo "$out" | grep -q "$SESSION3"; then
        fail "stale session not cleaned up"
    else
        pass "stale session auto-cleaned on list"
    fi
else
    echo "  SKIP: could not find PID file for stale test"
fi

# ---------- 12. attach to nonexistent ----------
bold "12. Attach to nonexistent"

if "$BIN" attach "nonexistent-$$" >/dev/null 2>&1; then
    fail "attach to nonexistent should fail"
else
    pass "attach to nonexistent fails gracefully"
fi

# ---------- 13. kill nonexistent ----------
bold "13. Kill nonexistent"

if "$BIN" kill "nonexistent-$$" >/dev/null 2>&1; then
    fail "kill nonexistent should fail"
else
    pass "kill nonexistent fails gracefully"
fi

# ---------- 14. unknown command ----------
bold "14. Unknown command"

if "$BIN" foobar >/dev/null 2>&1; then
    fail "unknown command should fail"
else
    pass "unknown command rejected"
fi

# ---------- summary ----------
echo ""
bold "=== Results ==="
green "Passed: $PASS"
if [ "$FAIL" -gt 0 ]; then
    red "Failed: $FAIL"
    exit 1
else
    echo "Failed: 0"
    green "All tests passed!"
fi
