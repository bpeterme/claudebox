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
# Host MCP servers relayed into the container (see "MCP relay" below)
CBOX_MCP_CONFIG="${CBOX_MCP_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/claudebox/mcp.json}"
_CBOX_MCP_RELAY="/home/claude/.local/bin/cbox-mcp-relay"
_CBOX_MCP_SLOTS=2
# Below Claude Code's 30s MCP connect timeout, so the hint lands before it gives up
_CBOX_MCP_HINT_SECONDS=25
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

  if [[ "$agent_bin" == "claude" ]]; then
    [[ "$mode" != "safe" ]] && _cbox_mcp_relay_start "$name"
    _cbox_generate_claude_json "$name" "$mode"
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
    _cbox_mcp_relay_stop "$name"
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
  echo "[mcp]"
  _cbox_mcp_status "$name"
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
        compadd -v --verbose list stop reset prune rebuild update doctor mcp safe shell keepalive oc opencode version help
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
        "-v --verbose list stop reset prune rebuild update doctor mcp safe shell keepalive oc opencode version help" \
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
