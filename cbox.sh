#!/bin/bash
# shellcheck shell=bash

# claudebox (cbox) - Claude Container Runtime
# Source this file in .bashrc or .zshrc:
#   source /path/to/claudebox/cbox.sh
#
# Configure by creating ~/.config/claudebox/cbox.env (see cbox.env.example)

# =========================================================
# cbox - Claude Container Runtime
# =========================================================

# ---------------------------------------------------------
# help
# ---------------------------------------------------------

_cbox_help() {
    cat <<'EOF'
cbox - Claude Container Runtime

Usage:
  cbox                  Start or enter normal container
  cbox safe             Start or enter safe container
  cbox shell            Open zsh shell instead of the container
  cbox keepalive        Keep container alive for 10 minutes after exit

Container Management:
  cbox stop             Stop current project container
  cbox reset            Remove current project container
  cbox rebuild          Rebuild container image
  cbox gc               Remove stopped cbox containers

Sync (cross-machine):
  cbox sync-init <url>  Initialize project history sync with a git remote
  cbox sync             Pull and push project history manually

Maintenance:
  cbox update           Force Claude Code update
  cbox doctor           Run environment diagnostics
  cbox list             List cbox containers

Help:
  cbox help
  cbox --help
  cbox -h
EOF
}

# ---------------------------------------------------------
# config
# ---------------------------------------------------------

CBOX_IMAGE="${CBOX_IMAGE:-claudebox}"
CBOX_LABEL="${CBOX_LABEL:-cbox.project=true}"
CBOX_KEEPALIVE_SECONDS="${CBOX_KEEPALIVE_SECONDS:-600}"

# Source user config if present (~/.config/claudebox/cbox.env)
_CBOX_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/claudebox/cbox.env"
[[ -f "$_CBOX_CONFIG" ]] && . "$_CBOX_CONFIG"
unset _CBOX_CONFIG

CBOX_DATA_DIR="${CBOX_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/cbox}"
CBOX_CLAUDE_DIR="${CBOX_CLAUDE_DIR:-$HOME/.claude}"
CBOX_HOST_CONFIG_DIR="${CBOX_HOST_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}}"
CBOX_SHARE_DIR="${CBOX_SHARE_DIR:-/tmp/cbox-$(id -un)}"
# CBOX_SSH_DIR  — path to SSH dir to mount; unset = no SSH mount
# CBOX_ZSHRC    — path to a .zshrc to source inside container; unset = none
_CBOX_BUILD_DIR="${CBOX_BUILD_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

if [[ "$(uname)" == "Darwin" ]]; then
  _CBOX_CMD="container"
  _CBOX_RUNTIME="apple"
else
  _CBOX_CMD="docker"
  _CBOX_RUNTIME="docker"
fi

# ---------------------------------------------------------
# helpers
# ---------------------------------------------------------

_cbox_name() {
  local name
  name=$(basename "$PWD" \
    | tr -cs '[:alnum:]' '-' \
    | sed 's/^-*//;s/-*$//')

  echo "${name:-project}"
}

# Returns "NAME STATE" pairs (no header) with optional extra args passed through.
# Normalises Apple Container tabular output and Docker --format output to the same shape.
_cbox_rt_list() {
  if [[ "$_CBOX_RUNTIME" == "apple" ]]; then
    container list --all "$@" | awk 'NR>1 {print $1, $4}'
  else
    docker ps -a "$@" --format "{{.Names}} {{.State}}"
  fi
}

_cbox_rt_image_list() {
  if [[ "$_CBOX_RUNTIME" == "apple" ]]; then
    container image list
  else
    docker image ls
  fi
}

_cbox_rt_label() {
  local name="$1" label="$2"
  if [[ "$_CBOX_RUNTIME" == "apple" ]]; then
    container inspect "$name" 2>/dev/null \
      | jq -r ".[0].configuration.labels[\"$label\"]"
  else
    docker inspect "$name" 2>/dev/null \
      | jq -r ".[0].Config.Labels[\"$label\"]"
  fi
}

_cbox_exists() {
  local name="$1"

  _cbox_rt_list \
    | awk '{print $1}' \
    | grep -qx "$name"
}

_cbox_running() {
  local name="$1"

  local state
  state=$(_cbox_rt_list \
    | awk -v n="$name" '$1==n {print $2}')

  [[ "$state" == "running" ]]
}

_cbox_mode() {
  local name="$1"

  _cbox_rt_label "$name" "cbox.mode"
}

_cbox_generate_claude_json() {
  local name="$1"

  mkdir -p "$CBOX_DATA_DIR"

  local claude_json="$CBOX_DATA_DIR/.claude-$name.json"

  echo "{\"hasCompletedOnboarding\":true,\"installMethod\":\"native\",\"projects\":{\"/Workspace/$name\":{\"hasTrustDialogAccepted\":true}}}" \
    > "$claude_json"
}

_cbox_maybe_update() {
  local name="$1"

  local stamp="/tmp/.cbox-update-$(date +%Y-%m-%d)"

  if [[ ! -f "$stamp" ]]; then
    echo "Updating Claude Code..."

    $_CBOX_CMD exec --user root "$name" \
      npm update -g --no-fund @anthropic-ai/claude-code

    touch "$stamp"
  fi
}

_cbox_force_update() {
  local name="$1"

  _cbox_ensure "$name" "normal"

  echo "Updating Claude Code..."

  $_CBOX_CMD exec --user root "$name" \
    npm update -g --no-fund @anthropic-ai/claude-code
}

_cbox_create_network() {
  $_CBOX_CMD network create cbox-bridge >/dev/null 2>&1 || true
}

# ---------------------------------------------------------
# sync
# ---------------------------------------------------------

_cbox_sync_pull() {
  local dir="$CBOX_CLAUDE_DIR"
  [[ -d "$dir/.git" ]] || return 0
  command -v git >/dev/null || return 0

  # Only pull if a tracking branch is configured
  git -C "$dir" rev-parse --abbrev-ref --symbolic-full-name @{u} >/dev/null 2>&1 || return 0

  echo "Pulling Claude config..."
  git -C "$dir" pull --rebase 2>&1 \
    || echo "⚠  Sync pull failed — continuing with local state"
}

_cbox_sync_push() {
  local dir="$CBOX_CLAUDE_DIR"
  [[ -d "$dir/.git" ]] || return 0
  command -v git >/dev/null || return 0

  # Only push if a remote is configured
  git -C "$dir" remote get-url origin >/dev/null 2>&1 || return 0

  git -C "$dir" add -A

  # Nothing new to commit
  git -C "$dir" diff --cached --quiet && return 0

  git -C "$dir" commit -m "sync — $(hostname) — $(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if git -C "$dir" push; then
    return 0
  fi

  # Push was rejected — rebase on remote and retry once
  echo "Push rejected, rebasing..."
  if git -C "$dir" pull --rebase && git -C "$dir" push; then
    echo "✔ Synced (after rebase)"
  else
    echo "⚠  Sync push failed — changes saved locally."
    echo "   Retry manually: git -C \"$dir\" push"
  fi
}

# Explicit allowlist of what gets synced — only these patterns are tracked.
# New files Claude Code might add in future will be ignored unless added here.
_cbox_sync_write_gitignore() {
  local dir="$1"
  cat > "$dir/.gitignore" <<'EOF'
# Ignore everything — only explicitly listed items are synced.
*

# This file itself
!.gitignore

# Claude Code config
!settings.json
!CLAUDE.md
!keybindings.json

# User scripts (e.g. statusline-command.sh)
!*.sh

# Project conversation history
!projects/
!projects/**

# Plugin configuration
!plugins/
!plugins/**
EOF
}

_cbox_sync_init() {
  local remote="$1"
  local dir="$CBOX_CLAUDE_DIR"

  if [[ -z "$remote" ]]; then
    echo "Usage: cbox sync-init <remote-url>"
    return 1
  fi

  if ! command -v git >/dev/null; then
    echo "Error: git not found"
    return 1
  fi

  mkdir -p "$dir"

  if [[ ! -d "$dir/.git" ]]; then
    git -C "$dir" init -b main 2>/dev/null \
      || { git -C "$dir" init && git -C "$dir" branch -M main 2>/dev/null || true; }
  fi

  _cbox_sync_write_gitignore "$dir"

  if git -C "$dir" remote get-url origin >/dev/null 2>&1; then
    git -C "$dir" remote set-url origin "$remote"
  else
    git -C "$dir" remote add origin "$remote"
  fi

  # Check whether the remote already has a main branch (second-machine setup)
  if git -C "$dir" fetch origin 2>/dev/null \
      && git -C "$dir" ls-remote --exit-code origin main >/dev/null 2>&1; then

    # Remote has history — commit any local state, then rebase on top of remote
    git -C "$dir" add -A
    if ! git -C "$dir" diff --cached --quiet 2>/dev/null; then
      git -C "$dir" commit -m "local state before initial sync — $(hostname)"
    fi
    git -C "$dir" branch --set-upstream-to=origin/main main 2>/dev/null || true
    git -C "$dir" rebase origin/main \
      || echo "⚠  Rebase had conflicts — resolve manually in $dir"
    echo "✔ Sync initialized — pulled existing history from remote."

  else
    # Remote is empty — push local state
    git -C "$dir" add -A
    if ! git -C "$dir" diff --cached --quiet 2>/dev/null \
        || ! git -C "$dir" log -1 >/dev/null 2>&1; then
      git -C "$dir" commit --allow-empty -m "initial sync — $(hostname)"
    fi
    if git -C "$dir" push -u origin main; then
      echo "✔ Sync initialized — pushed local config to remote."
    else
      echo "⚠  Push failed. Check remote access and retry:"
      echo "   git -C \"$dir\" push -u origin main"
    fi
  fi

  echo "Claude config will now sync automatically on cbox start and exit."
}

# ---------------------------------------------------------
# container creation
# ---------------------------------------------------------

_cbox_create() {
  local name="$1"
  local mode="$2"

  _cbox_generate_claude_json "$name"

  local claude_json="$CBOX_DATA_DIR/.claude-$name.json"

  echo "Creating $mode container '$name'..."

  local args=(
    run -d
    --name "$name"

    --label "$CBOX_LABEL"
    --label "cbox.mode=$mode"

    -v "$PWD:/Workspace/$name"
    -w "/Workspace/$name"

    -v "$claude_json:/home/claude/.claude.json"

    -e ZDOTDIR=/home/claude
  )

  if [[ -n "${CBOX_ZSHRC:-}" ]]; then
    args+=(-v "$CBOX_ZSHRC:/home/claude/.zshrc.global:ro")
  fi

  # Auto-mount targets of symlinks in CBOX_CLAUDE_DIR so they resolve inside the container.
  # We read the raw symlink value (no existence check) because this may run inside a container
  # where the host paths don't exist locally but are valid on the Docker host.
  local _mounted=() _link _target _tdir _raw _skip
  while IFS= read -r _link; do
    _raw=$(readlink "$_link" 2>/dev/null) || continue
    if [[ "$_raw" == /* ]]; then
      # Absolute symlink — use directly, no normalization needed
      _target="$_raw"
    else
      # Relative symlink — build absolute path and normalize .. via python3
      _target=$(python3 -c "import os,sys; print(os.path.normpath(os.path.join(os.path.dirname(sys.argv[1]), sys.argv[2])))" "$_link" "$_raw" 2>/dev/null) || continue
    fi
    [[ "$_target" == "$CBOX_CLAUDE_DIR"* ]] && continue
    _tdir=$(dirname "$_target")
    _skip=false
    for _d in "${_mounted[@]+"${_mounted[@]}"}"; do
      [[ "$_tdir" == "$_d"* ]] && { _skip=true; break; }
    done
    "$_skip" && continue
    _mounted+=("$_tdir")
    args+=(-v "$_tdir:$_tdir:ro")
  done < <(find "$CBOX_CLAUDE_DIR" -maxdepth 1 -type l 2>/dev/null)
  unset _link _target _tdir _raw _skip _mounted

  if [[ "$mode" == "normal" ]]; then
    if [[ -n "${CBOX_SSH_DIR:-}" ]]; then
      args+=(-v "$CBOX_SSH_DIR:/home/claude/.ssh:ro")
    fi
    args+=(
      -v "$CBOX_CLAUDE_DIR:/home/claude/.claude"
      -v "$CBOX_HOST_CONFIG_DIR:/home/claude/.config"
      -v "$CBOX_SHARE_DIR:/home/claude/share"
    )
  fi

  if [[ "$mode" == "safe" ]]; then
    _cbox_create_network

    args+=(
      --network cbox-bridge
      --cap-drop=ALL
      --security-opt no-new-privileges
      --pids-limit 512
      --memory=4g
      --cpus=2

      -v "$CBOX_CLAUDE_DIR:/home/claude/.claude:ro"
    )
  fi

  args+=(
    "$CBOX_IMAGE"
    tail -f /dev/null
  )

  $_CBOX_CMD "${args[@]}"
}

# ---------------------------------------------------------
# ensure container
# ---------------------------------------------------------

_cbox_ensure() {
  local name="$1"
  local requested_mode="$2"

  if ! _cbox_exists "$name"; then
    _cbox_create "$name" "$requested_mode"
    return
  fi

  local actual_mode
  actual_mode=$(_cbox_mode "$name")

  if [[ "$actual_mode" != "$requested_mode" ]]; then
    echo "ERROR:"
    echo "Container '$name' already exists in '$actual_mode' mode."
    echo "Requested mode: '$requested_mode'"
    return 1
  fi

  if ! _cbox_running "$name"; then
    echo "Starting container '$name'..."
    $_CBOX_CMD start "$name"
  fi
}

# ---------------------------------------------------------
# enter container
# ---------------------------------------------------------

_cbox_enter() {
  local name="$1"
  local command="$2"
  local stop_on_exit="${3:-yes}"

  if [[ "$command" == "claude" ]]; then
    _cbox_maybe_update "$name"
    _cbox_sync_pull
  fi

  echo "Entering container '$name'..."

  $_CBOX_CMD exec -it -w "/Workspace/$name" "$name" zsh -ic "$command"

  if [[ "$command" == "claude" ]]; then
    _cbox_sync_push
  fi

  if [[ "$stop_on_exit" == "yes" ]]; then
    echo "Stopping container '$name'..."
    $_CBOX_CMD stop "$name"
  fi

  find "$CBOX_SHARE_DIR" -mindepth 1 -delete 2>/dev/null || true
}

# ---------------------------------------------------------
# keepalive
# ---------------------------------------------------------

_cbox_keepalive() {
  local name="$1"

  echo "Keeping container alive for ${CBOX_KEEPALIVE_SECONDS} seconds..."

  (
    sleep "$CBOX_KEEPALIVE_SECONDS"

    if _cbox_running "$name"; then
      echo "Auto-stopping container '$name'..."
      $_CBOX_CMD stop "$name" >/dev/null 2>&1
    fi
  ) >/dev/null 2>&1 &
}

# ---------------------------------------------------------
# doctor
# ---------------------------------------------------------

_cbox_doctor() {
  local name
  name=$(_cbox_name)

  echo "== cbox doctor =="

  echo
  echo "[environment]"

  command -v "$_CBOX_CMD" >/dev/null \
    && echo "✔ $_CBOX_CMD command found" \
    || echo "✘ $_CBOX_CMD command missing"

  _cbox_rt_image_list | grep -q "^$CBOX_IMAGE " \
    && echo "✔ image '$CBOX_IMAGE' exists" \
    || echo "✘ image '$CBOX_IMAGE' missing"

  [[ -d "$CBOX_CLAUDE_DIR" ]] \
    && echo "✔ Claude config dir exists ($CBOX_CLAUDE_DIR)" \
    || echo "✘ Claude config dir missing ($CBOX_CLAUDE_DIR)"

  if [[ -n "${CBOX_ZSHRC:-}" ]]; then
    [[ -f "$CBOX_ZSHRC" ]] \
      && echo "✔ custom zshrc exists ($CBOX_ZSHRC)" \
      || echo "✘ custom zshrc missing ($CBOX_ZSHRC)"
  else
    echo "ℹ no custom zshrc configured (CBOX_ZSHRC unset)"
  fi

  echo
  echo "[sync]"

  if [[ -d "$CBOX_CLAUDE_DIR/.git" ]]; then
    local sync_remote
    sync_remote=$(git -C "$CBOX_CLAUDE_DIR" remote get-url origin 2>/dev/null || echo "none")
    echo "✔ sync enabled (remote: $sync_remote)"

    local ahead behind
    ahead=$(git -C "$CBOX_CLAUDE_DIR" rev-list --count @{u}..HEAD 2>/dev/null || echo "?")
    behind=$(git -C "$CBOX_CLAUDE_DIR" rev-list --count HEAD..@{u} 2>/dev/null || echo "?")
    echo "  ahead: $ahead  behind: $behind"
  else
    echo "ℹ sync not configured (run: cbox sync-init <remote-url>)"
  fi

  echo
  echo "[project]"

  echo "Project name: $name"

  if _cbox_exists "$name"; then
    echo "✔ container exists"

    local mode
    mode=$(_cbox_mode "$name")

    echo "Mode: $mode"

    if _cbox_running "$name"; then
      echo "✔ container running"
    else
      echo "✔ container stopped"
    fi
  else
    echo "ℹ container does not exist yet"
  fi
}

# ---------------------------------------------------------
# public command
# ---------------------------------------------------------

cbox() {
  local subcommand="$1"

  local name
  name=$(_cbox_name)

  case "$subcommand" in

    safe)
      _cbox_ensure "$name" "safe" || return 1
      _cbox_enter "$name" "claude"
      ;;

    shell)
      _cbox_ensure "$name" "normal" || return 1
      _cbox_enter "$name" "zsh"
      ;;

    keepalive)
      _cbox_ensure "$name" "normal" || return 1
      _cbox_enter "$name" "claude" "no"
      _cbox_keepalive "$name"
      ;;

    stop)
      echo "Stopping container '$name'..."
      $_CBOX_CMD stop "$name"
      ;;

    reset)
      echo "Removing container '$name'..."
      $_CBOX_CMD rm -f "$name"
      ;;

    rebuild)
      echo "Rebuilding image '$CBOX_IMAGE'..."
      $_CBOX_CMD build \
        --build-arg HOST_UID="$(id -u)" \
        --build-arg BUILD_PLAYWRIGHT="${BUILD_PLAYWRIGHT:-0}" \
        -t "$CBOX_IMAGE" "$_CBOX_BUILD_DIR"
      ;;

    sync-init)
      _cbox_sync_init "${2:-}"
      ;;

    sync)
      _cbox_sync_pull
      _cbox_sync_push
      ;;

    update)
      _cbox_force_update "$name"
      ;;

    doctor)
      _cbox_doctor
      ;;

    list)
      if [[ "$_CBOX_RUNTIME" == "apple" ]]; then
        container list --all --filter "label=$CBOX_LABEL"
      else
        docker ps -a --filter "label=$CBOX_LABEL"
      fi
      ;;

    gc)
      echo "Removing stopped cbox containers..."

      local stopped
      stopped=$(_cbox_rt_list --filter "label=$CBOX_LABEL" \
        | awk '$2 != "running" {print $1}')

      [[ -n "$stopped" ]] && echo "$stopped" | xargs "$_CBOX_CMD" rm -f
      ;;

    "")

      _cbox_ensure "$name" "normal" || return 1
      _cbox_enter "$name" "claude"
      ;;

     help|--help|-h)

      _cbox_help

      ;;

    *)

      echo "Unknown command: $subcommand"

      echo

      _cbox_help

      return 1

      ;;
  esac
}
