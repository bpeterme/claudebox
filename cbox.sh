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
  -v, --verbose         Show full output (updates, sync, MCP proxy status)

Container Management:
  cbox list             List cbox containers
  cbox stop [name]      Stop current (or named) container
  cbox reset            Remove current project container
  cbox prune            Remove stopped cbox containers
  cbox rebuild          Rebuild container image

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
CBOX_HOST_CONFIG_DIR="${CBOX_HOST_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}}"
CBOX_SHARE_DIR="${CBOX_SHARE_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/claudebox/share}"
# Playwright browser cache, mounted over the image's /opt/ms-playwright. Lives in
# CBOX_DATA_DIR, not CBOX_SHARE_DIR: the share dir is wiped when the last session
# closes, and these browsers are ~660 MB we never want to re-download.
CBOX_PLAYWRIGHT_DIR="${CBOX_PLAYWRIGHT_DIR:-$CBOX_DATA_DIR/ms-playwright}"
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

_cbox_generate_claude_json() {
  local name="$1"
  local portmap="$CBOX_DATA_DIR/.mcp-portmap-$name.json"
  local native_index="$CBOX_DATA_DIR/.mcp-native-$name.json"
  local gateway
  gateway=$(_cbox_mcp_host_gateway)

  mkdir -p "$CBOX_DATA_DIR"

  local claude_json="$CBOX_DATA_DIR/.claude-$name.json"

  python3 - "$claude_json" "$name" "$portmap" "$gateway" "$native_index" <<'PYEOF'
import json, sys, os

project_file, name, portmap_file, gateway, native_index_path = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]

try:
    with open(project_file) as f:
        project = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    project = {}

try:
    with open(os.path.expanduser("~/.claude.json")) as f:
        host = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    host = {}

try:
    with open(portmap_file) as f:
        portmap = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    portmap = {}

try:
    with open(native_index_path) as f:
        native_index = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    native_index = {}

# Build the final mcpServers set: host wins over project for shared keys
if "mcpServers" in host:
    final_mcp = {**project.get("mcpServers", {}), **host["mcpServers"]}
else:
    final_mcp = project.get("mcpServers")

if final_mcp is not None:
    container_mcp = {}
    for sname, scfg in final_mcp.items():
        if sname in portmap:
            # Proxy is running — rewrite to Streamable HTTP
            container_mcp[sname] = {
                "type": "http",
                "url": f"http://{gateway}:{portmap[sname]['port']}/mcp"
            }
        elif sname in native_index:
            # Known native but proxy not running — restore original stdio config
            ni = native_index[sname]
            entry = {"command": ni["command"], "args": ni.get("args", [])}
            if ni.get("env"):
                entry["env"] = ni["env"]
            container_mcp[sname] = entry
        else:
            container_mcp[sname] = scfg
    project["mcpServers"] = container_mcp

# Ensure required container defaults
project["hasCompletedOnboarding"] = True
project["installMethod"] = "npm"
project.setdefault("projects", {}).setdefault(
    f"/Workspace/{name}", {}
)["hasTrustDialogAccepted"] = True

with open(project_file, "w") as f:
    json.dump(project, f)
PYEOF
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
# MCP host-native proxy
# ---------------------------------------------------------

_cbox_mcp_host_gateway() {
  if [[ "$_CBOX_RUNTIME" == "apple" ]]; then
    echo "192.168.64.1"
  else
    echo "host.docker.internal"
  fi
}

# Detects host-native MCP servers, starts supergateway proxies for each, and
# writes a portmap file ($CBOX_DATA_DIR/.mcp-portmap-$name.json) recording
# {server_name: {port, pid}} so _cbox_generate_claude_json can rewrite entries.
# A persistent native index ($CBOX_DATA_DIR/.mcp-native-$name.json) remembers
# which servers are native across sessions so the stdio→SSE cycle stays correct.
_cbox_mcp_proxies_ensure() {
  local name="$1"
  local portmap="$CBOX_DATA_DIR/.mcp-portmap-$name.json"
  local native_index="$CBOX_DATA_DIR/.mcp-native-$name.json"
  local container_json="$CBOX_DATA_DIR/.claude-$name.json"

  command -v npx >/dev/null 2>&1 || return 0

  CBOX_VERBOSE="${CBOX_VERBOSE:-0}" python3 - "$portmap" "$CBOX_DATA_DIR" "$container_json" "$native_index" <<'PYEOF'
import json, os, sys, subprocess, time, socket, glob, shlex
verbose = os.environ.get("CBOX_VERBOSE", "0") == "1"

portmap_file, data_dir, container_json_path, native_index_path = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

try:
    with open(portmap_file) as f:
        portmap = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    portmap = {}

try:
    with open(native_index_path) as f:
        native_index = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    native_index = {}

def is_native(cmd):
    if not cmd:
        return False
    home = os.path.expanduser("~")
    expanded = os.path.expanduser(str(cmd))
    return (
        expanded.startswith("/Applications/") or
        expanded.startswith(home + "/Library/") or
        expanded.startswith(home + "/Applications/") or
        ".app/Contents/" in expanded
    )

def is_alive(pid):
    try:
        os.kill(int(pid), 0)
        return True
    except (OSError, ValueError):
        return False

def next_port():
    used = set()
    for pf in glob.glob(os.path.join(data_dir, ".mcp-portmap-*.json")):
        try:
            with open(pf) as f:
                pm = json.load(f)
            for v in pm.values():
                if "port" in v:
                    used.add(v["port"])
        except Exception:
            pass
    p = 39100
    while p in used:
        p += 1
    return p

def wait_for_port(port, timeout=8.0):
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            s = socket.create_connection(("127.0.0.1", port), timeout=0.2)
            s.close()
            return True
        except OSError:
            time.sleep(0.3)
    return False

# Collect all configured MCP servers from container JSON and host ~/.claude.json
all_mcp = {}
try:
    with open(container_json_path) as f:
        all_mcp.update(json.load(f).get("mcpServers", {}))
except (FileNotFoundError, json.JSONDecodeError):
    pass
try:
    with open(os.path.expanduser("~/.claude.json")) as f:
        all_mcp.update(json.load(f).get("mcpServers", {}))
except (FileNotFoundError, json.JSONDecodeError):
    pass

# Update native index with any newly detected native servers
for sname, scfg in all_mcp.items():
    cmd = scfg.get("command", "")
    if is_native(cmd):
        native_index[sname] = {
            "command": cmd,
            "args": scfg.get("args", []),
            "env": scfg.get("env", {}),
        }

with open(native_index_path, "w") as f:
    json.dump(native_index, f)

# Start/reuse proxies for all known native servers
new_portmap = {}
for sname, scfg in native_index.items():
    existing = portmap.get(sname, {})
    if existing and is_alive(existing.get("pid", 0)):
        new_portmap[sname] = existing
        continue

    port = next_port()
    cmd = scfg["command"]
    args = scfg.get("args", [])
    env_vars = scfg.get("env", {})

    env_prefix = " ".join(f"{k}={shlex.quote(str(v))}" for k, v in env_vars.items())
    arg_str = " ".join(shlex.quote(str(a)) for a in args)
    full_cmd = " ".join(filter(None, [env_prefix, shlex.quote(cmd), arg_str]))

    log_path = os.path.join(os.environ.get("TMPDIR", "/tmp"), f"cbox-mcp-{sname}.log")
    try:
        proc = subprocess.Popen(
            ["npx", "-y", "supergateway", "--stdio", full_cmd, "--port", str(port), "--outputTransport", "streamableHttp", "--stateful"],
            stdout=open(log_path, "w"),
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
    except Exception as e:
        print(f"  ⚠  MCP proxy '{sname}' failed to launch: {e}")
        continue

    if wait_for_port(port):
        new_portmap[sname] = {"port": port, "pid": proc.pid}
        if verbose:
            print(f"  ✔ MCP proxy '{sname}' on :{port}")
    else:
        print(f"  ⚠  MCP proxy '{sname}' did not start — check {log_path}")
        proc.terminate()

with open(portmap_file, "w") as f:
    json.dump(new_portmap, f)
PYEOF
}

_cbox_mcp_proxies_stop() {
  local name="$1"
  local portmap="$CBOX_DATA_DIR/.mcp-portmap-$name.json"
  [[ -f "$portmap" ]] || return 0

  python3 - "$portmap" <<'PYEOF'
import json, os, sys, signal

portmap_file = sys.argv[1]
try:
    with open(portmap_file) as f:
        portmap = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    sys.exit(0)

for sname, info in portmap.items():
    pid = info.get("pid")
    if not pid:
        continue
    try:
        pgid = os.getpgid(int(pid))
        os.killpg(pgid, signal.SIGTERM)
    except (ProcessLookupError, PermissionError, OSError):
        pass

os.remove(portmap_file)
PYEOF
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

_cbox_create() {
  local name="$1"
  local mode="$2"

  local agent_bin
  agent_bin=$(_cbox_agent_bin)

  if [[ "$agent_bin" == "claude" ]]; then
    _cbox_generate_claude_json "$name"
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
  )

  if [[ "$agent_bin" == "claude" ]]; then
    args+=(-v "$claude_json:/home/claude/.claude.json")
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
      -v "$CBOX_HOST_CONFIG_DIR:/home/claude/.config"
      -v "$CBOX_SHARE_DIR:/home/claude/share"
      -v "$CBOX_PLAYWRIGHT_DIR:/opt/ms-playwright"
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
  local _ro="" _link _target
  [[ "$mode" == "safe" ]] && _ro=":ro"
  while IFS= read -r _link; do
    _target=$(_cbox_resolve_path "$_link")
    [[ -e "$_target" ]] || continue
    [[ "$_target" == "$CBOX_CLAUDE_DIR"* ]] && continue
    [[ "$_target" == "$PWD" || "$_target" == "$PWD/"* ]] && continue
    args+=(-v "$_target:$_target$_ro")
  done < <(find "$CBOX_CLAUDE_DIR" -maxdepth 2 -type l 2>/dev/null)
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
# flux push — session-close sync for flux-managed repos
# ---------------------------------------------------------

# Runs `flux _push` (auto-commits any dirty work, then pushes git + DVC).
# Failures must always be visible — CBOX_VERBOSE only controls whether the
# routine success output is shown too, never whether failures are silenced.
# Same contract as _cbox_flux_push: a failed sync is reported, never fatal,
# so the teardown after it (stopping the container) always runs.
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

_cbox_flux_push() {
  if [[ "${CBOX_VERBOSE:-0}" == "1" ]]; then
    flux _push || true
  else
    local _out
    if ! _out=$(flux _push 2>&1); then
      echo "⚠  flux push failed:"
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
    if command -v flux >/dev/null 2>&1 && [[ -d "$PWD/.dvc" ]] && _cbox_check_companion_api flux "$_CBOX_FLUX_API"; then
      if [[ "${CBOX_VERBOSE:-0}" == "1" ]]; then
        flux _pull || true
      else
        flux _pull >/dev/null 2>&1 || true
      fi
    fi
  fi

  if [[ -n "${CBOX_AUDIO:-}" ]] && [[ "$mode" != "safe" ]] && [[ "$agent_bin" == "claude" ]]; then
    _cbox_audio_start || true
  fi

  if [[ "$mode" != "safe" ]] && [[ "$agent_bin" == "claude" ]]; then
    _cbox_mcp_proxies_ensure "$name"
    _cbox_generate_claude_json "$name"
  fi

  echo "Entering container '$name'..."

  local _exec_args=(-it -w "/Workspace/$name")
  [[ -n "${CBOX_AUDIO:-}" ]] && [[ "$mode" != "safe" ]] && [[ "$agent_bin" == "claude" ]] && \
    _exec_args+=(-e "PULSE_SERVER=$(_cbox_audio_pulse_server)")

  _cbox_session_start "$name"

  # The agent's exit status is irrelevant here, but under the script's
  # `set -e` a non-zero one would skip every teardown step below —
  # including stopping the container.
  $_CBOX_CMD exec "${_exec_args[@]}" "$name" zsh -ic "$command" || true

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
    if command -v flux >/dev/null 2>&1 && [[ -d "$PWD/.dvc" ]] && _cbox_check_companion_api flux "$_CBOX_FLUX_API"; then
      _cbox_flux_push
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
    _cbox_mcp_proxies_stop "$name"
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
  echo "[mcp proxies]"
  local _portmap="$CBOX_DATA_DIR/.mcp-portmap-$name.json"
  if [[ -f "$_portmap" ]]; then
    python3 - "$_portmap" <<'PYEOF'
import json, os, sys

portmap_file = sys.argv[1]
try:
    with open(portmap_file) as f:
        portmap = json.load(f)
except (FileNotFoundError, json.JSONDecodeError):
    portmap = {}

if not portmap:
    print("ℹ no host-native MCP proxies active")
else:
    for sname, info in portmap.items():
        pid = info.get("pid", 0)
        port = info.get("port", "?")
        try:
            os.kill(int(pid), 0)
            print(f"✔ {sname}: running on :{port} (pid {pid})")
        except (OSError, ValueError):
            print(f"✘ {sname}: dead (was on :{port}, pid {pid})")
PYEOF
  else
    echo "ℹ no host-native MCP proxies active"
  fi
  unset _portmap
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
      $_CBOX_CMD stop "$stop_target" >/dev/null
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
        compadd -v --verbose list stop reset prune rebuild update doctor safe shell keepalive oc opencode version help
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
        "-v --verbose list stop reset prune rebuild update doctor safe shell keepalive oc opencode version help" \
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
