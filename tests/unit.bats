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

@test "_cbox_generate_claude_json: does not overwrite existing file" {
  local f="$CBOX_DATA_DIR/.claude-stable.json"
  echo "preserved" > "$f"
  _cbox_generate_claude_json "stable"
  run cat "$f"
  [ "$output" = "preserved" ]
}

# ---------------------------------------------------------------------------
# _cbox_project_dir
# ---------------------------------------------------------------------------

@test "_cbox_project_dir: prefixes name with -Workspace-" {
  run _cbox_project_dir "myproject"
  [ "$status" -eq 0 ]
  [ "$output" = "-Workspace-myproject" ]
}

@test "_cbox_project_dir: preserves hyphens in name" {
  run _cbox_project_dir "my-cool-project"
  [ "$status" -eq 0 ]
  [ "$output" = "-Workspace-my-cool-project" ]
}

# ---------------------------------------------------------------------------
# _cbox_history_branch
# ---------------------------------------------------------------------------

@test "_cbox_history_branch: returns history/<name>/<hostname>" {
  run _cbox_history_branch "myproject"
  [ "$status" -eq 0 ]
  [ "$output" = "history/myproject/$(hostname)" ]
}

# ---------------------------------------------------------------------------
# _cbox_sync_is_opted_in
# ---------------------------------------------------------------------------

@test "_cbox_sync_is_opted_in: returns true when project is in list" {
  CBOX_SYNC_PROJECTS="alpha bravo charlie"
  run _cbox_sync_is_opted_in "bravo"
  [ "$status" -eq 0 ]
}

@test "_cbox_sync_is_opted_in: returns false when project is not in list" {
  CBOX_SYNC_PROJECTS="alpha charlie"
  run _cbox_sync_is_opted_in "bravo"
  [ "$status" -ne 0 ]
}

@test "_cbox_sync_is_opted_in: returns false when list is empty" {
  CBOX_SYNC_PROJECTS=""
  run _cbox_sync_is_opted_in "bravo"
  [ "$status" -ne 0 ]
}

@test "_cbox_sync_is_opted_in: does not match partial word" {
  CBOX_SYNC_PROJECTS="foobar"
  run _cbox_sync_is_opted_in "foo"
  [ "$status" -ne 0 ]
}

@test "_cbox_sync_is_opted_in: matches sole entry in list" {
  CBOX_SYNC_PROJECTS="only"
  run _cbox_sync_is_opted_in "only"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# _cbox_sync_register
# ---------------------------------------------------------------------------

@test "_cbox_sync_register add: creates cbox.env when absent" {
  local config="${XDG_CONFIG_HOME:-$HOME/.config}/claudebox/cbox.env"
  rm -f "$config"
  CBOX_SYNC_PROJECTS=""
  _cbox_sync_register "myproject" "add"
  [ -f "$config" ]
}

@test "_cbox_sync_register add: writes project into CBOX_SYNC_PROJECTS" {
  CBOX_SYNC_PROJECTS=""
  _cbox_sync_register "myproject" "add"
  local config="${XDG_CONFIG_HOME:-$HOME/.config}/claudebox/cbox.env"
  run grep "^CBOX_SYNC_PROJECTS=" "$config"
  [ "$status" -eq 0 ]
  [[ "$output" == *"myproject"* ]]
}

@test "_cbox_sync_register add: updates in-memory CBOX_SYNC_PROJECTS" {
  CBOX_SYNC_PROJECTS=""
  _cbox_sync_register "myproject" "add"
  [[ " $CBOX_SYNC_PROJECTS " == *" myproject "* ]]
}

@test "_cbox_sync_register add: is idempotent" {
  CBOX_SYNC_PROJECTS="myproject"
  _cbox_sync_register "myproject" "add"
  local count
  count=$(printf '%s\n' $CBOX_SYNC_PROJECTS | grep -cx "myproject")
  [ "$count" -eq 1 ]
}

@test "_cbox_sync_register add: appends to existing projects" {
  CBOX_SYNC_PROJECTS="alpha"
  _cbox_sync_register "bravo" "add"
  [[ " $CBOX_SYNC_PROJECTS " == *" alpha "* ]]
  [[ " $CBOX_SYNC_PROJECTS " == *" bravo "* ]]
}

@test "_cbox_sync_register add: preserves other lines in cbox.env" {
  local config="${XDG_CONFIG_HOME:-$HOME/.config}/claudebox/cbox.env"
  echo 'CBOX_IMAGE="myimage"' > "$config"
  CBOX_SYNC_PROJECTS=""
  _cbox_sync_register "myproject" "add"
  run grep "^CBOX_IMAGE=" "$config"
  [ "$status" -eq 0 ]
}

@test "_cbox_sync_register remove: removes project from list" {
  CBOX_SYNC_PROJECTS="alpha bravo charlie"
  _cbox_sync_register "bravo" "remove"
  [[ " $CBOX_SYNC_PROJECTS " != *" bravo "* ]]
}

@test "_cbox_sync_register remove: retains other projects" {
  CBOX_SYNC_PROJECTS="alpha bravo charlie"
  _cbox_sync_register "bravo" "remove"
  [[ " $CBOX_SYNC_PROJECTS " == *" alpha "* ]]
  [[ " $CBOX_SYNC_PROJECTS " == *" charlie "* ]]
}

@test "_cbox_sync_register remove: handles removing sole project" {
  CBOX_SYNC_PROJECTS="only"
  _cbox_sync_register "only" "remove"
  [ -z "$CBOX_SYNC_PROJECTS" ]
}

@test "_cbox_sync_register remove: no-op when project not in list" {
  CBOX_SYNC_PROJECTS="alpha charlie"
  _cbox_sync_register "bravo" "remove"
  [[ " $CBOX_SYNC_PROJECTS " == *" alpha "* ]]
  [[ " $CBOX_SYNC_PROJECTS " == *" charlie "* ]]
}

# ---------------------------------------------------------------------------
# _cbox_sync_write_gitignore
# ---------------------------------------------------------------------------

@test "_cbox_sync_write_gitignore: creates gitignore when absent" {
  local dir="$BATS_TMPDIR/gitignore-new"
  mkdir -p "$dir"
  _cbox_sync_write_gitignore "$dir"
  [ -f "$dir/.gitignore" ]
}

@test "_cbox_sync_write_gitignore: gitignore contains wildcard deny-all" {
  local dir="$BATS_TMPDIR/gitignore-content"
  mkdir -p "$dir"
  _cbox_sync_write_gitignore "$dir"
  run grep -q "^\*$" "$dir/.gitignore"
  [ "$status" -eq 0 ]
}

@test "_cbox_sync_write_gitignore: gitignore allows settings.json" {
  local dir="$BATS_TMPDIR/gitignore-allowlist"
  mkdir -p "$dir"
  _cbox_sync_write_gitignore "$dir"
  run grep -q "^!settings.json" "$dir/.gitignore"
  [ "$status" -eq 0 ]
}

@test "_cbox_sync_write_gitignore: gitignore does not allow projects/" {
  local dir="$BATS_TMPDIR/gitignore-no-projects"
  mkdir -p "$dir"
  _cbox_sync_write_gitignore "$dir"
  run grep -q "projects/" "$dir/.gitignore"
  [ "$status" -ne 0 ]
}

@test "_cbox_sync_write_gitignore: skips write when already correct" {
  local dir="$BATS_TMPDIR/gitignore-skip"
  mkdir -p "$dir"
  echo "correct" > "$dir/.gitignore"
  _cbox_sync_write_gitignore "$dir"
  run cat "$dir/.gitignore"
  [ "$output" = "correct" ]
}

@test "_cbox_sync_write_gitignore: overwrites old format containing !projects/" {
  local dir="$BATS_TMPDIR/gitignore-migrate"
  mkdir -p "$dir"
  printf '*\n!projects/\n!projects/**\n' > "$dir/.gitignore"
  _cbox_sync_write_gitignore "$dir"
  run grep -q "^!projects/" "$dir/.gitignore"
  [ "$status" -ne 0 ]
}
