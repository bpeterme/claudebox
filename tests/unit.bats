#!/usr/bin/env bats

CBOX_SH="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/cbox.sh"

setup() {
  export HOME="$BATS_TMPDIR/home"
  mkdir -p "$HOME/.config/claudebox"
  export CBOX_DATA_DIR="$BATS_TMPDIR/cbox-data"
  export CBOX_CLAUDE_DIR="$BATS_TMPDIR/claude"
  export CBOX_HOST_CONFIG_DIR="$BATS_TMPDIR/config"
  export CBOX_SHARE_DIR="$BATS_TMPDIR/share"
  mkdir -p "$CBOX_DATA_DIR" "$CBOX_CLAUDE_DIR" "$CBOX_HOST_CONFIG_DIR" "$CBOX_SHARE_DIR"
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

@test "_cbox_generate_claude_json: merges mcpServers from host on re-run" {
  local f="$CBOX_DATA_DIR/.claude-myapp.json"
  echo '{"oauthToken":"tok_abc"}' > "$f"
  echo '{"mcpServers":{"mytool":{"command":"npx","args":["mytool-mcp"]}}}' > "$HOME/.claude.json"
  _cbox_generate_claude_json "myapp"
  run python3 -c "import json,sys; d=json.load(open('$f')); sys.exit(0 if 'mytool' in d.get('mcpServers',{}) else 1)"
  [ "$status" -eq 0 ]
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
