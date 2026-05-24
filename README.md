# claudebox

A shell utility that runs [Claude Code](https://github.com/anthropics/claude-code) inside an isolated container, scoped to your current project directory. Uses [Apple Container](https://github.com/apple/containerization) on macOS and Docker on Linux.

Each project gets its own container, named after the directory. Two modes are available: **normal** (full access to your Claude config and SSH keys) and **safe** (sandboxed with dropped capabilities, memory/CPU limits, and an isolated network).

## Prerequisites

- [Apple Container](https://github.com/apple/containerization) (macOS) or Docker (Linux)

## Installation

### Homebrew (recommended)

```bash
brew tap bpeterme/claudebox
brew install bpeterme/claudebox/claudebox
cbox --help
```

### Manual

```bash
git clone https://github.com/bpeterme/claudebox.git ~/claudebox
```

Add to your `~/.zshrc` or `~/.bashrc`:

```bash
source ~/claudebox/cbox.sh
```

Then:

```bash
cbox --help
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
| `cbox reset [<name>]` | Remove the current project's container (or a named container) |
| `cbox rebuild` | Rebuild the container image |
| `cbox list` | List all cbox containers |
| `cbox prune` | Remove all stopped cbox containers |

**Maintenance**

| Command | Description |
|---------|-------------|
| `cbox update` | Force-update Claude Code inside a running container |
| `cbox doctor` | Run environment diagnostics (includes companion tool status) |
| `cbox version` | Show version |

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
- If [claudedot](https://github.com/bpeterme/claudedot) is installed, config and history sync runs automatically at session start and exit
- If [flux](https://github.com/bpeterme/flux) is installed and the project has a `.dvc/` directory, large-file sync runs automatically at session boundaries

## Companion Tools

### [claudedot](https://github.com/bpeterme/claudedot)

[claudedot](https://github.com/bpeterme/claudedot) (`cdot`) syncs your Claude config and per-project conversation history across machines via a private git remote. Config (settings, keybindings, global instructions) syncs automatically on every session; project history is opt-in per project. claudebox calls `cdot` automatically at session boundaries if it is installed — no manual steps needed.

```bash
brew tap bpeterme/claudedot
brew install bpeterme/claudedot/claudedot
cdot config    # connect to your sync remote
```

### [flux](https://github.com/bpeterme/flux)

[flux](https://github.com/bpeterme/flux) handles automatic file routing between any Git remote and Cloudflare R2 object storage. If your projects involve large assets alongside code, claudebox and flux complement each other naturally — claudebox scopes Claude Code to your project, flux manages the file transport layer for assets that don't belong in a regular git repo. claudebox calls `flux` automatically at session boundaries when a flux-managed project is detected.

```bash
brew tap bpeterme/flux
brew install bpeterme/flux/flux
flux add       # initialise flux in a git repository
```

## License

MIT
