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
