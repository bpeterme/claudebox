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

@test "_cbox_history_branch: returns history/<name>/<user>@<host>" {
  run _cbox_history_branch "myproject"
  [ "$status" -eq 0 ]
  [ "$output" = "history/myproject/${USER}@$(hostname -s)" ]
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

# ---------------------------------------------------------------------------
# _cbox_sync_exclude_symlinks
# ---------------------------------------------------------------------------

@test "_cbox_sync_exclude_symlinks: no-op when .git does not exist" {
  CBOX_CLAUDE_DIR="$BATS_TMPDIR/excl-no-git"
  mkdir -p "$CBOX_CLAUDE_DIR"
  run _cbox_sync_exclude_symlinks
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "_cbox_sync_exclude_symlinks: adds symlink path to .git/info/exclude" {
  CBOX_CLAUDE_DIR="$BATS_TMPDIR/excl-add"
  mkdir -p "$CBOX_CLAUDE_DIR"
  git -C "$CBOX_CLAUDE_DIR" init 2>/dev/null
  local target="$BATS_TMPDIR/real-settings.json"
  echo '{}' > "$target"
  ln -sf "$target" "$CBOX_CLAUDE_DIR/settings.json"
  _cbox_sync_exclude_symlinks
  run grep -Fx "settings.json" "$CBOX_CLAUDE_DIR/.git/info/exclude"
  [ "$status" -eq 0 ]
}

@test "_cbox_sync_exclude_symlinks: does not duplicate entry in exclude" {
  CBOX_CLAUDE_DIR="$BATS_TMPDIR/excl-dedup"
  mkdir -p "$CBOX_CLAUDE_DIR"
  git -C "$CBOX_CLAUDE_DIR" init 2>/dev/null
  local target="$BATS_TMPDIR/real-settings-dedup.json"
  echo '{}' > "$target"
  ln -sf "$target" "$CBOX_CLAUDE_DIR/settings.json"
  _cbox_sync_exclude_symlinks
  _cbox_sync_exclude_symlinks
  run bash -c "grep -Fc 'settings.json' '$CBOX_CLAUDE_DIR/.git/info/exclude'"
  [ "$output" -eq 1 ]
}

@test "_cbox_sync_exclude_symlinks: untracks a previously tracked symlink" {
  CBOX_CLAUDE_DIR="$BATS_TMPDIR/excl-untrack"
  mkdir -p "$CBOX_CLAUDE_DIR"
  git -C "$CBOX_CLAUDE_DIR" init 2>/dev/null
  git -C "$CBOX_CLAUDE_DIR" config user.email "test@test.com"
  git -C "$CBOX_CLAUDE_DIR" config user.name "Test"
  local target="$BATS_TMPDIR/real-settings-untrack.json"
  echo '{}' > "$target"
  ln -sf "$target" "$CBOX_CLAUDE_DIR/settings.json"
  git -C "$CBOX_CLAUDE_DIR" add -f settings.json
  _cbox_sync_exclude_symlinks
  run git -C "$CBOX_CLAUDE_DIR" ls-files "settings.json"
  [ -z "$output" ]
}

@test "_cbox_sync_exclude_symlinks: warns about broken symlinks" {
  CBOX_CLAUDE_DIR="$BATS_TMPDIR/excl-broken"
  mkdir -p "$CBOX_CLAUDE_DIR"
  git -C "$CBOX_CLAUDE_DIR" init 2>/dev/null
  ln -sf "/nonexistent/path/settings.json" "$CBOX_CLAUDE_DIR/settings.json"
  run _cbox_sync_exclude_symlinks
  [[ "$output" == *"Broken symlink"* ]]
}

@test "_cbox_sync_exclude_symlinks: no output for valid symlinks" {
  CBOX_CLAUDE_DIR="$BATS_TMPDIR/excl-valid"
  mkdir -p "$CBOX_CLAUDE_DIR"
  git -C "$CBOX_CLAUDE_DIR" init 2>/dev/null
  local target="$BATS_TMPDIR/real-settings-valid.json"
  echo '{}' > "$target"
  ln -sf "$target" "$CBOX_CLAUDE_DIR/settings.json"
  run _cbox_sync_exclude_symlinks
  [ -z "$output" ]
}

# ---------------------------------------------------------------------------
# _cbox_sync_unlink
# ---------------------------------------------------------------------------

@test "_cbox_sync_unlink: reports not initialized when .git absent" {
  CBOX_CLAUDE_DIR="$BATS_TMPDIR/unlink-no-git"
  mkdir -p "$CBOX_CLAUDE_DIR"
  run _cbox_sync_unlink --force
  [ "$status" -eq 0 ]
  [[ "$output" == *"not initialized"* ]]
}

@test "_cbox_sync_unlink --force: removes .git directory" {
  CBOX_CLAUDE_DIR="$BATS_TMPDIR/unlink-git"
  mkdir -p "$CBOX_CLAUDE_DIR"
  git -C "$CBOX_CLAUDE_DIR" init 2>/dev/null
  _cbox_sync_unlink --force
  [ ! -d "$CBOX_CLAUDE_DIR/.git" ]
}

@test "_cbox_sync_unlink --force: removes .gitignore" {
  CBOX_CLAUDE_DIR="$BATS_TMPDIR/unlink-gitignore"
  mkdir -p "$CBOX_CLAUDE_DIR"
  git -C "$CBOX_CLAUDE_DIR" init 2>/dev/null
  echo "*" > "$CBOX_CLAUDE_DIR/.gitignore"
  _cbox_sync_unlink --force
  [ ! -f "$CBOX_CLAUDE_DIR/.gitignore" ]
}

@test "_cbox_sync_unlink --force: clears CBOX_SYNC_PROJECTS from cbox.env" {
  CBOX_CLAUDE_DIR="$BATS_TMPDIR/unlink-env"
  mkdir -p "$CBOX_CLAUDE_DIR"
  git -C "$CBOX_CLAUDE_DIR" init 2>/dev/null
  local config="${XDG_CONFIG_HOME:-$HOME/.config}/claudebox/cbox.env"
  mkdir -p "$(dirname "$config")"
  echo 'CBOX_SYNC_PROJECTS="alpha bravo"' > "$config"
  CBOX_SYNC_PROJECTS="alpha bravo"
  _cbox_sync_unlink --force
  run grep "^CBOX_SYNC_PROJECTS=" "$config"
  [ "$status" -ne 0 ]
}

@test "_cbox_sync_unlink --force: clears CBOX_SYNC_PROJECTS in memory" {
  CBOX_CLAUDE_DIR="$BATS_TMPDIR/unlink-mem"
  mkdir -p "$CBOX_CLAUDE_DIR"
  git -C "$CBOX_CLAUDE_DIR" init 2>/dev/null
  CBOX_SYNC_PROJECTS="alpha bravo"
  _cbox_sync_unlink --force
  [ -z "$CBOX_SYNC_PROJECTS" ]
}

@test "_cbox_sync_unlink: aborts without removing .git when user declines" {
  CBOX_CLAUDE_DIR="$BATS_TMPDIR/unlink-abort"
  mkdir -p "$CBOX_CLAUDE_DIR"
  git -C "$CBOX_CLAUDE_DIR" init 2>/dev/null
  printf "n\n" | _cbox_sync_unlink >/dev/null 2>&1 || true
  [ -d "$CBOX_CLAUDE_DIR/.git" ]
}

# ---------------------------------------------------------------------------
# _cbox_sync_add guard conditions
# ---------------------------------------------------------------------------

@test "_cbox_sync_add: reports not initialized when .git absent" {
  CBOX_CLAUDE_DIR="$BATS_TMPDIR/add-no-git"
  mkdir -p "$CBOX_CLAUDE_DIR"
  run _cbox_sync_add "myproject"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not initialized"* ]]
}

@test "_cbox_sync_add: reports already opted in when project is in list" {
  CBOX_CLAUDE_DIR="$BATS_TMPDIR/add-opted-in"
  mkdir -p "$CBOX_CLAUDE_DIR"
  git -C "$CBOX_CLAUDE_DIR" init 2>/dev/null
  CBOX_SYNC_PROJECTS="myproject"
  run _cbox_sync_add "myproject"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already opted into"* ]]
}

# ---------------------------------------------------------------------------
# _cbox_sync_remove guard conditions
# ---------------------------------------------------------------------------

@test "_cbox_sync_remove: reports not initialized when .git absent" {
  CBOX_CLAUDE_DIR="$BATS_TMPDIR/remove-no-git"
  mkdir -p "$CBOX_CLAUDE_DIR"
  run _cbox_sync_remove "myproject"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not initialized"* ]]
}

@test "_cbox_sync_remove: reports not opted in when project not in list" {
  CBOX_CLAUDE_DIR="$BATS_TMPDIR/remove-not-opted"
  mkdir -p "$CBOX_CLAUDE_DIR"
  git -C "$CBOX_CLAUDE_DIR" init 2>/dev/null
  CBOX_SYNC_PROJECTS=""
  run _cbox_sync_remove "myproject"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not opted into history sync"* ]]
}

# ---------------------------------------------------------------------------
# _cbox_sync_compact guard conditions
# ---------------------------------------------------------------------------

@test "_cbox_sync_compact: reports not initialized when .git absent" {
  CBOX_CLAUDE_DIR="$BATS_TMPDIR/compact-no-git"
  mkdir -p "$CBOX_CLAUDE_DIR"
  run _cbox_sync_compact "myproject"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not initialized"* ]]
}

@test "_cbox_sync_compact: reports not opted in when project not in list" {
  CBOX_CLAUDE_DIR="$BATS_TMPDIR/compact-not-opted"
  mkdir -p "$CBOX_CLAUDE_DIR"
  git -C "$CBOX_CLAUDE_DIR" init 2>/dev/null
  CBOX_SYNC_PROJECTS=""
  run _cbox_sync_compact "myproject"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not opted into history sync"* ]]
}
