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
    clear
    cat <<'EOF'
cbox - AI Coding Agent Container Runtime

Usage:
  cbox [-v]             Start or enter normal container (Claude Code)
  cbox safe             Start or enter safe container
  cbox shell            Open zsh shell instead of the container
  cbox keepalive        Keep container alive for 10 minutes after exit
  cbox oc [...]         Same as above but use opencode instead of Claude Code

Agent:
  CBOX_AGENT=opencode   Use opencode instead of Claude Code (set in cbox.env)
  cbox oc               Shorthand: one-off opencode session
  cbox oc safe          opencode in safe mode
  cbox oc shell         zsh shell (opencode-mode container)

Options:
  -v, --verbose         Show full output (updates, sync, MCP relay status)

Container Management:
  cbox list             List cbox containers
  cbox stop [name]      Stop current (or named) container
  cbox reset            Remove current project container
  cbox prune            Remove stopped cbox containers
  cbox rebuild          Rebuild container image

MCP servers on the host (~/.config/claudebox/mcp.json):
  cbox mcp              Show configured host MCP servers and relay status
  cbox mcp import       Import servers from Claude Desktop / Claude Code

Credentials without exposing them (warden):
  cbox warden           List resources and what this project gets
  cbox warden edit      Define resources (APIs the container may use)
  cbox warden secret set <resource>
                        Store a secret in the Keychain
  cbox warden approve   Approve this project's .warden file
  cbox warden test <resource>
                        Check a resource from the host
  cbox warden log       Show recent broker requests

Maintenance:
  cbox update           Force agent update (Claude Code or opencode)
  cbox doctor           Run environment diagnostics
  cbox version          Show version

Companion tools:
  cdot help             claudedot — Config + history sync across machines
  flux help             Large-file routing for your projects (git + R2 storage)

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
_CBOX_CDOT_API=2
_CBOX_FLUX_API=1

# Source user config if present (~/.config/claudebox/cbox.env)
_CBOX_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/claudebox/cbox.env"
[[ -f "$_CBOX_CONFIG" ]] && . "$_CBOX_CONFIG"
unset _CBOX_CONFIG

CBOX_VERBOSE="${CBOX_VERBOSE:-0}"
CBOX_AGENT="${CBOX_AGENT:-claude}"
CBOX_DATA_DIR="${CBOX_DATA_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/claudebox}"
CBOX_CLAUDE_DIR="${CBOX_CLAUDE_DIR:-$HOME/.claude}"
# The container's ~/.config (normal mode): a folder of its own, because the real
# ~/.config holds config that runs on this Mac (cbox.env, mcp.json, git) and
# tokens. CBOX_SHARE_CONFIG shares chosen folders of it read-only.
CBOX_HOST_CONFIG_DIR="${CBOX_HOST_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/claudebox/.config}"
CBOX_SHARE_DIR="${CBOX_SHARE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/claudebox/share}"
# Playwright browser cache, mounted over the image's /opt/ms-playwright. Lives in
# CBOX_DATA_DIR, not CBOX_SHARE_DIR: the share dir is wiped when the last session
# closes, and these browsers are ~660 MB we never want to re-download.
CBOX_PLAYWRIGHT_DIR="${CBOX_PLAYWRIGHT_DIR:-$CBOX_DATA_DIR/ms-playwright}"
# Host MCP servers relayed into the container (see "MCP relay" below)
CBOX_MCP_CONFIG="${CBOX_MCP_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/claudebox/mcp.json}"
_CBOX_MCP_RELAY="/home/claude/.local/bin/cbox-mcp-relay"
_CBOX_MCP_SLOTS=2
# Below Claude Code's 30s MCP connect timeout, so the hint lands before it gives up
_CBOX_MCP_HINT_SECONDS=25
# warden: host-side credential broker (see "warden" below). Its directory holds
# resource definitions, approvals and session tokens — host only, never mounted.
CBOX_WARDEN_DIR="${CBOX_WARDEN_DIR:-$CBOX_DATA_DIR/warden}"
CBOX_WARDEN_PORT="${CBOX_WARDEN_PORT:-47100}"
# Container memory. Without it Apple's container runtime gives a VM 1 GB, which
# Claude Code (~400 MB) plus a test suite or a large file can exhaust; the VM
# then dies with the session. Applies when a container is created (cbox reset).
CBOX_MEMORY="${CBOX_MEMORY:-4g}"
# Mount the project's .git/config and .git/hooks read-only (see _cbox_create).
# 0 lets the container change them again. Applies when a container is created.
CBOX_PROTECT_GIT="${CBOX_PROTECT_GIT:-1}"
# CBOX_SSH_DIR  — path to SSH dir to mount; unset = no SSH mount
# CBOX_SHARE_CONFIG — folders of ~/.config to share read-only, e.g. "opencode nvim"
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

_cbox_log() { [[ "${CBOX_VERBOSE:-0}" == "1" ]] && echo "$@" || true; }

_cbox_agent_bin() { [[ "${CBOX_AGENT:-claude}" == "opencode" ]] && echo "opencode" || echo "claude"; }
_cbox_agent_pkg() { [[ "${CBOX_AGENT:-claude}" == "opencode" ]] && echo "opencode-ai" || echo "@anthropic-ai/claude-code"; }

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
    container ls --all "$@" | awk 'NR==1{for(i=1;i<=NF;i++)if($i=="STATE")col=i;next} col&&NR>1{print $1,$col}'
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
      | python3 -c "import sys,json; d=json.load(sys.stdin); e=d[0] if isinstance(d,list) else d; c=e.get('configuration') or e.get('Config') or e; l=c.get('labels') or c.get('Labels') or {}; print(l.get(sys.argv[1],'') if isinstance(l,dict) else '')" "$label"
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

# Apple Container's API server (container-apiserver). It is started by
# `container system start`, possibly late via a delayed launchagent.
# Not to be confused with `container machine`, a separate persistent VM
# that cbox does not use.
_cbox_system_running() {
  container system status >/dev/null 2>&1
}

# Writes the per-project ~/.claude.json the container mounts. Host MCP servers
# come from $CBOX_MCP_CONFIG only — never from a host Claude installation, which
# may not exist. See the "MCP relay" section for how they reach the container.
_cbox_generate_claude_json() {
  local name="$1"
  local mode="${2:-normal}"

  mkdir -p "$CBOX_DATA_DIR"

  local claude_json="$CBOX_DATA_DIR/.claude-$name.json"
  local managed="$CBOX_DATA_DIR/.mcp-managed-$name.json"

  python3 -c "$(_cbox_mcp_py)" claude-json \
    "$claude_json" "$name" "$CBOX_MCP_CONFIG" "$managed" "$_CBOX_MCP_RELAY" "$mode"
}

_cbox_maybe_update() {
  local name="$1"

  local agent_bin agent_pkg
  agent_bin=$(_cbox_agent_bin)
  agent_pkg=$(_cbox_agent_pkg)

  local stamp="${TMPDIR:-/tmp}/.cbox-update-${agent_bin}-$(date +%Y-%m-%d)"

  if [[ ! -f "$stamp" ]]; then
    _cbox_log "Updating ${agent_bin}..."
    if [[ "${CBOX_VERBOSE:-0}" == "1" ]]; then
      $_CBOX_CMD exec --user root "$name" \
        npm update -g --no-fund "$agent_pkg"
    else
      $_CBOX_CMD exec --user root "$name" \
        npm update -g --no-fund "$agent_pkg" >/dev/null 2>&1
    fi
    touch "$stamp"
  fi
}

_cbox_force_update() {
  local name="$1"
  clear

  if ! _cbox_exists "$name"; then
    echo "No container found for '$name'."
    return 0
  fi

  if ! _cbox_running "$name"; then
    echo "Starting container '$name'..."
    $_CBOX_CMD start "$name"
  fi

  local agent_bin agent_pkg
  agent_bin=$(_cbox_agent_bin)
  agent_pkg=$(_cbox_agent_pkg)

  echo "Updating ${agent_bin}..."

  $_CBOX_CMD exec --user root "$name" \
    npm update -g --no-fund "$agent_pkg"
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
# session tracking (multi-instance safety)
# ---------------------------------------------------------

_CBOX_SESSION_DIR="${TMPDIR:-/tmp}"

_cbox_session_start() {
  touch "$_CBOX_SESSION_DIR/.cbox-active-${1}-$$"
}

# Removes this session's marker, cleans stale markers (dead PIDs), and
# returns 0 if other live sessions for this container remain, 1 if this
# was the last one.
_cbox_session_end() {
  local name="$1" f pid others=1
  rm -f "$_CBOX_SESSION_DIR/.cbox-active-${name}-$$"
  while IFS= read -r f; do
    pid="${f##*-}"
    if ps -p "$pid" >/dev/null 2>&1; then
      others=0
    else
      rm -f "$f"
    fi
  done < <(_cbox_session_markers "$name")
  return $others
}

# Prints this container's marker paths. Uses find instead of a shell glob:
# zsh aborts the whole calling function on a glob with no matches, and
# compgen is bash-only. Filters out markers of containers whose name merely
# starts with "$name-".
_cbox_session_markers() {
  local name="$1" f pid
  find "$_CBOX_SESSION_DIR" -maxdepth 1 -name ".cbox-active-${name}-*" 2>/dev/null \
    | while IFS= read -r f; do
        pid="${f##*-}"
        [[ "$pid" =~ ^[0-9]+$ && "${f##*/}" == ".cbox-active-${name}-${pid}" ]] && echo "$f"
      done
  return 0
}

# Asks the container itself whether any exec session is still attached.
# Exec'd processes run with PPID 0 (PID 1 is the keep-alive entrypoint);
# the probe's own `ps` is excluded. Returns 0 if a session is active,
# 1 if none, 2 if the probe failed (caller must not treat that as "none").
# Marker files alone can outlive their session (interrupted cbox in a
# still-open shell, or macOS PID reuse), so this is the ground truth.
_cbox_container_has_sessions() {
  local out
  out=$($_CBOX_CMD exec "$1" ps -eo pid=,ppid=,comm= 2>/dev/null) || return 2
  [[ -n "$out" ]] || return 2
  awk '$2 == 0 && $1 != 1 && $3 != "ps" { found = 1 } END { exit !found }' <<<"$out"
}

# ---------------------------------------------------------
# audio (voice mode)
# ---------------------------------------------------------

_CBOX_AUDIO_STARTED=0

_cbox_audio_ensure_config() {
  local pulse_conf_dir="${XDG_CONFIG_HOME:-$HOME/.config}/pulse"
  local default_pa="$pulse_conf_dir/default.pa"
  local daemon_conf="$pulse_conf_dir/daemon.conf"

  mkdir -p "$pulse_conf_dir"

  if [[ ! -f "$default_pa" ]]; then
    local _brew_pa="" _candidate _brew_prefix
    if [[ -n "${HOMEBREW_PREFIX:-}" ]]; then
      # Explicit custom Homebrew install — trust it and don't look elsewhere
      [[ -f "$HOMEBREW_PREFIX/etc/pulse/default.pa" ]] && _brew_pa="$HOMEBREW_PREFIX/etc/pulse/default.pa"
    else
      _brew_prefix=$(brew --prefix 2>/dev/null) || _brew_prefix=""
      for _candidate in \
          "${_brew_prefix:+$_brew_prefix/etc/pulse/default.pa}" \
          /opt/homebrew/etc/pulse/default.pa \
          /usr/local/etc/pulse/default.pa; do
        [[ -n "$_candidate" && -f "$_candidate" ]] && _brew_pa="$_candidate" && break
      done
    fi
    { [[ -n "$_brew_pa" ]] && echo ".include $_brew_pa"; \
      echo "load-module module-native-protocol-tcp auth-ip-acl=127.0.0.1;10.0.0.0/8;172.16.0.0/12;192.168.0.0/16"; \
    } > "$default_pa"
    unset _brew_pa _candidate _brew_prefix
  else
    if ! grep -q "module-native-protocol-tcp" "$default_pa"; then
      echo "load-module module-native-protocol-tcp auth-ip-acl=127.0.0.1;10.0.0.0/8;172.16.0.0/12;192.168.0.0/16" >> "$default_pa"
    fi
  fi

  # Ensure CoreAudio device detection is loaded — required on macOS.
  # A .include of brew's default.pa already covers this; only add explicitly if absent.
  if ! grep -qE "(\.include|module-coreaudio)" "$default_pa"; then
    echo "load-module module-coreaudio-detect" >> "$default_pa"
  fi

  if ! grep -q "exit-idle-time" "$daemon_conf" 2>/dev/null; then
    echo "exit-idle-time = -1" >> "$daemon_conf"
  fi
}

_cbox_audio_pulse_server() {
  if [[ "$_CBOX_RUNTIME" == "apple" ]]; then
    echo "tcp:192.168.64.1:4713"
  else
    echo "tcp:host.docker.internal:4713"
  fi
}

_cbox_audio_start() {
  _CBOX_AUDIO_STARTED=0

  command -v pulseaudio >/dev/null 2>&1 || {
    echo "⚠  CBOX_AUDIO set but PulseAudio not found — install: brew install pulseaudio"
    return 1
  }

  _cbox_audio_ensure_config

  if ! lsof -i :4713 >/dev/null 2>&1; then
    echo "Starting PulseAudio for voice mode..."
    nohup pulseaudio --daemonize=no > "${TMPDIR:-/tmp}/cbox-pulse.log" 2>&1 &
    disown
    _CBOX_AUDIO_STARTED=1

    local _i
    for _i in $(seq 1 20); do
      sleep 0.3
      lsof -i :4713 >/dev/null 2>&1 && break
    done

    if ! lsof -i :4713 >/dev/null 2>&1; then
      echo "⚠  PulseAudio did not start — check ${TMPDIR:-/tmp}/cbox-pulse.log"
      return 1
    fi
  fi

  # module-suspend-on-idle parks sources after a few seconds; voice mode needs
  # the mic source to stay active, so unload it whenever PulseAudio is running.
  PULSE_SERVER=tcp:localhost:4713 pactl unload-module module-suspend-on-idle 2>/dev/null || true
}

_cbox_audio_stop() {
  [[ "${_CBOX_AUDIO_STARTED:-0}" == "1" ]] || return 0
  echo "Stopping PulseAudio..."
  pulseaudio --kill 2>/dev/null || true
  _CBOX_AUDIO_STARTED=0
}

# ---------------------------------------------------------
# MCP relay
# ---------------------------------------------------------
#
# Host MCP servers (anything that needs macOS: iMCP, Keychain, local apps) are
# configured in $CBOX_MCP_CONFIG and reach the container without any network
# listener — on the host or in the container:
#
#   claude ─stdio─▶ cbox-mcp-relay connect NAME ─unix socket─▶ cbox-mcp-relay accept NAME
#                   (in container)                             (in container)
#                                                                     │ stdio over `container exec -i`
#   host: relay supervisor ◀──────────────────────────────────────────┘
#         └─ starts the server command when a client connects and pipes both ways
#
# The supervisor keeps $_CBOX_MCP_SLOTS pending `accept`s per server, so that
# many concurrent clients (sessions) per container are served. Each connection
# gets a fresh server process, exactly like a native stdio MCP server. Bytes are
# passed through untouched — there is no protocol translation.
#
# Servers that work on file paths (filesystem, git, …) do not belong here: they
# would see host paths, not /Workspace. Run those inside the container instead
# (project .mcp.json or `claude mcp add`).

# Host-side logic: claude.json generation, the relay supervisor, `cbox mcp`.
# Emitted by a function (not stored in a variable) so the heredoc parses the
# same in bash 3.2 and zsh. Run as: python3 -c "$(_cbox_mcp_py)" <command> ...
_cbox_mcp_py() {
  cat <<'PYEOF'
import json, os, re, select, signal, subprocess, sys, threading, time
from urllib.parse import urlsplit

NAME_RE = re.compile(r"^[A-Za-z0-9_.-]{1,64}$")
LOCAL_HOSTS = ("localhost", "127.0.0.1", "::1", "0.0.0.0")
MARKER = b"\x01"  # sent by `accept` once a client has connected


def load_servers(path, warn=True):
    try:
        with open(path) as f:
            data = json.load(f)
    except FileNotFoundError:
        return {}
    except (OSError, ValueError) as e:
        if warn:
            print(f"⚠  {path} is not valid JSON ({e}) — host MCP servers skipped")
        return {}
    servers = data.get("mcpServers") if isinstance(data, dict) else None
    return servers if isinstance(servers, dict) else {}


def kind(cfg):
    """stdio: run on the host via the relay. remote: URL the container reaches
    directly. local-url: URL on the host's loopback — not reachable, unsupported."""
    if not isinstance(cfg, dict):
        return "invalid"
    if cfg.get("command"):
        return "stdio"
    url = cfg.get("url")
    if isinstance(url, str) and url:
        host = (urlsplit(url).hostname or "").lower()
        return "local-url" if host in LOCAL_HOSTS else "remote"
    return "invalid"


def relay_servers(path):
    return {n: c for n, c in load_servers(path, warn=False).items()
            if NAME_RE.match(n) and kind(c) == "stdio"}


def is_macos_path(cmd):
    cmd = str(cmd)
    return (cmd.startswith(("/Applications/", "~/Applications/", "~/Library/"))
            or re.match(r"^/Users/[^/]+/(Applications|Library)/", cmd) is not None
            or ".app/Contents/" in cmd)


def is_legacy(cfg, relay):
    """Entries written by earlier cbox versions: the supergateway proxy design
    (HTTP on the host gateway) or its fallback of a raw macOS command, which
    cannot run in the Linux container anyway."""
    if not isinstance(cfg, dict):
        return False
    if cfg.get("command") == relay:
        return True
    url = cfg.get("url")
    if isinstance(url, str) and re.match(
            r"^http://(192\.168\.64\.1|host\.docker\.internal):\d+/mcp$", url):
        return True
    return is_macos_path(cfg.get("command", ""))


# --- claude-json ------------------------------------------------------------

def cmd_claude_json(project_file, name, config, managed_file, relay, mode):
    try:
        with open(project_file) as f:
            project = json.load(f)
    except (FileNotFoundError, ValueError):
        project = {}
    try:
        with open(managed_file) as f:
            managed_before = set(json.load(f))
    except (FileNotFoundError, ValueError, TypeError):
        managed_before = set()

    existing = project.get("mcpServers")
    servers = dict(existing) if isinstance(existing, dict) else {}

    # Drop everything cbox wrote earlier; servers the user added inside the
    # container (`claude mcp add`) are left alone.
    for sname in list(servers):
        if sname in managed_before or is_legacy(servers[sname], relay):
            del servers[sname]

    managed_now = []
    if mode != "safe":
        for sname, cfg in load_servers(config).items():
            k = kind(cfg)
            if not NAME_RE.match(sname):
                print(f"⚠  MCP server '{sname}': name may only contain letters, digits, '.', '_' and '-' — skipped")
            elif k == "stdio":
                servers[sname] = {"type": "stdio", "command": relay, "args": ["connect", sname]}
                managed_now.append(sname)
            elif k == "remote":
                servers[sname] = cfg
                managed_now.append(sname)
            elif k == "local-url":
                print(f"⚠  MCP server '{sname}': URLs on the host's localhost are not reachable from the container — skipped")
            else:
                print(f"⚠  MCP server '{sname}': needs a \"command\" or a \"url\" — skipped")

    if servers or existing is not None:
        project["mcpServers"] = servers

    project["hasCompletedOnboarding"] = True
    project["installMethod"] = "npm"
    project.setdefault("projects", {}).setdefault(
        f"/Workspace/{name}", {}
    )["hasTrustDialogAccepted"] = True

    with open(project_file, "w") as f:
        json.dump(project, f)
    with open(managed_file, "w") as f:
        json.dump(sorted(managed_now), f)


# --- supervise --------------------------------------------------------------

NO_ANSWER_HINT = (
    "{name}: no response from the server {secs}s after a client connected. "
    "Servers that find their app via Bonjour, like iMCP, need Local Network access "
    "(System Settings → Privacy & Security → Local Network → enable the server, "
    "e.g. imcp-server, and its app), and only one Mac on the network may run iMCP."
)


def log(msg, warn=False):
    print(time.strftime("%Y-%m-%d %H:%M:%S"), "WARN" if warn else "INFO", msg, flush=True)


def pump(src, dst, first_data=None):
    """Copy bytes until EOF or error, then close dst so the peer sees EOF."""
    try:
        while True:
            data = os.read(src.fileno(), 65536)
            if not data:
                break
            if first_data is not None:
                first_data.set()
            while data:
                data = data[os.write(dst.fileno(), data):]
    except (OSError, ValueError):
        pass
    finally:
        try:
            dst.close()
        except OSError:
            pass


def finish(proc, grace=5.0):
    try:
        proc.wait(timeout=grace)
    except subprocess.TimeoutExpired:
        proc.terminate()
        try:
            proc.wait(timeout=grace)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()


def close(f):
    try:
        f.close()
    except OSError:
        pass


def serve(sname, cfg, ex, hint_after):
    """One client connection. Ends — and takes the server with it — as soon as
    either the exec process (the client's side) or the server exits."""
    env = dict(os.environ)
    env.update({str(k): str(v) for k, v in (cfg.get("env") or {}).items()})
    argv = [os.path.expanduser(str(cfg["command"]))] + [str(a) for a in (cfg.get("args") or [])]
    try:
        srv = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                               stderr=sys.stdout, env=env, bufsize=0,
                               cwd=os.path.expanduser("~"))
    except OSError as e:
        log(f"{sname}: cannot start {argv[0]}: {e}", warn=True)
        close(ex.stdin)
        finish(ex, grace=2)
        return
    log(f"{sname}: client connected — server started (pid {srv.pid})")
    answered = threading.Event()
    up = threading.Thread(target=pump, args=(ex.stdout, srv.stdin), daemon=True)
    down = threading.Thread(target=pump, args=(srv.stdout, ex.stdin, answered), daemon=True)
    up.start()
    down.start()

    # Watch the processes, not the pipes: EOF on the exec process's stdout does
    # not reliably cross `container exec` while the in-container side is alive,
    # but the in-container `accept` exits as soon as its client is gone.
    connected = time.time()
    hinted = False
    while ex.poll() is None and srv.poll() is None:
        if not hinted and not answered.is_set() and time.time() - connected >= hint_after:
            log(NO_ANSWER_HINT.format(name=sname, secs=int(hint_after)), warn=True)
            hinted = True
        time.sleep(0.2)

    if srv.poll() is not None:
        # Server ended: deliver its last output, then let the client see EOF.
        down.join(2)
        close(ex.stdin)
        finish(ex, grace=2)
        if answered.is_set():
            log(f"{sname}: server exited ({srv.returncode}) — client disconnected")
        else:
            log(f"{sname}: server exited ({srv.returncode}) without answering", warn=True)
    else:
        # Client gone: stop the server, however stuck it is.
        close(srv.stdin)
        finish(srv, grace=2)
        if answered.is_set():
            log(f"{sname}: client disconnected — server exited ({srv.returncode})")
        else:
            log(f"{sname}: client gave up before the server answered — server stopped", warn=True)
    up.join(1)
    down.join(1)


def slot(stop, runtime, box, config, relay, sname, hint_after):
    """Keeps one `accept` pending in the container. Each connection is handed
    to its own thread, so the slot is ready again right away."""
    fails = 0
    while not stop.is_set():
        cfg = relay_servers(config).get(sname)
        if cfg is None:
            return  # removed from config
        try:
            ex = subprocess.Popen([runtime, "exec", "-i", box, relay, "accept", sname],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=sys.stdout, bufsize=0)
        except OSError as e:
            log(f"{sname}: cannot run {runtime}: {e}", warn=True)
            stop.wait(30)
            continue
        # Blocks until a client connects in the container.
        try:
            marker = os.read(ex.stdout.fileno(), 1)
        except OSError:
            marker = b""
        if marker != MARKER:
            # Container stopped, relay missing, or exec failed: back off.
            close(ex.stdin)
            finish(ex, grace=1)
            fails += 1
            if fails == 1:
                log(f"{sname}: relay endpoint unavailable in '{box}' (exit {ex.returncode}) — retrying", warn=True)
            stop.wait(min(30, 2 ** min(fails, 5)))
            continue
        fails = 0
        threading.Thread(target=serve, args=(sname, cfg, ex, hint_after), daemon=True).start()


def cmd_supervise(runtime, box, config, relay, slots, hint_after, pidfile):
    try:
        os.setsid()  # own process group, so stop can kill every child at once
    except OSError:
        pass  # already a group leader
    with open(pidfile, "w") as f:
        f.write(str(os.getpid()))
    stop = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    log(f"relay supervisor started for '{box}' (pid {os.getpid()})")
    workers = {}
    try:
        while not stop.is_set():
            # Re-read the config so servers added later need no restart.
            for sname in relay_servers(config):
                alive = [t for t in workers.get(sname, []) if t.is_alive()]
                while len(alive) < int(slots):
                    t = threading.Thread(target=slot, daemon=True,
                                         args=(stop, runtime, box, config, relay, sname,
                                               float(hint_after)))
                    t.start()
                    alive.append(t)
                workers[sname] = alive
            stop.wait(2)
    finally:
        log("relay supervisor stopped")
        try:
            os.remove(pidfile)
        except OSError:
            pass
        # Slot threads may still be blocked on children; a normal interpreter
        # shutdown would race them. The process group is being killed anyway.
        os._exit(0)


# --- has-relay-servers ------------------------------------------------------

def cmd_has_relay_servers(config):
    sys.exit(0 if relay_servers(config) else 1)


# --- list -------------------------------------------------------------------

def describe(cfg):
    k = kind(cfg)
    if k == "stdio":
        return " ".join([str(cfg["command"])] + [str(a) for a in (cfg.get("args") or [])])
    return str(cfg.get("url", "")) if isinstance(cfg, dict) else ""


def shown(path):
    home = os.path.expanduser("~")
    return "~" + path[len(home):] if path.startswith(home + os.sep) else path


LOG_RE = re.compile(r"^(\S+ \S+) (INFO|WARN) ([A-Za-z0-9_.-]+): (.*)$")


def recent_problems(logfile):
    """Per server: the warnings logged since its last normal event, so a later
    successful connection clears them."""
    problems = {}
    try:
        with open(logfile, errors="replace") as f:
            lines = f.read().splitlines()
    except OSError:
        return problems
    for line in lines:
        m = LOG_RE.match(line)
        if not m:
            continue
        stamp, level, sname, msg = m.groups()
        if level == "WARN":
            problems.setdefault(sname, []).append(f"{stamp[11:16]} {msg}")
        else:
            problems.pop(sname, None)
    return problems


def cmd_list(config, logfile=""):
    shown_config = shown(config)
    problems = recent_problems(logfile) if logfile else {}
    servers = load_servers(config)
    if not servers:
        print(f"No host MCP servers configured ({shown_config}).")
        print("  Import from Claude Desktop / Claude Code:  cbox mcp import")
        print("  Or add them by hand, in the usual format:")
        print('    { "mcpServers": { "imcp": { "command": "/Applications/iMCP.app/Contents/MacOS/imcp-server" } } }')
        return
    print(f"Host MCP servers ({shown_config}):")
    width = max(len(n) for n in servers)
    for sname, cfg in servers.items():
        k = kind(cfg)
        if not NAME_RE.match(sname):
            mark, label = "✘", "invalid name"
        elif k == "stdio":
            mark, label = "✔", "host  "
        elif k == "remote":
            mark, label = "✔", "remote"
        elif k == "local-url":
            mark, label = "✘", "localhost URL, not supported"
        else:
            mark, label = "✘", "needs \"command\" or \"url\""
        print(f"  {mark} {sname.ljust(width)}  {label}  {describe(cfg)}")
        for problem in problems.get(sname, [])[-2:]:
            print(f"      ⚠ {problem}")


# --- import -----------------------------------------------------------------

def cmd_import(config):
    shown_config = shown(config)
    home = os.path.expanduser("~")
    sources = [
        ("Claude Desktop", os.path.join(home, "Library", "Application Support", "Claude",
                                        "claude_desktop_config.json")),
        ("Claude Code", os.path.join(home, ".claude.json")),
    ]
    candidates = []  # (name, cfg, source)
    seen = set(load_servers(config))
    for label, path in sources:
        try:
            with open(path) as f:
                data = json.load(f)
        except (OSError, ValueError):
            continue
        found = dict(data.get("mcpServers") or {})
        # Claude Code also keeps servers per project (local scope).
        for proj in (data.get("projects") or {}).values():
            if isinstance(proj, dict):
                for n, c in (proj.get("mcpServers") or {}).items():
                    found.setdefault(n, c)
        for n, c in found.items():
            if n not in seen and kind(c) in ("stdio", "remote") and NAME_RE.match(n):
                seen.add(n)
                candidates.append((n, c, label))

    if not candidates:
        print("Nothing new to import from Claude Desktop or Claude Code.")
        return

    interactive = sys.stdin.isatty()
    if not interactive:
        print("Servers available for import (run in a terminal to choose):")
    else:
        print("Host MCP servers run on your Mac. Servers that work on files or")
        print("repositories (filesystem, git, …) belong inside the container instead.")
        print()
    chosen = {}
    for n, c, label in candidates:
        native = kind(c) == "stdio" and is_macos_path(c.get("command", ""))
        line = f"'{n}' from {label}: {describe(c)}"
        if not interactive:
            print(f"  {line}")
            continue
        hint = "Y/n" if native else "y/N"
        try:
            answer = input(f"Import {line}? [{hint}] ").strip().lower()
        except EOFError:
            answer = ""
        if answer in ("y", "yes") or (answer == "" and native):
            chosen[n] = c

    if not chosen:
        return
    try:
        with open(config) as f:
            data = json.load(f)
        if not isinstance(data, dict):
            raise ValueError("not a JSON object")
    except FileNotFoundError:
        data = {}
    except (OSError, ValueError) as e:
        print(f"✘ {shown_config} is not valid JSON ({e}) — fix it first, nothing imported")
        sys.exit(1)
    data.setdefault("mcpServers", {}).update(chosen)
    os.makedirs(os.path.dirname(config), exist_ok=True)
    # May hold API tokens in "env".
    fd = os.open(config, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    print(f"✔ Imported {', '.join(chosen)} into {shown_config}")
    print("  Takes effect with the next cbox session.")


# --- legacy-cleanup ---------------------------------------------------------

def cmd_legacy_cleanup(portmap_file, native_index):
    """Stop supergateway proxies left by earlier cbox versions — they listen on
    every interface without authentication."""
    try:
        with open(portmap_file) as f:
            portmap = json.load(f)
    except (OSError, ValueError):
        portmap = {}
    for info in (portmap.values() if isinstance(portmap, dict) else []):
        try:
            os.killpg(os.getpgid(int(info.get("pid", 0))), signal.SIGTERM)
        except (OSError, ValueError, TypeError, AttributeError):
            pass
    for path in (portmap_file, native_index):
        try:
            os.remove(path)
        except OSError:
            pass


COMMANDS = {
    "claude-json": cmd_claude_json,
    "supervise": cmd_supervise,
    "has-relay-servers": cmd_has_relay_servers,
    "list": cmd_list,
    "import": cmd_import,
    "legacy-cleanup": cmd_legacy_cleanup,
}

if __name__ == "__main__":
    COMMANDS[sys.argv[1]](*sys.argv[2:])
PYEOF
}

# Container-side relay, installed as $_CBOX_MCP_RELAY at every session start so
# it always matches the host side. Only needs python3 from the image.
_cbox_mcp_relay_py() {
  cat <<'PYEOF'
#!/usr/bin/env python3
# cbox-mcp-relay — installed by cbox at session start; local edits are overwritten.
#   connect NAME  stdio command for Claude: reach host MCP server NAME
#   accept NAME   run by the host over `container exec -i`; serves one client
import glob, os, select, signal, socket, sys, time

BASE = os.environ.get("CBOX_MCP_SOCKET_DIR", "/tmp/cbox-mcp")
ACK = b"\x06"     # accept → client: this slot is yours
MARKER = b"\x01"  # accept → host: a client connected, start the server
DRAIN_SECONDS = 2  # accept: server output still forwarded after the client stops sending


def write_all(fd, data):
    while data:
        data = data[os.write(fd, data):]


def pump(in_fd, out_fd, sock, half_close):
    """in_fd → sock and sock → out_fd.
    connect (half_close) passes EOF on its input on and ends when the socket
    does. accept ends on EOF from either side — its process exiting is what
    tells the host the connection is over, since EOF alone does not cross
    `container exec`. After the client stops sending, the server's output is
    still forwarded for up to DRAIN_SECONDS, or until it fails because the
    client is gone entirely."""
    readers = [in_fd, sock]
    deadline = None
    try:
        while True:
            timeout = None if deadline is None else max(0, deadline - time.time())
            ready, _, _ = select.select(readers, [], [], timeout)
            if not ready:
                return  # drain time is up
            if in_fd in ready:
                data = os.read(in_fd, 65536)
                if data:
                    sock.sendall(data)
                elif half_close:
                    sock.shutdown(socket.SHUT_WR)
                    readers.remove(in_fd)
                else:
                    return
            if sock in ready:
                data = sock.recv(65536)
                if data:
                    write_all(out_fd, data)
                elif half_close:
                    return
                else:
                    os.close(out_fd)  # reaches the server where the runtime passes EOF on
                    readers.remove(sock)
                    deadline = time.time() + DRAIN_SECONDS
    except OSError:
        return
    finally:
        sock.close()


def accept(name):
    d = os.path.join(BASE, name)
    os.makedirs(d, mode=0o700, exist_ok=True)
    path = os.path.join(d, f"{os.getpid()}.sock")
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        srv.bind(path)
        os.chmod(path, 0o600)
        srv.listen(1)
        while True:
            ready, _, _ = select.select([srv, 0], [], [])
            if 0 in ready:
                return 0  # host went away before a client came
            if srv in ready:
                conn, _ = srv.accept()
                break
    finally:
        srv.close()
        try:
            os.unlink(path)
        except OSError:
            pass
    try:
        conn.sendall(ACK)
    except OSError:
        return 0
    write_all(1, MARKER)
    pump(0, 1, conn, half_close=False)
    return 0


def connect(name):
    d = os.path.join(BASE, name)
    deadline = time.time() + 15
    while True:
        for path in sorted(glob.glob(os.path.join(d, "*.sock"))):
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(3)
            try:
                s.connect(path)
                ok = s.recv(1) == ACK
            except ConnectionRefusedError:
                ok = False
                try:
                    os.unlink(path)  # no listener: left over from a killed accept
                except OSError:
                    pass
            except OSError:
                ok = False
            if ok:
                s.settimeout(None)
                pump(0, 1, s, half_close=True)
                return 0
            s.close()
        if time.time() > deadline:
            break
        time.sleep(0.25)
    sys.stderr.write(
        f"cbox-mcp-relay: host MCP server '{name}' is not reachable.\n"
        "It is relayed from the host by cbox: check that it is listed in\n"
        "~/.config/claudebox/mcp.json and run `cbox mcp` on the host.\n")
    return 1


if __name__ == "__main__":
    # Let finally blocks (socket cleanup) run when terminated.
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
    if len(sys.argv) != 3 or sys.argv[1] not in ("connect", "accept"):
        sys.stderr.write("usage: cbox-mcp-relay connect|accept NAME\n")
        sys.exit(2)
    sys.exit({"connect": connect, "accept": accept}[sys.argv[1]](sys.argv[2]))
PYEOF
}

_cbox_mcp_legacy_cleanup() {
  local name="$1"
  local portmap="$CBOX_DATA_DIR/.mcp-portmap-$name.json"
  local native_index="$CBOX_DATA_DIR/.mcp-native-$name.json"
  [[ -f "$portmap" || -f "$native_index" ]] || return 0
  python3 -c "$(_cbox_mcp_py)" legacy-cleanup "$portmap" "$native_index"
}

_cbox_mcp_relay_pid() {
  local pidfile="$CBOX_DATA_DIR/.mcp-relay-$1.pid"
  local pid
  [[ -f "$pidfile" ]] || return 1
  pid=$(cat "$pidfile" 2>/dev/null)
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  # Guard against pid reuse: the process must still be our supervisor.
  ps -p "$pid" -o command= 2>/dev/null | grep -q "supervise" || return 1
  echo "$pid"
}

# Installs the container-side relay and starts the host supervisor for the
# container, unless it is already running (it re-reads the config by itself).
# Failures are reported, never fatal: the session works without host MCP.
_cbox_mcp_relay_start() {
  local name="$1"
  local pidfile="$CBOX_DATA_DIR/.mcp-relay-$name.pid"
  local logfile="$CBOX_DATA_DIR/.mcp-relay-$name.log"

  _cbox_mcp_legacy_cleanup "$name"

  python3 -c "$(_cbox_mcp_py)" has-relay-servers "$CBOX_MCP_CONFIG" || return 0

  # Atomic rename: other sessions may be running the relay right now.
  # shellcheck disable=SC2016
  if ! _cbox_mcp_relay_py | $_CBOX_CMD exec -i "$name" sh -c \
      'mkdir -p "${1%/*}" && cat > "$1.tmp" && chmod 755 "$1.tmp" && mv "$1.tmp" "$1"' \
      sh "$_CBOX_MCP_RELAY" >/dev/null 2>&1; then
    echo "⚠  Could not install the MCP relay in '$name' — host MCP servers unavailable this session"
    return 0
  fi

  if _cbox_mcp_relay_pid "$name" >/dev/null; then
    return 0
  fi

  mkdir -p "$CBOX_DATA_DIR"
  rm -f "$pidfile"
  # Subshell: no job-control noise in interactive shells, and the supervisor
  # detaches into its own session so it survives the terminal.
  ( python3 -c "$(_cbox_mcp_py)" supervise \
      "$_CBOX_CMD" "$name" "$CBOX_MCP_CONFIG" "$_CBOX_MCP_RELAY" "$_CBOX_MCP_SLOTS" \
      "$_CBOX_MCP_HINT_SECONDS" "$pidfile" \
      </dev/null >"$logfile" 2>&1 & )

  local _i
  for _i in 1 2 3 4 5 6 7 8 9 10; do
    [[ -f "$pidfile" ]] && break
    sleep 0.2
  done
  if [[ -f "$pidfile" ]]; then
    _cbox_log "✔ MCP relay running (log: $logfile)"
  else
    echo "⚠  MCP relay did not start — check $logfile"
  fi
}

_cbox_mcp_relay_stop() {
  local name="$1"
  local pid
  _cbox_mcp_legacy_cleanup "$name"
  pid=$(_cbox_mcp_relay_pid "$name") || return 0
  # Negative pid: the whole process group — supervisor, exec clients, servers.
  kill -TERM -- "-$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
}

_cbox_mcp_status() {
  local name="$1"
  python3 -c "$(_cbox_mcp_py)" list "$CBOX_MCP_CONFIG" "$CBOX_DATA_DIR/.mcp-relay-$name.log"
  python3 -c "$(_cbox_mcp_py)" has-relay-servers "$CBOX_MCP_CONFIG" || return 0
  local pid
  if pid=$(_cbox_mcp_relay_pid "$name"); then
    echo "✔ relay for '$name' running (pid $pid, log: $CBOX_DATA_DIR/.mcp-relay-$name.log)"
  else
    echo "ℹ relay for '$name' not running — starts with the next cbox session"
  fi
}

# ---------------------------------------------------------
# warden
# ---------------------------------------------------------
#
# Lets code in the container use host credentials without ever holding them:
#
#   container: $WARDEN_URL/<resource>/path ──http──▶ host: warden broker
#                                                      ├─ token → container + granted resources
#                                                      ├─ policy check (allow list, no dot segments)
#                                                      ├─ secret from the Keychain, per request
#                                                      └─ forwards to the upstream with auth applied
#
# Resources are defined on the host only ($CBOX_WARDEN_DIR/resources, never
# mounted). `availability = global` gives a resource to every container;
# `project` only to repos whose tracked .warden file lists it AND whose
# current .warden the user approved on the host (approval is tied to the file's
# hash, so an edit made inside the container needs a fresh approval).
#
# The per-container token in $WARDEN_URL is not a secret from Claude: it only
# unlocks what the user already granted to this container, and it dies with the
# container's last session.

# Host-side logic: session grants, the broker, `cbox warden`.
# Run as: _cbox_warden_python <command> ...
_cbox_warden_py() {
  cat <<'PYEOF'
import base64, configparser, datetime, hashlib, hmac, http.client, http.server, json, os, re, secrets, socketserver, subprocess, sys, threading
from fnmatch import fnmatchcase
from urllib.parse import urlsplit, unquote, parse_qsl, quote, urlencode

NAME_RE = re.compile(r"^[a-z0-9][a-z0-9_-]{0,31}$")
ENV_KEY_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
AUTH_SCHEMES = ("bearer", "basic", "header:", "query:", "sigv4")
HOP = {"connection", "keep-alive", "proxy-connection", "proxy-authorization", "te", "trailer",
       "transfer-encoding", "upgrade", "host", "expect"}
CHUNK = 1 << 16
PROFILE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]{0,63}$")
PREFIX_RE = re.compile(r"^[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)*$")
PROJECT_KEYS = {"prefix"}  # settings a project's .warden may add to a resource; approval covers them
AWS_CONFIG = "/home/claude/.aws/warden-config"  # container path; written by cbox at session start
TEMPLATE = """\
# warden resources — host only, never mounted into a container.
# One section per resource; the container never sees the secret itself.
#
# [openrouter]
# type         = http
# upstream     = https://openrouter.ai/api/v1
# auth         = bearer                  # bearer | basic | header:<Name> | query:<param>
# secret       = cbox.warden.openrouter  # Keychain item (service name); set with: cbox warden secret set openrouter
# availability = global                  # global: every container | project: only repos whose .warden lists it
# allow        = POST /chat/completions, GET /models   # optional; default: everything under upstream
# env          = OPENROUTER_BASE_URL={url} OPENROUTER_API_KEY=warden
# test         = GET /models             # used by: cbox warden test openrouter
#
# [storage]                              # any S3-compatible API (AWS S3, R2, MinIO, ...)
# type         = http
# upstream     = https://<account>.r2.cloudflarestorage.com
# auth         = sigv4                   # requests are re-signed; the container gets dummy keys
# key-id       = cbox.warden.storage-id  # Keychain item with the access key ID
# secret       = cbox.warden.storage     # Keychain item with the secret access key
# region       = auto                    # optional; default: auto
# policy       = dvc                     # optional: only DVC's data layout in one bucket/prefix, no deletes
# bucket       = my-bucket               # needed by policy = dvc
# availability = project                 # the project's .warden sets the prefix:  [storage] prefix = my-project
# profile      = storage                 # AWS profile created in the container (default: the resource name)
"""


# --- helpers ----------------------------------------------------------------

def paths(d):
    return {"resources": os.path.join(d, "resources"), "approvals": os.path.join(d, "approvals.json"),
            "sessions": os.path.join(d, "sessions"), "log": os.path.join(d, "broker.log")}


def write_private(path, text):
    os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
    tmp = f"{path}.{os.getpid()}.tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(text)
    os.replace(tmp, path)


def load_json(path, default):
    try:
        with open(path) as f:
            return json.load(f)
    except (FileNotFoundError, ValueError):
        return default


def container_mounts(d, extra=()):
    """Host paths that some container can see: the dirs and files cbox mounts
    (passed in as CBOX_* environment), the targets of symlinks in the Claude
    dir (mounted at their own path, up to two levels deep, like _cbox_create),
    and the workspace of every active session."""
    found = [os.environ.get(v) for v in ("CBOX_CLAUDE_DIR", "CBOX_HOST_CONFIG_DIR", "CBOX_SHARE_DIR",
                                          "CBOX_PLAYWRIGHT_DIR", "CBOX_SSH_DIR", "CBOX_ZSHRC")]
    found += os.environ.get("CBOX_SHARED_CONFIG_PATHS", "").split("\n")
    claude = os.environ.get("CBOX_CLAUDE_DIR")
    for level in ([claude] if claude and os.path.isdir(claude) else []):
        for e in os.scandir(level):
            if e.is_symlink():
                found.append(e.path)
            elif e.is_dir():
                found += [s.path for s in os.scandir(e.path) if s.is_symlink()]
    s = paths(d)["sessions"]
    for f in os.listdir(s) if os.path.isdir(s) else []:
        found.append(load_json(os.path.join(s, f), {}).get("project") if f.endswith(".json") else None)
    return {os.path.realpath(m) for m in list(found) + list(extra) if m}


def exposure(d, extra=()):
    """(path, mount) when the warden dir or its resources file is visible inside
    a container, else None. A container that can edit them could point a
    resource at its own server and receive the secret, so warden then stays off."""
    mounts = container_mounts(d, extra)
    for target in (os.path.realpath(d), os.path.realpath(paths(d)["resources"])):
        for m in mounts:
            if target == m or target.startswith(m.rstrip("/") + "/"):
                return target, m
    return None


def exposure_message(hit):
    return (f"warden is off: {hit[0]} is visible inside containers (via {hit[1]}). "
            "Move it to a path no container mounts.")


def load_resources(d, warn=None, extra=()):
    """Valid resources from the host-only config; problems go to warn()."""
    hit = exposure(d, extra)
    if hit:
        warn and warn(exposure_message(hit))
        return {}
    cp = configparser.ConfigParser(interpolation=None, inline_comment_prefixes=("#",))
    try:
        cp.read(paths(d)["resources"])
    except configparser.Error as e:
        warn and warn(f"warden resources file is not valid: {e}")
        return {}
    out = {}
    for name in cp.sections():
        r = dict(cp[name])
        problem = validate(name, r)
        if problem:
            warn and warn(f"warden resource '{name}': {problem} — skipped")
            continue
        out[name] = r
    return out


def validate(name, r):
    if not NAME_RE.match(name):
        return "name may only contain a-z, 0-9, '_' and '-'"
    if r.get("type", "http") != "http":
        return f"type '{r.get('type')}' is not supported yet"
    up = urlsplit(r.get("upstream", ""))
    if up.scheme not in ("http", "https") or not up.netloc:
        return "upstream must be an http(s) URL"
    if not r.get("auth", "").startswith(AUTH_SCHEMES):
        return "auth must be bearer, basic, header:<Name>, query:<param> or sigv4"
    if not r.get("secret"):
        return "secret (Keychain item name) is missing"
    if r.get("availability", "global") not in ("global", "project"):
        return "availability must be global or project"
    if r["auth"] == "sigv4" and not r.get("key-id"):
        return "sigv4 needs key-id (Keychain item with the access key ID)"
    if r.get("policy", "dvc") != "dvc":
        return f"policy '{r['policy']}' is unknown (known: dvc)"
    if r.get("policy") == "dvc" and (r["auth"] != "sigv4" or not r.get("bucket")):
        return "policy = dvc needs auth = sigv4 and a bucket"
    if r.get("prefix") and not PREFIX_RE.match(r["prefix"]):
        return "prefix may only contain letters, digits, '_', '-', '.' and '/'"
    if r.get("profile") and not PROFILE_RE.match(r["profile"]):
        return "profile may only contain letters, digits, '_', '-' and '.'"
    for pair in r.get("env", "").split():
        if "=" not in pair or not ENV_KEY_RE.match(pair.split("=", 1)[0]):
            return f"env entry '{pair}' is not KEY=VALUE"
    return None


def read_secret(r, field="secret"):
    """Secret for resource r: macOS Keychain, or CBOX_WARDEN_SECRET_CMD <item>."""
    item = r[field]
    cmd = os.environ.get("CBOX_WARDEN_SECRET_CMD")
    if cmd:
        argv = [cmd, item]
    elif sys.platform == "darwin":
        argv = ["security", "find-generic-password", "-s", item, "-a", r.get("secret-account") or os.environ.get("USER", ""), "-w"]
    else:
        raise LookupError("no secret store: set CBOX_WARDEN_SECRET_CMD (a command that prints the secret for an item name)")
    p = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10)
    value = p.stdout.decode().rstrip("\n")
    if p.returncode != 0 or not value:
        raise LookupError(f"secret '{item}' not found — set it with: cbox warden secret set <name>")
    return value


def project_file(project):
    return os.path.join(project, ".warden")


def project_request(project):
    """({resource name: project settings}, sha256) from the project's .warden, or ({}, None)."""
    try:
        with open(project_file(project), "rb") as f:
            raw = f.read()
    except FileNotFoundError:
        return {}, None
    cp = configparser.ConfigParser(interpolation=None, inline_comment_prefixes=("#",))
    try:
        cp.read_string(raw.decode())
    except (configparser.Error, UnicodeDecodeError):
        return None, hashlib.sha256(raw).hexdigest()
    return {n: dict(cp[n]) for n in cp.sections()}, hashlib.sha256(raw).hexdigest()


def with_project(name, r, settings):
    """Resource r narrowed by the project's settings, or (None, problem). A project
    may only add PROJECT_KEYS; a prefix must stay inside the resource's own prefix."""
    extra = set(settings) - PROJECT_KEYS
    if extra:
        return None, f".warden sets {', '.join(sorted(extra))} for '{name}' — only {', '.join(sorted(PROJECT_KEYS))} is allowed"
    out = dict(r)
    want = settings.get("prefix", "").strip("/")
    if want:
        base = r.get("prefix", "").strip("/")
        if not PREFIX_RE.match(want) or ".." in want.split("/") or "." in want.split("/"):
            return None, f".warden prefix for '{name}' is not a plain path"
        if base and want != base and not want.startswith(base + "/"):
            return None, f".warden prefix for '{name}' is outside the resource's prefix '{base}'"
        out["prefix"] = want
    if out.get("policy") == "dvc" and not out.get("prefix", "").strip("/"):
        return None, f"'{name}' needs a prefix (set it in .warden:  [{name}] prefix = <folder>)"
    return out, None


def describe(r):
    """One line for listings and the approval prompt."""
    scope = f", bucket {r['bucket']}" if r.get("bucket") else ""
    scope += f", prefix {r['prefix']}" if r.get("prefix") else ""
    return f"{r['upstream']} ({r.get('availability', 'global')}{scope})"


def err(msg):
    sys.stderr.write(msg + "\n")


# --- session: decide grants, issue token, print container env ---------------

def ask(question):
    if not sys.stdin.isatty():
        return False
    sys.stderr.write(question)
    sys.stderr.flush()
    return sys.stdin.readline().strip().lower() in ("y", "yes")


def approve(d, project, interactive):
    """True if the project's current .warden is approved (asking if allowed)."""
    names, digest = project_request(project)
    if digest is None:
        return True
    if names is None:
        err(f"⚠  {project_file(project)} is not valid INI — project resources skipped")
        return False
    approvals = load_json(paths(d)["approvals"], {})
    if approvals.get(project) == digest:
        return True
    resources = load_resources(d)
    err(f"This project asks warden for: (from {project_file(project)})")
    for n, settings in names.items():
        r, problem = with_project(n, resources[n], settings) if n in resources else (None, "not configured on this machine")
        err(f"  • {n}: " + (describe(r) if r else problem))
    if not interactive or not ask("Allow these for this project? [y/N] "):
        err("ℹ  Not approved — project resources stay off. Approve later with: cbox warden approve")
        return False
    approvals[project] = digest
    write_private(paths(d)["approvals"], json.dumps(approvals, indent=2, sort_keys=True) + "\n")
    return True


def cmd_session(d, box, project, base_url, interactive):
    p = paths(d)
    hit = exposure(d, extra=[project])
    if hit:
        err("⚠  " + exposure_message(hit))
        return
    resources = load_resources(d, warn=err)
    # A global resource that still needs a project setting (a dvc prefix) waits for a .warden.
    granted = {n: {} for n, r in resources.items()
               if r.get("availability", "global") == "global" and not with_project(n, r, {})[1]}
    names, _ = project_request(project)
    if names and approve(d, project, interactive == "1"):
        for n, settings in names.items():
            if n not in resources:
                err(f"⚠  .warden asks for '{n}', which is not configured in {p['resources']}")
                continue
            r, problem = with_project(n, resources[n], settings)
            if problem:
                err(f"⚠  {problem} — skipped")
            else:
                granted[n] = settings
    sess_path = os.path.join(p["sessions"], f"{box}.json")
    token = load_json(sess_path, {}).get("token") or secrets.token_urlsafe(24)
    write_private(sess_path, json.dumps({"token": token, "box": box, "project": project,
                                         "resources": sorted(granted), "settings": granted}, indent=2) + "\n")
    url = f"{base_url}/w/{token}"
    print(f"WARDEN_URL={url}")
    profiles = []
    for n in sorted(granted):
        r = resources[n]
        for pair in r.get("env", "").split():
            print(pair.replace("{url}", f"{url}/{n}"))
        if r["auth"] == "sigv4":
            # Dummy keys: the broker drops their signature and signs with the real ones.
            profile = r.get("profile") or n
            profiles.append(("[default]" if profile == "default" else f"[profile {profile}]") +
                            f"\nendpoint_url = {url}/{n}\naws_access_key_id = warden\n"
                            f"aws_secret_access_key = warden\nregion = {r.get('region', 'auto')}\n"
                            "s3 =\n    addressing_style = path\n")
    if profiles:
        print(f"AWS_CONFIG_FILE={AWS_CONFIG}")
        print("WARDEN_AWS_CONFIG=" + base64.b64encode("\n".join(profiles).encode()).decode())


def cmd_end(d, box):
    """Forget the container's token. Exit 0 when no sessions remain."""
    s = paths(d)["sessions"]
    try:
        os.remove(os.path.join(s, f"{box}.json"))
    except FileNotFoundError:
        pass
    left = [f for f in os.listdir(s)] if os.path.isdir(s) else []
    sys.exit(0 if not any(f.endswith(".json") for f in left) else 1)


# --- broker -------------------------------------------------------------------

def log_line(d, text):
    stamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    with open(paths(d)["log"], "a") as f:
        f.write(f"{stamp} {text}\n")


def find_session(d, token):
    s = paths(d)["sessions"]
    for f in os.listdir(s) if os.path.isdir(s) else []:
        sess = load_json(os.path.join(s, f), {}) if f.endswith(".json") else {}
        if sess.get("token") and secrets.compare_digest(sess["token"], token):
            return sess
    return None


def allowed(r, method, rest):
    rules = [x.strip() for x in r.get("allow", "").split(",") if x.strip()]
    if not rules:
        return True
    for rule in rules:
        m, _, pat = rule.partition(" ")
        if fnmatchcase(method, m.strip().upper()) and fnmatchcase(rest, pat.strip()):
            return True
    return False


def apply_auth(r, headers, query, secret):
    scheme = r["auth"]
    if scheme == "bearer":
        headers["Authorization"] = f"Bearer {secret}"
    elif scheme == "basic":
        headers["Authorization"] = "Basic " + base64.b64encode(secret.encode()).decode()
    elif scheme.startswith("header:"):
        headers[scheme.split(":", 1)[1].strip()] = secret
    elif scheme.startswith("query:"):
        param = scheme.split(":", 1)[1].strip()
        query = [(k, v) for k, v in query if k != param] + [(param, secret)]
    return headers, query


def sign_v4(r, method, path, query, headers, host, key_id, secret, now=None):
    """Headers for an AWS SigV4-signed request (S3 rules: the path is signed as
    sent, the payload hash comes from the client or is UNSIGNED-PAYLOAD)."""
    region, service = r.get("region", "auto"), r.get("service", "s3")
    h = {k.lower(): v for k, v in headers.items()
         if k.lower() not in ("authorization", "x-amz-date", "x-amz-security-token")}
    h["host"] = host
    h["x-amz-date"] = now or datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    h.setdefault("x-amz-content-sha256", "UNSIGNED-PAYLOAD")
    day = h["x-amz-date"][:8]
    scope = f"{day}/{region}/{service}/aws4_request"
    signed = sorted(k for k in h if k in ("host", "content-type", "content-md5") or k.startswith("x-amz-"))
    canon_headers = "".join(f"{k}:{' '.join(h[k].split())}\n" for k in signed)
    pairs = sorted((quote(k, safe="-_.~"), quote(v, safe="-_.~")) for k, v in parse_qsl(query, keep_blank_values=True))
    canon = "\n".join([method, path or "/", "&".join(f"{k}={v}" for k, v in pairs), canon_headers,
                       ";".join(signed), h["x-amz-content-sha256"]])
    to_sign = "\n".join(["AWS4-HMAC-SHA256", h["x-amz-date"], scope, hashlib.sha256(canon.encode()).hexdigest()])
    key = ("AWS4" + secret).encode()
    for part in (day, region, service, "aws4_request"):
        key = hmac.new(key, part.encode(), hashlib.sha256).digest()
    sig = hmac.new(key, to_sign.encode(), hashlib.sha256).hexdigest()
    h["authorization"] = (f"AWS4-HMAC-SHA256 Credential={key_id}/{scope}, "
                          f"SignedHeaders={';'.join(signed)}, Signature={sig}")
    return h


def dvc_allowed(r, method, path, query):
    """Only what DVC does with an S3 remote: content-addressed objects under
    bucket/prefix/files/md5/, listings of that tree, multipart uploads — never
    a delete. Exact shapes instead of blocklisting tricks (dot segments, encodings)."""
    if method not in ("GET", "HEAD", "PUT", "POST"):
        return False
    bucket, prefix = re.escape(r["bucket"]), re.escape(r["prefix"].strip("/"))
    if path in (f"/{r['bucket']}", f"/{r['bucket']}/"):
        listing = dict(parse_qsl(query, keep_blank_values=True)).get("prefix", "")
        return method == "GET" and re.fullmatch(
            rf"{prefix}/files/(md5/([0-9a-f]{{2}}(/([0-9a-f]{{0,30}}(\.dir)?/?)?)?)?)?", listing) is not None
    if method == "HEAD" and re.fullmatch(rf"/{bucket}/{prefix}(/files(/md5)?)?/?", path):
        return True  # "does this directory exist"
    return re.fullmatch(rf"/{bucket}/{prefix}/files/md5/[0-9a-f]{{2}}/[0-9a-f]{{30}}(\.dir)?", path) is not None


class Broker(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "warden"
    sys_version = ""
    d = None

    def fail(self, code, msg, who="-"):
        body = json.dumps({"error": {"message": f"warden: {msg}", "code": code}}).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)
        self.close_connection = True
        log_line(self.d, f"{who} {self.command} {urlsplit(self.path).path.split('/', 3)[-1][:120]} -> {code} {msg}")

    def body_iter(self):
        if "chunked" in self.headers.get("Transfer-Encoding", "").lower():
            while True:
                size = int(self.rfile.readline().split(b";")[0].strip() or b"0", 16)
                if size == 0:
                    while self.rfile.readline() not in (b"\r\n", b"\n", b""):
                        pass
                    return
                yield self.rfile.read(size)
                self.rfile.readline()
        left = int(self.headers.get("Content-Length") or 0)
        while left > 0:
            data = self.rfile.read(min(CHUNK, left))
            if not data:
                return
            left -= len(data)
            yield data

    def handle_any(self):
        split = urlsplit(self.path)
        parts = split.path.split("/", 4)  # '', 'w', token, resource, rest
        if len(parts) < 4 or parts[1] != "w":
            return self.fail(404, "unknown path; use $WARDEN_URL/<resource>/...")
        sess = find_session(self.d, parts[2])
        if not sess:
            return self.fail(403, "unknown or expired session token")
        hit = exposure(self.d)
        if hit:
            return self.fail(503, exposure_message(hit), sess.get("box", "?"))
        who, name = sess.get("box", "?"), parts[3]
        rest = "/" + (parts[4] if len(parts) > 4 else "")
        resources = load_resources(self.d)
        if name not in sess.get("resources", []) or name not in resources:
            return self.fail(403, f"resource '{name}' is not available to this container", who)
        r, problem = with_project(name, resources[name], sess.get("settings", {}).get(name, {}))
        if problem:
            return self.fail(403, problem, who)
        if ".." in unquote(unquote(rest)).split("/") or "." in unquote(unquote(rest)).split("/"):
            return self.fail(403, "dot segments are not allowed", who)
        if not allowed(r, self.command, rest) or (
                r.get("policy") == "dvc" and not dvc_allowed(r, self.command, rest, split.query)):
            return self.fail(403, f"{self.command} {rest} is not allowed for '{name}'", who)
        try:
            secret = read_secret(r)
            key_id = read_secret(r, "key-id") if r["auth"] == "sigv4" else None
        except (LookupError, OSError, subprocess.SubprocessError) as e:
            return self.fail(502, str(e), who)
        up = urlsplit(r["upstream"])
        scheme = r["auth"]
        drop = {"authorization", "x-api-key", "api-key"}
        if scheme.startswith("header:"):
            drop.add(scheme.split(":", 1)[1].strip().lower())
        headers = {k: v for k, v in self.headers.items() if k.lower() not in HOP | drop}
        if scheme == "sigv4":
            # The query is signed exactly as sent, so it is passed on untouched.
            target = up.path.rstrip("/") + rest
            headers = sign_v4(r, self.command, target, split.query, headers, up.netloc, key_id, secret)
            target += ("?" + split.query) if split.query else ""
        else:
            headers, query = apply_auth(r, headers, parse_qsl(split.query, keep_blank_values=True), secret)
            target = up.path.rstrip("/") + rest + (("?" + urlencode(query)) if query else "")
            headers["Host"] = up.netloc
        conn_cls = http.client.HTTPSConnection if up.scheme == "https" else http.client.HTTPConnection
        conn = conn_cls(up.netloc, timeout=600)
        try:
            # Bodies are streamed; without Content-Length, http.client sends them chunked.
            has_body = "Content-Length" in self.headers or "chunked" in self.headers.get("Transfer-Encoding", "").lower()
            conn.request(self.command, target, body=self.body_iter() if has_body else None, headers=headers)
            resp = conn.getresponse()
        except (OSError, http.client.HTTPException) as e:
            conn.close()
            return self.fail(502, f"upstream {up.netloc} unreachable: {e.__class__.__name__}", who)
        log_line(self.d, f"{who} {self.command} {name}{rest[:120]} -> {resp.status}")
        self.send_response(resp.status)
        length = resp.getheader("Content-Length")
        for k, v in resp.getheaders():
            if k.lower() not in HOP and k.lower() != "content-length":
                self.send_header(k, v)
        chunked = length is None and self.command != "HEAD" and resp.status not in (204, 304)
        if length is not None:
            self.send_header("Content-Length", length)
        if chunked:
            self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()
        try:
            while True:
                data = resp.read1(CHUNK) if hasattr(resp, "read1") else resp.read(CHUNK)
                if not data:
                    break
                self.wfile.write(b"%x\r\n%s\r\n" % (len(data), data) if chunked else data)
                self.wfile.flush()
            if chunked:
                self.wfile.write(b"0\r\n\r\n")
        except OSError:
            self.close_connection = True
        finally:
            conn.close()

    do_GET = do_POST = do_PUT = do_PATCH = do_DELETE = do_HEAD = do_OPTIONS = handle_any

    def log_message(self, *a):
        pass


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def cmd_serve(d, bind, port, pidfile):
    Broker.d = d
    srv = Server((bind, int(port)), Broker)
    write_private(pidfile, f"{os.getpid()}\n")
    log_line(d, f"broker started on {bind}:{port} (pid {os.getpid()})")
    try:
        srv.serve_forever()
    finally:
        log_line(d, "broker stopped")


# --- user-facing ----------------------------------------------------------------

def cmd_list(d, project):
    p = paths(d)
    if not os.path.exists(p["resources"]):
        print("No warden resources configured.")
        print("  Create them with: cbox warden edit")
        return
    resources = load_resources(d, warn=lambda m: print("⚠  " + m))
    names, digest = project_request(project)
    approved = digest is not None and load_json(p["approvals"], {}).get(project) == digest
    for n, r in resources.items():
        avail = r.get("availability", "global")
        here = avail == "global" or (names and n in names and approved)
        note = "every container" if avail == "global" else (
            "this project (approved)" if here else "this project: listed in .warden, not approved" if names and n in names
            else "projects whose .warden lists it")
        if names and n in names:
            r = with_project(n, r, names[n])[0] or r
        scope = "".join(f", {k} {r[k]}" for k in ("bucket", "prefix") if r.get(k))
        print(f"{'✔' if here else '·'} {n:<16} {r['upstream']}  [{r['auth'].split(':')[0]}{scope}; {note}]")
    if names is None:
        print(f"⚠  {project_file(project)} is not valid INI")
    elif names and not approved:
        print("ℹ  This project's .warden is not approved yet: cbox warden approve")


def cmd_approve(d, project):
    names, digest = project_request(project)
    if digest is None:
        print(f"No .warden file in {project}")
        return
    approvals = load_json(paths(d)["approvals"], {})
    if approvals.get(project) == digest:
        print("✔ Already approved.")
        return
    approve(d, project, interactive=True)


def cmd_test(d, name):
    r = load_resources(d, warn=err).get(name)
    if not r:
        err(f"No resource '{name}' in {paths(d)['resources']}")
        sys.exit(1)
    default = f"GET /{r['bucket']}?list-type=2&max-keys=1" if r.get("bucket") else "GET /"
    method, _, path = (r.get("test") or default).partition(" ")
    try:
        secret = read_secret(r)
        key_id = read_secret(r, "key-id") if r["auth"] == "sigv4" else None
    except (LookupError, OSError, subprocess.SubprocessError) as e:
        err(f"✖ {e}")
        sys.exit(1)
    up = urlsplit(r["upstream"])
    if r["auth"] == "sigv4":
        target, _, raw_query = (up.path.rstrip("/") + path.strip()).partition("?")
        headers = sign_v4(r, method.upper(), target, raw_query, {"User-Agent": "warden-test"}, up.netloc, key_id, secret)
        target += ("?" + raw_query) if raw_query else ""
    else:
        headers, query = apply_auth(r, {"User-Agent": "warden-test"}, [], secret)
        target = up.path.rstrip("/") + path.strip() + (("?" + urlencode(query)) if query else "")
    conn = (http.client.HTTPSConnection if up.scheme == "https" else http.client.HTTPConnection)(up.netloc, timeout=30)
    try:
        conn.request(method.upper(), target, headers=headers)
        status = conn.getresponse().status
    except (OSError, http.client.HTTPException) as e:
        err(f"✖ {name}: {up.netloc} unreachable ({e.__class__.__name__})")
        sys.exit(1)
    print(f"{'✔' if status < 400 else '✖'} {name}: {method.upper()} {path.strip()} → HTTP {status}")
    sys.exit(0 if status < 400 else 1)


def cmd_template(d):
    """Create the resources file from the template if missing. A symlink is kept
    and its target created, so the file can live in a dotfiles repo."""
    path = paths(d)["resources"]
    real = os.path.realpath(path)
    if not os.path.exists(real):
        write_private(real, TEMPLATE)
    print(path)


def cmd_ensure(d, name):
    """Add resource `name` (settings as INI lines on stdin) unless it already
    exists. For companion tools on the host (flux); never overwrites."""
    hit = exposure(d)
    if hit:
        err("✖ " + exposure_message(hit))
        sys.exit(1)
    path = os.path.realpath(paths(d)["resources"])
    cp = configparser.ConfigParser(interpolation=None, inline_comment_prefixes=("#",))
    try:
        cp.read(path)
    except configparser.Error as e:
        err(f"✖ warden resources file is not valid: {e}")
        sys.exit(1)
    if cp.has_section(name):
        print(f"✔ warden resource '{name}' is already configured")
        return
    body = sys.stdin.read().strip()
    new = configparser.ConfigParser(interpolation=None, inline_comment_prefixes=("#",))
    try:
        new.read_string(f"[{name}]\n{body}\n")
    except configparser.Error as e:
        err(f"✖ resource '{name}' is not valid INI: {e}")
        sys.exit(1)
    problem = validate(name, dict(new[name]))
    if problem:
        err(f"✖ resource '{name}': {problem}")
        sys.exit(1)
    current = open(path).read() if os.path.exists(path) else TEMPLATE
    write_private(path, current.rstrip("\n") + f"\n\n[{name}]\n{body}\n")
    print(f"✔ added warden resource '{name}' to {paths(d)['resources']}")


def cmd_exposed(d, path):
    """Exit 0 (printing the mount) when path is visible inside a container."""
    real = os.path.realpath(os.path.expanduser(path))
    for m in sorted(container_mounts(d)):
        if real == m or real.startswith(m.rstrip("/") + "/"):
            print(m)
            sys.exit(0)
    sys.exit(1)


COMMANDS = {
    "ensure": lambda a: cmd_ensure(*a),
    "exposed": lambda a: cmd_exposed(*a),
    "session": lambda a: cmd_session(*a),
    "end": lambda a: cmd_end(*a),
    "serve": lambda a: cmd_serve(*a),
    "list": lambda a: cmd_list(*a),
    "approve": lambda a: cmd_approve(*a),
    "test": lambda a: cmd_test(*a),
    "template": lambda a: cmd_template(*a),
}

if __name__ == "__main__":
    COMMANDS[sys.argv[1]](sys.argv[2:])
PYEOF
}

# Runs the warden logic with the paths cbox mounts into containers, so it can
# refuse to work when its own files would be visible inside one.
_cbox_warden_env() {
  _CBOX_WARDEN_ENV=(
    "CBOX_CLAUDE_DIR=$CBOX_CLAUDE_DIR" "CBOX_HOST_CONFIG_DIR=$CBOX_HOST_CONFIG_DIR"
    "CBOX_SHARE_DIR=$CBOX_SHARE_DIR" "CBOX_PLAYWRIGHT_DIR=$CBOX_PLAYWRIGHT_DIR"
    "CBOX_SSH_DIR=${CBOX_SSH_DIR:-}" "CBOX_ZSHRC=${CBOX_ZSHRC:-}"
    "CBOX_SHARED_CONFIG_PATHS=$(_cbox_shared_config_names | sed "s|^|${XDG_CONFIG_HOME:-$HOME/.config}/|")"
  )
}

_cbox_warden_python() {
  _cbox_warden_env
  env "${_CBOX_WARDEN_ENV[@]}" python3 -c "$(_cbox_warden_py)" "$@"
}

_cbox_warden_enabled() {
  [[ -f "$CBOX_WARDEN_DIR/resources" ]]
}

# Address on which the host is reachable from containers. The broker binds only
# there — not on all interfaces — so it is not exposed to the local network.
_cbox_warden_host_ip() {
  if [[ -n "${CBOX_WARDEN_HOST:-}" ]]; then
    echo "$CBOX_WARDEN_HOST"
  elif [[ "$_CBOX_RUNTIME" == "apple" ]]; then
    echo "192.168.64.1"
  else
    ip -4 -o addr show docker0 2>/dev/null | awk '{sub(/\/.*/, "", $4); print $4; exit}' | grep . || echo "172.17.0.1"
  fi
}

_cbox_warden_broker_pid() {
  local pid
  pid=$(cat "$CBOX_WARDEN_DIR/broker.pid" 2>/dev/null) || return 1
  [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null && echo "$pid"
}

# Identifies the broker's code and address. A running broker started by another
# cbox version (e.g. before brew upgrade) would keep serving old rules, so it is
# restarted; sessions live in files, so running containers keep their access.
_cbox_warden_broker_id() {
  { _cbox_warden_py; echo "$1:$CBOX_WARDEN_PORT"; } | cksum | cut -d' ' -f1
}

_cbox_warden_broker_start() {
  local ip pidfile="$CBOX_WARDEN_DIR/broker.pid" idfile="$CBOX_WARDEN_DIR/broker.id" _i id
  ip=$(_cbox_warden_host_ip)
  id=$(_cbox_warden_broker_id "$ip")
  if _cbox_warden_broker_pid >/dev/null; then
    [[ "$(cat "$idfile" 2>/dev/null)" == "$id" ]] && return 0
    _cbox_log "ℹ  restarting the warden broker (cbox was updated)"
    _cbox_warden_broker_stop
  fi
  rm -f "$pidfile"
  _cbox_warden_env
  nohup env "${_CBOX_WARDEN_ENV[@]}" python3 -c "$(_cbox_warden_py)" serve \
    "$CBOX_WARDEN_DIR" "$ip" "$CBOX_WARDEN_PORT" "$pidfile" >>"$CBOX_WARDEN_DIR/broker.log" 2>&1 &
  local launcher=$!
  disown 2>/dev/null || true
  # The broker writes its pid file once it listens. A cold python3 on macOS can
  # take seconds to get there, so wait while it is still alive (up to 15s) and
  # give up early only when it has died (a zombie counts as dead).
  for ((_i = 0; _i < 75; _i++)); do
    if _cbox_warden_broker_pid >/dev/null; then
      printf '%s\n' "$id" > "$idfile"
      _cbox_log "✔ warden broker running on $ip:$CBOX_WARDEN_PORT"
      return 0
    fi
    [[ "$(ps -o stat= -p "$launcher" 2>/dev/null)" =~ ^[^Z] ]] || break
    sleep 0.2
  done
  echo "⚠  warden broker did not start — check $CBOX_WARDEN_DIR/broker.log" >&2
  return 1
}

_cbox_warden_broker_stop() {
  local pid _i
  pid=$(_cbox_warden_broker_pid) || return 0
  kill "$pid" 2>/dev/null || true
  # Wait until the port is free, so a restart can bind it right away.
  for ((_i = 0; _i < 25; _i++)); do
    [[ "$(ps -o stat= -p "$pid" 2>/dev/null)" =~ ^[^Z] ]] || break
    sleep 0.2
  done
  rm -f "$CBOX_WARDEN_DIR/broker.pid" "$CBOX_WARDEN_DIR/broker.id"
}

# Prints the container's environment (KEY=VALUE lines) for this session and
# makes sure the broker runs. Approval questions go to stderr / the terminal.
_cbox_warden_start() {
  local name="$1" f box interactive=0
  _cbox_warden_enabled || return 0
  mkdir -p "$CBOX_WARDEN_DIR/sessions"
  chmod 700 "$CBOX_WARDEN_DIR" "$CBOX_WARDEN_DIR/sessions"
  # Forget tokens of containers whose sessions ended without cleanup.
  while IFS= read -r f; do
    box=$(basename "$f" .json)
    [[ "$box" == "$name" ]] && continue
    [[ -n "$(_cbox_session_markers "$box")" ]] || rm -f "$f"
  done < <(find "$CBOX_WARDEN_DIR/sessions" -maxdepth 1 -name '*.json' 2>/dev/null)
  [[ -t 0 ]] && interactive=1
  # Grants first: when warden is off (e.g. its files are visible in a
  # container), nothing is printed and no broker is started.
  local env_lines
  env_lines=$(_cbox_warden_python session "$CBOX_WARDEN_DIR" "$name" "$PWD" \
    "http://$(_cbox_warden_host_ip):$CBOX_WARDEN_PORT" "$interactive") || return 0
  [[ -n "$env_lines" ]] || return 0
  _cbox_warden_broker_start || return 0
  printf '%s\n' "$env_lines"
}

# The container's last session ended: drop its token, and stop the broker once
# no container has a session left.
_cbox_warden_end() {
  [[ -d "$CBOX_WARDEN_DIR/sessions" ]] || return 0
  if _cbox_warden_python end "$CBOX_WARDEN_DIR" "$1"; then
    _cbox_warden_broker_stop
  fi
}

_cbox_warden_secret_set() {
  local res="$1"
  if [[ ! "$res" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]]; then
    echo "Usage: cbox warden secret set <resource>   (a-z, 0-9, '_' and '-')"
    return 1
  fi
  if [[ "$(/usr/bin/uname)" != "Darwin" ]]; then
    echo "Storing secrets needs the macOS Keychain. On other hosts, set CBOX_WARDEN_SECRET_CMD"
    echo "to a command that prints the secret for an item name (e.g. a 'pass' or 'secret-tool' wrapper)."
    return 1
  fi
  echo "Paste the secret for '$res' (input is hidden). It is stored in the Keychain as cbox.warden.$res."
  security add-generic-password -U -s "cbox.warden.$res" -a "$USER" -l "cbox warden: $res" -w || return 1
  echo "✔ Stored. Reference it in $CBOX_WARDEN_DIR/resources with:  secret = cbox.warden.$res"
}

_cbox_warden_cmd() {
  case "${1:-}" in
    ""|list)
      _cbox_warden_python list "$CBOX_WARDEN_DIR" "$PWD"
      _cbox_warden_enabled || return 0
      local pid
      if pid=$(_cbox_warden_broker_pid); then
        echo "✔ broker running (pid $pid, $(_cbox_warden_host_ip):$CBOX_WARDEN_PORT, log: $CBOX_WARDEN_DIR/broker.log)"
      else
        echo "ℹ broker not running — starts with the next cbox session"
      fi
      ;;
    edit)
      local file
      file=$(_cbox_warden_python template "$CBOX_WARDEN_DIR") || return 1
      "${EDITOR:-vi}" "$file"
      ;;
    secret)
      [[ "${2:-}" == "set" ]] || { echo "Usage: cbox warden secret set <resource>"; return 1; }
      _cbox_warden_secret_set "${3:-}"
      ;;
    approve) _cbox_warden_python approve "$CBOX_WARDEN_DIR" "$PWD" ;;
    test)
      [[ -n "${2:-}" ]] || { echo "Usage: cbox warden test <resource>"; return 1; }
      _cbox_warden_python test "$CBOX_WARDEN_DIR" "$2"
      ;;
    log) tail -n "${2:-20}" "$CBOX_WARDEN_DIR/broker.log" 2>/dev/null || echo "No broker log yet." ;;
    # Internal, for companion tools on the host (flux):
    #   _ensure <name>  add a resource (INI lines on stdin) unless it exists
    #   _exposed <path> exit 0 when the path is visible inside a container
    _ensure|_exposed)
      [[ -n "${2:-}" ]] || { echo "Usage: cbox warden $1 <name|path>"; return 1; }
      _cbox_warden_python "${1#_}" "$CBOX_WARDEN_DIR" "$2"
      ;;
    *)
      echo "Unknown warden command: $1"
      echo "Usage: cbox warden [list|edit|secret set <resource>|approve|test <resource>|log]"
      return 1
      ;;
  esac
}

# ---------------------------------------------------------
# playwright browser cache
# ---------------------------------------------------------

# Chromium is baked into the image's /opt/ms-playwright when BUILD_PLAYWRIGHT=1,
# but a bind-mount over that path would hide it and force a fresh ~115 MB
# download on first use. So when the host directory is still empty, copy the
# image's browsers into it once.
#
# After that the cache is per-machine rather than per-container: it survives
# `cbox reset`, `cbox prune` and image rebuilds, and every project shares it.
# Without the mount, anything a container installs itself lives in that
# container's writable layer and is lost the moment the container is removed —
# so each project re-downloaded the same browsers.
#
# If the image has no baked browsers there is nothing to copy, the mount simply
# starts empty, and the first container to install playwright fills it for every
# later container on this machine.
_cbox_seed_playwright() {
  mkdir -p "$CBOX_PLAYWRIGHT_DIR"

  # Already seeded, or already filled from inside a container.
  [[ -n "$(ls -A "$CBOX_PLAYWRIGHT_DIR" 2>/dev/null)" ]] && return 0

  # Whether the image actually has browsers cannot be known without looking
  # inside it, and BUILD_PLAYWRIGHT does not answer the question: it describes
  # what the *next* build will do, and it is commonly passed inline to
  # `cbox rebuild` rather than kept in cbox.env — so it reads as unset here even
  # when the image is fully baked. Gating on it would skip the copy and let an
  # empty mount shadow browsers that are really there, which is the exact
  # failure this function exists to prevent. So always look: copying nothing
  # costs one short container run, and the empty check above means a machine
  # that does have browsers pays it only once.
  #
  # `cp -a` of the directory *contents*, tolerating an image where
  # /opt/ms-playwright exists but is empty.
  local _out
  if ! _out=$($_CBOX_CMD run --rm \
        -v "$CBOX_PLAYWRIGHT_DIR:/seed" \
        "$CBOX_IMAGE" \
        sh -c 'cp -a /opt/ms-playwright/. /seed/ 2>/dev/null || true' 2>&1); then
    echo "⚠  Could not seed the Playwright cache from the image:"
    echo "$_out" | sed 's/^/    /'
    echo "    Browsers will be downloaded inside the container on first use."
    return 0
  fi

  # Only speak up when something was actually copied — an image without baked
  # browsers is a normal, silent case.
  [[ -n "$(ls -A "$CBOX_PLAYWRIGHT_DIR" 2>/dev/null)" ]] && \
    echo "Seeded Playwright browser cache from image ($CBOX_PLAYWRIGHT_DIR)"
  return 0
}

# ---------------------------------------------------------
# container creation
# ---------------------------------------------------------

# Folder names listed in CBOX_SHARE_CONFIG, one per line (zsh does not split
# an unquoted variable, so no word splitting here).
_cbox_shared_config_names() {
  printf '%s\n' "${CBOX_SHARE_CONFIG:-}" | tr -s ' \t' '\n\n' | grep -v '^$' || true
}

# The -v values for the container's ~/.config and the folders of the real
# ~/.config shared into it read-only, one per line. Fails when the container
# would get write access to cbox's own config: cbox.env and mcp.json run on
# this Mac.
_cbox_config_mounts() {
  local real="${XDG_CONFIG_HOME:-$HOME/.config}" own dir n
  own=$(_cbox_resolve_path "$real/claudebox")
  dir=$(_cbox_resolve_path "$CBOX_HOST_CONFIG_DIR")
  if [[ "$own" == "$dir" || "$own" == "$dir"/* ]]; then
    echo "✘ CBOX_HOST_CONFIG_DIR=$CBOX_HOST_CONFIG_DIR would let code in the container change config that runs on this Mac (cbox.env, mcp.json, git)." >&2
    echo "  Remove that line from $real/claudebox/cbox.env (the default is $real/claudebox/.config)," >&2
    echo "  and share the folders you need read-only instead, e.g.: CBOX_SHARE_CONFIG=\"opencode\"" >&2
    return 1
  fi
  mkdir -p "$CBOX_HOST_CONFIG_DIR"
  echo "$CBOX_HOST_CONFIG_DIR:/home/claude/.config"
  while IFS= read -r n; do
    if [[ ! "$n" =~ ^[A-Za-z0-9._-]+$ || "$n" == "." || "$n" == ".." ]]; then
      echo "⚠  CBOX_SHARE_CONFIG: '$n' is not a folder name in $real — not shared." >&2
    elif [[ "$n" == "claudebox" ]]; then
      echo "⚠  CBOX_SHARE_CONFIG: claudebox is cbox's own config (MCP tokens) — not shared." >&2
    elif [[ ! -d "$real/$n" ]]; then
      echo "⚠  CBOX_SHARE_CONFIG: $real/$n does not exist — not shared." >&2
    else
      # The mount point, created here so the runtime does not create it as root.
      mkdir -p "$CBOX_HOST_CONFIG_DIR/$n"
      echo "$real/$n:/home/claude/.config/$n:ro"
    fi
  done < <(_cbox_shared_config_names)
  return 0
}

_cbox_create() {
  local name="$1"
  local mode="$2"

  # A new container still has the image's flux.
  rm -f "$CBOX_DATA_DIR/.flux-installed-$name"

  local config_mounts="" _cm
  if [[ "$mode" == "normal" ]]; then
    config_mounts=$(_cbox_config_mounts) || return 1
  fi

  local agent_bin
  agent_bin=$(_cbox_agent_bin)

  if [[ "$agent_bin" == "claude" ]]; then
    _cbox_generate_claude_json "$name" "$mode"
    mkdir -p "$CBOX_CLAUDE_DIR/projects"
  fi

  local claude_json="$CBOX_DATA_DIR/.claude-$name.json"

  echo "Creating $mode container '$name' ($agent_bin)..."

  local args=(
    run -d
    --name "$name"

    --label "$CBOX_LABEL"
    --label "cbox.mode=$mode"
    --label "cbox.agent=$agent_bin"

    -v "$PWD:/Workspace/$name"
    -w "/Workspace/$name"

    -e ZDOTDIR=/home/claude
    --memory="$CBOX_MEMORY"
  )

  if [[ "$agent_bin" == "claude" ]]; then
    args+=(-v "$claude_json:/home/claude/.claude.json")
  fi

  # git on the Mac runs commands named in .git/config (core.fsmonitor, filters,
  # core.sshCommand, …) and in .git/hooks — with your Keychain and SSH keys.
  # Read-only here, so code in the container cannot plant them. Git writes the
  # config by renaming a new file over it, so a config change made on the Mac
  # may only show up in the container after its next start.
  if [[ "$CBOX_PROTECT_GIT" == "1" && -d "$PWD/.git" && ! -L "$PWD/.git" ]]; then
    mkdir -p "$PWD/.git/hooks"
    [[ -f "$PWD/.git/config" ]] && args+=(-v "$PWD/.git/config:/Workspace/$name/.git/config:ro")
    args+=(-v "$PWD/.git/hooks:/Workspace/$name/.git/hooks:ro")
  fi

  if [[ -n "${CBOX_ZSHRC:-}" ]]; then
    local _zshrc_real
    _zshrc_real=$(_cbox_resolve_path "$CBOX_ZSHRC")
    [[ -f "$_zshrc_real" ]] && args+=(-v "$_zshrc_real:/home/claude/.zshrc.global:ro")
    unset _zshrc_real
  fi

  # Both modes mount the Playwright cache, so it must exist (and be seeded)
  # before either branch adds it — a missing host path would be created
  # root-owned by the runtime.
  _cbox_seed_playwright

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
    mkdir -p "$CBOX_SHARE_DIR"
    args+=(
      -v "$CBOX_CLAUDE_DIR:/home/claude/.claude"
      -v "$CBOX_SHARE_DIR:/home/claude/share"
      -v "$CBOX_PLAYWRIGHT_DIR:/opt/ms-playwright"
    )
    while IFS= read -r _cm; do
      [[ -n "$_cm" ]] && args+=(-v "$_cm")
    done <<<"$config_mounts"
  fi

  if [[ "$mode" == "safe" ]]; then
    _cbox_create_network
    args+=(
      --network cbox-bridge
      --cap-drop=ALL
      --cpus=2
      -v "$CBOX_CLAUDE_DIR:/home/claude/.claude:ro"
      # Read-only for the same reason .claude is: safe mode must not be able to
      # write host state shared with every other container. Baked browsers still
      # work; a playwright self-install inside the container will fail, which is
      # the intended trade-off for this mode.
      -v "$CBOX_PLAYWRIGHT_DIR:/opt/ms-playwright:ro"
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
  # maxdepth 2 also covers symlinks one level down (e.g. output-styles/ELI5.md,
  # commands/foo.md) without recursing into large trees like projects/.
  # Targets inside an already-mounted target directory (or duplicates) are
  # skipped: Apple Container shares a file mount's parent directory, so a
  # directory mount plus file mounts inside it collapse into the file mounts
  # alone and the rest of the directory disappears. Sorting puts a parent
  # before its children.
  local _ro="" _link _target _kept _nested
  local _targets=() _mounted=()
  [[ "$mode" == "safe" ]] && _ro=":ro"
  while IFS= read -r _link; do
    _target=$(_cbox_resolve_path "$_link")
    [[ -e "$_target" ]] || continue
    [[ "$_target" == "$CBOX_CLAUDE_DIR"* ]] && continue
    [[ "$_target" == "$PWD" || "$_target" == "$PWD/"* ]] && continue
    _targets+=("$_target")
  done < <(find "$CBOX_CLAUDE_DIR" -maxdepth 2 -type l 2>/dev/null)
  while IFS= read -r _target; do
    [[ -n "$_target" ]] || continue
    _nested=0
    for _kept in ${_mounted[@]+"${_mounted[@]}"}; do
      [[ "$_target" == "$_kept" || "$_target" == "$_kept/"* ]] && { _nested=1; break; }
    done
    (( _nested )) && continue
    _mounted+=("$_target")
    args+=(-v "$_target:$_target$_ro")
  done < <(printf '%s\n' ${_targets[@]+"${_targets[@]}"} | LC_ALL=C sort)
  unset _ro _link _target _kept _nested _targets _mounted

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

  if [[ "$_CBOX_RUNTIME" == "apple" ]] && ! _cbox_system_running; then
    echo "Starting container system..."
    if [[ "${CBOX_VERBOSE:-0}" == "1" ]]; then
      container system start
    else
      container system start >/dev/null 2>&1
    fi
  fi

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
    if [[ "${CBOX_VERBOSE:-0}" == "1" ]]; then
      $_CBOX_CMD start "$name"
    else
      $_CBOX_CMD start "$name" >/dev/null
    fi
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
# companion tools at session boundaries
# ---------------------------------------------------------

# The container runs the host's own flux: copied in whenever the host's flux
# changed (e.g. after brew upgrade), so both sides agree on the repo layout.
# No rebuild, no download. Storage access inside comes from warden, so cbox
# no longer syncs flux projects on the host around the session.
_cbox_flux_install() {
  local name="$1" src sum stamp
  src=$(command -v flux 2>/dev/null) || return 0
  [[ -f "$src" ]] || return 0
  sum=$(cksum < "$src" | cut -d' ' -f1)
  stamp="$CBOX_DATA_DIR/.flux-installed-$name"
  [[ "$(cat "$stamp" 2>/dev/null)" == "$sum" ]] && return 0
  if $_CBOX_CMD exec -i --user root "$name" sh -c \
      'cat > /usr/local/bin/flux.new && chmod 755 /usr/local/bin/flux.new && mv /usr/local/bin/flux.new /usr/local/bin/flux' \
      < "$src" >/dev/null 2>&1; then
    printf '%s\n' "$sum" > "$stamp"
    _cbox_log "✔ flux in the container updated to the host's version"
  else
    echo "⚠  Could not install the host's flux in the container — it keeps its own version."
  fi
}

# The container has no git identity of its own. Commits made in it use the one
# git on the host would use for this project (global, includeIf and repo rules).
_cbox_git_identity() {
  local n e
  n=$(git -C "$PWD" config user.name 2>/dev/null) || true
  e=$(git -C "$PWD" config user.email 2>/dev/null) || true
  if [[ -n "$n" ]]; then printf 'GIT_AUTHOR_NAME=%s\nGIT_COMMITTER_NAME=%s\n' "$n" "$n"; fi
  if [[ -n "$e" ]]; then printf 'GIT_AUTHOR_EMAIL=%s\nGIT_COMMITTER_EMAIL=%s\n' "$e" "$e"; fi
  return 0
}

# ---------------------------------------------------------
# git guard: catch commands planted for git on the Mac
# ---------------------------------------------------------
# The read-only mounts cover the project's own .git/config and .git/hooks.
# Everything else git would also obey stays writable from the container:
# nested repositories, submodules (.git/modules), worktrees, .git/commondir,
# or a replaced .git. So cbox lists every git setting in the project that runs
# a command when a session starts, and warns about new ones when the last
# session ends. Nothing here runs git hooks or reads includes.

# Config keys whose value git runs as a command (or that redirect git to
# other config, hooks or a work tree). Matched on git's lowercased key names.
_CBOX_GIT_RISKY_KEYS='^(core\.(fsmonitor|sshcommand|pager|editor|askpass|hookspath|gitproxy|worktree)|sequence\.editor|diff\.external|diff\..+\.(textconv|command)|filter\..+\.(clean|smudge|process)|merge\..+\.driver|credential\.(.+\.)?helper|url\..+\.(insteadof|pushinsteadof)|include\.path|includeif\..+\.path|gpg\.(.+\.)?program|remote\..+\.(uploadpack|receivepack)|(difftool|mergetool|man|browser)\..+\.(cmd|path)|pager\..+|web\.browser|protocol\.(.+\.)?allow|uploadpack\.packobjectshook|ssh\.variant|submodule\..+\.update|extensions\.worktreeconfig)$'

# Prints "<label>|<kind>|<detail>" for each risky setting of one git dir.
_cbox_git_guard_gitdir() {
  local gd="$1" label="$2" f entry key value h
  for f in config config.worktree; do
    [[ -f "$gd/$f" ]] || continue
    while IFS= read -r -d '' entry; do
      key="${entry%%$'\n'*}"
      value=""
      [[ "$entry" == *$'\n'* ]] && value="${entry#*$'\n'}"
      if [[ "$key" =~ $_CBOX_GIT_RISKY_KEYS ]] || [[ "$key" == alias.* && "$value" == '!'* ]]; then
        printf '%s|%s|%s=%s\n' "$label" "$f" "$key" "${value//$'\n'/\\n}"
      fi
    done < <(git config --file "$gd/$f" --no-includes --list -z 2>/dev/null)
  done
  [[ -f "$gd/commondir" ]] && printf '%s|commondir|%s\n' "$label" "$(head -n 1 "$gd/commondir")"
  while IFS= read -r h; do
    printf '%s|hook|%s %s\n' "$label" "${h##*/}" "$(cksum < "$h" 2>/dev/null | cut -d' ' -f1)"
  done < <(find "$gd/hooks" -mindepth 1 -maxdepth 1 ! -type d ! -name '*.sample' 2>/dev/null | LC_ALL=C sort)
  return 0
}

# Prints the risky settings of every git dir under the project root, sorted.
_cbox_git_guard_scan() {
  local root="$1" g rel sub
  while IFS= read -r g; do
    rel="${g#"$root"/}"
    if [[ -L "$g" ]]; then
      printf '%s|symlink|%s\n' "$rel" "$(/usr/bin/readlink "$g" 2>/dev/null || readlink "$g")"
    elif [[ -f "$g" ]]; then
      printf '%s|gitfile|%s\n' "$rel" "$(head -n 1 "$g")"
    elif [[ -d "$g" ]]; then
      _cbox_git_guard_gitdir "$g" "$rel"
      # Submodule and worktree git dirs live inside .git.
      while IFS= read -r sub; do
        sub="${sub%/config}"
        _cbox_git_guard_gitdir "$sub" "${sub#"$root"/}"
      done < <(find "$g/modules" -type f -name config 2>/dev/null)
      while IFS= read -r sub; do
        _cbox_git_guard_gitdir "$sub" "${sub#"$root"/}"
      done < <(find "$g/worktrees" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)
    fi
  done < <(find "$root" -name .git -prune -print 2>/dev/null)
  return 0
}

# First session of a container: record the project's git settings, plus copies
# of .git/config and .git/hooks to restore from. A later concurrent session
# keeps the first one's record.
_cbox_git_guard_start() {
  local name="$1" f pid
  local dir="$CBOX_DATA_DIR/git-guard/$name"
  while IFS= read -r f; do
    pid="${f##*-}"
    [[ "$pid" != "$$" ]] && ps -p "$pid" >/dev/null 2>&1 && [[ -f "$dir/scan" ]] && return 0
  done < <(_cbox_session_markers "$name")
  rm -rf "$dir"
  mkdir -p "$dir/hooks"
  chmod 700 "$dir"
  _cbox_git_guard_scan "$PWD" | LC_ALL=C sort > "$dir/scan.tmp"
  if [[ -d "$PWD/.git" && ! -L "$PWD/.git" ]]; then
    [[ -f "$PWD/.git/config" ]] && command cp -p "$PWD/.git/config" "$dir/config"
    while IFS= read -r f; do
      command cp -p "$f" "$dir/hooks/"
    done < <(find "$PWD/.git/hooks" -mindepth 1 -maxdepth 1 ! -type d ! -name '*.sample' 2>/dev/null)
  fi
  # Written last: a snapshot without "scan" is incomplete and is not checked.
  mv "$dir/scan.tmp" "$dir/scan"
}

# Asks on a terminal only; anything else means no.
_cbox_git_guard_ask() {
  [[ -t 0 ]] || return 1
  local answer=""
  printf '   Restore .git/config and .git/hooks as they were at the session start? [y/N] '
  read -r answer || return 1
  [[ "$answer" == [yY]* ]]
}

# Last session ended: warn about git settings that run commands and were not
# there at the start, and offer to put .git/config and .git/hooks back.
_cbox_git_guard_check() {
  local name="$1"
  local dir="$CBOX_DATA_DIR/git-guard/$name"
  [[ -f "$dir/scan" ]] || return 0
  local new line label kind detail restorable=0
  new=$(_cbox_git_guard_scan "$PWD" | LC_ALL=C sort | LC_ALL=C comm -13 "$dir/scan" -)
  if [[ -z "$new" ]]; then
    rm -rf "$dir"
    return 0
  fi

  echo ""
  echo "⚠  New git settings in '$name' that would run commands on this Mac:"
  while IFS= read -r line; do
    label="${line%%|*}"; line="${line#*|}"
    kind="${line%%|*}"; detail="${line#*|}"
    case "$kind" in
      hook)    echo "     $label/hooks/${detail%% *}" ;;
      symlink) echo "     $label → $detail (replaced by a link)" ;;
      gitfile) echo "     $label → $detail (points git elsewhere)" ;;
      *)       echo "     $label/$kind: $detail" ;;
    esac
    [[ "$label" == ".git" && "$kind" != "symlink" && "$kind" != "gitfile" ]] && restorable=1
  done <<<"$new"
  echo "   Code in the container made them. Do not run git there on the Mac until you have checked them."

  local keep
  keep="$CBOX_DATA_DIR/git-guard/$name-$(date +%Y%m%d-%H%M%S)"
  mv "$dir" "$keep"
  if (( ! restorable )) || [[ ! -d "$PWD/.git" || -L "$PWD/.git" ]]; then
    echo "   Session-start copies: $keep"
    return 0
  fi

  if ! _cbox_git_guard_ask; then
    echo "   Not restored. Session-start copies: $keep"
    return 0
  fi

  # Changed files go to $keep/changed, never deleted.
  local h base
  mkdir -p "$keep/changed/hooks"
  if [[ -f "$keep/config" ]] && ! cmp -s "$keep/config" "$PWD/.git/config"; then
    [[ -f "$PWD/.git/config" ]] && mv "$PWD/.git/config" "$keep/changed/config"
    command cp -p "$keep/config" "$PWD/.git/config"
  fi
  for base in commondir config.worktree; do
    [[ -e "$PWD/.git/$base" ]] && ! grep -q "^\.git|$base|" "$keep/scan" && \
      mv "$PWD/.git/$base" "$keep/changed/$base"
  done
  while IFS= read -r h; do
    base="${h##*/}"
    cmp -s "$h" "$keep/hooks/$base" 2>/dev/null && continue
    mv "$h" "$keep/changed/hooks/$base"
    [[ -f "$keep/hooks/$base" ]] && command cp -p "$keep/hooks/$base" "$h"
  done < <(find "$PWD/.git/hooks" -mindepth 1 -maxdepth 1 ! -type d ! -name '*.sample' 2>/dev/null)
  echo "   ✔ Restored. The changed files are kept in $keep/changed"
  return 0
}

# Runs a cdot sync command. Failures must always be visible — CBOX_VERBOSE only
# controls whether the routine success output is shown too, never whether
# failures are silenced. A failed sync is reported, never fatal, so the
# teardown after it (stopping the container) always runs.
_cbox_cdot_push() {
  if [[ "${CBOX_VERBOSE:-0}" == "1" ]]; then
    cdot "$@" || true
  else
    local _out
    if ! _out=$(cdot "$@" 2>&1); then
      echo "⚠  cdot $1 failed:"
      echo "$_out" | sed 's/^/    /'
    fi
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

  local agent_bin
  agent_bin=$(_cbox_agent_bin)

  if [[ "$command" != "zsh" ]]; then
    _cbox_maybe_update "$name"
    if command -v cdot >/dev/null 2>&1 && _cbox_check_companion_api cdot "$_CBOX_CDOT_API"; then
      if [[ "$agent_bin" == "claude" ]]; then
        if [[ "${CBOX_VERBOSE:-0}" == "1" ]]; then
          cdot _pull
          [[ "$mode" != "safe" ]] && cdot _pull-history "$name"
        else
          cdot _pull >/dev/null 2>&1
          [[ "$mode" != "safe" ]] && cdot _pull-history "$name" >/dev/null 2>&1
        fi
      elif [[ "$agent_bin" == "opencode" ]]; then
        if [[ "${CBOX_VERBOSE:-0}" == "1" ]]; then
          cdot _pull-opencode
        else
          cdot _pull-opencode >/dev/null 2>&1
        fi
      fi
    fi
  fi

  if [[ -n "${CBOX_AUDIO:-}" ]] && [[ "$mode" != "safe" ]] && [[ "$agent_bin" == "claude" ]]; then
    _cbox_audio_start || true
  fi

  if [[ "$agent_bin" == "claude" ]]; then
    [[ "$mode" != "safe" ]] && _cbox_mcp_relay_start "$name"
    _cbox_generate_claude_json "$name" "$mode"
  fi

  local _exec_args=(-it -w "/Workspace/$name")
  [[ -n "${CBOX_AUDIO:-}" ]] && [[ "$mode" != "safe" ]] && [[ "$agent_bin" == "claude" ]] && \
    _exec_args+=(-e "PULSE_SERVER=$(_cbox_audio_pulse_server)")
  local _run="$command" _g
  while IFS= read -r _g; do _exec_args+=(-e "$_g"); done < <(_cbox_git_identity)
  if [[ "$mode" != "safe" ]]; then
    local _w_env
    while IFS= read -r _w_env; do
      case "$_w_env" in
        # S3-style resources: write their AWS profiles inside the container
        # (base64 only; the profiles hold dummy keys and the broker URL).
        WARDEN_AWS_CONFIG=*)
          _run="mkdir -p ~/.aws && print -rn -- '${_w_env#*=}' | base64 -d >| ~/.aws/warden-config; $command" ;;
        ?*) _exec_args+=(-e "$_w_env") ;;
      esac
    done < <(_cbox_warden_start "$name")
  fi

  _cbox_flux_install "$name"

  echo "Entering container '$name'..."

  _cbox_git_guard_start "$name" || true
  _cbox_session_start "$name"

  # The agent's exit status is irrelevant here, but under the script's
  # `set -e` a non-zero one would skip every teardown step below —
  # including stopping the container.
  $_CBOX_CMD exec "${_exec_args[@]}" "$name" zsh -ic "$_run" || true

  if [[ -n "${CBOX_AUDIO:-}" ]] && [[ "$mode" != "safe" ]] && [[ "$agent_bin" == "claude" ]]; then
    _cbox_audio_stop
  fi

  if [[ "$command" != "zsh" && "$mode" != "safe" ]]; then
    if command -v cdot >/dev/null 2>&1 && _cbox_check_companion_api cdot "$_CBOX_CDOT_API"; then
      if [[ "$agent_bin" == "claude" ]]; then
        _cbox_cdot_push _push
        _cbox_cdot_push _push-history "$name"
      elif [[ "$agent_bin" == "opencode" ]]; then
        _cbox_cdot_push _push-opencode
      fi
    fi
  fi

  local _last_session=1
  _cbox_session_end "$name" && _last_session=0

  # Markers claim another session — verify with the container before keeping it alive.
  if (( ! _last_session )); then
    local _probe=0
    _cbox_container_has_sessions "$name" || _probe=$?
    if (( _probe == 1 )); then
      _last_session=1
      local _m
      _cbox_session_markers "$name" | while IFS= read -r _m; do rm -f "$_m"; done
    fi
  fi

  if [[ "$stop_on_exit" == "yes" ]]; then
    if (( _last_session )); then
      echo "Stopping container '$name'..."
      $_CBOX_CMD stop "$name" >/dev/null || echo "⚠  Failed to stop container '$name' — run: cbox stop"
    else
      echo "Session closed. Container '$name' kept alive (other sessions still active)."
    fi
  fi

  if (( _last_session )); then
    _cbox_mcp_relay_stop "$name"
    _cbox_warden_end "$name"
    _cbox_git_guard_check "$name" || true
    local _cache_base="${XDG_CACHE_HOME:-$HOME/.cache}"
    [[ -n "$CBOX_SHARE_DIR" && ( "$CBOX_SHARE_DIR" == /tmp/* || "$CBOX_SHARE_DIR" == "$_cache_base"/* ) ]] && \
      find "$CBOX_SHARE_DIR" -mindepth 1 -delete 2>/dev/null || true
    unset _cache_base
  fi
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

  if [[ "$_CBOX_RUNTIME" == "apple" ]]; then
    if _cbox_system_running; then
      echo "✔ container system running"
    else
      echo "✘ container system not running (cbox will start it automatically)"
    fi
  fi

  _cbox_rt_image_list | grep -q "^$CBOX_IMAGE " \
    && echo "✔ image '$CBOX_IMAGE' exists" \
    || echo "✘ image '$CBOX_IMAGE' missing"

  echo "Active agent: $(_cbox_agent_bin) (CBOX_AGENT=${CBOX_AGENT:-claude})"

  [[ -d "$CBOX_CLAUDE_DIR" ]] \
    && echo "✔ Claude config dir exists ($CBOX_CLAUDE_DIR)" \
    || echo "✘ Claude config dir missing ($CBOX_CLAUDE_DIR)"

  # Nothing prunes this cache automatically: unlike an image layer it survives
  # rebuilds, so every playwright upgrade leaves its old chromium-<id> behind.
  # Report the size so it stays visible and the user can clear it deliberately.
  if [[ -d "$CBOX_PLAYWRIGHT_DIR" ]] && [[ -n "$(ls -A "$CBOX_PLAYWRIGHT_DIR" 2>/dev/null)" ]]; then
    local _pw_size
    _pw_size=$(du -sh "$CBOX_PLAYWRIGHT_DIR" 2>/dev/null | cut -f1)
    echo "✔ Playwright cache present ($CBOX_PLAYWRIGHT_DIR, ${_pw_size:-unknown})"
    echo "  ℹ never pruned automatically — clear with: rm -rf $CBOX_PLAYWRIGHT_DIR"
    unset _pw_size
  else
    echo "ℹ Playwright cache empty ($CBOX_PLAYWRIGHT_DIR) — filled on first use"
  fi

  local _opencode_cfg="${CBOX_HOST_CONFIG_DIR}/opencode"
  _cbox_shared_config_names | grep -qx opencode && _opencode_cfg="${XDG_CONFIG_HOME:-$HOME/.config}/opencode"
  [[ -d "$_opencode_cfg" ]] \
    && echo "✔ opencode config dir exists ($_opencode_cfg)" \
    || echo "ℹ opencode config dir absent ($_opencode_cfg) — created on first run"
  unset _opencode_cfg

  if [[ -n "${CBOX_ZSHRC:-}" ]]; then
    [[ -f "$CBOX_ZSHRC" ]] \
      && echo "✔ custom zshrc exists ($CBOX_ZSHRC)" \
      || echo "✘ custom zshrc missing ($CBOX_ZSHRC)"
  else
    echo "ℹ no custom zshrc configured (CBOX_ZSHRC unset)"
  fi

  if [[ -n "${CBOX_AUDIO:-}" ]]; then
    command -v pulseaudio >/dev/null 2>&1 \
      && echo "✔ PulseAudio installed" \
      || echo "✘ PulseAudio not found (CBOX_AUDIO set) — install: brew install pulseaudio"
    lsof -i :4713 >/dev/null 2>&1 \
      && echo "✔ PulseAudio listening on :4713" \
      || echo "ℹ PulseAudio not running (will auto-start on next cbox session)"
  else
    echo "ℹ voice mode disabled (set CBOX_AUDIO=1 in cbox.env to enable)"
  fi
}

_cbox_doctor() {
  local name
  name=$(_cbox_name)
  clear

  echo "== cbox doctor =="
  echo "Version: $_CBOX_VERSION"
  echo "Agent:   $(_cbox_agent_bin)"

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

  echo
  echo "[mcp]"
  _cbox_mcp_status "$name"

  echo
  echo "[warden]"
  _cbox_warden_cmd list
}

# ---------------------------------------------------------
# public command
# ---------------------------------------------------------

cbox() {
  while [[ "${1:-}" == -* ]]; do
    case "$1" in
      -v|--verbose) local CBOX_VERBOSE=1; shift ;;
      *) echo "Unknown flag: $1"; return 1 ;;
    esac
  done

  local subcommand="${1:-}"

  local name
  name=$(_cbox_name)

  case "$subcommand" in

    oc|opencode)
      local CBOX_AGENT=opencode
      shift
      cbox "$@"
      return
      ;;

    safe)
      _cbox_ensure "$name" "safe" || return 1
      _cbox_enter "$name" "$(_cbox_agent_bin)"
      ;;

    shell)
      _cbox_ensure "$name" "normal" || return 1
      _cbox_enter "$name" "zsh"
      ;;

    keepalive)
      _cbox_ensure "$name" "normal" || return 1
      _cbox_enter "$name" "$(_cbox_agent_bin)" "no"
      _cbox_keepalive "$name"
      ;;

    stop)
      local stop_target="${2:-$name}"
      if ! _cbox_exists "$stop_target"; then
        echo "No container found for '$stop_target'."
        return 0
      fi
      echo "Stopping container '$stop_target'..."
      _cbox_mcp_relay_stop "$stop_target"
      _cbox_warden_end "$stop_target"
      $_CBOX_CMD stop "$stop_target" >/dev/null
      ;;

    reset)
      local reset_target="${2:-$name}"
      if ! _cbox_exists "$reset_target"; then
        echo "No container found for '$reset_target'."
        return 0
      fi
      echo "Removing container '$reset_target'..."
      _cbox_mcp_relay_stop "$reset_target"
      _cbox_warden_end "$reset_target"
      $_CBOX_CMD rm -f "$reset_target"
      ;;

    rebuild)
      clear
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

    mcp)
      case "${2:-}" in
        ""|list) _cbox_mcp_status "$name" ;;
        import)  python3 -c "$(_cbox_mcp_py)" import "$CBOX_MCP_CONFIG" ;;
        *)
          echo "Unknown mcp command: $2"
          echo "Usage: cbox mcp [list|import]"
          return 1
          ;;
      esac
      ;;

    warden)
      shift
      _cbox_warden_cmd "$@"
      ;;

    _doctor)
      _cbox_doctor_inline
      ;;

    list)
      clear
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
            # Use an explicit if (not && echo): under `set -euo pipefail` a
            # trailing false [[ … ]] would make the loop — and thus this
            # command substitution — exit non-zero, aborting prune before it
            # removes anything. This bites whenever the last listed container
            # is a stopped non-cbox one (e.g. Apple Container's buildkit).
            if [[ "$(_cbox_rt_label "$cname" "cbox.project")" == "true" ]]; then
              echo "$cname"
            fi
          done
        )
      else
        stopped=$(_cbox_rt_list --filter "label=$CBOX_LABEL" \
          | awk '$2 != "running" {print $1}')
      fi

      if [[ -n "$stopped" ]]; then
        echo "$stopped" | xargs "$_CBOX_CMD" rm -f
      else
        echo "Nothing to prune."
      fi
      ;;

    "")

      _cbox_ensure "$name" "normal" || return 1
      _cbox_enter "$name" "$(_cbox_agent_bin)"
      ;;

    version)
      echo "cbox $_CBOX_VERSION"
      # Show which script is actually executing. The Homebrew install is a
      # frozen snapshot of cbox.sh, so this disambiguates it from a repo
      # checkout when debugging — resolving brew's bin shim to the versioned
      # Cellar path.
      echo "path: $(_cbox_resolve_path "${BASH_SOURCE[0]}")"
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

# ---------------------------------------------------------
# shell completions (sourced case)
# ---------------------------------------------------------

_cbox_list_names() {
  _cbox_rt_list 2>/dev/null | awk '{print $1}'
}

if [[ -n "${ZSH_VERSION:-}" ]]; then
  _cbox_zsh_complete() {
    case $CURRENT in
      2)
        compadd -v --verbose list stop reset prune rebuild update doctor mcp warden safe shell keepalive oc opencode version help
        ;;
      3)
        if [[ "${words[2]}" == "reset" || "${words[2]}" == "stop" ]]; then
          local -a containers
          containers=($(_cbox_list_names))
          (( ${#containers[@]} )) && compadd -a containers
        fi
        ;;
    esac
  }
  (( ${+functions[compdef]} )) && compdef _cbox_zsh_complete cbox
elif [[ -n "${BASH_VERSION:-}" ]]; then
  _cbox_bash_complete() {
    local cur="${COMP_WORDS[COMP_CWORD]}"
    local prev="${COMP_WORDS[COMP_CWORD-1]}"
    COMPREPLY=()

    if [[ $COMP_CWORD -eq 1 ]]; then
      COMPREPLY=( $(compgen -W \
        "-v --verbose list stop reset prune rebuild update doctor mcp warden safe shell keepalive oc opencode version help" \
        -- "$cur") )
    elif [[ $COMP_CWORD -eq 2 && ( "$prev" == "reset" || "$prev" == "stop" ) ]]; then
      COMPREPLY=( $(compgen -W "$(_cbox_list_names)" -- "$cur") )
    fi
  }
  complete -F _cbox_bash_complete cbox
fi

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  cbox "$@"
fi
