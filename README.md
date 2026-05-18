# claudebox

A shell utility that runs [Claude Code](https://github.com/anthropics/claude-code) inside an isolated container, scoped to your current project directory. Uses [Apple Container](https://github.com/apple/containerization) on macOS and Docker on Linux.

Each project gets its own container, named after the directory. Two modes are available: **normal** (full access to your Claude config and SSH keys) and **safe** (sandboxed with dropped capabilities, memory/CPU limits, and an isolated network).

**Machine independent by design.** Claude config and per-project conversation history can sync across machines via a private git remote. Config (settings, keybindings, global instructions) syncs automatically; project history is opt-in per project. Authentication is automatic: credentials are mounted from the host, so no re-authentication is needed inside the container.

## Prerequisites

- [Apple Container](https://github.com/apple/containerization) (macOS) or Docker (Linux)
- `jq`
- `bash` or `zsh`

## Installation

```bash
git clone https://github.com/bpeterme/claudebox.git ~/claudebox
```

Add to your `~/.zshrc` or `~/.bashrc`:

```bash
source ~/claudebox/cbox.sh
```

Then build the Docker image:

```bash
cbox rebuild
```

## Quick Start

```bash
cd ~/my-project
cbox           # start Claude Code in a container for this project
cbox safe      # same, but sandboxed
cbox shell     # open a zsh shell instead of Claude Code
```

## Commands

| Command | Description |
|---------|-------------|
| `cbox` | Start or enter normal container for the current directory |
| `cbox safe` | Start or enter sandboxed container |
| `cbox shell` | Open a zsh shell in the container instead of Claude Code |
| `cbox keepalive` | Run Claude Code; keep container alive for 10 min after exit |

**Container management**

| Command | Description |
|---------|-------------|
| `cbox stop` | Stop the current project's container |
| `cbox reset` | Remove the current project's container |
| `cbox rebuild` | Rebuild the container image |
| `cbox list` | List all cbox containers |
| `cbox prune` | Remove all stopped cbox containers |

**Sync (cross-machine)**

| Command | Description |
|---------|-------------|
| `cbox sync-init <url>` | Initialize cross-machine sync with a git remote |
| `cbox sync` | Pull/push config and opted-in project history |
| `cbox sync add` | Opt current project into history sync |
| `cbox sync remove` | Stop syncing history for the current project |
| `cbox sync compact` | Squash current project's history to a single commit |
| `cbox sync prune [--all]` | Delete old/oversized history branches from remote |
| `cbox sync list` | List all synced projects with sizes and last-push date |

**Maintenance**

| Command | Description |
|---------|-------------|
| `cbox update` | Force-update Claude Code inside a running container |
| `cbox doctor` | Run environment diagnostics |
| `cbox version` | Show the sourced version |

## Cross-Machine Sync

claudebox syncs your Claude config directory (`CBOX_CLAUDE_DIR`, default `~/.claude`) across machines using a private git remote. Config sync is automatic; project conversation history is opt-in per project.

### Architecture

Two types of branches are used in the same remote repository:

| Branch | Contents | When updated |
|--------|----------|--------------|
| `main` | Config files (see table below) | Every session automatically |
| `history/<project>/<hostname>` | Conversation history for one project on one machine | Only when opted in with `cbox sync add` |

History branches are never checked out — they are written and read via git plumbing, so they never interfere with the config on `main`.

### What gets synced to `main`

Only an explicit allowlist is tracked — everything else in `~/.claude` is ignored. This keeps config sync lean and future-proof.

| File/folder | Description |
|-------------|-------------|
| `settings.json` | Permissions, hooks, model preferences |
| `CLAUDE.md` | Global instructions |
| `keybindings.json` | Keyboard shortcuts |
| `*.sh` | User scripts (e.g. `statusline-command.sh`) |
| `plugins/` | Plugin/marketplace configuration |

**Never synced to `main`:** `.credentials.json`, `projects/` (conversation history), `backups/`, `cache/`, `sessions/`, and anything else not in the list above.

### Setup

Create a **private** empty repository on GitHub (or any git host), then run:

```bash
cbox sync-init git@github.com:you/claude-sync.git
```

Config sync is now active. Run the same command on your other machines to connect them.

### Opt in a project to history sync

Navigate to the project directory and opt it in:

```bash
cd ~/my-project
cbox sync add
```

From that point on, claudebox pulls history before each session and pushes it after. History is stored on a branch named `history/my-project/<hostname>`, so each machine's history is independent and separately prunable.

To stop syncing a project's history and delete the remote branch:

```bash
cbox sync remove
```

### Managing history size

Conversation history can grow large over time. claudebox warns when total history exceeds 500 MB (configurable via `CBOX_SYNC_SIZE_WARN_MB`).

```bash
cbox sync list                        # show all projects, sizes, and last-push date
cbox sync compact                     # squash all commits to one (frees git history, keeps files)
cbox sync prune --older-than 30d      # delete current project's remote branch if last push > 30 days ago
cbox sync prune --all --over 200m     # delete any project branch on this machine over 200 MB
```

`prune` operates on the current project by default. Pass `--all` to sweep all projects on this machine. Without `--force`, it always shows candidates and asks for confirmation before deleting.

### How it handles conflicts

- Each session commits with a timestamp and hostname, so history is always traceable.
- Push rejections (two machines worked offline) trigger an automatic `git pull --rebase` and retry. Because conversation files are append-only, rebases almost never produce conflicts.
- `settings.json` is structured JSON — if the same key diverges on two machines, git will flag a conflict that must be resolved manually.
- If a rebase fails for any reason, the local commit is preserved and a clear message tells you exactly what to run to resolve it manually.
- `cbox doctor` shows sync status (remote URL, commits ahead/behind) at a glance.

### Safe mode and sync

In safe mode (`cbox safe`), claudebox pulls config from `main` but performs no writes and no history sync. This matches the read-only nature of the safe mode mount.

| Operation | Normal | Safe |
|-----------|--------|------|
| Pull config (`main`) | ✔ | ✔ |
| Push config (`main`) | ✔ | — |
| Pull project history | ✔ | — |
| Push project history | ✔ | — |

### What not to use

**Avoid placing `CBOX_CLAUDE_DIR` (default `~/.claude`), or your project directories, on iCloud Drive, Dropbox Smart Sync, Google Drive Stream, or any on-demand cloud storage.** These services evict file contents to stubs when not recently accessed. A container mounting an evicted path will fail to read files that appear to exist on disk — a subtle failure that is hard to diagnose.

**Avoid continuous sync tools (Syncthing, rsync daemons, etc.) for `CBOX_CLAUDE_DIR`.** They can write into the directory while Claude is actively appending to a conversation file, risking corruption or lost writes. The git approach is safe because it only touches the directory at explicit session boundaries.

## Container Modes

### Normal mode (`cbox`)
- Mounts your Claude config and optionally SSH keys and dotfiles
- Intended for trusted development work

### Safe mode (`cbox safe`)
- All Linux capabilities dropped (`--cap-drop=ALL`)
- No privilege escalation (`--security-opt no-new-privileges`)
- 4 GB memory limit, 2 CPU cores, 512 max PIDs
- Isolated network bridge (`cbox-bridge`)
- Claude config mounted read-only

## Configuration

Create `~/.config/claudebox/cbox.env` to override defaults. See [`cbox.env.example`](cbox.env.example) for all options. If `$XDG_CONFIG_HOME` is set, the file goes in `$XDG_CONFIG_HOME/claudebox/cbox.env` instead.

| Variable | Default | Description |
|----------|---------|-------------|
| `CBOX_IMAGE` | `claudebox` | Docker image name |
| `CBOX_LABEL` | `cbox.project=true` | Label applied to all cbox containers |
| `CBOX_KEEPALIVE_SECONDS` | `600` | Seconds container stays alive before auto-stop in keepalive mode |
| `CBOX_DATA_DIR` | `~/.local/share/claudebox` | Per-project container config files (`.claude-<name>.json`), one per project |
| `CBOX_CLAUDE_DIR` | `~/.claude` | Claude Code config, mounted as `~/.claude` (read-write; read-only in safe mode) |
| `CBOX_HOST_CONFIG_DIR` | `~/.config` | Host config dir, mounted as `~/.config` in container (normal mode, read-write) |
| `CBOX_SHARE_DIR` | `/tmp/cbox-<user>` | Share folder, mounted as `~/share` in container; cleared on exit (read-write) |
| `CBOX_SSH_DIR` | *(unset)* | SSH dir to mount as `~/.ssh` in container (normal mode, **read-only**); unset = no SSH mount |
| `CBOX_ZSHRC` | *(unset)* | `.zshrc` to source as `~/.zshrc.global` inside the container (**read-only**); unset = none |
| `CBOX_BUILD_DIR` | cbox.sh directory | Build context for `cbox rebuild` |
| `BUILD_PLAYWRIGHT` | `0` | Set to `1` to include Playwright + Chromium in the image |
| `CBOX_SYNC_SIZE_WARN_MB` | `500` | Warn when total history size exceeds this threshold (MB) |
| `CBOX_SYNC_PROJECTS` | *(managed automatically)* | Space-separated list of projects opted into history sync; managed by `cbox sync add/remove` |

### `~/.config/claudebox/cbox.env` template

```bash
# ── image & container ─────────────────────────────────────────────────────────
# CBOX_IMAGE="claudebox"
# CBOX_LABEL="cbox.project=true"
# CBOX_KEEPALIVE_SECONDS=600

# ── host paths ────────────────────────────────────────────────────────────────
# CBOX_DATA_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/claudebox"
# CBOX_CLAUDE_DIR="$HOME/.claude"
# CBOX_HOST_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}"
# CBOX_SHARE_DIR="/tmp/cbox-$USER"

# ── optional mounts (leave unset to disable) ──────────────────────────────────
# CBOX_SSH_DIR="$HOME/.ssh"
# CBOX_ZSHRC="$HOME/.zshrc"

# ── build ─────────────────────────────────────────────────────────────────────
# CBOX_BUILD_DIR="$HOME/claudebox"
# BUILD_PLAYWRIGHT=0

# ── sync ──────────────────────────────────────────────────────────────────────
# CBOX_SYNC_SIZE_WARN_MB=500
# CBOX_SYNC_PROJECTS=""        # managed by 'cbox sync add/remove'
```

## Container Image

The image is based on Ubuntu 24.04 and includes:

- Node.js 22, Claude Code
- Python 3, [uv](https://github.com/astral-sh/uv)
- Git, git-crypt, openssh-client
- ripgrep, fd-find, jq, eza
- zsh with autosuggestions and syntax highlighting
- Playwright + Chromium (opt-in via `BUILD_PLAYWRIGHT=1`)

The container user is `claude` (UID matches your host UID to avoid permission issues on mounted volumes).

## macOS: Screenshot Script

[`macos/screenshot.sh`](macos/screenshot.sh) captures an interactive screenshot (drag to select a region, same as ⇧⌘4) and saves it directly to the container's `~/share/` folder. It reads `~/.config/claudebox/cbox.env` automatically so no path configuration is needed. See [`macos/README.md`](macos/README.md) for how to assign a keyboard shortcut via Automator, Hammerspoon, or Raycast.

## How It Works

- Container name is derived from the current directory name (e.g. `my-project`)
- Project directory is mounted at `/Workspace/<name>` inside the container
- Claude Code is updated automatically once per day on first use
- On exit, the container is stopped and the share folder is cleared
- `cbox keepalive` leaves the container running for 10 minutes (useful for follow-up `exec` calls)
- Authentication is automatic — credentials are mounted from the host, so no re-authentication is needed inside the container

## Works With

### [flux](https://github.com/bpeterme/flux)

[flux](https://github.com/bpeterme/flux) handles automatic file routing between any Git remote and large file cloud object storage. If your projects involve large assets alongside code, claudebox and flux complement each other naturally — claudebox scopes Claude Code to your project, flux manages the file transport layer for assets that don't belong in a regular git repo.

## License

MIT
