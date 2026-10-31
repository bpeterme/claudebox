#!/usr/bin/env bats

CBOX_SH="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/cbox.sh"

setup() {
  export HOME="$BATS_TMPDIR/home"
  # CI runners set these to the real home; cbox's defaults must follow $HOME here.
  unset XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME
  mkdir -p "$HOME/.config/claudebox"
  export CBOX_DATA_DIR="$BATS_TMPDIR/cbox-data"
  export CBOX_CLAUDE_DIR="$BATS_TMPDIR/claude"
  export CBOX_HOST_CONFIG_DIR="$BATS_TMPDIR/config"
  export CBOX_SHARE_DIR="$BATS_TMPDIR/share"
  export CBOX_MCP_CONFIG="$BATS_TMPDIR/mcp.json"
  mkdir -p "$CBOX_DATA_DIR" "$CBOX_CLAUDE_DIR" "$CBOX_HOST_CONFIG_DIR" "$CBOX_SHARE_DIR"
  rm -f "$CBOX_MCP_CONFIG" "$CBOX_DATA_DIR"/.claude-*.json "$CBOX_DATA_DIR"/.mcp-*
  rm -rf "$HOME/Library" "$HOME/.claude.json"
  # shellcheck source=/dev/null
  source "$CBOX_SH"
}

# ---------------------------------------------------------------------------
# _cbox_name
# ---------------------------------------------------------------------------

@test "_cbox_name: returns basename of current directory" {
  local dir="$BATS_TMPDIR/my-project"
  mkdir -p "$dir"
  cd "$dir"
  run _cbox_name
  [ "$status" -eq 0 ]
  [ "$output" = "my-project" ]
}

@test "_cbox_name: replaces spaces and special chars with hyphens" {
  local dir="$BATS_TMPDIR/my project"
  mkdir -p "$dir"
  cd "$dir"
  run _cbox_name
  [ "$status" -eq 0 ]
  [ "$output" = "my-project" ]
}

@test "_cbox_name: trims leading and trailing hyphens" {
  local dir="$BATS_TMPDIR/---test---"
  mkdir -p "$dir"
  cd "$dir"
  run _cbox_name
  [ "$status" -eq 0 ]
  [ "$output" = "test" ]
}

# ---------------------------------------------------------------------------
# _cbox_resolve_path
# ---------------------------------------------------------------------------

@test "_cbox_resolve_path: returns path unchanged for a regular file" {
  local f="$BATS_TMPDIR/regular"
  touch "$f"
  run _cbox_resolve_path "$f"
  [ "$status" -eq 0 ]
  [ "$output" = "$f" ]
}

@test "_cbox_resolve_path: resolves an absolute symlink" {
  local target="$BATS_TMPDIR/abs-target"
  local link="$BATS_TMPDIR/abs-link"
  touch "$target"
  ln -sf "$target" "$link"
  run _cbox_resolve_path "$link"
  [ "$status" -eq 0 ]
  [ "$output" = "$target" ]
}

@test "_cbox_resolve_path: resolves a relative symlink" {
  local dir="$BATS_TMPDIR/reldir"
  mkdir -p "$dir"
  touch "$dir/real"
  ln -sf "real" "$dir/link"
  run _cbox_resolve_path "$dir/link"
  [ "$status" -eq 0 ]
  [ "$output" = "$dir/real" ]
}

@test "_cbox_resolve_path: resolves a chain of symlinks" {
  local target="$BATS_TMPDIR/chain-target"
  local mid="$BATS_TMPDIR/chain-mid"
  local link="$BATS_TMPDIR/chain-link"
  touch "$target"
  ln -sf "$target" "$mid"
  ln -sf "$mid" "$link"
  run _cbox_resolve_path "$link"
  [ "$status" -eq 0 ]
  [ "$output" = "$target" ]
}

# ---------------------------------------------------------------------------
# _cbox_generate_claude_json
# ---------------------------------------------------------------------------

@test "_cbox_generate_claude_json: creates file when absent" {
  _cbox_generate_claude_json "testapp"
  [ -f "$CBOX_DATA_DIR/.claude-testapp.json" ]
}

@test "_cbox_generate_claude_json: file contains correct project path" {
  _cbox_generate_claude_json "myapp"
  run grep -q '"/Workspace/myapp"' "$CBOX_DATA_DIR/.claude-myapp.json"
  [ "$status" -eq 0 ]
}

@test "_cbox_generate_claude_json: preserves existing auth tokens on re-run" {
  local f="$CBOX_DATA_DIR/.claude-stable.json"
  echo '{"oauthToken":"tok_abc","projects":{}}' > "$f"
  _cbox_generate_claude_json "stable"
  run python3 -c "import json,sys; d=json.load(open('$f')); sys.exit(0 if d.get('oauthToken')=='tok_abc' else 1)"
  [ "$status" -eq 0 ]
}

@test "_cbox_generate_claude_json: ignores the host's ~/.claude.json mcpServers" {
  local f="$CBOX_DATA_DIR/.claude-myapp.json"
  echo '{"mcpServers":{"mytool":{"command":"npx","args":["mytool-mcp"]}}}' > "$HOME/.claude.json"
  _cbox_generate_claude_json "myapp"
  run python3 -c "import json,sys; d=json.load(open('$f')); sys.exit(1 if 'mytool' in d.get('mcpServers',{}) else 0)"
  [ "$status" -eq 0 ]
}

# Prints the container's mcpServers entry for $2 as compact JSON ("null" if absent).
_mcp_entry() {
  python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps(d.get('mcpServers',{}).get(sys.argv[2]), sort_keys=True))" \
    "$CBOX_DATA_DIR/.claude-$1.json" "$2"
}

@test "_cbox_generate_claude_json: host stdio server becomes a relay entry" {
  echo '{"mcpServers":{"imcp":{"command":"/Applications/iMCP.app/Contents/MacOS/imcp-server"}}}' > "$CBOX_MCP_CONFIG"
  _cbox_generate_claude_json "myapp"
  run _mcp_entry myapp imcp
  [ "$output" = "{\"args\": [\"connect\", \"imcp\"], \"command\": \"$_CBOX_MCP_RELAY\", \"type\": \"stdio\"}" ]
}

@test "_cbox_generate_claude_json: remote URL server is passed through unchanged" {
  echo '{"mcpServers":{"lin":{"type":"sse","url":"https://mcp.example.com/sse"}}}' > "$CBOX_MCP_CONFIG"
  _cbox_generate_claude_json "myapp"
  run _mcp_entry myapp lin
  [ "$output" = '{"type": "sse", "url": "https://mcp.example.com/sse"}' ]
}

@test "_cbox_generate_claude_json: localhost URL server is skipped with a warning" {
  echo '{"mcpServers":{"loc":{"url":"http://127.0.0.1:9000/mcp"}}}' > "$CBOX_MCP_CONFIG"
  run _cbox_generate_claude_json "myapp"
  [[ "$output" == *"'loc'"*"not reachable from the container"* ]]
  run _mcp_entry myapp loc
  [ "$output" = "null" ]
}

@test "_cbox_generate_claude_json: invalid server name is skipped with a warning" {
  echo '{"mcpServers":{"bad/name":{"command":"x"}}}' > "$CBOX_MCP_CONFIG"
  run _cbox_generate_claude_json "myapp"
  [[ "$output" == *"'bad/name'"*"skipped"* ]]
  run _mcp_entry myapp "bad/name"
  [ "$output" = "null" ]
}

@test "_cbox_generate_claude_json: invalid mcp.json warns and keeps the file usable" {
  echo '{not json' > "$CBOX_MCP_CONFIG"
  run _cbox_generate_claude_json "myapp"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not valid JSON"* ]]
  grep -q '"hasTrustDialogAccepted": true' "$CBOX_DATA_DIR/.claude-myapp.json"
}

@test "_cbox_generate_claude_json: server removed from mcp.json is removed from the container" {
  echo '{"mcpServers":{"a":{"command":"x"},"r":{"url":"https://r.example.com/mcp"}}}' > "$CBOX_MCP_CONFIG"
  _cbox_generate_claude_json "myapp"
  echo '{"mcpServers":{}}' > "$CBOX_MCP_CONFIG"
  _cbox_generate_claude_json "myapp"
  run _mcp_entry myapp a
  [ "$output" = "null" ]
  run _mcp_entry myapp r
  [ "$output" = "null" ]
}

@test "_cbox_generate_claude_json: keeps servers added inside the container" {
  local f="$CBOX_DATA_DIR/.claude-myapp.json"
  echo '{"mcpServers":{"fs":{"command":"npx","args":["-y","@modelcontextprotocol/server-filesystem","/Workspace"]}}}' > "$f"
  _cbox_generate_claude_json "myapp"
  run _mcp_entry myapp fs
  [[ "$output" == *"server-filesystem"* ]]
}

@test "_cbox_generate_claude_json: removes entries left by the old supergateway proxy" {
  local f="$CBOX_DATA_DIR/.claude-myapp.json"
  echo '{"mcpServers":{"p":{"type":"http","url":"http://192.168.64.1:39100/mcp"},"n":{"command":"/Applications/X.app/Contents/MacOS/x"}}}' > "$f"
  _cbox_generate_claude_json "myapp"
  run _mcp_entry myapp p
  [ "$output" = "null" ]
  run _mcp_entry myapp n
  [ "$output" = "null" ]
}

@test "_cbox_generate_claude_json: safe mode gets no host servers" {
  echo '{"mcpServers":{"imcp":{"command":"/Applications/iMCP.app/Contents/MacOS/imcp-server"}}}' > "$CBOX_MCP_CONFIG"
  _cbox_generate_claude_json "myapp" "normal"
  _cbox_generate_claude_json "myapp" "safe"
  run _mcp_entry myapp imcp
  [ "$output" = "null" ]
}

# ---------------------------------------------------------------------------
# MCP relay (end to end, with a fake runtime whose `exec` runs locally)
# ---------------------------------------------------------------------------

_relay_setup() {
  # Unix socket paths are length-limited, so keep them short.
  RELAY_TMP=$(mktemp -d /tmp/cbr.XXXX)
  export CBOX_MCP_SOCKET_DIR="$RELAY_TMP/s"
  # Like `container exec`: no `exec`, so the wrapper keeps stdout open until the
  # in-container process exits — EOF alone does not reach the host earlier.
  printf '#!/bin/bash\n[[ "$1" == exec ]] || exit 1\nshift; [[ "$1" == -i ]] && shift; shift\n"$@"\n' > "$RELAY_TMP/rt"
  printf '#!/bin/bash\nwhile read -r l; do sleep 0.5; echo "late-$l"; done\n' > "$RELAY_TMP/late"
  # Never answers and ignores EOF, like imcp-server without Local Network access.
  printf '#!/bin/bash\nwhile :; do sleep 1; done\n' > "$RELAY_TMP/stuck"
  # Stuck until the flag file exists, then echoes.
  printf '#!/bin/bash\n[ -f "%s/fixed" ] && exec cat\nwhile :; do sleep 1; done\n' "$RELAY_TMP" > "$RELAY_TMP/flaky"
  chmod +x "$RELAY_TMP/rt" "$RELAY_TMP/late" "$RELAY_TMP/stuck" "$RELAY_TMP/flaky"
  _CBOX_CMD="$RELAY_TMP/rt"
  _CBOX_MCP_RELAY="$RELAY_TMP/bin/cbox-mcp-relay"
  _CBOX_MCP_HINT_SECONDS=1
  RELAY_LOG="$CBOX_DATA_DIR/.mcp-relay-rbox.log"
  cat > "$CBOX_MCP_CONFIG" <<JSON
{"mcpServers":{"echo":{"command":"cat"},"late":{"command":"$RELAY_TMP/late"},"crash":{"command":"false"},
 "stuck":{"command":"$RELAY_TMP/stuck"},"flaky":{"command":"$RELAY_TMP/flaky"}}}
JSON
  _cbox_mcp_relay_start "rbox"
}

_relay_teardown() {
  _cbox_mcp_relay_stop "rbox"
  sleep 0.5
  rm -rf "$RELAY_TMP"
}

@test "mcp relay: round-trips bytes between client and host server" {
  _relay_setup
  run bash -c "printf '{\"jsonrpc\":\"2.0\",\"id\":1}\n' | timeout 10 '$_CBOX_MCP_RELAY' connect echo"
  _relay_teardown
  [ "$status" -eq 0 ]
  [ "$output" = '{"jsonrpc":"2.0","id":1}' ]
}

@test "mcp relay: answers a request written just before the client stopped sending" {
  _relay_setup
  run bash -c "echo x | timeout 10 '$_CBOX_MCP_RELAY' connect late"
  _relay_teardown
  [ "$output" = "late-x" ]
}

@test "mcp relay: serves consecutive connections with fresh servers" {
  _relay_setup
  run bash -c "for i in 1 2 3 4; do echo \$i | timeout 10 '$_CBOX_MCP_RELAY' connect echo; done"
  _relay_teardown
  [ "$output" = "$(printf '1\n2\n3\n4')" ]
}

@test "mcp relay: client ends promptly when the host server exits" {
  _relay_setup
  # Timed inside: the client's stdin stays open (sleep), so only the server
  # exiting can end it. `run` itself would wait for sleep's inherited fds.
  run bash -c "s=\$SECONDS; timeout 10 '$_CBOX_MCP_RELAY' connect crash < <(sleep 8 2>/dev/null); echo \$? \$((SECONDS - s))"
  _relay_teardown
  local rc elapsed
  read -r rc elapsed <<< "$output"
  [ "$rc" -eq 0 ]
  (( elapsed < 5 ))
}

# Client that keeps its input open for $2 seconds, like Claude, but gives up
# after $3 seconds, like Claude's connect timeout.
_relay_client() {
  timeout "$3" "$_CBOX_MCP_RELAY" connect "$1" < <(sleep "$2" 2>/dev/null)
}

# Waits up to $2 seconds for the number of processes matching $1 to reach $3.
_wait_procs() {
  local i
  for i in $(seq 1 $(( $2 * 5 ))); do
    [ "$(pgrep -fc "$1")" -eq "$3" ] && return 0
    sleep 0.2
  done
  return 1
}

@test "mcp relay: client disconnecting mid-session stops the server and frees the slot" {
  _relay_setup
  _relay_client stuck 30 2 || true
  _relay_client stuck 30 2 || true
  # Both servers are stopped although they ignore EOF on stdin.
  _wait_procs "$RELAY_TMP/stuck" 6 0
  local stopped=$?
  # Two slots were used; a third client must still be served.
  run bash -c "echo hi | timeout 10 '$_CBOX_MCP_RELAY' connect echo"
  _relay_teardown
  [ "$stopped" -eq 0 ]
  [ "$output" = "hi" ]
}

@test "mcp relay: server that never answers logs a hint and does not hold the slot" {
  _relay_setup
  _relay_client stuck 30 3 || true
  _wait_procs "$RELAY_TMP/stuck" 6 0
  local stopped=$?
  local log; log=$(cat "$RELAY_LOG")
  _relay_teardown
  [ "$stopped" -eq 0 ]
  [[ "$log" == *"WARN stuck: no response from the server 1s after a client connected"*"Local Network"* ]]
  [[ "$log" == *"WARN stuck: client gave up before the server answered"* ]]
}

@test "mcp relay: repeated failed connects do not exhaust the slots" {
  _relay_setup
  local i
  for i in 1 2 3 4 5; do _relay_client flaky 30 1 || true; done
  touch "$RELAY_TMP/fixed"
  run bash -c "{ echo works; sleep 0.5; } | timeout 10 '$_CBOX_MCP_RELAY' connect flaky"
  _wait_procs "$RELAY_TMP/flaky" 10 0
  local stopped=$?
  _relay_teardown
  [ "$output" = "works" ]
  [ "$stopped" -eq 0 ]
}

@test "mcp relay: unknown server fails with a helpful message" {
  run bash -c "_CBOX_DIR=\$(mktemp -d /tmp/cbr.XXXX); source '$CBOX_SH'; _cbox_mcp_relay_py > \$_CBOX_DIR/r; CBOX_MCP_SOCKET_DIR=\$_CBOX_DIR/s timeout 30 python3 \$_CBOX_DIR/r connect nope; rc=\$?; rm -rf \$_CBOX_DIR; exit \$rc"
  [ "$status" -eq 1 ]
  [[ "$output" == *"'nope' is not reachable"*"mcp.json"* ]]
}

@test "mcp relay: stop leaves no processes or sockets behind" {
  _relay_setup
  echo hi | timeout 10 "$_CBOX_MCP_RELAY" connect echo >/dev/null
  _cbox_mcp_relay_stop "rbox"
  sleep 1
  run pgrep -f "$RELAY_TMP"
  local procs="$output"
  run find "$CBOX_MCP_SOCKET_DIR" -name '*.sock'
  local socks="$output"
  rm -rf "$RELAY_TMP"
  [ -z "$procs" ]
  [ -z "$socks" ]
}

@test "mcp relay: not started when no host stdio servers are configured" {
  echo '{"mcpServers":{"r":{"url":"https://r.example.com/mcp"}}}' > "$CBOX_MCP_CONFIG"
  _CBOX_CMD=false
  run _cbox_mcp_relay_start "none"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -f "$CBOX_DATA_DIR/.mcp-relay-none.pid" ]
}

@test "mcp relay: legacy supergateway files are cleaned up" {
  echo '{}' > "$CBOX_DATA_DIR/.mcp-portmap-old.json"
  echo '{}' > "$CBOX_DATA_DIR/.mcp-native-old.json"
  _cbox_mcp_relay_stop "old"
  [ ! -f "$CBOX_DATA_DIR/.mcp-portmap-old.json" ]
  [ ! -f "$CBOX_DATA_DIR/.mcp-native-old.json" ]
}

# ---------------------------------------------------------------------------
# cbox mcp
# ---------------------------------------------------------------------------

@test "cbox mcp: explains how to configure when nothing is set up" {
  run _cbox_mcp_status "myapp"
  [[ "$output" == *"No host MCP servers configured"*"cbox mcp import"* ]]
}

@test "cbox mcp: lists servers with their kind" {
  echo '{"mcpServers":{"imcp":{"command":"/x/imcp"},"r":{"url":"https://r.example.com/mcp"},"l":{"url":"http://localhost:1/mcp"}}}' > "$CBOX_MCP_CONFIG"
  run _cbox_mcp_status "myapp"
  [[ "$output" == *"✔ imcp"*"host"*"/x/imcp"* ]]
  [[ "$output" == *"✔ r"*"remote"* ]]
  [[ "$output" == *"✘ l"*"not supported"* ]]
  [[ "$output" == *"relay for 'myapp' not running"* ]]
}

@test "cbox mcp: shows the latest relay problem under its server" {
  echo '{"mcpServers":{"iMCP":{"command":"/x/imcp-server"},"other":{"command":"/x/o"}}}' > "$CBOX_MCP_CONFIG"
  cat > "$CBOX_DATA_DIR/.mcp-relay-myapp.log" <<'LOG'
2026-10-04 09:00:00 INFO iMCP: client connected — server started (pid 1)
2026-10-04 09:00:25 WARN iMCP: no response from the server 25s after a client connected. Local Network ...
2026-10-04 09:00:30 WARN iMCP: client gave up before the server answered — server stopped
2026-10-04 09:01:00 INFO other: client connected — server started (pid 2)
LOG
  run _cbox_mcp_status "myapp"
  [[ "$output" == *"iMCP"*"⚠ 09:00 no response"*"Local Network"*"⚠ 09:00 client gave up"* ]]
  [[ "$output" != *"other"*"⚠"* ]]
}

@test "cbox mcp: a later successful connection clears the problem" {
  echo '{"mcpServers":{"iMCP":{"command":"/x/imcp-server"}}}' > "$CBOX_MCP_CONFIG"
  cat > "$CBOX_DATA_DIR/.mcp-relay-myapp.log" <<'LOG'
2026-10-04 09:00:30 WARN iMCP: client gave up before the server answered — server stopped
2026-10-04 09:05:00 INFO iMCP: client connected — server started (pid 3)
LOG
  run _cbox_mcp_status "myapp"
  [[ "$output" != *"⚠"* ]]
}

@test "cbox mcp import: lists candidates from Claude Desktop and Claude Code when not interactive" {
  mkdir -p "$HOME/Library/Application Support/Claude"
  echo '{"mcpServers":{"imcp":{"command":"/Applications/iMCP.app/Contents/MacOS/imcp-server"}}}' \
    > "$HOME/Library/Application Support/Claude/claude_desktop_config.json"
  echo '{"projects":{"/p":{"mcpServers":{"tool":{"command":"npx","args":["tool"]}}}}}' > "$HOME/.claude.json"
  run python3 -c "$(_cbox_mcp_py)" import "$CBOX_MCP_CONFIG" < /dev/null
  [[ "$output" == *"'imcp' from Claude Desktop"* ]]
  [[ "$output" == *"'tool' from Claude Code"* ]]
  [ ! -f "$CBOX_MCP_CONFIG" ]
}

@test "cbox mcp import: interactive import writes chosen servers with mode 600" {
  mkdir -p "$HOME/Library/Application Support/Claude"
  echo '{"mcpServers":{"imcp":{"command":"/Applications/iMCP.app/Contents/MacOS/imcp-server"},"tool":{"command":"npx"}}}' \
    > "$HOME/Library/Application Support/Claude/claude_desktop_config.json"
  # Fake a terminal: accept the default for imcp (yes, macOS app), default for tool (no).
  run python3 -c "
import sys, io
sys.stdin = io.TextIOWrapper(io.BytesIO(b'\n\n'))
sys.stdin.isatty = lambda: True
exec(sys.argv[1])
" "$(_cbox_mcp_py | sed '/^if __name__/,$d')
cmd_import(sys.argv[2])" "$CBOX_MCP_CONFIG"
  [ "$status" -eq 0 ]
  python3 -c "import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if list(d['mcpServers'])==['imcp'] else 1)" "$CBOX_MCP_CONFIG"
  [ "$(stat -c %a "$CBOX_MCP_CONFIG" 2>/dev/null || stat -f %Lp "$CBOX_MCP_CONFIG")" = "600" ]
}

# ---------------------------------------------------------------------------
# warden (credential broker; end to end with a fake upstream on localhost)
# ---------------------------------------------------------------------------

_warden_setup() {
  rm -rf "$CBOX_WARDEN_DIR"
  mkdir -p "$CBOX_WARDEN_DIR"
  export CBOX_WARDEN_HOST=127.0.0.1
  CBOX_WARDEN_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
  UP_PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1])')
  WT="$BATS_TMPDIR/warden-t"
  rm -rf "$WT"; mkdir -p "$WT/proj"
  # Fake secret store: never a real secret.
  printf '#!/bin/sh\necho "sk-test-REDACTED-$1"\n' > "$WT/secret"
  chmod +x "$WT/secret"
  export CBOX_WARDEN_SECRET_CMD="$WT/secret"
  cat > "$WT/upstream.py" <<'PY'
import http.server, json, sys, time
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def handle_any(self):
        body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if self.path.endswith("/stream"):
            self.send_response(200); self.send_header("Connection", "close"); self.end_headers()
            for i in range(3):
                self.wfile.write(f"data: {i}\n\n".encode()); self.wfile.flush(); time.sleep(0.1)
            self.close_connection = True
            return
        out = json.dumps({"path": self.path, "body": body.decode(),
                          "headers": {k.lower(): v for k, v in self.headers.items()}}).encode()
        self.send_response(200); self.send_header("Content-Length", str(len(out))); self.end_headers()
        self.wfile.write(out)
    do_GET = do_POST = do_PUT = do_DELETE = handle_any
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
  python3 "$WT/upstream.py" "$UP_PORT" &
  UP_PID=$!
  cat > "$CBOX_WARDEN_DIR/resources" <<INI
[llm]
upstream     = http://127.0.0.1:$UP_PORT/api/v1
auth         = bearer
secret       = cbox.warden.llm
allow        = POST /chat/*, GET /models, GET /stream
env          = OPENAI_BASE_URL={url} OPENAI_API_KEY=warden
[hdr]
upstream = http://127.0.0.1:$UP_PORT/h
auth     = header:X-Api-Key
secret   = cbox.warden.hdr
[bas]
upstream = http://127.0.0.1:$UP_PORT/b
auth     = basic
secret   = cbox.warden.bas
[qry]
upstream = http://127.0.0.1:$UP_PORT/q
auth     = query:key
secret   = cbox.warden.qry
[proj]
upstream     = http://127.0.0.1:$UP_PORT/p
auth         = bearer
secret       = cbox.warden.proj
availability = project
INI
  cd "$WT/proj"
}

_warden_teardown() {
  _cbox_warden_broker_stop
  kill "$UP_PID" 2>/dev/null || true
  cd "$BATS_TMPDIR"
}

# Session env for container wbox (non-interactive), one KEY=VALUE per line.
_warden_env() {
  _cbox_warden_start wbox </dev/null 2>"$WT/stderr"
}

_warden_url() {
  _warden_env | sed -n 's/^WARDEN_URL=//p'
}

# Approve the project's current .warden as if the user typed "y".
_warden_approve_yes() {
  python3 -c "
import sys, io
sys.stdin = io.TextIOWrapper(io.BytesIO(b'y\n'))
sys.stdin.isatty = lambda: True
exec(sys.argv[1])
" "$(_cbox_warden_py | sed '/^if __name__/,$d')
cmd_approve(sys.argv[2], sys.argv[3])" "$CBOX_WARDEN_DIR" "$PWD" 2>/dev/null
}

@test "warden: nothing happens without a resources file" {
  rm -rf "$CBOX_WARDEN_DIR"
  run _cbox_warden_start wbox
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -d "$CBOX_WARDEN_DIR" ]
}

@test "warden: session env has WARDEN_URL and the global resources' env" {
  _warden_setup
  run _warden_env
  _warden_teardown
  [[ "${lines[0]}" =~ ^WARDEN_URL=http://127\.0\.0\.1:[0-9]+/w/[A-Za-z0-9_-]{20,}$ ]]
  [[ "$output" == *"OPENAI_BASE_URL=${lines[0]#WARDEN_URL=}/llm"* ]]
  [[ "$output" == *"OPENAI_API_KEY=warden"* ]]
}

@test "warden: bearer secret replaces whatever key the client sends" {
  _warden_setup
  url=$(_warden_url)
  run curl -s -H 'Authorization: Bearer sk-or-REDACTED' -d '{"m":1}' "$url/llm/chat/completions"
  _warden_teardown
  [[ "$output" == *'"path": "/api/v1/chat/completions"'* ]]
  [[ "$output" == *'"authorization": "Bearer sk-test-REDACTED-cbox.warden.llm"'* ]]
  [[ "$output" == *'"body": "{\"m\":1}"'* ]]
}

@test "warden: header, basic and query schemes" {
  _warden_setup
  url=$(_warden_url)
  hdr=$(curl -s -H 'X-Api-Key: fake' "$url/hdr/a")
  bas=$(curl -s "$url/bas/a")
  qry=$(curl -s "$url/qry/a?x=1&key=fake")
  _warden_teardown
  [[ "$hdr" == *'"x-api-key": "sk-test-REDACTED-cbox.warden.hdr"'* ]]
  [[ "$hdr" != *'"authorization"'* ]]
  [[ "$bas" == *"\"authorization\": \"Basic $(printf 'sk-test-REDACTED-cbox.warden.bas' | base64)\""* ]]
  [[ "$qry" == *'"path": "/q/a?x=1&key=sk-test-REDACTED-cbox.warden.qry"'* ]]
}

@test "warden: streamed responses pass through" {
  _warden_setup
  url=$(_warden_url)
  run curl -sN "$url/llm/stream"
  _warden_teardown
  [ "$output" = "$(printf 'data: 0\n\ndata: 1\n\ndata: 2\n')" ]
}

@test "warden: refuses what was not granted or allowed" {
  _warden_setup
  url=$(_warden_url)
  host=${url%/w/*}
  code() { curl -s -o /dev/null -w '%{http_code} ' --path-as-is "$@"; }
  got=$(code "$url/llm/admin")                # outside the allow list
  got+=$(code -X DELETE "$url/llm/models")    # method not allowed
  got+=$(code "$url/proj/a")                  # project resource, not approved
  got+=$(code "$url/nope/a")                  # unknown resource
  got+=$(code "$url/llm/../hdr/a")            # dot segments
  got+=$(code "$url/llm/%252e%252e/x")        # encoded dot segments
  got+=$(code "$host/w/wrong-token/llm/models")
  got+=$(code "$host/llm/models")
  _warden_teardown
  [ "$got" = "403 403 403 403 403 403 403 404 " ]
}

@test "warden: the secret never appears in the broker log" {
  _warden_setup
  url=$(_warden_url)
  curl -s "$url/llm/models" >/dev/null
  curl -s "$url/qry/a" >/dev/null
  curl -s "$url/llm/admin" >/dev/null
  _warden_teardown
  grep -q "llm/models -> 200" "$CBOX_WARDEN_DIR/broker.log"
  [ "$(grep -c "REDACTED" "$CBOX_WARDEN_DIR/broker.log")" = 0 ]
}

@test "warden: project resource needs an approved .warden" {
  _warden_setup
  printf '[proj]\n' > .warden
  _warden_env >/dev/null
  before=$(cat "$CBOX_WARDEN_DIR/sessions/wbox.json")
  hint=$(cat "$WT/stderr")
  _warden_approve_yes
  url=$(_warden_url)
  run curl -s "$url/proj/a"
  _warden_teardown
  [[ "$before" != *'"proj"'* ]]
  [[ "$hint" == *"cbox warden approve"* ]]
  [[ "$output" == *'"authorization": "Bearer sk-test-REDACTED-cbox.warden.proj"'* ]]
}

@test "warden: editing .warden after approval needs a new approval" {
  _warden_setup
  printf '[proj]\n' > .warden
  _warden_approve_yes
  printf '[proj]\n[hdr]\n' > .warden
  _warden_env >/dev/null
  run cat "$CBOX_WARDEN_DIR/sessions/wbox.json"
  _warden_teardown
  [[ "$output" != *'"proj"'* ]]
}

@test "warden: unknown and invalid resources are reported, not fatal" {
  _warden_setup
  printf '[bad name]\nupstream = ftp://x\n' >> "$CBOX_WARDEN_DIR/resources"
  printf '[ghost]\n' > .warden
  _warden_approve_yes
  _warden_env >/dev/null
  run cat "$WT/stderr"
  _warden_teardown
  [[ "$output" == *"'bad name'"*"skipped"* ]]
  [[ "$output" == *"'ghost', which is not configured"* ]]
}

@test "warden: token is stable per container and private on disk" {
  _warden_setup
  a=$(_warden_url)
  b=$(_warden_url)
  dmode=$(stat -c %a "$CBOX_WARDEN_DIR/sessions" 2>/dev/null || stat -f %Lp "$CBOX_WARDEN_DIR/sessions")
  fmode=$(stat -c %a "$CBOX_WARDEN_DIR/sessions/wbox.json" 2>/dev/null || stat -f %Lp "$CBOX_WARDEN_DIR/sessions/wbox.json")
  _warden_teardown
  [ "$a" = "$b" ]
  [ "$dmode" = 700 ]
  [ "$fmode" = 600 ]
}

@test "warden: last session end revokes the token and stops the broker" {
  _warden_setup
  url=$(_warden_url)
  pid=$(_cbox_warden_broker_pid)
  _cbox_warden_end wbox
  sleep 0.3
  # A zombie counts as stopped: where PID 1 never reaps orphans (a container
  # created by an older cbox), the killed broker lingers as one.
  alive=no; [[ "$(ps -o stat= -p "$pid" 2>/dev/null)" =~ ^[^Z] ]] && alive=yes
  run _cbox_warden_broker_pid
  _warden_teardown
  [ "$status" -ne 0 ]
  [ "$alive" = no ]
  [ ! -f "$CBOX_WARDEN_DIR/sessions/wbox.json" ]
}

@test "warden: broker keeps running while another container has a session" {
  _warden_setup
  _warden_env >/dev/null
  _cbox_warden_start obox </dev/null >/dev/null 2>&1
  _cbox_session_start obox
  _cbox_warden_end wbox
  run _cbox_warden_broker_pid
  rm -f "$_CBOX_SESSION_DIR/.cbox-active-obox-$$"
  _warden_teardown
  [ "$status" -eq 0 ]
}

# Moves the resources file to $1 and leaves a symlink in its place, like a
# dotfiles setup does.
_warden_relocate() {
  mkdir -p "$(dirname "$1")"
  mv "$CBOX_WARDEN_DIR/resources" "$1"
  ln -s "$1" "$CBOX_WARDEN_DIR/resources"
}

@test "cbox warden edit: creates the target of a symlinked resources file, keeping the link" {
  rm -rf "$CBOX_WARDEN_DIR" "$BATS_TMPDIR/wdots"
  mkdir -p "$CBOX_WARDEN_DIR"
  ln -s "$BATS_TMPDIR/wdots/warden/resources" "$CBOX_WARDEN_DIR/resources"
  EDITOR=true run _cbox_warden_cmd edit
  [ "$status" -eq 0 ]
  [ -L "$CBOX_WARDEN_DIR/resources" ]
  grep -q "^# \[openrouter\]" "$BATS_TMPDIR/wdots/warden/resources"
}

@test "warden guard: off when the resources file lives in the mounted host config dir" {
  _warden_setup
  _warden_relocate "$CBOX_HOST_CONFIG_DIR/warden/resources"
  run _warden_env
  broker=$(_cbox_warden_broker_pid || true)
  listing=$(_cbox_warden_cmd list)
  _warden_teardown
  [ -z "$output" ]
  [ -z "$broker" ]
  [[ "$(cat "$WT/stderr")" == *"warden is off"*"visible inside containers"*"$CBOX_HOST_CONFIG_DIR"* ]]
  [[ "$listing" == *"warden is off"* ]]
}

@test "warden guard: off when the file sits in a dir mounted via a ~/.claude symlink" {
  _warden_setup
  local dots="$BATS_TMPDIR/wdots-mounted"
  rm -rf "$dots"; mkdir -p "$dots/output-styles"
  rm -rf "$CBOX_CLAUDE_DIR/output-styles"
  ln -s "$dots/output-styles" "$CBOX_CLAUDE_DIR/output-styles"
  _warden_relocate "$dots/output-styles/resources"
  run _warden_env
  rm -f "$CBOX_CLAUDE_DIR/output-styles"
  _warden_teardown
  [ -z "$output" ]
  [[ "$(cat "$WT/stderr")" == *"warden is off"* ]]
}

@test "warden guard: a file next to mounted files (not in a mounted dir) is fine" {
  _warden_setup
  local dots="$BATS_TMPDIR/wdots-files"
  rm -rf "$dots"; mkdir -p "$dots/claudebox"
  echo "{}" > "$dots/claudebox/settings.json"
  rm -f "$CBOX_CLAUDE_DIR/settings.json"
  ln -s "$dots/claudebox/settings.json" "$CBOX_CLAUDE_DIR/settings.json"
  _warden_relocate "$dots/claudebox/warden/resources"
  run _warden_env
  rm -f "$CBOX_CLAUDE_DIR/settings.json"
  _warden_teardown
  [[ "${lines[0]}" == WARDEN_URL=* ]]
}

@test "warden guard: off for a session whose workspace contains the file" {
  _warden_setup
  _warden_relocate "$WT/proj/config/resources"
  run _warden_env
  _warden_teardown
  [ -z "$output" ]
  [[ "$(cat "$WT/stderr")" == *"warden is off"*"$WT/proj"* ]]
}

@test "warden guard: broker refuses all requests once any session's workspace exposes the file" {
  _warden_setup
  url=$(_warden_url)
  ok_before=$(curl -s -o /dev/null -w '%{http_code}' "$url/llm/models")
  _warden_relocate "$BATS_TMPDIR/wdots-other/resources"
  printf '{"token":"x","box":"other","project":"%s","resources":[]}\n' "$BATS_TMPDIR/wdots-other" \
    > "$CBOX_WARDEN_DIR/sessions/other.json"
  run curl -s -w ' %{http_code}' "$url/llm/models"
  _warden_teardown
  [ "$ok_before" = 200 ]
  [[ "$output" == *"warden is off"*" 503" ]]
}

@test "warden guard: off when the warden dir itself is inside a mounted dir" {
  _warden_setup
  local res; res=$(cat "$CBOX_WARDEN_DIR/resources")
  CBOX_WARDEN_DIR="$CBOX_SHARE_DIR/warden"
  rm -rf "$CBOX_WARDEN_DIR"; mkdir -p "$CBOX_WARDEN_DIR"
  printf '%s\n' "$res" > "$CBOX_WARDEN_DIR/resources"
  run _warden_env
  broker=$(_cbox_warden_broker_pid || true)
  _warden_teardown
  rm -rf "$CBOX_WARDEN_DIR"
  [ -z "$output" ]
  [ -z "$broker" ]
  [[ "$(cat "$WT/stderr")" == *"warden is off"*"$CBOX_SHARE_DIR"* ]]
}

@test "warden: a broker from another cbox version is restarted; tokens keep working" {
  _warden_setup
  url=$(_warden_url)
  pid1=$(_cbox_warden_broker_pid)
  _warden_env >/dev/null
  pid2=$(_cbox_warden_broker_pid)
  # As left by an older cbox: no (or another) code id.
  rm -f "$CBOX_WARDEN_DIR/broker.id"
  _warden_env >/dev/null
  pid3=$(_cbox_warden_broker_pid)
  echo other > "$CBOX_WARDEN_DIR/broker.id"
  url_after=$(_warden_url)
  pid4=$(_cbox_warden_broker_pid)
  out=$(curl -s "$url/llm/models")
  _warden_teardown
  [ "$pid1" = "$pid2" ]
  [ "$pid3" != "$pid2" ]
  [ "$pid4" != "$pid3" ]
  [ "$url_after" = "$url" ]
  [[ "$out" == *'"path": "/api/v1/models"'* ]]
}

@test "warden: waits for a slow-starting broker (cold python3 on macOS)" {
  _warden_setup
  mkdir -p "$WT/slowbin"
  printf '#!/bin/sh\nsleep 4\nexec %s "$@"\n' "$(command -v python3)" > "$WT/slowbin/python3"
  chmod +x "$WT/slowbin/python3"
  PATH="$WT/slowbin:$PATH" run _cbox_warden_broker_start
  _warden_teardown
  [ "$status" -eq 0 ]
  [[ "$output" != *"did not start"* ]]
}

@test "warden: gives up quickly when the broker dies at startup" {
  _warden_setup
  python3 -c 'import socket,time; s=socket.socket(); s.bind(("127.0.0.1",'"$CBOX_WARDEN_PORT"')); s.listen(); time.sleep(30)' &
  local blocker=$!
  sleep 0.5
  local start=$SECONDS
  run _cbox_warden_broker_start
  local took=$((SECONDS - start))
  kill "$blocker" 2>/dev/null || true
  _warden_teardown
  [ "$status" -eq 1 ]
  [[ "$output" == *"did not start"*"broker.log"* ]]
  [ "$took" -lt 10 ]
}

@test "cbox warden: lists resources and what this project gets" {
  _warden_setup
  printf '[proj]\n' > .warden
  run _cbox_warden_cmd list
  _warden_teardown
  [[ "$output" == *"✔ llm"*"every container"* ]]
  [[ "$output" == *"· proj"*"listed in .warden, not approved"* ]]
  [[ "$output" == *"cbox warden approve"* ]]
}

@test "cbox warden: explains how to start when nothing is configured" {
  rm -rf "$CBOX_WARDEN_DIR"
  run _cbox_warden_cmd
  [[ "$output" == *"No warden resources configured"*"cbox warden edit"* ]]
}

@test "cbox warden secret set: rejects invalid resource names" {
  run _cbox_warden_cmd secret set "Bad Name"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage: cbox warden secret set"* ]]
}

@test "cbox warden: unknown command shows usage" {
  run _cbox_warden_cmd frobnicate
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage: cbox warden"* ]]
}

# S3-style resource with the dvc policy (bucket bkt); the project's .warden sets the prefix.
_warden_add_store() {
  cat >> "$CBOX_WARDEN_DIR/resources" <<INI
[store]
upstream     = http://127.0.0.1:$UP_PORT
auth         = sigv4
key-id       = cbox.warden.store-id
secret       = cbox.warden.store
policy       = dvc
bucket       = bkt
availability = project
${1:-}
INI
}

_WARDEN_OBJ="bkt/proj1/files/md5/ab/cdef0123456789abcdef0123456789"

@test "warden sigv4: signature matches the AWS documentation example" {
  run python3 -c "$(_cbox_warden_py | sed '/^if __name__/,$d')
h = sign_v4({'region': 'us-east-1'}, 'GET', '/', 'max-keys=2&prefix=J',
            {'x-amz-content-sha256': 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855'},
            'examplebucket.s3.amazonaws.com', 'AKIAIOSFODNN7EXAMPLE',
            'wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY', now='20130524T000000Z')
print(h['authorization'].split('Signature=')[1])"
  [ "$output" = "34b48302e7b5fa45bde8084f4b7868a86f0a534bc59db6670ed5711ef69dc6f7" ]
}

@test "warden sigv4: container gets an AWS profile with dummy keys pointing at the broker" {
  _warden_setup
  _warden_add_store "profile = flux-dvc-bkt"
  printf '[store]\nprefix = proj1\n' > .warden
  _warden_approve_yes
  env=$(_warden_env)
  _warden_teardown
  url=$(sed -n 's/^WARDEN_URL=//p' <<<"$env")
  profile=$(sed -n 's/^WARDEN_AWS_CONFIG=//p' <<<"$env" | base64 -d)
  [[ "$env" == *"AWS_CONFIG_FILE=/home/claude/.aws/warden-config"* ]]
  [[ "$profile" == *"[profile flux-dvc-bkt]"* ]]
  [[ "$profile" == *"endpoint_url = $url/store"* ]]
  [[ "$profile" == *"aws_access_key_id = warden"* ]]
  [[ "$profile" == *"addressing_style = path"* ]]
  [[ "$profile$env" != *REDACTED* ]]
}

@test "warden sigv4: re-signs with the real keys and drops the client's signature" {
  _warden_setup
  _warden_add_store
  printf '[store]\nprefix = proj1\n' > .warden
  _warden_approve_yes
  url=$(_warden_url)
  out=$(curl -s -H 'Authorization: AWS4-HMAC-SHA256 Credential=warden/x' -H 'X-Amz-Security-Token: t' \
    -H 'X-Amz-Content-Sha256: UNSIGNED-PAYLOAD' "$url/store/$_WARDEN_OBJ")
  _warden_teardown
  [[ "$out" == *'"authorization": "AWS4-HMAC-SHA256 Credential=sk-test-REDACTED-cbox.warden.store-id/'*'/auto/s3/aws4_request, SignedHeaders=host;x-amz-content-sha256;x-amz-date, Signature='* ]]
  [[ "$out" == *"\"path\": \"/$_WARDEN_OBJ\""* ]]
  [[ "$out" != *"Credential=warden"* ]]
  [[ "$out" != *"x-amz-security-token"* ]]
}

@test "warden sigv4: the dvc policy allows only the project's DVC tree, never deletes" {
  _warden_setup
  _warden_add_store
  printf '[store]\nprefix = proj1\n' > .warden
  _warden_approve_yes
  url=$(_warden_url)/store
  code() { curl -s -o /dev/null -w '%{http_code}' -X "$1" "$url/$2"; }
  got="$(code GET "$_WARDEN_OBJ") $(code PUT "$_WARDEN_OBJ") $(code POST "$_WARDEN_OBJ?uploads")"
  got+=" $(code GET 'bkt?list-type=2&prefix=proj1/files/md5/ab/')"
  got+=" | $(code DELETE "$_WARDEN_OBJ") $(code GET "${_WARDEN_OBJ/proj1/proj2}")"
  got+=" $(code GET "${_WARDEN_OBJ/bkt/other}") $(code GET bkt/proj1/notes.txt)"
  got+=" $(code GET 'bkt?list-type=2&prefix=proj2/') $(code GET 'bkt?list-type=2')"
  got+=" $(code GET bkt/proj1/files/md5/%2e%2e/cdef0123456789abcdef0123456789)"
  _warden_teardown
  [ "$got" = "200 200 200 200 | 403 403 403 403 403 403 403" ]
}

@test "warden sigv4: no grant without a prefix, or when .warden sets anything else" {
  _warden_setup
  _warden_add_store
  # Global availability alone does not do: the dvc policy needs a project prefix.
  sed -i.bak 's/^availability = project$/availability = global/' "$CBOX_WARDEN_DIR/resources"
  no_prefix=$(_warden_env)
  printf '[store]\nprefix = proj1\nupstream = http://127.0.0.1:1\n' > .warden
  _warden_approve_yes
  extra_key=$(_warden_env)
  extra_err=$(cat "$WT/stderr")
  _warden_teardown
  [[ "$no_prefix" != *AWS_CONFIG_FILE* ]]
  [[ "$extra_key" != *AWS_CONFIG_FILE* ]]
  [[ "$extra_err" == *"only prefix is allowed"* ]]
}

@test "warden sigv4: a .warden prefix must stay inside the resource's own prefix" {
  _warden_setup
  _warden_add_store "prefix = team"
  printf '[store]\nprefix = other\n' > .warden
  _warden_approve_yes
  outside=$(_warden_env)
  outside_err=$(cat "$WT/stderr")
  printf '[store]\nprefix = team/proj1\n' > .warden
  _warden_approve_yes
  inside=$(_warden_env)
  _warden_teardown
  [[ "$outside" != *AWS_CONFIG_FILE* ]]
  [[ "$outside_err" == *"outside the resource's prefix 'team'"* ]]
  [[ "$inside" == *AWS_CONFIG_FILE* ]]
}

@test "cbox warden _ensure: adds a resource once and never overwrites it" {
  _warden_setup
  rm -f "$CBOX_WARDEN_DIR/resources"
  body='type = http
upstream = https://storage.example
auth = sigv4
key-id = t.id
secret = t.secret
policy = dvc
bucket = bkt
availability = project
profile = flux-dvc-bkt.v1'
  first=$(_cbox_warden_cmd _ensure dvc-bkt <<<"$body")
  again=$(_cbox_warden_cmd _ensure dvc-bkt <<<"${body/storage.example/other.example}")
  list=$(_cbox_warden_python list "$CBOX_WARDEN_DIR" "$PWD")
  _warden_teardown
  [[ "$first" == *"added warden resource 'dvc-bkt'"* ]]
  [[ "$again" == *"already configured"* ]]
  [ "$(grep -c '^\[dvc-bkt\]' "$CBOX_WARDEN_DIR/resources")" -eq 1 ]
  grep -q 'storage.example' "$CBOX_WARDEN_DIR/resources"
  ! grep -q 'other.example' "$CBOX_WARDEN_DIR/resources" || false
  grep -q '^# warden resources' "$CBOX_WARDEN_DIR/resources"
  [[ "$list" == *"dvc-bkt"* ]]
}

@test "cbox warden _ensure: refuses an invalid resource" {
  _warden_setup
  run _cbox_warden_cmd _ensure broken <<<"upstream = https://x.example
auth = sigv4"
  _warden_teardown
  [ "$status" -eq 1 ]
  [[ "$output" == *"resource 'broken'"* ]]
  ! grep -q '^\[broken\]' "$CBOX_WARDEN_DIR/resources" || false
}

@test "cbox warden _exposed: knows which host paths a container can see" {
  mkdir -p "$CBOX_HOST_CONFIG_DIR/.aws" "$BATS_TMPDIR/private-aws"
  run _cbox_warden_cmd _exposed "$CBOX_HOST_CONFIG_DIR/.aws/config"
  inside=$status
  run _cbox_warden_cmd _exposed "$BATS_TMPDIR/private-aws/config"
  [ "$inside" -eq 0 ]
  [ "$status" -eq 1 ]
}

@test "warden sigv4: a resource without key-id is reported and skipped" {
  _warden_setup
  _warden_add_store
  sed -i.bak '/^key-id/d' "$CBOX_WARDEN_DIR/resources"
  run _cbox_warden_python list "$CBOX_WARDEN_DIR" "$PWD"
  _warden_teardown
  [[ "$output" == *"warden resource 'store': sigv4 needs key-id"* ]]
}

# ---------------------------------------------------------------------------
# _cbox_audio_ensure_config
# ---------------------------------------------------------------------------

@test "_cbox_audio_ensure_config: leaves PulseAudio's own default.pa alone" {
  export XDG_CONFIG_HOME="$BATS_TMPDIR/xdg-config"
  rm -rf "$XDG_CONFIG_HOME"
  _cbox_audio_ensure_config
  [ ! -e "$XDG_CONFIG_HOME/pulse/default.pa" ]
}

@test "_cbox_audio_ensure_config: removes the network listener older cbox versions added" {
  export XDG_CONFIG_HOME="$BATS_TMPDIR/xdg-config2"
  mkdir -p "$XDG_CONFIG_HOME/pulse"
  printf '%s\n' ".include /opt/homebrew/etc/pulse/default.pa" "$_CBOX_PULSE_TCP_LINE" "load-module module-coreaudio-detect" \
    > "$XDG_CONFIG_HOME/pulse/default.pa"
  _cbox_audio_ensure_config
  run cat "$XDG_CONFIG_HOME/pulse/default.pa"
  [[ "$output" != *"module-native-protocol-tcp"* ]]
  [[ "$output" == *".include /opt/homebrew/etc/pulse/default.pa"* ]]
  [[ "$output" == *"module-coreaudio-detect"* ]]
}

@test "_cbox_audio_ensure_config: keeps a TCP listener the user configured" {
  export XDG_CONFIG_HOME="$BATS_TMPDIR/xdg-config3"
  mkdir -p "$XDG_CONFIG_HOME/pulse"
  echo "load-module module-native-protocol-tcp auth-ip-acl=127.0.0.1" > "$XDG_CONFIG_HOME/pulse/default.pa"
  _cbox_audio_ensure_config
  run grep -c "module-native-protocol-tcp" "$XDG_CONFIG_HOME/pulse/default.pa"
  [ "$output" -eq 1 ]
}

@test "_cbox_audio_ensure_config: adds exit-idle-time to daemon.conf" {
  export XDG_CONFIG_HOME="$BATS_TMPDIR/xdg-config4"
  _cbox_audio_ensure_config
  run grep "exit-idle-time" "$XDG_CONFIG_HOME/pulse/daemon.conf"
  [ "$status" -eq 0 ]
}

@test "_cbox_audio_stop: keeps PulseAudio while any cbox session is open" {
  local dir; dir=$(_cbox_audio_socket); dir="${dir%/*}"
  mkdir -p "$dir"; : > "$dir/started-by-cbox"
  _CBOX_SESSION_DIR="$BATS_TMPDIR/sessions-audio"; mkdir -p "$_CBOX_SESSION_DIR"
  : > "$_CBOX_SESSION_DIR/.cbox-active-other-$$"
  pulseaudio() { echo "killed"; }
  run _cbox_audio_stop
  [[ "$output" != *killed* ]]
  rm -f "$_CBOX_SESSION_DIR/.cbox-active-other-$$"
  run _cbox_audio_stop
  [[ "$output" == *killed* ]]
  [ ! -e "$dir/started-by-cbox" ]
}

@test "_cbox_audio_stop: never stops a PulseAudio cbox did not start" {
  local dir; dir=$(_cbox_audio_socket); rm -f "${dir%/*}/started-by-cbox"
  pulseaudio() { echo "killed"; }
  run _cbox_audio_stop
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# _cbox_session_start / _cbox_session_end
# ---------------------------------------------------------------------------

@test "_cbox_session_start: creates marker file for the current PID" {
  _CBOX_SESSION_DIR="$BATS_TMPDIR"
  _cbox_session_start "myproject"
  [ -f "$BATS_TMPDIR/.cbox-active-myproject-$$" ]
  rm -f "$BATS_TMPDIR/.cbox-active-myproject-$$"
}

@test "_cbox_session_end: removes own marker and returns 1 when no other sessions" {
  _CBOX_SESSION_DIR="$BATS_TMPDIR"
  touch "$BATS_TMPDIR/.cbox-active-myproject-$$"
  run _cbox_session_end "myproject"
  [ "$status" -eq 1 ]
  [ ! -f "$BATS_TMPDIR/.cbox-active-myproject-$$" ]
}

@test "_cbox_session_end: returns 0 when another live session exists" {
  _CBOX_SESSION_DIR="$BATS_TMPDIR"
  touch "$BATS_TMPDIR/.cbox-active-myproject-$$"
  # Simulate a second session owned by the current shell's parent (init/PID 1 always alive)
  touch "$BATS_TMPDIR/.cbox-active-myproject-1"
  run _cbox_session_end "myproject"
  [ "$status" -eq 0 ]
  rm -f "$BATS_TMPDIR/.cbox-active-myproject-1"
}

@test "_cbox_session_end: cleans up stale marker files from dead PIDs" {
  _CBOX_SESSION_DIR="$BATS_TMPDIR"
  touch "$BATS_TMPDIR/.cbox-active-myproject-$$"
  # Use a PID that is guaranteed to not exist
  touch "$BATS_TMPDIR/.cbox-active-myproject-999999999"
  _cbox_session_end "myproject" || true
  [ ! -f "$BATS_TMPDIR/.cbox-active-myproject-999999999" ]
}

@test "_cbox_session_end: does not remove markers from a different container" {
  _CBOX_SESSION_DIR="$BATS_TMPDIR"
  touch "$BATS_TMPDIR/.cbox-active-myproject-$$"
  touch "$BATS_TMPDIR/.cbox-active-otherproject-1"
  _cbox_session_end "myproject" || true
  [ -f "$BATS_TMPDIR/.cbox-active-otherproject-1" ]
  rm -f "$BATS_TMPDIR/.cbox-active-otherproject-1"
}

@test "_cbox_session_end: ignores markers of a container whose name extends this one" {
  _CBOX_SESSION_DIR="$BATS_TMPDIR"
  touch "$BATS_TMPDIR/.cbox-active-myproject-$$"
  touch "$BATS_TMPDIR/.cbox-active-myproject-two-1"
  run _cbox_session_end "myproject"
  [ "$status" -eq 1 ]
  [ -f "$BATS_TMPDIR/.cbox-active-myproject-two-1" ]
  rm -f "$BATS_TMPDIR/.cbox-active-myproject-two-1"
}

@test "_cbox_session_end: last session under zsh returns 1 instead of aborting on an empty glob" {
  command -v zsh >/dev/null || skip "zsh not installed"
  local dir="$BATS_TMPDIR/zsh-sessions"
  rm -rf "$dir"; mkdir -p "$dir"
  run zsh -f -c "
    source '$CBOX_SH' >/dev/null 2>&1
    _CBOX_SESSION_DIR='$dir'
    _cbox_session_start myproject
    _cbox_session_end myproject
    echo \"status=\$?\"
  "
  [ "$output" = "status=1" ]
}

# ---------------------------------------------------------------------------
# _cbox_container_has_sessions
# ---------------------------------------------------------------------------

@test "_cbox_container_has_sessions: returns 1 when only PID 1 and the probe run with PPID 0" {
  _CBOX_CMD=_fake_runtime
  _fake_runtime() { printf '    1     0 tail\n   61     1 dbus-daemon\n  900     0 ps\n'; }
  run _cbox_container_has_sessions "myproject"
  [ "$status" -eq 1 ]
}

@test "_cbox_container_has_sessions: returns 0 when another exec session is attached" {
  _CBOX_CMD=_fake_runtime
  _fake_runtime() { printf '    1     0 tail\n  134     0 claude\n  900     0 ps\n'; }
  run _cbox_container_has_sessions "myproject"
  [ "$status" -eq 0 ]
}

@test "_cbox_container_has_sessions: returns 2 when the probe fails" {
  _CBOX_CMD=_fake_runtime
  _fake_runtime() { return 1; }
  run _cbox_container_has_sessions "myproject"
  [ "$status" -eq 2 ]
}

@test "_cbox_container_has_sessions: returns 2 when the probe prints nothing" {
  _CBOX_CMD=_fake_runtime
  _fake_runtime() { true; }
  run _cbox_container_has_sessions "myproject"
  [ "$status" -eq 2 ]
}

# ---------------------------------------------------------------------------
# _cbox_git_identity
# ---------------------------------------------------------------------------

@test "_cbox_git_identity: passes the host's identity for this project" {
  local repo="$BATS_TMPDIR/ident-repo"
  rm -rf "$repo"; git init -q "$repo"
  git config --global user.name "Global Name"
  git config --global user.email "global@example.com"
  git -C "$repo" config user.email "work@example.com"
  cd "$repo"
  run _cbox_git_identity
  git config --global --unset user.name; git config --global --unset user.email
  [[ "$output" == *"GIT_AUTHOR_NAME=Global Name"* ]]
  [[ "$output" == *"GIT_COMMITTER_NAME=Global Name"* ]]
  [[ "$output" == *"GIT_AUTHOR_EMAIL=work@example.com"* ]]
  [[ "$output" == *"GIT_COMMITTER_EMAIL=work@example.com"* ]]
}

@test "_cbox_git_identity: prints nothing when the host has no identity" {
  cd "$BATS_TMPDIR"
  run env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 bash -c "source '$CBOX_SH'; _cbox_git_identity"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# _cbox_flux_install
# ---------------------------------------------------------------------------

_flux_install_setup() {
  FAKE_BIN="$BATS_TMPDIR/fake-flux-bin"
  rm -rf "$FAKE_BIN"; mkdir -p "$FAKE_BIN"
  printf '#!/usr/bin/env bash\necho "flux v1"\n' > "$FAKE_BIN/flux"
  chmod +x "$FAKE_BIN/flux"
  PATH="$FAKE_BIN:$PATH"
  rm -f "$CBOX_DATA_DIR"/.flux-installed-*
  INSTALLED="$BATS_TMPDIR/installed-flux"
  rm -f "$INSTALLED"
  _CBOX_CMD=_fake_runtime
  _fake_runtime() { echo "$*" >> "$BATS_TMPDIR/runtime-calls"; cat > "$INSTALLED"; }
  rm -f "$BATS_TMPDIR/runtime-calls"
}

@test "_cbox_flux_install: copies the host's flux into the container as root" {
  _flux_install_setup
  run _cbox_flux_install box1
  [ "$status" -eq 0 ]
  cmp -s "$FAKE_BIN/flux" "$INSTALLED"
  [[ "$(cat "$BATS_TMPDIR/runtime-calls")" == "exec -i --user root box1 sh -c "* ]]
}

@test "_cbox_flux_install: skips when unchanged, reinstalls after a host upgrade" {
  _flux_install_setup
  _cbox_flux_install box1
  _cbox_flux_install box1
  [ "$(grep -c . "$BATS_TMPDIR/runtime-calls")" -eq 1 ]
  printf '#!/usr/bin/env bash\necho "flux v2"\n' > "$FAKE_BIN/flux"
  _cbox_flux_install box1
  [ "$(grep -c . "$BATS_TMPDIR/runtime-calls")" -eq 2 ]
  grep -q "flux v2" "$INSTALLED"
}

@test "_cbox_flux_install: a failed copy is reported and retried next time" {
  _flux_install_setup
  _fake_runtime() { cat >/dev/null; return 1; }
  run _cbox_flux_install box1
  [[ "$output" == *"Could not install the host's flux"* ]]
  [ ! -f "$CBOX_DATA_DIR/.flux-installed-box1" ]
}

@test "_cbox_flux_install: does nothing without flux on the host" {
  _CBOX_CMD=_fake_runtime
  _fake_runtime() { echo called; }
  PATH="/usr/bin:/bin" run _cbox_flux_install box1
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# _cbox_list_names
# ---------------------------------------------------------------------------

@test "_cbox_list_names: returns only names from _cbox_rt_list output" {
  _cbox_rt_list() { printf "alpha running\nbeta stopped\n"; }
  run _cbox_list_names
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'alpha\nbeta')" ]
}

@test "_cbox_list_names: returns empty output when no containers exist" {
  _cbox_rt_list() { return 0; }
  run _cbox_list_names
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_cbox_list_names: tolerates _cbox_rt_list failure gracefully" {
  _cbox_rt_list() { return 1; }
  run _cbox_list_names
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# _cbox_rt_list STATE column parsing (Apple Container 1.0.0 format)
# ---------------------------------------------------------------------------

_rt_list_awk() {
  # apply the same awk as _cbox_rt_list uses for Apple Container
  awk 'NR==1{for(i=1;i<=NF;i++)if($i=="STATE")col=i;next} col&&NR>1{print $1,$col}'
}

@test "_cbox_rt_list awk: extracts name and STATE from 1.0.0 header format" {
  local input
  input=$(printf "ID IMAGE OS ARCH STATE IP CPUS MEMORY STARTED\nmy-app claudebox:latest linux arm64 stopped  4 1024 MB 2026-01-01\nbuildkit builder:0.12.0 linux arm64 running 192.168.64.5/24 2 2048 MB 2026-01-01\n")
  run bash -c "echo '$input' | $(_rt_list_awk_cmd)"
  # use helper inline
  run bash -c "printf 'ID IMAGE OS ARCH STATE IP CPUS MEMORY STARTED\nmy-app claudebox:latest linux arm64 stopped  4 1024 MB 2026-01-01\nbuildkit builder:0.12.0 linux arm64 running 192.168.64.5/24 2 2048 MB 2026-01-01\n' | awk 'NR==1{for(i=1;i<=NF;i++)if(\$i==\"STATE\")col=i;next} col&&NR>1{print \$1,\$col}'"
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'my-app stopped\nbuildkit running')" ]
}

@test "_cbox_rt_list awk: tolerates STATE column being absent" {
  run bash -c "printf 'NAME STATUS\nmy-app stopped\n' | awk 'NR==1{for(i=1;i<=NF;i++)if(\$i==\"STATE\")col=i;next} col&&NR>1{print \$1,\$col}'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# _cbox_rt_label (Apple Container path via python3)
# ---------------------------------------------------------------------------

_label_from_json() {
  # helper: simulate _cbox_rt_label python logic against a given JSON string
  local json="$1" label="$2"
  echo "$json" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); e=d[0] if isinstance(d,list) else d; c=e.get('configuration') or e.get('Config') or e; l=c.get('labels') or c.get('Labels') or {}; print(l.get(sys.argv[1],'') if isinstance(l,dict) else '')" "$label"
}

@test "_cbox_rt_label python: reads label from array with configuration.labels" {
  run _label_from_json '[{"configuration":{"labels":{"cbox.project":"true"}}}]' "cbox.project"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "_cbox_rt_label python: reads label from single object with configuration.labels" {
  run _label_from_json '{"configuration":{"labels":{"cbox.project":"true"}}}' "cbox.project"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "_cbox_rt_label python: reads label from flat labels key" {
  run _label_from_json '[{"labels":{"cbox.project":"true"}}]' "cbox.project"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "_cbox_rt_label python: reads label from Config.Labels (Docker-like)" {
  run _label_from_json '[{"Config":{"Labels":{"cbox.project":"true"}}}]' "cbox.project"
  [ "$status" -eq 0 ]
  [ "$output" = "true" ]
}

@test "_cbox_rt_label python: returns empty string when label absent" {
  run _label_from_json '[{"configuration":{"labels":{}}}]' "cbox.project"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_cbox_rt_label python: returns empty string when labels missing entirely" {
  run _label_from_json '[{"configuration":{}}]' "cbox.project"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# prune loop robustness under `set -euo pipefail` (Homebrew executable path)
# ---------------------------------------------------------------------------

# Mirrors the Apple Container prune loop, including the `stopped=$(…)`
# assignment, under the same `set -euo pipefail` the script applies when run as
# an installed executable. Regression: a stopped, unlabeled container listed
# LAST (e.g. Apple Container's `buildkit`) left the loop with a non-zero exit
# status; under `set -e` that aborted prune before it removed anything, with no
# "Nothing to prune." message. Runs in a subshell so the shell options and stub
# functions do not leak into the rest of the suite.
_prune_collect() {
  (
    set -euo pipefail
    _cbox_rt_list() {
      printf '%s\n' \
        "Temp stopped" \
        "companyon-apps running" \
        "Genesis stopped" \
        "buildkit stopped"
    }
    _cbox_rt_label() {
      # only cbox containers carry cbox.project=true; buildkit does not
      case "$1" in
        buildkit) echo "" ;;
        *) echo "true" ;;
      esac
    }
    local stopped
    stopped=$(
      _cbox_rt_list | while read -r cname cstate; do
        [[ "$cstate" == "running" ]] && continue
        if [[ "$(_cbox_rt_label "$cname" "cbox.project")" == "true" ]]; then
          echo "$cname"
        fi
      done
    )
    # Reaching here means the substitution did not abort under set -e.
    printf '%s\n' "$stopped"
  )
}

@test "prune loop: does not abort under set -e when last container is stopped and unlabeled" {
  run _prune_collect
  [ "$status" -eq 0 ]
}

@test "prune loop: collects stopped cbox containers, skips running and unlabeled" {
  run _prune_collect
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "Temp" ]
  [ "${lines[1]}" = "Genesis" ]
  [ "${#lines[@]}" -eq 2 ]
}

# ---------------------------------------------------------------------------
# _cbox_agent_bin / _cbox_agent_pkg
# ---------------------------------------------------------------------------

@test "_cbox_agent_bin: returns claude by default" {
  unset CBOX_AGENT
  run _cbox_agent_bin
  [ "$status" -eq 0 ]
  [ "$output" = "claude" ]
}

@test "_cbox_agent_bin: returns claude when CBOX_AGENT=claude" {
  CBOX_AGENT=claude run _cbox_agent_bin
  [ "$status" -eq 0 ]
  [ "$output" = "claude" ]
}

@test "_cbox_agent_bin: returns opencode when CBOX_AGENT=opencode" {
  CBOX_AGENT=opencode run _cbox_agent_bin
  [ "$status" -eq 0 ]
  [ "$output" = "opencode" ]
}

@test "_cbox_agent_pkg: returns claude package by default" {
  unset CBOX_AGENT
  run _cbox_agent_pkg
  [ "$status" -eq 0 ]
  [ "$output" = "@anthropic-ai/claude-code" ]
}

@test "_cbox_agent_pkg: returns opencode-ai when CBOX_AGENT=opencode" {
  CBOX_AGENT=opencode run _cbox_agent_pkg
  [ "$status" -eq 0 ]
  [ "$output" = "opencode-ai" ]
}

# ---------------------------------------------------------------------------
# cbox oc dispatch
# ---------------------------------------------------------------------------

@test "cbox oc: sets CBOX_AGENT=opencode for the session" {
  _cbox_ensure() { true; }
  _cbox_enter() {
    echo "agent=$(_cbox_agent_bin)"
  }
  run bash -c "
    source '$CBOX_SH'
    _cbox_ensure() { true; }
    _cbox_enter() { echo \"agent=\$(_cbox_agent_bin)\"; }
    cbox oc
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent=opencode"* ]]
}

@test "cbox oc safe: sets CBOX_AGENT=opencode for safe mode" {
  run bash -c "
    source '$CBOX_SH'
    _cbox_ensure() { true; }
    _cbox_enter() { echo \"agent=\$(_cbox_agent_bin) mode=\$2\"; }
    cbox oc safe
  "
  [ "$status" -eq 0 ]
  [[ "$output" == *"agent=opencode"* ]]
}

# ---------------------------------------------------------------------------
# playwright browser cache
# ---------------------------------------------------------------------------

@test "CBOX_PLAYWRIGHT_DIR: defaults to a subdir of CBOX_DATA_DIR" {
  run bash -c "
    unset CBOX_PLAYWRIGHT_DIR
    export CBOX_DATA_DIR='$BATS_TMPDIR/data-default'
    source '$CBOX_SH'
    echo \"\$CBOX_PLAYWRIGHT_DIR\"
  "
  [ "$status" -eq 0 ]
  [ "$output" = "$BATS_TMPDIR/data-default/ms-playwright" ]
}

@test "CBOX_PLAYWRIGHT_DIR: an explicit override is what actually gets mounted" {
  local capture="$BATS_TMPDIR/override-args"
  rm -f "$capture"
  cd "$BATS_TMPDIR"
  CBOX_PLAYWRIGHT_DIR="$BATS_TMPDIR/custom-browsers"
  _CBOX_CMD=_fake_runtime
  _fake_runtime() { printf '%s\n' "$@" >> "$capture"; }

  _cbox_create "cbox-unit-override" "normal"

  run cat "$capture"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$BATS_TMPDIR/custom-browsers:/opt/ms-playwright"* ]]
  [[ "$output" != *"$CBOX_DATA_DIR/ms-playwright"* ]]
}

@test "_cbox_seed_playwright: creates the host dir even when there is nothing to seed" {
  CBOX_PLAYWRIGHT_DIR="$BATS_TMPDIR/pw-created"
  rm -rf "$CBOX_PLAYWRIGHT_DIR"
  _CBOX_CMD=_fake_runtime
  _fake_runtime() { true; }
  run _cbox_seed_playwright
  [ "$status" -eq 0 ]
  [ -d "$BATS_TMPDIR/pw-created" ]
}

@test "_cbox_seed_playwright: stays silent when the image had no browsers" {
  CBOX_PLAYWRIGHT_DIR="$BATS_TMPDIR/pw-nothing"
  rm -rf "$CBOX_PLAYWRIGHT_DIR"
  _CBOX_CMD=_fake_runtime
  _fake_runtime() { true; }   # copies nothing, leaves the dir empty
  run _cbox_seed_playwright
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# BUILD_PLAYWRIGHT describes what the next build will do, not what the current
# image holds, and is usually passed inline to `cbox rebuild` rather than stored
# in cbox.env. Gating the seed on it let an empty mount shadow a fully baked
# image, so seeding must not consult it at all.
@test "_cbox_seed_playwright: seeds even when BUILD_PLAYWRIGHT is unset" {
  CBOX_PLAYWRIGHT_DIR="$BATS_TMPDIR/pw-unset-flag"
  rm -rf "$CBOX_PLAYWRIGHT_DIR"
  local capture="$BATS_TMPDIR/pw-unset-flag-args"
  rm -f "$capture"
  _CBOX_CMD=_fake_runtime
  _fake_runtime() { printf '%s\n' "$@" >> "$capture"; }
  unset BUILD_PLAYWRIGHT
  _cbox_seed_playwright

  run cat "$capture"
  [ "$status" -eq 0 ]
  [[ "$output" == *"/opt/ms-playwright/."* ]]
}

@test "_cbox_seed_playwright: seeds even when BUILD_PLAYWRIGHT=0" {
  CBOX_PLAYWRIGHT_DIR="$BATS_TMPDIR/pw-flag-zero"
  rm -rf "$CBOX_PLAYWRIGHT_DIR"
  local capture="$BATS_TMPDIR/pw-flag-zero-args"
  rm -f "$capture"
  _CBOX_CMD=_fake_runtime
  _fake_runtime() { printf '%s\n' "$@" >> "$capture"; }
  BUILD_PLAYWRIGHT=0 _cbox_seed_playwright

  run cat "$capture"
  [ "$status" -eq 0 ]
  [[ "$output" == *"/opt/ms-playwright/."* ]]
}

@test "_cbox_seed_playwright: copies from the image when the dir is empty" {
  CBOX_PLAYWRIGHT_DIR="$BATS_TMPDIR/pw-empty"
  rm -rf "$CBOX_PLAYWRIGHT_DIR"
  local capture="$BATS_TMPDIR/pw-empty-args"
  rm -f "$capture"
  _CBOX_CMD=_fake_runtime
  _fake_runtime() { printf '%s\n' "$@" >> "$capture"; }
  _cbox_seed_playwright

  run cat "$capture"
  [ "$status" -eq 0 ]
  [[ "$output" == *"run"* ]]
  [[ "$output" == *"--rm"* ]]
  [[ "$output" == *"$BATS_TMPDIR/pw-empty:/seed"* ]]
  [[ "$output" == *"/opt/ms-playwright/."* ]]
}

@test "_cbox_seed_playwright: leaves an already-populated dir alone" {
  CBOX_PLAYWRIGHT_DIR="$BATS_TMPDIR/pw-populated"
  mkdir -p "$CBOX_PLAYWRIGHT_DIR/chromium-1243"
  _CBOX_CMD=_fake_runtime
  _fake_runtime() { echo "RUNTIME CALLED"; }
  run _cbox_seed_playwright
  [ "$status" -eq 0 ]
  [[ "$output" != *"RUNTIME CALLED"* ]]
}

@test "_cbox_seed_playwright: surfaces a runtime failure without failing the caller" {
  CBOX_PLAYWRIGHT_DIR="$BATS_TMPDIR/pw-broken"
  rm -rf "$CBOX_PLAYWRIGHT_DIR"
  _CBOX_CMD=_fake_runtime
  _fake_runtime() { echo "unknown flag: --rm" >&2; return 1; }
  run _cbox_seed_playwright
  [ "$status" -eq 0 ]
  [[ "$output" == *"Could not seed the Playwright cache"* ]]
  [[ "$output" == *"unknown flag: --rm"* ]]
  [[ "$output" == *"downloaded inside the container on first use"* ]]
}

@test "_cbox_create: mounts the playwright cache writable in normal mode" {
  local capture="$BATS_TMPDIR/create-normal-args"
  rm -f "$capture"
  cd "$BATS_TMPDIR"
  CBOX_PLAYWRIGHT_DIR="$BATS_TMPDIR/pw-normal"
  _CBOX_CMD=_fake_runtime
  _fake_runtime() { printf '%s\n' "$@" >> "$capture"; }

  _cbox_create "cbox-unit-normal" "normal"

  run cat "$capture"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$BATS_TMPDIR/pw-normal:/opt/ms-playwright"* ]]
  [[ "$output" != *"$BATS_TMPDIR/pw-normal:/opt/ms-playwright:ro"* ]]
}

@test "_cbox_create: both modes get CBOX_MEMORY (default 4g), not the runtime's 1 GB" {
  local capture="$BATS_TMPDIR/create-memory-args"
  cd "$BATS_TMPDIR"
  _CBOX_CMD=_fake_runtime
  _fake_runtime() { printf '%s\n' "$@" >> "$capture"; }
  rm -f "$capture"; _cbox_create "cbox-unit-mem" "normal"
  normal=$(grep -c '^--memory=4g$' "$capture")
  rm -f "$capture"; _cbox_create "cbox-unit-mem" "safe"
  safe=$(grep -c '^--memory=4g$' "$capture")
  rm -f "$capture"; CBOX_MEMORY=6g _cbox_create "cbox-unit-mem" "normal"
  custom=$(grep -c '^--memory=6g$' "$capture")
  [ "$normal" -eq 1 ]
  [ "$safe" -eq 1 ]
  [ "$custom" -eq 1 ]
}

@test "_cbox_create: mounts the playwright cache read-only in safe mode" {
  local capture="$BATS_TMPDIR/create-safe-args"
  rm -f "$capture"
  cd "$BATS_TMPDIR"
  CBOX_PLAYWRIGHT_DIR="$BATS_TMPDIR/pw-safe"
  _CBOX_CMD=_fake_runtime
  _fake_runtime() { printf '%s\n' "$@" >> "$capture"; }

  _cbox_create "cbox-unit-safe" "safe"

  run cat "$capture"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$BATS_TMPDIR/pw-safe:/opt/ms-playwright:ro"* ]]
}

@test "_cbox_create: creates the playwright dir before mounting it" {
  cd "$BATS_TMPDIR"
  CBOX_PLAYWRIGHT_DIR="$BATS_TMPDIR/pw-precreate"
  rm -rf "$CBOX_PLAYWRIGHT_DIR"
  _CBOX_CMD=_fake_runtime
  _fake_runtime() { true; }

  _cbox_create "cbox-unit-precreate" "safe"
  [ -d "$CBOX_PLAYWRIGHT_DIR" ]
}

@test "_cbox_create: skips symlink targets nested inside a mounted target directory" {
  local capture="$BATS_TMPDIR/create-nested-args"
  local dots="$BATS_TMPDIR/nested-dots"
  rm -rf "$capture" "$dots" "$CBOX_CLAUDE_DIR/output-styles" "$CBOX_CLAUDE_DIR/output-styles.bak" \
    "$CBOX_CLAUDE_DIR/settings.json" "$CBOX_CLAUDE_DIR/settings-copy.json"
  mkdir -p "$dots/output-styles" "$CBOX_CLAUDE_DIR/output-styles.bak"
  echo "# ELI5" > "$dots/output-styles/ELI5.md"
  echo "{}" > "$dots/settings.json"
  ln -s "$dots/output-styles" "$CBOX_CLAUDE_DIR/output-styles"
  ln -s "$dots/output-styles/ELI5.md" "$CBOX_CLAUDE_DIR/output-styles.bak/ELI5.md"
  ln -s "$dots/settings.json" "$CBOX_CLAUDE_DIR/settings.json"
  ln -s "$dots/settings.json" "$CBOX_CLAUDE_DIR/settings-copy.json"
  # Work dir must not contain $dots, or the targets are skipped as workspace paths
  mkdir -p "$BATS_TMPDIR/nested-project"
  cd "$BATS_TMPDIR/nested-project"
  CBOX_PLAYWRIGHT_DIR="$BATS_TMPDIR/pw-nested"
  _CBOX_CMD=_fake_runtime
  _fake_runtime() { printf '%s\n' "$@" >> "$capture"; }

  _cbox_create "cbox-unit-nested" "normal"
  rm -rf "$CBOX_CLAUDE_DIR/output-styles" "$CBOX_CLAUDE_DIR/output-styles.bak" \
    "$CBOX_CLAUDE_DIR/settings.json" "$CBOX_CLAUDE_DIR/settings-copy.json"

  run cat "$capture"
  [ "$status" -eq 0 ]
  [[ "$output" == *"$dots/output-styles:$dots/output-styles"* ]]
  [[ "$output" != *"$dots/output-styles/ELI5.md:"* ]]
  [ "$(grep -c "^$dots/settings.json:$dots/settings.json\$" "$capture")" -eq 1 ]
}

@test "_cbox_create: possibly-empty arrays are expanded bash-3.2-safe under set -u" {
  # macOS /bin/bash 3.2 treats "${arr[@]}" on an empty array as unbound under
  # `set -u`; newer bash (and this test runner) does not, so check statically.
  run grep -nE '"\$\{(_mounted|_targets)\[@\]\}"' "$CBOX_SH"
  [ "$status" -eq 0 ]
  ! grep -nE '(^|[^+])"\$\{(_mounted|_targets)\[@\]\}"' "$CBOX_SH"
}

# ---------------------------------------------------------------------------
# exit path under `set -e` (how the Homebrew install runs cbox)
# ---------------------------------------------------------------------------

_run_cbox_script_with_fake_docker() {
  local bin="$BATS_TMPDIR/fake-bin" proj="$BATS_TMPDIR/exitpath"
  mkdir -p "$bin" "$proj" "$BATS_TMPDIR/exitpath-tmp"
  rm -f "$BATS_TMPDIR/exitpath-tmp"/.cbox-active-*
  cat > "$bin/docker" <<'SH'
#!/bin/bash
echo "docker $*" >> "$FAKE_LOG"
case "$1" in
  ps) echo "exitpath running" ;;
  inspect) echo '[{"Config":{"Labels":{"cbox.mode":"normal"}}}]' ;;
  exec) [[ " $* " == *" -it "* ]] && exit "${FAKE_EXEC_RC:-0}" ;;
esac
exit 0
SH
  chmod +x "$bin/docker"
  : > "$BATS_TMPDIR/exitpath.log"
  cd "$proj"
  FAKE_LOG="$BATS_TMPDIR/exitpath.log" TMPDIR="$BATS_TMPDIR/exitpath-tmp" \
    PATH="$bin:/usr/bin:/bin" /bin/bash "$CBOX_SH" "$@"
}

@test "exit path: container is stopped even when the agent exits non-zero" {
  FAKE_EXEC_RC=130 run _run_cbox_script_with_fake_docker
  [ "$status" -eq 0 ]
  grep -qx "docker stop exitpath" "$BATS_TMPDIR/exitpath.log"
}

@test "exit path: container is stopped when the agent exits cleanly" {
  FAKE_EXEC_RC=0 run _run_cbox_script_with_fake_docker
  [ "$status" -eq 0 ]
  grep -qx "docker stop exitpath" "$BATS_TMPDIR/exitpath.log"
}

# ---------------------------------------------------------------------------
# uv project environment
# ---------------------------------------------------------------------------

# The workspace is bind-mounted, so a container-built .venv replaces the host's
# macOS venv with a Linux one. The container must use its own per-project env,
# which only a relative path gives: an absolute one is shared by all projects.
@test "dockerfile: uv uses a per-project .venv-linux, leaving .venv to the host" {
  local dockerfile="$BATS_TEST_DIRNAME/../dockerfile"
  run grep -nE '^ENV UV_PROJECT_ENVIRONMENT=' "$dockerfile"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ENV UV_PROJECT_ENVIRONMENT=.venv-linux" ]]
}

# ---------------------------------------------------------------------------
# git guard: read-only .git/config and .git/hooks, session-end check
# ---------------------------------------------------------------------------

@test "_cbox_create: .git/config and .git/hooks are read-only in both modes" {
  local capture="$BATS_TMPDIR/create-git-args" proj="$BATS_TMPDIR/gitproj"
  rm -rf "$proj"; mkdir -p "$proj"; git -C "$proj" init -q; rm -rf "$proj/.git/hooks"
  cd "$proj"
  _CBOX_CMD=_fake_runtime
  _fake_runtime() { printf '%s\n' "$@" >> "$capture"; }
  for mode in normal safe; do
    rm -f "$capture"; _cbox_create "gitproj" "$mode"
    grep -qx "$proj/.git/config:/Workspace/gitproj/.git/config:ro" "$capture"
    grep -qx "$proj/.git/hooks:/Workspace/gitproj/.git/hooks:ro" "$capture"
  done
  [ -d "$proj/.git/hooks" ]
  rm -f "$capture"; CBOX_PROTECT_GIT=0 _cbox_create "gitproj" "normal"
  run grep -c '/.git/' "$capture"
  [ "$output" = "0" ]
}

@test "_cbox_create: no git mounts outside a git repository" {
  local capture="$BATS_TMPDIR/create-nogit-args"
  mkdir -p "$BATS_TMPDIR/nogit"; cd "$BATS_TMPDIR/nogit"
  _CBOX_CMD=_fake_runtime
  _fake_runtime() { printf '%s\n' "$@" >> "$capture"; }
  rm -f "$capture"; _cbox_create "nogit" "normal"
  run grep -c '/.git/' "$capture"
  [ "$output" = "0" ]
}

_guard_repo() {
  GUARD_PROJ="$BATS_TMPDIR/guardproj"
  rm -rf "$GUARD_PROJ" "$CBOX_DATA_DIR/git-guard"
  mkdir -p "$GUARD_PROJ"; cd "$GUARD_PROJ"
  git init -q .
  printf '#!/bin/sh\necho mine\n' > .git/hooks/pre-commit
  # Present before the session: not reported.
  mkdir lib && git -C lib init -q && git -C lib config core.pager less
}

@test "git guard: a session that changes nothing reports nothing and leaves no record" {
  _guard_repo
  _cbox_git_guard_start "gp"
  git clone -q lib cloned 2>/dev/null
  echo "work" > notes.txt
  run _cbox_git_guard_check "gp"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ ! -e "$CBOX_DATA_DIR/git-guard" ] || [ -z "$(ls -A "$CBOX_DATA_DIR/git-guard")" ]
}

@test "git guard: names each new command-running setting with its location" {
  _guard_repo
  _cbox_git_guard_start "gp"
  git config core.fsmonitor 'touch /tmp/x'
  git config alias.st '!sh -c evil'
  git config alias.co checkout
  printf '#!/bin/sh\n' > .git/hooks/post-checkout
  mkdir -p vendor/x && git -C vendor/x init -q && git -C vendor/x config filter.a.smudge evil
  mkdir -p .git/modules/sub && printf '[core]\n\tsshCommand = evil\n' > .git/modules/sub/config
  run _cbox_git_guard_check "gp"
  [[ "$output" == *".git/config: core.fsmonitor=touch /tmp/x"* ]]
  [[ "$output" == *".git/config: alias.st=!sh -c evil"* ]]
  [[ "$output" != *"alias.co"* ]]
  [[ "$output" == *".git/hooks/post-checkout"* ]]
  [[ "$output" == *"vendor/x/.git/config: filter.a.smudge=evil"* ]]
  [[ "$output" == *".git/modules/sub/config: core.sshcommand=evil"* ]]
  [[ "$output" != *"lib/.git"* ]]
  [[ "$output" == *"Not restored"* ]]
  # Declined: nothing touched.
  [ "$(git config --get core.fsmonitor)" = "touch /tmp/x" ]
}

@test "git guard: a .git replaced by a pointer elsewhere is reported" {
  _guard_repo
  _cbox_git_guard_start "gp"
  mv lib/.git "$BATS_TMPDIR/elsewhere.git"
  echo "gitdir: $BATS_TMPDIR/elsewhere.git" > lib/.git
  run _cbox_git_guard_check "gp"
  [[ "$output" == *"lib/.git → gitdir: $BATS_TMPDIR/elsewhere.git (points git elsewhere)"* ]]
  rm -rf "$BATS_TMPDIR/elsewhere.git"
}

@test "git guard: restore puts .git/config and .git/hooks back and keeps the changed files" {
  _guard_repo
  _cbox_git_guard_start "gp"
  git config core.fsmonitor 'touch /tmp/x'
  printf '#!/bin/sh\n' > .git/hooks/post-checkout
  echo evil >> .git/hooks/pre-commit
  echo ../elsewhere > .git/commondir
  _cbox_git_guard_ask() { return 0; }
  run _cbox_git_guard_check "gp"
  [[ "$output" == *"Restored"* ]]
  run git config --get core.fsmonitor
  [ "$status" -eq 1 ]
  [ ! -e .git/hooks/post-checkout ]
  [ ! -e .git/commondir ]
  [ "$(cat .git/hooks/pre-commit)" = "$(printf '#!/bin/sh\necho mine')" ]
  local kept
  kept=$(find "$CBOX_DATA_DIR/git-guard" -mindepth 1 -maxdepth 1 -name 'gp-*')
  grep -q fsmonitor "$kept/changed/config"
  [ -f "$kept/changed/hooks/post-checkout" ]
  [ -f "$kept/changed/commondir" ]
}

@test "git guard: a second concurrent session keeps the first session's record" {
  _guard_repo
  _cbox_git_guard_start "gp"
  git config core.fsmonitor 'touch /tmp/x'
  sleep 300 & local other=$!
  touch "$_CBOX_SESSION_DIR/.cbox-active-gp-$other"
  _cbox_git_guard_start "gp"
  kill "$other"; wait "$other" 2>/dev/null || true
  rm -f "$_CBOX_SESSION_DIR/.cbox-active-gp-$other"
  run _cbox_git_guard_check "gp"
  [[ "$output" == *"core.fsmonitor"* ]]
}

# ---------------------------------------------------------------------------
# Container ~/.config: own folder by default, chosen folders shared read-only
# ---------------------------------------------------------------------------

@test "config dir: defaults to claudebox/.config, not the real ~/.config" {
  run env -u CBOX_HOST_CONFIG_DIR -u XDG_CONFIG_HOME HOME="$HOME" bash -c 'source "$1"; echo "$CBOX_HOST_CONFIG_DIR"' _ "$CBOX_SH"
  [ "$output" = "$HOME/.config/claudebox/.config" ]
}

@test "_cbox_create: refuses a config dir that contains cbox's own config" {
  local capture="$BATS_TMPDIR/create-cfg-refused"
  cd "$BATS_TMPDIR"
  _CBOX_CMD=_fake_runtime
  _fake_runtime() { printf '%s\n' "$@" >> "$capture"; }
  for d in "$HOME/.config" "$HOME" "$HOME/.config/claudebox"; do
    rm -f "$capture"
    CBOX_HOST_CONFIG_DIR="$d" run _cbox_create "cfgbox" "normal"
    [ "$status" -ne 0 ]
    [[ "$output" == *"would let code in the container change config that runs on this Mac"* ]]
    [ ! -e "$capture" ]
  done
  # Safe mode mounts no config dir, so it is not affected.
  rm -f "$capture"
  CBOX_HOST_CONFIG_DIR="$HOME/.config" run _cbox_create "cfgbox" "safe"
  [ "$status" -eq 0 ]
}

@test "_cbox_create: CBOX_SHARE_CONFIG shares chosen folders read-only, never claudebox" {
  local capture="$BATS_TMPDIR/create-cfg-share"
  mkdir -p "$HOME/.config/opencode" "$HOME/.config/nvim" "$HOME/.config/claudebox"
  cd "$BATS_TMPDIR"
  _CBOX_CMD=_fake_runtime
  _fake_runtime() { printf '%s\n' "$@" >> "$capture"; }
  rm -f "$capture"
  CBOX_SHARE_CONFIG="opencode  nvim claudebox missing ../x" run _cbox_create "cfgbox" "normal"
  [ "$status" -eq 0 ]
  grep -qx "$CBOX_HOST_CONFIG_DIR:/home/claude/.config" "$capture"
  grep -qx "$HOME/.config/opencode:/home/claude/.config/opencode:ro" "$capture"
  grep -qx "$HOME/.config/nvim:/home/claude/.config/nvim:ro" "$capture"
  [ -d "$CBOX_HOST_CONFIG_DIR/opencode" ]
  run grep -c 'claudebox:/home/claude/.config\|missing\|\.\./x' "$capture"
  [ "$output" = "0" ]
  CBOX_SHARE_CONFIG="claudebox missing ../x" run _cbox_create "cfgbox" "normal"
  [[ "$output" == *"claudebox is cbox's own config"* ]]
  [[ "$output" == *"/missing does not exist"* ]]
  [[ "$output" == *"'../x' is not a folder name"* ]]
}

@test "warden: a folder shared with CBOX_SHARE_CONFIG counts as visible in containers" {
  mkdir -p "$HOME/.config/awsx"
  CBOX_SHARE_CONFIG="awsx" run _cbox_warden_cmd _exposed "$HOME/.config/awsx/config"
  [ "$status" -eq 0 ]
  run _cbox_warden_cmd _exposed "$HOME/.config/awsx/config"
  [ "$status" -ne 0 ]
}

@test "_cbox_create: the git dirs of the mounted Claude and config dirs are read-only" {
  local capture="$BATS_TMPDIR/create-claude-git"
  mkdir -p "$CBOX_CLAUDE_DIR/.git" "$CBOX_HOST_CONFIG_DIR/.git"
  cd "$BATS_TMPDIR"
  _CBOX_CMD=_fake_runtime
  _fake_runtime() { printf '%s\n' "$@" >> "$capture"; }
  rm -f "$capture"; _cbox_create "cgit" "normal"
  grep -qx "$CBOX_CLAUDE_DIR/.git:/home/claude/.claude/.git:ro" "$capture"
  grep -qx "$CBOX_HOST_CONFIG_DIR/.git:/home/claude/.config/.git:ro" "$capture"
  rm -rf "$CBOX_CLAUDE_DIR/.git" "$CBOX_HOST_CONFIG_DIR/.git"
  rm -f "$capture"; _cbox_create "cgit" "normal"
  run grep -c '/.git:/home/claude' "$capture"
  [ "$output" = "0" ]
}

# ---------------------------------------------------------------------------
# Container ~/.claude: own folder by default, seeded from ~/.claude
# ---------------------------------------------------------------------------

@test "claude dir: defaults to claudebox/.claude, not the Mac's ~/.claude" {
  run env -u CBOX_CLAUDE_DIR -u XDG_CONFIG_HOME HOME="$HOME" bash -c 'source "$1"; echo "$CBOX_CLAUDE_DIR"' _ "$CBOX_SH"
  [ "$output" = "$HOME/.config/claudebox/.claude" ]
}

@test "_cbox_create: refuses the Mac's ~/.claude as the container's Claude folder (normal mode)" {
  local capture="$BATS_TMPDIR/create-claude-refused"
  mkdir -p "$HOME/.claude"
  cd "$BATS_TMPDIR"
  _CBOX_CMD=_fake_runtime
  _fake_runtime() { printf '%s\n' "$@" >> "$capture"; }
  for d in "$HOME/.claude" "$HOME"; do
    rm -f "$capture"
    CBOX_CLAUDE_DIR="$d" run _cbox_create "cbclaude" "normal"
    [ "$status" -ne 0 ]
    [[ "$output" == *"CBOX_CLAUDE_DIR=$d would let code in the container change config"* ]]
    [ ! -e "$capture" ]
  done
  rm -f "$capture"
  CBOX_CLAUDE_DIR="$HOME/.claude" run _cbox_create "cbclaude" "safe"
  [ "$status" -eq 0 ]
  rm -rf "$HOME/.claude"
}

@test "_cbox_create: a new Claude folder gets copies of settings and add-ons, not history or links" {
  local capture="$BATS_TMPDIR/create-claude-seed"
  mkdir -p "$HOME/.claude/agents" "$HOME/.claude/projects/p" "$BATS_TMPDIR/dotfiles"
  echo '{"hooks":{}}' > "$HOME/.claude/settings.json"
  echo "rules" > "$BATS_TMPDIR/dotfiles/CLAUDE.md"
  ln -sf "$BATS_TMPDIR/dotfiles/CLAUDE.md" "$HOME/.claude/CLAUDE.md"
  echo "a" > "$HOME/.claude/agents/a.md"
  echo "{}" > "$HOME/.claude/history.jsonl"
  echo "{}" > "$HOME/.claude/projects/p/s.jsonl"
  CBOX_CLAUDE_DIR="$BATS_TMPDIR/new-claude"; rm -rf "$CBOX_CLAUDE_DIR"
  cd "$BATS_TMPDIR"
  _CBOX_CMD=_fake_runtime
  _fake_runtime() { printf '%s\n' "$@" >> "$capture"; }
  rm -f "$capture"
  run _cbox_create "cbseed" "normal"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Claude in containers has its own folder: $CBOX_CLAUDE_DIR"* ]]
  [[ "$output" == *"Copied from $HOME/.claude: CLAUDE.md settings.json agents"* ]]
  [ -f "$CBOX_CLAUDE_DIR/settings.json" ]
  [ -f "$CBOX_CLAUDE_DIR/CLAUDE.md" ]
  [ ! -L "$CBOX_CLAUDE_DIR/CLAUDE.md" ]
  [ -f "$CBOX_CLAUDE_DIR/agents/a.md" ]
  [ ! -e "$CBOX_CLAUDE_DIR/history.jsonl" ]
  [ ! -e "$CBOX_CLAUDE_DIR/projects/p" ]
  # The copied file is not a link, so the dotfiles target is not mounted.
  run grep -c "$BATS_TMPDIR/dotfiles" "$capture"
  [ "$output" = "0" ]
  # Only once.
  run _cbox_create "cbseed" "normal"
  [[ "$output" != *"has its own folder"* ]]
  rm -rf "$HOME/.claude" "$CBOX_CLAUDE_DIR" "$BATS_TMPDIR/dotfiles"
}

@test "_cbox_cdot: cdot syncs the Claude folder containers use" {
  cdot() { echo "dir=$CDOT_CLAUDE_DIR args=$*"; }
  run _cbox_cdot _pull
  [ "$output" = "dir=$CBOX_CLAUDE_DIR args=_pull" ]
}

# ---------------------------------------------------------------------------
# tunnel and warden ssh
# ---------------------------------------------------------------------------

# A public key file with a made-up key (byte $2 repeated); no private key exists.
_fake_pub() {
  python3 -c 'import base64, struct, sys
s = lambda b: struct.pack(">I", len(b)) + b
print("ssh-ed25519 " + base64.b64encode(s(b"ssh-ed25519") + s(bytes([int(sys.argv[1])]) * 32)).decode() + " me@mac")' "$2" > "$1"
}

# Stand-in agent on $1: lists keys 1 and 2, signs anything, accepts extensions,
# and records every request type in $2.
_fake_agent() {
  python3 -c '
import os, socket, struct, sys, threading
s = lambda b: struct.pack(">I", len(b)) + b
key = lambda n: s(b"ssh-ed25519") + s(bytes([n]) * 32)
def serve(c):
    while True:
        h = c.recv(4)
        if len(h) < 4: return
        m = c.recv(struct.unpack(">I", h)[0])
        open(sys.argv[2], "a").write(f"{m[0]}\n")
        if m[0] == 11: r = bytes([12]) + struct.pack(">I", 2) + s(key(1)) + s(b"/Users/me/.ssh/one") + s(key(2)) + s(b"/Users/me/.ssh/two")
        elif m[0] == 13: r = bytes([14]) + s(b"signature")
        else: r = bytes([6])
        c.sendall(struct.pack(">I", len(r)) + r)
srv = socket.socket(socket.AF_UNIX); srv.bind(sys.argv[1]); srv.listen(8)
while True: threading.Thread(target=serve, args=(srv.accept()[0],), daemon=True).start()
' "$1" "$2" </dev/null >/dev/null 2>&1 &
  echo $!
}

_ssh_setup() {
  _warden_setup
  TT="$BATS_TMPDIR/tun"; rm -rf "$TT"; mkdir -p "$TT/keys"
  _fake_pub "$TT/keys/one.pub" 1
  _fake_pub "$TT/keys/two.pub" 2
  cat > "$CBOX_WARDEN_DIR/resources" <<EOF
[gh]
type = ssh
key = $TT/keys/one
hosts = github.com
EOF
}

_ssh_py() {  # runs python with the warden functions loaded
  python3 -c "$(_cbox_warden_py | sed '/^if __name__/,$d')
$1" "${@:2}"
}

@test "warden ssh: a valid ssh resource is listed; broken ones are skipped with a reason" {
  _ssh_setup
  cat >> "$CBOX_WARDEN_DIR/resources" <<EOF
[nopub]
type = ssh
key = $TT/keys/missing
hosts = github.com
[nohosts]
type = ssh
key = $TT/keys/two
[twin]
type = ssh
key = $TT/keys/one
hosts = gitlab.com
[mixed]
type = ssh
key = $TT/keys/two
hosts = github.com
upstream = https://example.com
EOF
  run _cbox_warden_python list "$CBOX_WARDEN_DIR" "$PWD"
  _warden_teardown
  [[ "$output" == *"gh"*"ssh $TT/keys/one → github.com"* ]]
  [[ "$output" == *"'nopub': $TT/keys/missing.pub is missing"* ]]
  [[ "$output" == *"'nohosts': hosts is missing"* ]]
  # Several resources may share a key.
  [[ "$output" == *"twin"*"ssh $TT/keys/one → gitlab.com"* ]]
  [[ "$output" != *"'twin':"* ]]
  [[ "$output" == *"'mixed': upstream is not used by type = ssh"* ]]
}

@test "warden ssh: the filter signs only for servers of granted resources and refuses key management" {
  _ssh_setup
  agent_pid=$(_fake_agent "$TT/agent.sock" "$TT/agent.log")
  for _ in $(seq 50); do [ -S "$TT/agent.sock" ] && break; sleep 0.1; done
  run _ssh_py '
s = lambda b: struct.pack(">I", len(b)) + b
key = lambda n: s(b"ssh-ed25519") + s(bytes([n]) * 32)
granted = {key(1): {key(5): "gh", key(6): "lab"}}  # key 1 for the servers with host keys 5 and 6
def conn():
    ours, theirs = socket.socketpair()
    agent = socket.socket(socket.AF_UNIX); agent.connect(sys.argv[2])
    threading.Thread(target=ssh_filter, args=(sys.argv[1], "box", theirs, agent, granted), daemon=True).start()
    def ask(m):
        ours.sendall(struct.pack(">I", len(m)) + m)
        return ssh_recv(ours)
    return ask
bind = lambda hk: bytes([27]) + s(b"session-bind@openssh.com") + s(hk) + s(b"sid") + s(b"sig") + b"\0"
sign = lambda k: bytes([13]) + s(k) + s(b"data") + struct.pack(">I", 0)
ask = conn()
ids = ask(bytes([11]))
print("list", struct.unpack(">I", ids[1:5])[0], key(1) in ids, key(2) in ids, b"warden:gh+lab" in ids, b"/Users" in ids)
print("sign-unbound", ask(sign(key(1)))[0])
print("bind", ask(bind(key(5)))[0])
print("sign-granted", ask(sign(key(1)))[0])
print("sign-other-key", ask(sign(key(2)))[0])
print("add", ask(bytes([17]) + s(b"ssh-ed25519"))[0])
print("lock", ask(bytes([22]) + s(b"pw"))[0])
print("other-ext", ask(bytes([27]) + s(b"something@else"))[0])
ask = conn()
ask(bind(key(9)))  # a server no granted resource lists
print("sign-other-server", ask(sign(key(1)))[0])
' "$CBOX_WARDEN_DIR" "$TT/agent.sock"
  kill "$agent_pid" 2>/dev/null || true
  reached=$(sort -u "$TT/agent.log" | tr '\n' ' ')
  signs=$(grep -c '^13$' "$TT/agent.log")
  _warden_teardown
  [[ "$output" == *"list 1 True False True False"* ]]
  [[ "$output" == *"sign-unbound 5"* ]]
  [[ "$output" == *"bind 6"* ]]
  [[ "$output" == *"sign-granted 14"* ]]
  [[ "$output" == *"sign-other-key 5"* ]]
  [[ "$output" == *"add 5"* ]]
  [[ "$output" == *"lock 5"* ]]
  [[ "$output" == *"other-ext 5"* ]]
  [[ "$output" == *"sign-other-server 5"* ]]
  # Only list, session-bind and the one allowed signature reached the agent.
  [ "$reached" = "11 13 27 " ]
  [ "$signs" -eq 1 ]
  grep -q "box ssh: signed for 'gh'" "$CBOX_WARDEN_DIR/broker.log"
  grep -q "did not say which server" "$CBOX_WARDEN_DIR/broker.log"
  grep -q "for a server none of its resources lists" "$CBOX_WARDEN_DIR/broker.log"
  grep -q "box ssh: refused agent request type 17" "$CBOX_WARDEN_DIR/broker.log"
}

# Stub OpenSSH: ssh-add -L prints $TT/loaded; ssh-add <args> appends the key's
# .pub to it and records the args; ssh-agent pretends to start.
_ssh_stubs() {
  mkdir -p "$TT/bin"
  cat > "$TT/bin/ssh-add" <<EOF
#!/bin/sh
if [ "\$1" = "-L" ]; then [ -s "$TT/loaded" ] || exit 1; cat "$TT/loaded"; exit 0; fi
echo "\$*" >> "$TT/ssh-add.args"
for last; do :; done
cat "\$last.pub" >> "$TT/loaded"
EOF
  printf '#!/bin/sh\necho "SSH_AGENT_PID=999999; export SSH_AGENT_PID;"\n' > "$TT/bin/ssh-agent"
  chmod +x "$TT/bin/ssh-add" "$TT/bin/ssh-agent"
  export PATH="$TT/bin:$PATH"
  _known_hosts github.com
}

# The Mac's known_hosts with a made-up (public) host key for each name given.
_known_hosts() {
  local key h
  key=$(cut -d' ' -f2 "$TT/keys/two.pub")
  mkdir -p "$HOME/.ssh"
  : > "$HOME/.ssh/known_hosts"
  for h in "$@"; do echo "$h ssh-ed25519 $key" >> "$HOME/.ssh/known_hosts"; done
}

@test "warden ssh: session sets SSH_AUTH_SOCK only once the key is unlocked" {
  _ssh_setup
  _ssh_stubs
  : > "$TT/loaded"
  run _warden_env
  first="$output"
  # Unlocking happens with a terminal: ssh-add -h <host> <key>
  _ssh_py 'ssh_load(sys.argv[1], ["gh"], load_resources(sys.argv[1]), True)' "$CBOX_WARDEN_DIR" 2>/dev/null
  run _warden_env
  second="$output"
  _warden_teardown
  [[ "$first" != *SSH_AUTH_SOCK* ]]
  grep -q "not unlocked yet" "$WT/stderr" || [[ "$first" != *SSH_AUTH_SOCK* ]]
  [ "$(cat "$TT/ssh-add.args")" = "-h github.com $TT/keys/one" ]
  [[ "$second" == *"SSH_AUTH_SOCK=/tmp/cbox-tunnel/ssh-agent.sock"* ]]
}

@test "warden ssh: the broker does not treat an ssh resource as an http route" {
  _ssh_setup
  _ssh_stubs
  _fake_pub "$TT/loaded" 1
  url=$(_warden_url)
  run curl -s "$url/gh/anything"
  _warden_teardown
  [[ "$output" == *"'gh' is not an http resource"* ]]
}

@test "tunnel: carries many connections at once to the host, and grants decide per channel" {
  _ssh_setup
  _ssh_stubs
  _fake_pub "$TT/loaded" 1
  _warden_env >/dev/null   # session file for wbox: gh granted
  mkdir -p "$CBOX_WARDEN_DIR/ssh"
  agent_pid=$(_fake_agent "$CBOX_WARDEN_DIR/ssh/agent.sock" "$TT/agent.log")
  # Echo server standing in for PulseAudio's socket.
  python3 -c '
import socket, sys, threading
def echo(c):
    while (b := c.recv(65536)): c.sendall(b)
    c.close()
srv = socket.socket(socket.AF_UNIX); srv.bind(sys.argv[1]); srv.listen(16)
while True: threading.Thread(target=echo, args=(srv.accept()[0],), daemon=True).start()
' "$TT/pulse" </dev/null >/dev/null 2>&1 &
  echo_pid=$!
  # Fake runtime: `rt exec -i box cmd...` runs cmd here.
  printf '#!/bin/sh\nshift 3\nexec "$@"\n' > "$TT/rt"; chmod +x "$TT/rt"
  _cbox_tunnel_py > "$TT/cbox-tunnel"; chmod +x "$TT/cbox-tunnel"
  export CBOX_TUNNEL_DIR="$TT/sock"
  _cbox_warden_env
  env "${_CBOX_WARDEN_ENV[@]}" CBOX_TUNNEL_DIR="$TT/sock" python3 -c "$(_cbox_warden_py)" tunnel \
    "$CBOX_WARDEN_DIR" "$TT/rt" wbox "$TT/cbox-tunnel" "$TT/tunnel.pid" "$TT/pulse" </dev/null >"$TT/tunnel.log" 2>&1 &
  for _ in $(seq 100); do [ -S "$TT/sock/pulse.sock" ] && [ -S "$TT/sock/ssh-agent.sock" ] && break; sleep 0.1; done
  run python3 -c '
import os, socket, struct, sys, threading
d = sys.argv[1]
results = {}
def one(i):
    data = os.urandom(200000 + i)
    c = socket.socket(socket.AF_UNIX); c.connect(d + "/pulse.sock")
    threading.Thread(target=lambda: (c.sendall(data), c.shutdown(socket.SHUT_WR)), daemon=True).start()
    got = b""
    while (b := c.recv(65536)): got += b
    results[i] = got == data
ts = [threading.Thread(target=one, args=(i,)) for i in range(6)]
[t.start() for t in ts]; [t.join(30) for t in ts]
print("echo", sum(results.values()), "of 6")
c = socket.socket(socket.AF_UNIX); c.connect(d + "/ssh-agent.sock")
c.sendall(struct.pack(">I", 1) + bytes([11]))
h = c.recv(4); ans = c.recv(struct.unpack(">I", h)[0])
print("ssh keys", struct.unpack(">I", ans[1:5])[0], b"warden:gh" in ans)
' "$TT/sock"
  echo_out="$output"
  # Without the grant, the ssh channel closes at once.
  rm -f "$CBOX_WARDEN_DIR/sessions/wbox.json"
  run python3 -c '
import socket, struct, sys
c = socket.socket(socket.AF_UNIX); c.settimeout(10); c.connect(sys.argv[1] + "/ssh-agent.sock")
c.sendall(struct.pack(">I", 1) + bytes([11]))
print("closed" if c.recv(4) == b"" else "answered")
' "$TT/sock"
  nogrant="$output"
  kill -TERM -- "-$(cat "$TT/tunnel.pid")" 2>/dev/null || true
  kill "$agent_pid" "$echo_pid" 2>/dev/null || true
  _warden_teardown
  [ "$echo_out" = "echo 6 of 6
ssh keys 1 True" ] || { cat "$TT/tunnel.log"; false; }
  [ "$nogrant" = "closed" ]
}

@test "_cbox_create: with a warden ssh resource only public SSH files are mounted" {
  local capture="$BATS_TMPDIR/create-ssh-args"
  cd "$BATS_TMPDIR"
  export CBOX_SSH_DIR="$BATS_TMPDIR/dot-ssh"
  mkdir -p "$CBOX_SSH_DIR"
  : > "$CBOX_SSH_DIR/known_hosts"; : > "$CBOX_SSH_DIR/config"; : > "$CBOX_SSH_DIR/work"; : > "$CBOX_SSH_DIR/work.pub"
  _CBOX_CMD=_fake_runtime
  _fake_runtime() { printf '%s\n' "$@" >> "$capture"; }
  mkdir -p "$CBOX_WARDEN_DIR"; rm -f "$CBOX_WARDEN_DIR/resources"
  rm -f "$capture"; _cbox_create "cbox-unit-ssh" "normal"
  before=$(cat "$capture")
  printf '[gh]\ntype = ssh   # agent only\nkey = x\nhosts = github.com\n' > "$CBOX_WARDEN_DIR/resources"
  rm -f "$capture"; _cbox_create "cbox-unit-ssh" "normal"
  after=$(cat "$capture")
  rm -f "$CBOX_WARDEN_DIR/resources"
  [[ "$before" == *"$CBOX_SSH_DIR/work:/home/claude/.ssh/work:ro"* ]]
  [[ "$after" != *"$CBOX_SSH_DIR/work:/home/claude/.ssh/work:ro"* ]]
  [[ "$after" == *"$CBOX_SSH_DIR/work.pub:/home/claude/.ssh/work.pub:ro"* ]]
  [[ "$after" == *"$CBOX_SSH_DIR/config:/home/claude/.ssh/config:ro"* ]]
  [[ "$after" == *"$CBOX_SSH_DIR/known_hosts:/home/claude/.ssh/known_hosts"* ]]
}

# ---------------------------------------------------------------------------
# warden mcp
# ---------------------------------------------------------------------------

_mcp_setup() {
  _warden_setup
  cat >> "$CBOX_WARDEN_DIR/resources" <<INI
[tracker]
type   = mcp
url    = http://127.0.0.1:$UP_PORT/api/mcp?team=x
auth   = bearer
secret = cbox.warden.tracker
[broken]
type = mcp
url  = http://127.0.0.1:$UP_PORT/mcp
auth = bearer
INI
}

@test "warden mcp: the session hands out a warden URL for the server; the token stays on the host" {
  _mcp_setup
  run _warden_env
  env_out="$output"
  base=$(sed -n 's/^WARDEN_URL=//p' <<<"$env_out")
  mcp=$(sed -n 's/^WARDEN_MCP=//p' <<<"$env_out" | base64 -d)
  url=$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["tracker"])' "$mcp")
  post=$(curl -s -H 'Authorization: Bearer fake' -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0"}' "$url")
  other=$(curl -s -o /dev/null -w '%{http_code}' "$base/tracker/admin")
  _warden_teardown
  [ "$url" = "$base/tracker/api/mcp?team=x" ]
  [[ "$post" == *'"path": "/api/mcp?team=x"'* ]]
  [[ "$post" == *'"authorization": "Bearer sk-test-REDACTED-cbox.warden.tracker"'* ]]
  [ "$other" = "403" ]
  grep -q "'broken': secret (Keychain item name) is missing" "$WT/stderr"
}

@test "_cbox_generate_claude_json: warden MCP servers are added as http servers and managed" {
  _cbox_generate_claude_json "mcpapp" "normal" '{"tracker": "http://192.168.64.1:47100/w/tok/tracker/mcp"}'
  run python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["mcpServers"]["tracker"])' "$CBOX_DATA_DIR/.claude-mcpapp.json"
  [[ "$output" == *"'type': 'http'"*"'url': 'http://192.168.64.1:47100/w/tok/tracker/mcp'"* ]]
  # Gone again once warden no longer grants it.
  _cbox_generate_claude_json "mcpapp" "normal"
  run python3 -c 'import json,sys; print(sorted(json.load(open(sys.argv[1])).get("mcpServers", {})))' "$CBOX_DATA_DIR/.claude-mcpapp.json"
  [ "$output" = "[]" ]
}

@test "_cbox_generate_claude_json: warns that headers of a remote MCP server are readable in the container" {
  echo '{"mcpServers": {"remote": {"type": "http", "url": "https://mcp.example.com/mcp", "headers": {"Authorization": "Bearer x"}}}}' > "$CBOX_MCP_CONFIG"
  run _cbox_generate_claude_json "hdrapp" "normal"
  [[ "$output" == *"'remote': its headers are readable inside the container"*"type = mcp"* ]]
}

# ---------------------------------------------------------------------------
# opencode
# ---------------------------------------------------------------------------

@test "opencode config: host servers, warden MCP servers and warden providers, or nothing" {
  rm -f "$CBOX_MCP_CONFIG"
  run python3 -c "$(_cbox_mcp_py)" opencode-config "$CBOX_MCP_CONFIG" /relay "" ""
  [ -z "$output" ]
  echo '{"mcpServers": {"imcp": {"command": "/Applications/iMCP.app/x"}, "open": {"url": "https://mcp.example.com/mcp"}}}' > "$CBOX_MCP_CONFIG"
  run python3 -c "$(_cbox_mcp_py)" opencode-config "$CBOX_MCP_CONFIG" /relay \
    '{"tracker": "http://h/w/t/tracker/mcp"}' '{"openrouter": {"options": {"baseURL": "http://h/w/t/llm", "apiKey": "warden"}}}'
  [ "$status" -eq 0 ]
  run python3 -c 'import json,sys; c=json.loads(sys.argv[1]); print(c["mcp"]["imcp"], c["mcp"]["open"], c["mcp"]["tracker"], c["provider"]["openrouter"]["options"]["baseURL"])' "$output"
  [ "$output" = "{'type': 'local', 'command': ['/relay', 'connect', 'imcp']} {'type': 'remote', 'url': 'https://mcp.example.com/mcp'} {'type': 'remote', 'url': 'http://h/w/t/tracker/mcp'} http://h/w/t/llm" ]
}

@test "warden opencode: a resource with opencode = <provider> routes that provider through warden" {
  _warden_setup
  sed -i 's|^env          = OPENAI_BASE_URL={url} OPENAI_API_KEY=warden|&\nopencode     = openrouter|' "$CBOX_WARDEN_DIR/resources"
  printf '[s3x]\nupstream = http://127.0.0.1:1\nauth = sigv4\nkey-id = a\nsecret = b\nopencode = x\n' >> "$CBOX_WARDEN_DIR/resources"
  run _warden_env
  base=$(sed -n 's/^WARDEN_URL=//p' <<<"$output")
  oc=$(sed -n 's/^WARDEN_OPENCODE=//p' <<<"$output" | base64 -d)
  _warden_teardown
  [ "$oc" = "{\"openrouter\": {\"options\": {\"baseURL\": \"$base/llm\", \"apiKey\": \"warden\"}}}" ]
  grep -q "'s3x': opencode must be the id of an opencode provider" "$WT/stderr"
}

@test "warden ssh: hosts takes names, IPs and host:port; ssh-add gets the known_hosts form" {
  _ssh_setup
  _ssh_stubs
  _known_hosts github.com 203.0.113.5 "[10.30.0.204]:6673" "[2001:db8::1]:2222"
  sed -i 's|^hosts = github.com$|hosts = github.com 203.0.113.5 10.30.0.204:6673 [2001:db8::1]:2222 example.org:22|' "$CBOX_WARDEN_DIR/resources"
  printf '[bad]\ntype = ssh\nkey = %s\nhosts = 10.0.0.1:99999\n' "$TT/keys/two" >> "$CBOX_WARDEN_DIR/resources"
  echo "example.org ssh-ed25519 $(cut -d' ' -f2 "$TT/keys/two.pub")" >> "$HOME/.ssh/known_hosts"
  : > "$TT/loaded"
  _ssh_py 'ssh_load(sys.argv[1], ["gh"], load_resources(sys.argv[1], warn=err), True)' "$CBOX_WARDEN_DIR" 2>"$TT/err"
  _warden_teardown
  [ "$(cat "$TT/ssh-add.args")" = "-h github.com -h 203.0.113.5 -h [10.30.0.204]:6673 -h [2001:db8::1]:2222 -h example.org $TT/keys/one" ]
  grep -q "'bad': host '10.0.0.1:99999' is not a host name, IP address or host:port" "$TT/err"
}

@test "warden ssh: a host the Mac never connected to gets the command to do it, not an ssh-add error" {
  _ssh_setup
  _ssh_stubs
  sed -i 's|^hosts = github.com$|hosts = github.com 10.30.0.204:6673|' "$CBOX_WARDEN_DIR/resources"
  : > "$TT/loaded"
  _ssh_py 'ssh_load(sys.argv[1], ["gh"], load_resources(sys.argv[1]), True)' "$CBOX_WARDEN_DIR" 2>"$TT/err"
  _warden_teardown
  # Unlocked for the hosts the Mac knows; the other one gets the command.
  [ "$(cat "$TT/ssh-add.args")" = "-h github.com $TT/keys/one" ]
  grep -q "never connected to 10.30.0.204:6673" "$TT/err"
  grep -q "ssh -p 6673 <user>@10.30.0.204" "$TT/err"
}

@test "warden ssh: resources sharing a key load it once for all their hosts; grants stay per resource" {
  _ssh_setup
  _ssh_stubs
  _known_hosts github.com gitlab.com
  printf '[lab]\ntype = ssh\nkey = %s\nhosts = gitlab.com\navailability = project\n' "$TT/keys/one" >> "$CBOX_WARDEN_DIR/resources"
  : > "$TT/loaded"
  _ssh_py 'ssh_load(sys.argv[1], ["gh"], load_resources(sys.argv[1]), True)' "$CBOX_WARDEN_DIR" 2>/dev/null
  _ssh_py 'ssh_load(sys.argv[1], ["gh"], load_resources(sys.argv[1]), True)' "$CBOX_WARDEN_DIR" 2>/dev/null
  once=$(cat "$TT/ssh-add.args")
  # A host added later: the key is added again with the new list.
  _known_hosts github.com gitlab.com example.org
  sed -i 's|^hosts = gitlab.com$|hosts = gitlab.com example.org|' "$CBOX_WARDEN_DIR/resources"
  _ssh_py 'ssh_load(sys.argv[1], ["gh"], load_resources(sys.argv[1]), True)' "$CBOX_WARDEN_DIR" 2>/dev/null
  again=$(sed -n 2p "$TT/ssh-add.args")
  _warden_env >/dev/null   # wbox: only the global 'gh' is granted
  _cbox_warden_env
  servers=$(env "${_CBOX_WARDEN_ENV[@]}" python3 -c "$(_cbox_warden_py | sed '/^if __name__/,$d')
print(sorted(set(v for k in ssh_granted(sys.argv[1], 'wbox').values() for v in k.values())), sum(len(k) for k in ssh_granted(sys.argv[1], 'wbox').values()))" "$CBOX_WARDEN_DIR")
  _warden_teardown
  [ "$once" = "-h github.com -h gitlab.com $TT/keys/one" ]
  [ "$again" = "-h github.com -h gitlab.com -h example.org $TT/keys/one" ]
  # wbox may sign with the key only for github.com's host key, as 'gh'.
  [ "$servers" = "['gh'] 1" ]
}

# ---------------------------------------------------------------------------
# container PID 1
# ---------------------------------------------------------------------------

@test "_cbox_create: PID 1 is cbox's init, not tail" {
  local capture="$BATS_TMPDIR/create-init-args"
  rm -f "$capture"
  cd "$BATS_TMPDIR"
  _CBOX_CMD=_fake_runtime
  _fake_runtime() { printf '%s\n' "$@" >> "$capture"; }
  _cbox_create "cbox-unit-init" "normal"
  run cat "$capture"
  [[ "$output" == *"-c"$'\n'"$_CBOX_INIT_SH"$'\n'"sh"$'\n'"import os, signal, time"* ]]
  [[ "$output" != *$'\n'"tail"$'\n'* ]]
}

@test "_CBOX_INIT_SH: runs the init with python3, and tail in images without it" {
  mkdir -p "$BATS_TMPDIR/init-bin"
  printf '#!/bin/sh\necho "python3 $1 $2"\n' > "$BATS_TMPDIR/init-bin/python3"
  chmod +x "$BATS_TMPDIR/init-bin/python3"
  run env PATH="$BATS_TMPDIR/init-bin:/usr/bin:/bin" sh -c "$_CBOX_INIT_SH" sh "CODE"
  [ "$output" = "python3 -c CODE" ]
  mkdir -p "$BATS_TMPDIR/init-nopy"
  ln -sf "$(command -v tail)" "$BATS_TMPDIR/init-nopy/tail"
  run timeout 1 env PATH="$BATS_TMPDIR/init-nopy" /bin/sh -c "$_CBOX_INIT_SH" sh "CODE"
  [ "$status" -eq 124 ]  # tail -f keeps running
}

@test "_cbox_init_py: collects orphaned processes and stops on SIGTERM" {
  # A subreaper stands in for PID 1: orphans of its children come to it.
  run timeout 20 python3 -c '
import ctypes, os, signal, subprocess, sys, time
ctypes.CDLL(None).prctl(36, 1, 0, 0, 0)  # PR_SET_CHILD_SUBREAPER
if os.fork() == 0:
    if os.fork() == 0:
        time.sleep(0.5)
        os._exit(0)  # ends after its parent: an orphan
    os._exit(0)
time.sleep(0.2)
os.waitpid(-1, 0)  # the direct child; the orphan is now ours
pid = os.getpid()
if os.fork() == 0:
    time.sleep(2)
    st = subprocess.run(["ps", "-o", "stat=", "--ppid", str(pid)], capture_output=True, text=True).stdout.split()
    print("zombies", sum(s.startswith("Z") for s in st), flush=True)
    t = time.time(); os.kill(pid, signal.SIGTERM)
    os._exit(0)
os.execvp("python3", ["python3", "-c", sys.argv[1]])
' "$(_cbox_init_py)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"zombies 0"* ]]
}

@test "_cbox_old_init: recognises containers created with tail as PID 1" {
  _CBOX_CMD=_fake_runtime
  _fake_runtime() { echo '[{"configuration": {"initProcess": {"executable": "tail", "arguments": ["-f", "/dev/null"]}}}]'; }
  run _cbox_old_init box
  [ "$status" -eq 0 ]
  _fake_runtime() { echo '[{"configuration": {"initProcess": {"executable": "python3", "arguments": ["-c", "import os"]}}}]'; }
  run _cbox_old_init box
  [ "$status" -ne 0 ]
}

@test "warden: resource names may contain dots, like a host name" {
  _ssh_setup
  printf '[ai.vm]\ntype = ssh\nkey = %s\nhosts = ai.vm\n[.hidden]\ntype = ssh\nkey = %s\nhosts = x\n' "$TT/keys/two" "$TT/keys/two" >> "$CBOX_WARDEN_DIR/resources"
  run _cbox_warden_python list "$CBOX_WARDEN_DIR" "$PWD"
  _warden_teardown
  [[ "$output" == *"ai.vm"*"ssh $TT/keys/two → ai.vm"* ]]
  [[ "$output" == *"'.hidden': name may only contain"* ]]
}
