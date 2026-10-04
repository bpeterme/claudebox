#!/usr/bin/env bats

CBOX_SH="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/cbox.sh"

setup() {
  export HOME="$BATS_TMPDIR/home"
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
  printf '#!/bin/bash\n[[ "$1" == exec ]] || exit 1\nshift; [[ "$1" == -i ]] && shift; shift\nexec "$@"\n' > "$RELAY_TMP/rt"
  printf '#!/bin/bash\ncat > /dev/null; sleep 0.3; echo late-reply\n' > "$RELAY_TMP/late"
  chmod +x "$RELAY_TMP/rt" "$RELAY_TMP/late"
  _CBOX_CMD="$RELAY_TMP/rt"
  _CBOX_MCP_RELAY="$RELAY_TMP/bin/cbox-mcp-relay"
  cat > "$CBOX_MCP_CONFIG" <<JSON
{"mcpServers":{"echo":{"command":"cat"},"late":{"command":"$RELAY_TMP/late"},"crash":{"command":"false"}}}
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

@test "mcp relay: forwards server output sent after the client stopped sending" {
  _relay_setup
  run bash -c "echo x | timeout 10 '$_CBOX_MCP_RELAY' connect late"
  _relay_teardown
  [ "$output" = "late-reply" ]
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
# _cbox_audio_ensure_config
# ---------------------------------------------------------------------------

@test "_cbox_audio_ensure_config: creates default.pa with TCP module when absent" {
  export XDG_CONFIG_HOME="$BATS_TMPDIR/xdg-config"
  _cbox_audio_ensure_config
  run grep "module-native-protocol-tcp" "$XDG_CONFIG_HOME/pulse/default.pa"
  [ "$status" -eq 0 ]
  run grep "module-coreaudio" "$XDG_CONFIG_HOME/pulse/default.pa"
  [ "$status" -eq 0 ]
}

@test "_cbox_audio_ensure_config: uses HOMEBREW_PREFIX over global brew paths" {
  export XDG_CONFIG_HOME="$BATS_TMPDIR/xdg-config-hbp"
  local fake_brew="$BATS_TMPDIR/fakebrew"
  mkdir -p "$fake_brew/etc/pulse"
  echo "# custom brew default.pa" > "$fake_brew/etc/pulse/default.pa"
  # Also create a decoy at the standard path to confirm it is not used
  mkdir -p "$BATS_TMPDIR/opt-homebrew/etc/pulse"
  echo "# global brew default.pa" > "$BATS_TMPDIR/opt-homebrew/etc/pulse/default.pa"
  HOMEBREW_PREFIX="$fake_brew" _cbox_audio_ensure_config
  # Generated file must .include the custom brew path
  run grep "$fake_brew" "$XDG_CONFIG_HOME/pulse/default.pa"
  [ "$status" -eq 0 ]
  # The global decoy path must not be referenced
  run grep "opt-homebrew" "$XDG_CONFIG_HOME/pulse/default.pa"
  [ "$status" -ne 0 ]
}

@test "_cbox_audio_ensure_config: appends TCP module to existing default.pa without overwriting" {
  export XDG_CONFIG_HOME="$BATS_TMPDIR/xdg-config2"
  mkdir -p "$XDG_CONFIG_HOME/pulse"
  echo "existing-content" > "$XDG_CONFIG_HOME/pulse/default.pa"
  _cbox_audio_ensure_config
  run grep "existing-content" "$XDG_CONFIG_HOME/pulse/default.pa"
  [ "$status" -eq 0 ]
  run grep "module-native-protocol-tcp" "$XDG_CONFIG_HOME/pulse/default.pa"
  [ "$status" -eq 0 ]
  run grep "module-coreaudio" "$XDG_CONFIG_HOME/pulse/default.pa"
  [ "$status" -eq 0 ]
}

@test "_cbox_audio_ensure_config: does not duplicate TCP module if already present" {
  export XDG_CONFIG_HOME="$BATS_TMPDIR/xdg-config3"
  mkdir -p "$XDG_CONFIG_HOME/pulse"
  echo "load-module module-native-protocol-tcp" > "$XDG_CONFIG_HOME/pulse/default.pa"
  _cbox_audio_ensure_config
  run grep -c "module-native-protocol-tcp" "$XDG_CONFIG_HOME/pulse/default.pa"
  [ "$output" -eq 1 ]
  run grep "module-coreaudio" "$XDG_CONFIG_HOME/pulse/default.pa"
  [ "$status" -eq 0 ]
}

@test "_cbox_audio_ensure_config: does not add coreaudio if .include already present" {
  export XDG_CONFIG_HOME="$BATS_TMPDIR/xdg-config5"
  mkdir -p "$XDG_CONFIG_HOME/pulse"
  printf ".include /opt/homebrew/etc/pulse/default.pa\nload-module module-native-protocol-tcp\n" \
    > "$XDG_CONFIG_HOME/pulse/default.pa"
  _cbox_audio_ensure_config
  run grep -c "module-coreaudio" "$XDG_CONFIG_HOME/pulse/default.pa"
  [ "$output" -eq 0 ]
}

@test "_cbox_audio_ensure_config: adds exit-idle-time to daemon.conf" {
  export XDG_CONFIG_HOME="$BATS_TMPDIR/xdg-config4"
  _cbox_audio_ensure_config
  run grep "exit-idle-time" "$XDG_CONFIG_HOME/pulse/daemon.conf"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# _cbox_audio_pulse_server
# ---------------------------------------------------------------------------

@test "_cbox_audio_pulse_server: returns apple gateway for apple runtime" {
  _CBOX_RUNTIME="apple"
  run _cbox_audio_pulse_server
  [ "$status" -eq 0 ]
  [ "$output" = "tcp:192.168.64.1:4713" ]
}

@test "_cbox_audio_pulse_server: returns docker hostname for docker runtime" {
  _CBOX_RUNTIME="docker"
  run _cbox_audio_pulse_server
  [ "$status" -eq 0 ]
  [ "$output" = "tcp:host.docker.internal:4713" ]
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
# _cbox_flux_push
# ---------------------------------------------------------------------------

@test "_cbox_flux_push: non-verbose, success stays silent" {
  unset CBOX_VERBOSE
  flux() { return 0; }
  run _cbox_flux_push
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_cbox_flux_push: non-verbose, failure is always surfaced" {
  unset CBOX_VERBOSE
  flux() { echo "dvc push: access denied" >&2; return 1; }
  run _cbox_flux_push
  [ "$status" -eq 0 ]
  [[ "$output" == *"⚠  flux push failed:"* ]]
  [[ "$output" == *"dvc push: access denied"* ]]
}

@test "_cbox_flux_push: verbose, failure is shown and does not abort the caller" {
  CBOX_VERBOSE=1
  flux() { echo "dvc push: access denied" >&2; return 1; }
  run _cbox_flux_push
  [ "$status" -eq 0 ]
  [[ "$output" == *"dvc push: access denied"* ]]
}

@test "_cbox_flux_push: verbose, success output is shown" {
  CBOX_VERBOSE=1
  flux() { echo "Pushed to Git remote."; return 0; }
  run _cbox_flux_push
  [ "$status" -eq 0 ]
  [[ "$output" == *"Pushed to Git remote."* ]]
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
