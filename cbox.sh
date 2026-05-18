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
  cbox list             List cbox containers
  cbox prune            Remove stopped cbox containers

Sync (cross-machine):
  cbox sync-init <url>  Initialize config sync with a git remote
  cbox sync             Pull and push config + opted-in project history
  cbox sync add         Opt current project into history sync
  cbox sync remove      Stop syncing history for current project
  cbox sync compact     Squash current project's history to one commit
  cbox sync prune [--all]  Remove old/oversized history branches (default: current project)
  cbox sync list        List projects with history sync and sizes

Maintenance:
  cbox update           Force Claude Code update
  cbox doctor           Run environment diagnostics
  cbox version          Show sourced commit hash

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

CBOX_DATA_DIR="${CBOX_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/claudebox}"
CBOX_CLAUDE_DIR="${CBOX_CLAUDE_DIR:-$HOME/.claude}"
CBOX_HOST_CONFIG_DIR="${CBOX_HOST_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}}"
CBOX_SHARE_DIR="${CBOX_SHARE_DIR:-/tmp/cbox-$(id -un)}"
CBOX_SYNC_SIZE_WARN_MB="${CBOX_SYNC_SIZE_WARN_MB:-500}"
CBOX_SYNC_PROJECTS="${CBOX_SYNC_PROJECTS:-}"
# CBOX_SSH_DIR  — path to SSH dir to mount; unset = no SSH mount
# CBOX_ZSHRC    — path to a .zshrc to source inside container; unset = none
_CBOX_BUILD_DIR="${CBOX_BUILD_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
_CBOX_VERSION="dev"

if [[ "$(/usr/bin/uname)" == "Darwin" ]]; then
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
    container ls --all "$@" | awk 'NR>1 {print $1, $2}'
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

  [[ -f "$claude_json" ]] && return 0

  echo "{\"hasCompletedOnboarding\":true,\"installMethod\":\"npm\",\"projects\":{\"/Workspace/$name\":{\"hasTrustDialogAccepted\":true}}}" \
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

# Resolves a path through symlink chain (up to 10 levels), returning the real path.
# Uses /usr/bin/readlink and shell builtins only — no PATH dependency.
_cbox_resolve_path() {
  local path="$1" target count=0
  while [[ -L "$path" ]] && (( count++ < 10 )); do
    target=$(/usr/bin/readlink "$path" 2>/dev/null) || break
    [[ "$target" == /* ]] || target="${path%/*}/$target"
    path="$target"
  done
  local _dir="${path%/*}" _base="${path##*/}"
  path="$(cd "$_dir" 2>/dev/null && pwd -P)/$_base"
  echo "$path"
}

# ---------------------------------------------------------
# sync — helpers
# ---------------------------------------------------------

_cbox_project_dir() {
  echo "-Workspace-$1"
}

_cbox_history_branch() {
  echo "history/$1/$(hostname)"
}

_cbox_sync_is_opted_in() {
  [[ " ${CBOX_SYNC_PROJECTS:-} " == *" $1 "* ]]
}

_cbox_sync_register() {
  local name="$1" action="$2"
  local config="${XDG_CONFIG_HOME:-$HOME/.config}/claudebox/cbox.env"
  local current="${CBOX_SYNC_PROJECTS:-}"
  local new_value

  if [[ "$action" == "add" ]]; then
    [[ " $current " == *" $name "* ]] && return 0
    new_value="${current:+$current }$name"
  else
    new_value=$(printf '%s\n' $current | grep -vx "$name" | tr '\n' ' ')
    new_value="${new_value% }"
  fi

  local tmp
  tmp=$(mktemp)
  mkdir -p "$(dirname "$config")"
  [[ -f "$config" ]] && grep -v "^CBOX_SYNC_PROJECTS=" "$config" > "$tmp" || true
  printf 'CBOX_SYNC_PROJECTS="%s"\n' "$new_value" >> "$tmp"
  mv "$tmp" "$config"
  CBOX_SYNC_PROJECTS="$new_value"
}

# ---------------------------------------------------------
# sync — config (main branch)
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

  # Bail if a rebase is in progress (unresolved pull conflict)
  if [[ -d "$dir/.git/rebase-merge" || -d "$dir/.git/rebase-apply" ]]; then
    echo "⚠  Rebase in progress in $dir — resolve conflicts before syncing."
    return 1
  fi

  # Only push if a remote is configured
  git -C "$dir" remote get-url origin >/dev/null 2>&1 || return 0

  git -C "$dir" add -A

  # Nothing new to commit
  git -C "$dir" diff --cached --quiet && return 0

  git -C "$dir" commit -m "sync — $(hostname) — $(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if git -C "$dir" push; then
    return 0
  fi

  # Only retry if an upstream tracking branch is configured (genuine rejection)
  if git -C "$dir" rev-parse --abbrev-ref --symbolic-full-name @{u} >/dev/null 2>&1; then
    echo "Push rejected, rebasing..."
    if git -C "$dir" pull --rebase && git -C "$dir" push; then
      echo "✔ Synced (after rebase)"
      return 0
    fi
  fi

  echo "⚠  Sync push failed — changes saved locally."
  echo "   Retry manually: git -C \"$dir\" push"
}

# Allowlist for main branch — config only. projects/ is handled via per-project
# history branches and is intentionally excluded here.
# Overwritten if the old format (containing !projects/) is detected (migration).
_cbox_sync_write_gitignore() {
  local dir="$1"
  if [[ -f "$dir/.gitignore" ]] && ! grep -q "^!projects/" "$dir/.gitignore" 2>/dev/null; then
    return 0
  fi
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

  # Detect whether the remote has history and what its default branch is
  local remote_default=""
  if git -C "$dir" fetch origin 2>/dev/null; then
    remote_default=$(git -C "$dir" ls-remote --symref origin HEAD 2>/dev/null \
      | awk '/^ref:/ {sub("refs/heads/", "", $2); print $2; exit}')
  fi

  if [[ -n "$remote_default" ]]; then
    # Remote has history — commit any local state, then rebase on top of remote
    git -C "$dir" add -A
    if [[ -n "$(git -C "$dir" status --porcelain 2>/dev/null)" ]]; then
      git -C "$dir" commit -m "local state before initial sync — $(hostname)"
    fi
    git -C "$dir" branch --set-upstream-to="origin/$remote_default" main 2>/dev/null || true
    git -C "$dir" rebase "origin/$remote_default" \
      || echo "⚠  Rebase had conflicts — resolve manually in $dir"
    echo "✔ Sync initialized — pulled existing config from remote."

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

  echo "Config will now sync automatically on cbox start and exit."
  echo "Use 'cbox sync add' to opt the current project into history sync."
}

# ---------------------------------------------------------
# sync — history (per-project branches: history/<project>/<hostname>)
# ---------------------------------------------------------

_cbox_sync_size_check() {
  local warn_mb="${CBOX_SYNC_SIZE_WARN_MB:-500}"
  local size_mb
  size_mb=$(du -sm "$CBOX_CLAUDE_DIR/projects/" 2>/dev/null | awk '{print $1}')
  [[ -z "$size_mb" ]] && return 0
  if (( size_mb > warn_mb )); then
    echo "⚠  Project history is ${size_mb}MB (threshold: ${warn_mb}MB)"
    echo "   Consider: cbox sync prune --older-than 30d"
    echo "             cbox sync compact"
  fi
}

_cbox_sync_pull_history() {
  local name="$1"
  local dir="$CBOX_CLAUDE_DIR"
  [[ -d "$dir/.git" ]] || return 0
  command -v git >/dev/null || return 0
  _cbox_sync_is_opted_in "$name" || return 0

  local branch
  branch=$(_cbox_history_branch "$name")

  echo "Pulling history for '$name'..."
  git -C "$dir" fetch origin \
    "refs/heads/$branch:refs/remotes/origin/$branch" 2>/dev/null || return 0

  # Extract directly to working tree — does not touch main's index
  git -C "$dir" archive "refs/remotes/origin/$branch" \
    | tar -x -C "$dir" 2>/dev/null || true
}

_cbox_sync_push_history() {
  local name="$1"
  local dir="$CBOX_CLAUDE_DIR"
  [[ -d "$dir/.git" ]] || return 0
  command -v git >/dev/null || return 0
  _cbox_sync_is_opted_in "$name" || return 0

  if [[ -d "$dir/.git/rebase-merge" || -d "$dir/.git/rebase-apply" ]]; then
    echo "⚠  Rebase in progress in $dir — resolve conflicts before syncing."
    return 1
  fi

  local project_dir
  project_dir=$(_cbox_project_dir "$name")
  [[ -d "$dir/projects/$project_dir" ]] || return 0

  local branch
  branch=$(_cbox_history_branch "$name")

  echo "Pushing history for '$name'..."

  local tmp_index="$dir/.git/cbox-history-index-$$"
  GIT_INDEX_FILE="$tmp_index" git -C "$dir" add "projects/$project_dir/" 2>/dev/null
  local tree
  tree=$(GIT_INDEX_FILE="$tmp_index" git -C "$dir" write-tree 2>/dev/null)
  rm -f "$tmp_index"

  [[ -n "$tree" ]] || { echo "⚠  Failed to build history tree for '$name'."; return 1; }

  local parent_args=()
  local parent
  parent=$(git -C "$dir" rev-parse --verify "refs/remotes/origin/$branch" 2>/dev/null)
  [[ -n "$parent" ]] && parent_args=(-p "$parent")

  local commit
  commit=$(git -C "$dir" commit-tree "$tree" "${parent_args[@]}" \
    -m "sync — $(hostname) — $(date -u +%Y-%m-%dT%H:%M:%SZ)" 2>/dev/null)

  [[ -n "$commit" ]] || { echo "⚠  Failed to create history commit for '$name'."; return 1; }

  if git -C "$dir" push origin "$commit:refs/heads/$branch" 2>&1; then
    _cbox_sync_size_check
    return 0
  else
    echo "⚠  History push failed for '$name'."
    echo "   Retry manually: git -C \"$dir\" push origin $commit:refs/heads/$branch"
    return 1
  fi
}

_cbox_sync_add() {
  local name="$1"
  local dir="$CBOX_CLAUDE_DIR"
  [[ -d "$dir/.git" ]] || { echo "Sync not initialized. Run: cbox sync-init <url>"; return 1; }
  _cbox_sync_register "$name" add
  _cbox_sync_push_history "$name"
  echo "✔ Project '$name' opted into history sync on this machine."
}

_cbox_sync_remove() {
  local name="$1"
  local dir="$CBOX_CLAUDE_DIR"
  local branch
  branch=$(_cbox_history_branch "$name")

  _cbox_sync_register "$name" remove

  if git -C "$dir" push origin --delete "$branch" 2>/dev/null; then
    echo "✔ History for '$name' removed from remote."
  else
    echo "⚠  Could not delete remote branch (may not exist)."
  fi
  echo "   '$name' removed from history sync on this machine."
}

_cbox_sync_compact() {
  local name="$1"
  local dir="$CBOX_CLAUDE_DIR"

  if ! _cbox_sync_is_opted_in "$name"; then
    echo "Project '$name' is not opted into history sync. Run: cbox sync add"
    return 1
  fi

  local project_dir branch
  project_dir=$(_cbox_project_dir "$name")
  branch=$(_cbox_history_branch "$name")

  [[ -d "$dir/projects/$project_dir" ]] || { echo "No history found for '$name'."; return 1; }

  local tmp_index="$dir/.git/cbox-compact-index-$$"
  GIT_INDEX_FILE="$tmp_index" git -C "$dir" add "projects/$project_dir/" 2>/dev/null
  local tree
  tree=$(GIT_INDEX_FILE="$tmp_index" git -C "$dir" write-tree 2>/dev/null)
  rm -f "$tmp_index"

  [[ -n "$tree" ]] || { echo "⚠  Failed to build tree for compact."; return 1; }

  # Orphan commit — no parent, drops all prior history on this branch
  local commit
  commit=$(git -C "$dir" commit-tree "$tree" \
    -m "compact — $(hostname) — $(date -u +%Y-%m-%dT%H:%M:%SZ)" 2>/dev/null)

  [[ -n "$commit" ]] || { echo "⚠  Failed to create compact commit."; return 1; }

  if git -C "$dir" push --force origin "$commit:refs/heads/$branch"; then
    echo "✔ History for '$name' compacted to a single commit."
  else
    echo "⚠  Compact push failed."
    echo "   Retry: git -C \"$dir\" push --force origin $commit:refs/heads/$branch"
  fi
}

_cbox_sync_prune() {
  local name="$1"; shift
  local dir="$CBOX_CLAUDE_DIR"
  [[ -d "$dir/.git" ]] || { echo "Sync not initialized. Run: cbox sync-init <url>"; return 1; }

  local older_than_days="" size_limit_mb="" force=false all_projects=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all)        all_projects=true; shift ;;
      --older-than) older_than_days="${2%[dD]}"; shift 2 ;;
      --over)       size_limit_mb="${2%[mM]}";   shift 2 ;;
      --force)      force=true; shift ;;
      *) echo "Unknown flag: $1"; return 1 ;;
    esac
  done

  if [[ -z "$older_than_days" && -z "$size_limit_mb" ]]; then
    echo "Usage: cbox sync prune --older-than <N>d [--force]"
    echo "       cbox sync prune --over <N>m [--force]"
    echo "       add --all to operate on all projects on this machine"
    return 1
  fi

  echo "Fetching remote refs..."
  git -C "$dir" fetch origin 2>/dev/null || true

  local host; host=$(hostname)
  local branches=()

  if $all_projects; then
    while IFS= read -r ref; do
      [[ -n "$ref" ]] && branches+=("${ref#refs/heads/}")
    done < <(git -C "$dir" ls-remote --heads origin "history/*/$host" 2>/dev/null \
      | awk '{print $2}')
  else
    local branch; branch=$(_cbox_history_branch "$name")
    local ref
    ref=$(git -C "$dir" ls-remote origin "refs/heads/$branch" 2>/dev/null | awk '{print $2}')
    [[ -n "$ref" ]] && branches+=("$branch")
  fi

  if [[ ${#branches[@]} -eq 0 ]]; then
    $all_projects && echo "No history branches found for this machine." \
      || echo "No history branch found for project '$name'. Run: cbox sync add"
    return 0
  fi

  local candidates=()
  local now_ts
  now_ts=$(date +%s)

  for branch in "${branches[@]}"; do
    local project="${branch#history/}"
    project="${project%/$host}"
    local should_prune=false

    if [[ -n "$older_than_days" ]]; then
      local last_ts
      last_ts=$(git -C "$dir" log -1 --format="%ct" \
        "refs/remotes/origin/$branch" 2>/dev/null)
      if [[ -n "$last_ts" ]]; then
        local cutoff=$(( now_ts - older_than_days * 86400 ))
        (( last_ts < cutoff )) && should_prune=true
      fi
    fi

    if [[ -n "$size_limit_mb" ]]; then
      local project_dir proj_mb=0
      project_dir=$(_cbox_project_dir "$project")
      proj_mb=$(du -sm "$dir/projects/$project_dir" 2>/dev/null | awk '{print $1}')
      (( proj_mb > size_limit_mb )) && should_prune=true
    fi

    $should_prune && candidates+=("$branch")
  done

  if [[ ${#candidates[@]} -eq 0 ]]; then
    echo "No branches match the prune criteria."
    return 0
  fi

  echo "Branches to delete:"
  for branch in "${candidates[@]}"; do
    echo "  $branch"
  done

  if ! $force; then
    printf "Delete %d branch(es)? [y/N] " "${#candidates[@]}"
    read -r reply
    [[ "$reply" =~ ^[Yy]$ ]] || { echo "Aborted."; return 0; }
  fi

  for branch in "${candidates[@]}"; do
    if git -C "$dir" push origin --delete "$branch" 2>/dev/null; then
      echo "✔ Deleted $branch"
    else
      echo "⚠  Failed to delete $branch"
    fi
  done
}

_cbox_sync_list() {
  local dir="$CBOX_CLAUDE_DIR"
  [[ -d "$dir/.git" ]] || { echo "Sync not initialized. Run: cbox sync-init <url>"; return 1; }

  echo "Fetching remote refs..."
  git -C "$dir" fetch origin 2>/dev/null || true

  local host
  host=$(hostname)
  local found=false

  while IFS= read -r ref; do
    found=true
    local branch="${ref#refs/heads/}"
    local project="${branch#history/}"
    project="${project%/$host}"

    local project_dir
    project_dir=$(_cbox_project_dir "$project")

    local last_date
    last_date=$(git -C "$dir" log -1 --format="%ci" \
      "refs/remotes/origin/$branch" 2>/dev/null | cut -d' ' -f1)

    local size_mb="?"
    [[ -d "$dir/projects/$project_dir" ]] && \
      size_mb=$(du -sm "$dir/projects/$project_dir" 2>/dev/null | awk '{print $1}')

    local opted=""
    _cbox_sync_is_opted_in "$project" && opted=" ✔"

    printf "  %-30s  last: %s  size: %smb%s\n" \
      "$project" "${last_date:-?}" "$size_mb" "$opted"
  done < <(git -C "$dir" ls-remote --heads origin "history/*/$host" 2>/dev/null \
    | awk '{print $2}')

  $found || echo "No history branches found for this machine."
}

# ---------------------------------------------------------
# container creation
# ---------------------------------------------------------

_cbox_create() {
  local name="$1"
  local mode="$2"

  _cbox_generate_claude_json "$name"

  local claude_json="$CBOX_DATA_DIR/.claude-$name.json"

  mkdir -p "$CBOX_CLAUDE_DIR/projects"

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
    local _zshrc_real
    _zshrc_real=$(_cbox_resolve_path "$CBOX_ZSHRC")
    [[ -f "$_zshrc_real" ]] && args+=(-v "$_zshrc_real:/home/claude/.zshrc.global:ro")
    unset _zshrc_real
  fi

  if [[ "$mode" == "normal" ]]; then
    [[ -n "${CBOX_SSH_DIR:-}" ]] && args+=(-v "$CBOX_SSH_DIR:/home/claude/.ssh:ro")
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

  # For each symlink in CBOX_CLAUDE_DIR, resolve it to the real host path and
  # mount that target at its own absolute path inside the container. The symlink
  # in ~/.claude points to e.g. /Users/work/.config/dotfiles/claude/settings.json;
  # mounting that path at the same path in the container lets the symlink resolve.
  local _ro="" _link _target
  [[ "$mode" == "safe" ]] && _ro=":ro"
  while IFS= read -r _link; do
    _target=$(_cbox_resolve_path "$_link")
    [[ -e "$_target" ]] || continue
    [[ "$_target" == "$CBOX_CLAUDE_DIR"* ]] && continue
    [[ "$_target" == "$PWD" || "$_target" == "$PWD/"* ]] && continue
    args+=(-v "$_target:$_target$_ro")
  done < <(find "$CBOX_CLAUDE_DIR" -maxdepth 1 -type l 2>/dev/null)
  unset _ro _link _target

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
  local mode
  mode=$(_cbox_mode "$name")

  if [[ "$command" == "claude" ]]; then
    _cbox_maybe_update "$name"
    _cbox_sync_pull
    [[ "$mode" != "safe" ]] && _cbox_sync_pull_history "$name"
  fi

  echo "Entering container '$name'..."

  $_CBOX_CMD exec -it -w "/Workspace/$name" "$name" zsh -ic "$command"

  if [[ "$command" == "claude" && "$mode" != "safe" ]]; then
    _cbox_sync_push
    _cbox_sync_push_history "$name"
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
  echo "Version: $_CBOX_VERSION"

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

    if [[ -n "${CBOX_SYNC_PROJECTS:-}" ]]; then
      echo "  history projects: $CBOX_SYNC_PROJECTS"
    else
      echo "  history projects: none (use: cbox sync add)"
    fi
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
      case "${2:-}" in
        add)     _cbox_sync_add "$name" ;;
        remove)  _cbox_sync_remove "$name" ;;
        compact) _cbox_sync_compact "$name" ;;
        prune)   _cbox_sync_prune "$name" "${@:3}" ;;
        list)    _cbox_sync_list ;;
        "")
          _cbox_sync_pull
          _cbox_sync_push
          _cbox_sync_pull_history "$name"
          _cbox_sync_push_history "$name"
          ;;
        *)
          echo "Unknown sync command: ${2}"
          echo
          _cbox_help
          return 1
          ;;
      esac
      ;;

    update)
      _cbox_force_update "$name"
      ;;

    doctor)
      _cbox_doctor
      ;;

    list)
      if [[ "$_CBOX_RUNTIME" == "apple" ]]; then
        container ls --all
      else
        docker ps -a --filter "label=$CBOX_LABEL"
      fi
      ;;

    prune)
      echo "Removing stopped cbox containers..."

      local stopped
      if [[ "$_CBOX_RUNTIME" == "apple" ]]; then
        stopped=$(
          _cbox_rt_list | while read -r cname cstate; do
            [[ "$cstate" == "running" ]] && continue
            [[ "$(_cbox_rt_label "$cname" "cbox.project")" == "true" ]] && echo "$cname"
          done
        )
      else
        stopped=$(_cbox_rt_list --filter "label=$CBOX_LABEL" \
          | awk '$2 != "running" {print $1}')
      fi

      [[ -n "$stopped" ]] && echo "$stopped" | xargs "$_CBOX_CMD" rm -f
      ;;

    "")

      _cbox_ensure "$name" "normal" || return 1
      _cbox_enter "$name" "claude"
      ;;

    version)
      echo "cbox $_CBOX_VERSION"
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
