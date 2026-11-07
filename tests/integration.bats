#!/usr/bin/env bats
# Requires Docker. Each test creates a container named TEST_NAME and teardown removes it.

CBOX_SH="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/cbox.sh"
TEST_NAME="cbox-test-$$"

setup() {
  export HOME="$BATS_TMPDIR/home"
  mkdir -p "$HOME/.config/claudebox"
  export CBOX_IMAGE="alpine"
  export CBOX_DATA_DIR="$BATS_TMPDIR/cbox-data"
  export CBOX_CLAUDE_DIR="$BATS_TMPDIR/claude"
  export CBOX_HOST_CONFIG_DIR="$BATS_TMPDIR/config"
  export CBOX_SHARE_DIR="$BATS_TMPDIR/share"
  export CBOX_PLAYWRIGHT_DIR="$BATS_TMPDIR/ms-playwright"
  mkdir -p "$CBOX_DATA_DIR" "$CBOX_CLAUDE_DIR/projects" "$CBOX_HOST_CONFIG_DIR" "$CBOX_SHARE_DIR"
  export TEST_WORKDIR="$BATS_TMPDIR/workdir"
  mkdir -p "$TEST_WORKDIR"
  # shellcheck source=/dev/null
  source "$CBOX_SH"
  cd "$TEST_WORKDIR"
}

teardown() {
  _cbox_tunnel_stop "$TEST_NAME" 2>/dev/null || true
  docker rm -f "$TEST_NAME" 2>/dev/null || true
  # $BATS_TMPDIR/claude is shared with unit.bats: drop the symlinks the
  # tests above create there, or later runs trip over them.
  find "$CBOX_CLAUDE_DIR" -maxdepth 2 -type l -delete 2>/dev/null || true
}

_mounts() {
  docker inspect --format \
    '{{range .Mounts}}{{printf "%s:%s\n" .Source .Destination}}{{end}}' \
    "$TEST_NAME"
}

# Same as _mounts but appends the writability flag, as "<source>:<dest>:<rw>".
_mounts_rw() {
  docker inspect --format \
    '{{range .Mounts}}{{printf "%s:%s:%v\n" .Source .Destination .RW}}{{end}}' \
    "$TEST_NAME"
}

# ---------------------------------------------------------------------------
# container lifecycle
# ---------------------------------------------------------------------------

@test "normal container is created and running" {
  _cbox_create "$TEST_NAME" "normal"
  run docker inspect --format '{{.State.Status}}' "$TEST_NAME"
  [ "$status" -eq 0 ]
  [ "$output" = "running" ]
}

@test "PID 1 is the runtime's init: orphans are collected, stop is immediate" {
  _cbox_create "$TEST_NAME" "normal"
  run docker inspect --format '{{.HostConfig.Init}}' "$TEST_NAME"
  [ "$output" = "true" ]
  # A background process whose parent exits is handed to PID 1.
  docker exec "$TEST_NAME" sh -c 'sh -c "sleep 1 &"; exit 0'
  sleep 3
  run docker exec "$TEST_NAME" sh -c 'grep -l "^State:.*Z" /proc/[0-9]*/status 2>/dev/null | wc -l'
  [ "$output" -eq 0 ]
  # SIGTERM reaches the command at once: no wait for the 10 s kill timeout.
  local t0=$SECONDS
  docker stop "$TEST_NAME" >/dev/null
  (( SECONDS - t0 < 5 ))
}

# ---------------------------------------------------------------------------
# mounts — normal mode
# ---------------------------------------------------------------------------

@test "workspace is mounted at /Workspace/NAME" {
  _cbox_create "$TEST_NAME" "normal"
  run _mounts
  [[ "$output" == *"$TEST_WORKDIR:/Workspace/$TEST_NAME"* ]]
}

@test ".claude dir is mounted at /home/claude/.claude" {
  _cbox_create "$TEST_NAME" "normal"
  run _mounts
  [[ "$output" == *"$CBOX_CLAUDE_DIR:/home/claude/.claude"* ]]
}

@test ".claude.json is mounted at /home/claude/.claude.json" {
  _cbox_create "$TEST_NAME" "normal"
  local expected="$CBOX_DATA_DIR/.claude-$TEST_NAME.json"
  run _mounts
  [[ "$output" == *"$expected:/home/claude/.claude.json"* ]]
}

# ---------------------------------------------------------------------------
# playwright browser cache
# ---------------------------------------------------------------------------

@test "playwright cache is created on the host and mounted at /opt/ms-playwright" {
  rm -rf "$CBOX_PLAYWRIGHT_DIR"
  _cbox_create "$TEST_NAME" "normal"
  [ -d "$CBOX_PLAYWRIGHT_DIR" ]
  run _mounts
  [[ "$output" == *"$CBOX_PLAYWRIGHT_DIR:/opt/ms-playwright"* ]]
}

@test "playwright cache is writable in normal mode" {
  _cbox_create "$TEST_NAME" "normal"
  run _mounts_rw
  [[ "$output" == *"$CBOX_PLAYWRIGHT_DIR:/opt/ms-playwright:true"* ]]
}

@test "playwright cache written inside the container lands on the host" {
  rm -rf "$CBOX_PLAYWRIGHT_DIR"
  _cbox_create "$TEST_NAME" "normal"
  docker exec "$TEST_NAME" sh -c 'echo ok > /opt/ms-playwright/chromium-test'
  [ -f "$CBOX_PLAYWRIGHT_DIR/chromium-test" ]
}

# ---------------------------------------------------------------------------
# symlink target mounts
# ---------------------------------------------------------------------------

@test "symlink target outside CBOX_CLAUDE_DIR is mounted at its own path" {
  local target_dir="$BATS_TMPDIR/dotfiles"
  mkdir -p "$target_dir"
  echo "{}" > "$target_dir/settings.json"
  ln -sf "$target_dir/settings.json" "$CBOX_CLAUDE_DIR/settings.json"

  _cbox_create "$TEST_NAME" "normal"
  run _mounts
  [[ "$output" == *"$target_dir/settings.json:$target_dir/settings.json"* ]]
}

@test "symlink target one level deep (e.g. output-styles/foo.md) is mounted at its own path" {
  local target_dir="$BATS_TMPDIR/dotfiles"
  mkdir -p "$target_dir" "$CBOX_CLAUDE_DIR/output-styles"
  echo "# ELI5" > "$target_dir/ELI5.md"
  ln -sf "$target_dir/ELI5.md" "$CBOX_CLAUDE_DIR/output-styles/ELI5.md"

  _cbox_create "$TEST_NAME" "normal"
  run _mounts
  [[ "$output" == *"$target_dir/ELI5.md:$target_dir/ELI5.md"* ]]
}

@test "directory symlink (e.g. output-styles -> dotfiles dir) is mounted as a directory" {
  local target_dir="$BATS_TMPDIR/dotfiles/output-styles"
  mkdir -p "$target_dir"
  echo "# ELI5" > "$target_dir/ELI5.md"
  rm -rf "$CBOX_CLAUDE_DIR/output-styles"
  ln -s "$target_dir" "$CBOX_CLAUDE_DIR/output-styles"

  _cbox_create "$TEST_NAME" "normal"
  run _mounts
  [[ "$output" == *"$target_dir:$target_dir"* ]]

  # Files added after container creation must be visible without a recreate
  echo "# New" > "$target_dir/New.md"
  run docker exec "$TEST_NAME" cat "$target_dir/New.md"
  [ "$status" -eq 0 ]
  [ "$output" = "# New" ]
}

@test "symlink target inside workspace is not double-mounted" {
  local inner="$TEST_WORKDIR/inner"
  mkdir -p "$inner"
  echo "{}" > "$inner/config.json"
  ln -sf "$inner/config.json" "$CBOX_CLAUDE_DIR/config.json"

  _cbox_create "$TEST_NAME" "normal"
  run _mounts
  # The inner path should not appear as a standalone mount source
  local count
  count=$(echo "$output" | grep -c "^$inner/config.json:" || true)
  [ "$count" -eq 0 ]
}

# ---------------------------------------------------------------------------
# auth persistence
# ---------------------------------------------------------------------------

@test ".claude.json preserves auth tokens across re-runs" {
  local f="$CBOX_DATA_DIR/.claude-$TEST_NAME.json"
  echo '{"oauthToken":"tok_abc","projects":{}}' > "$f"
  _cbox_generate_claude_json "$TEST_NAME"
  run python3 -c "import json,sys; d=json.load(open('$f')); sys.exit(0 if d.get('oauthToken')=='tok_abc' else 1)"
  [ "$status" -eq 0 ]
}

# ---------------------------------------------------------------------------
# safe mode — outbound traffic
# ---------------------------------------------------------------------------

# Fetches a URL in the container with Python (the tunnel needs python3 anyway)
# and prints the HTTP status, or the error.
_fetch() {
  docker exec "${@:2}" "$TEST_NAME" python3 -c '
import sys, urllib.request, urllib.error
try:
    print(urllib.request.urlopen(sys.argv[1], timeout=20).status)
except urllib.error.HTTPError as e:
    print(e.code)
except Exception as e:
    print(type(e).__name__, e)
' "$1"
}

@test "safe container reaches only allowed hosts, and only through the egress proxy" {
  export CBOX_IMAGE="python:3.12-alpine"
  _cbox_create "$TEST_NAME" "safe"
  # No network of its own.
  run _fetch "https://pypi.org/simple/"
  [[ "$output" != "200" ]]
  _cbox_tunnel_start "$TEST_NAME" on
  local proxy="http://127.0.0.1:$_CBOX_EGRESS_PORT"
  for _ in $(seq 50); do
    docker exec "$TEST_NAME" python3 -c "import socket; socket.create_connection(('127.0.0.1', $_CBOX_EGRESS_PORT), 1)" \
      2>/dev/null && break
    sleep 0.2
  done
  run _fetch "https://pypi.org/simple/" -e "HTTPS_PROXY=$proxy"
  [ "$output" = "200" ]
  run _fetch "https://example.com/" -e "HTTPS_PROXY=$proxy"
  [[ "$output" == *"403"* ]]
  grep -q "egress: blocked example.com:443" "$CBOX_DATA_DIR/.tunnel-$TEST_NAME.log"
}

# ---------------------------------------------------------------------------
# masking — secret files the agent sees empty
# ---------------------------------------------------------------------------

@test "masked files read empty and cannot be written; masked folders are empty" {
  mkdir -p secrets
  echo "TOKEN=s3cret" > .env
  echo "key" > secrets/k
  echo "visible" > .env.example
  CBOX_MASK=".env .env.* !.env.example secrets/" _cbox_create "$TEST_NAME" "normal"
  run docker exec "$TEST_NAME" cat "/Workspace/$TEST_NAME/.env"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run docker exec "$TEST_NAME" ls -A "/Workspace/$TEST_NAME/secrets"
  [ -z "$output" ]
  run docker exec "$TEST_NAME" sh -c "echo x > /Workspace/$TEST_NAME/.env"
  [ "$status" -ne 0 ]
  run docker exec "$TEST_NAME" cat "/Workspace/$TEST_NAME/.env.example"
  [ "$output" = "visible" ]
  # the files on the host are untouched
  [ "$(cat .env)" = "TOKEN=s3cret" ]
  rm -rf secrets .env .env.example
}
