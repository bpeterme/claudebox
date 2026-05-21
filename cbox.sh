#!/bin/bash
# shellcheck shell=bash

# claudebox (cbox) - Claude Container Runtime
# Install via Homebrew:
#   brew tap bpeterme/claudebox && brew install claudebox
# Or source this file in .bashrc or .zshrc:
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
  cbox list             List cbox containers
  cbox stop             Stop current project container
  cbox reset            Remove current project container
  cbox prune            Remove stopped cbox containers
  cbox rebuild          Rebuild container image

Maintenance:
  cbox update           Force Claude Code update
  cbox doctor           Run environment diagnostics
  cbox version          Show version

Companion tools:
  cdot                  claudedot — Config + history sync across machines
  flux                  Large-file routing for your projects (git + R2 storage)

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
# Minimum plumbing API versions required from companion tools
_CBOX_CDOT_API=1
_CBOX_FLUX_API=1

# Source user config if present (~/.config/claudebox/cbox.env)
_CBOX_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/claudebox/cbox.env"
[[ -f "$_CBOX_CONFIG" ]] && . "$_CBOX_CONFIG"
unset _CBOX_CONFIG

CBOX_DATA_DIR="${CBOX_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/claudebox}"
CBOX_CLAUDE_DIR="${CBOX_CLAUDE_DIR:-$HOME/.claude}"
CBOX_HOST_CONFIG_DIR="${CBOX_HOST_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}}"
CBOX_SHARE_DIR="${CBOX_SHARE_DIR:-/tmp/cbox-$(id -un)}"
# CBOX_SSH_DIR  — path to SSH dir to mount; unset = no SSH mount
# CBOX_ZSHRC    — path to a .zshrc to source inside container; unset = none
_CBOX_BUILD_DIR="${CBOX_BUILD_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
# For prefix-based installs (e.g. Homebrew), the dockerfile lives in share/claudebox
# rather than next to the binary — check PREFIX/share/claudebox as a fallback.
if [[ ! -f "$_CBOX_BUILD_DIR/dockerfile" ]]; then
  _cbox_share="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/share/claudebox"
  [[ -f "$_cbox_share/dockerfile" ]] && _CBOX_BUILD_DIR="$_cbox_share"
  unset _cbox_share
fi
_CBOX_VERSION="dev"
if [[ "$_CBOX_VERSION" == "dev" ]]; then
  _v=$(git -C "$(dirname "${BASH_SOURCE[0]}")" describe --tags --always 2>/dev/null)
  [[ -n "$_v" ]] && _CBOX_VERSION="$_v"
  unset _v
fi

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
      | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0].get('configuration',{}).get('labels',{}).get(sys.argv[1],''))" "$label"
  else
    docker inspect "$name" 2>/dev/null \
      | python3 -c "import sys,json; d=json.load(sys.stdin); print(d[0].get('Config',{}).get('Labels',{}).get(sys.argv[1],''))" "$label"
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

  if ! _cbox_exists "$name"; then
    echo "No container found for '$name'."
    return 0
  fi

  if ! _cbox_running "$name"; then
    echo "Starting container '$name'..."
    $_CBOX_CMD start "$name"
  fi

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
    if [[ -n "${CBOX_SSH_DIR:-}" ]]; then
      # Mount each file individually so ~/.ssh/ itself is not a volume mount.
      # This allows known_hosts to be writable while keys remain read-only,
      # and lets us mount a generated config without EROFS conflicts.
      while IFS= read -r _f; do
        local _fname; _fname=$(basename "$_f")
        case "$_fname" in
          known_hosts|known_hosts.old) args+=(-v "$_f:/home/claude/.ssh/$_fname") ;;
          *)                           args+=(-v "$_f:/home/claude/.ssh/$_fname:ro") ;;
        esac
      done < <(find "$CBOX_SSH_DIR" -maxdepth 1 -type f 2>/dev/null)

      # Generate and mount a config if the source directory has none
      if [[ ! -f "$CBOX_SSH_DIR/config" ]]; then
        local _ssh_cfg="$CBOX_DATA_DIR/.ssh_config"
        {
          echo "Host *"
          find "$CBOX_SSH_DIR" -maxdepth 1 -type f \
            ! -name "*.pub" ! -name "known_hosts" ! -name "known_hosts.old" \
            ! -name "authorized_keys" ! -name "config" 2>/dev/null | sort \
            | while IFS= read -r _key; do
                echo "  IdentityFile /home/claude/.ssh/$(basename "$_key")"
              done
        } > "$_ssh_cfg"
        chmod 600 "$_ssh_cfg"
        args+=(-v "$_ssh_cfg:/home/claude/.ssh/config:ro")
        unset _ssh_cfg
      fi
      unset _f _fname _key
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
      --memory=4g
      --cpus=2
      -v "$CBOX_CLAUDE_DIR:/home/claude/.claude:ro"
    )
    # --security-opt and --pids-limit are not supported by Apple's container CLI
    if [[ "$_CBOX_RUNTIME" != "apple" ]]; then
      args+=(
        --security-opt no-new-privileges
        --pids-limit 512
      )
    fi
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
# companion API version check
# ---------------------------------------------------------

_cbox_check_companion_api() {
  local tool="$1" expected="$2"
  local actual
  actual=$("$tool" _api-version 2>/dev/null) || true
  if ! [[ "$actual" =~ ^[0-9]+$ ]] || (( actual < expected )); then
    echo "⚠  $tool is outdated (need API $expected) — upgrade: brew upgrade $tool"
    return 1
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
    if command -v cdot >/dev/null 2>&1 && _cbox_check_companion_api cdot "$_CBOX_CDOT_API"; then
      cdot _pull
      [[ "$mode" != "safe" ]] && cdot _pull-history "$name"
    fi
    if command -v flux >/dev/null 2>&1 && [[ -d "$PWD/.dvc" ]] && _cbox_check_companion_api flux "$_CBOX_FLUX_API"; then
      flux _pull
    fi
  fi

  echo "Entering container '$name'..."

  $_CBOX_CMD exec -it -w "/Workspace/$name" "$name" zsh -ic "$command"

  if [[ "$command" == "claude" && "$mode" != "safe" ]]; then
    if command -v cdot >/dev/null 2>&1 && _cbox_check_companion_api cdot "$_CBOX_CDOT_API"; then
      cdot _push
      cdot _push-history "$name"
    fi
    if command -v flux >/dev/null 2>&1 && [[ -d "$PWD/.dvc" ]] && _cbox_check_companion_api flux "$_CBOX_FLUX_API"; then
      flux _push
    fi
  fi

  if [[ "$stop_on_exit" == "yes" ]]; then
    echo "Stopping container '$name'..."
    $_CBOX_CMD stop "$name"
  fi

  [[ -n "$CBOX_SHARE_DIR" && "$CBOX_SHARE_DIR" == /tmp/* ]] && \
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

_cbox_doctor_inline() {
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
}

_cbox_doctor() {
  local name
  name=$(_cbox_name)

  echo "== cbox doctor =="
  echo "Version: $_CBOX_VERSION"

  echo
  echo "[environment]"
  _cbox_doctor_inline

  echo
  echo "[cdot]"
  if command -v cdot >/dev/null 2>&1; then
    if _cbox_check_companion_api cdot "$_CBOX_CDOT_API"; then
      cdot _doctor
    fi
  else
    echo "ℹ cdot not installed — sync unavailable"
    echo "  Install: brew tap bpeterme/claudebox && brew install claudedot"
  fi

  echo
  echo "[flux]"
  if command -v flux >/dev/null 2>&1; then
    if _cbox_check_companion_api flux "$_CBOX_FLUX_API"; then
      flux _doctor
    fi
  else
    echo "ℹ flux not installed — large-file sync unavailable"
    echo "  Install: brew tap bpeterme/flux && brew install flux"
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
  local subcommand="${1:-}"

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
      if ! _cbox_exists "$name"; then
        echo "No container found for '$name'."
        return 0
      fi
      echo "Stopping container '$name'..."
      $_CBOX_CMD stop "$name"
      ;;

    reset)
      local reset_target="${2:-$name}"
      if ! _cbox_exists "$reset_target"; then
        echo "No container found for '$reset_target'."
        return 0
      fi
      echo "Removing container '$reset_target'..."
      $_CBOX_CMD rm -f "$reset_target"
      ;;

    rebuild)
      echo "Rebuilding image '$CBOX_IMAGE'..."
      $_CBOX_CMD build \
        --build-arg HOST_UID="$(id -u)" \
        --build-arg BUILD_PLAYWRIGHT="${BUILD_PLAYWRIGHT:-0}" \
        -t "$CBOX_IMAGE" "$_CBOX_BUILD_DIR"
      ;;

    update)
      _cbox_force_update "$name"
      ;;

    doctor)
      _cbox_doctor
      ;;

    _doctor)
      _cbox_doctor_inline
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

    cdot)
      if command -v cdot >/dev/null 2>&1; then
        cdot help
      else
        echo "claudedot is not installed."
        echo "Install: brew tap bpeterme/claudedot && brew install bpeterme/claudedot/claudedot"
        return 1
      fi
      ;;

    flux)
      if command -v flux >/dev/null 2>&1; then
        echo "flux is installed. Use: flux help"
      else
        echo "flux is not installed."
        echo "Install: brew tap bpeterme/flux && brew install bpeterme/flux/flux"
      fi
      ;;

    *)

      echo "Unknown command: $subcommand"

      echo

      _cbox_help

      return 1

      ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  cbox "$@"
fi
