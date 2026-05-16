# claudebox

A shell utility that runs [Claude Code](https://github.com/anthropics/claude-code) inside an isolated Docker container, scoped to your current project directory.

Each project gets its own container, named after the directory. Two modes are available: **normal** (full access to your Claude config and SSH keys) and **safe** (sandboxed with dropped capabilities, memory/CPU limits, and an isolated network).

## Prerequisites

- Docker (Linux/macOS) or [Apple Container](https://github.com/apple/containerization) (macOS)
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
| `cbox stop` | Stop the current project's container |
| `cbox reset` | Remove the current project's container |
| `cbox rebuild` | Rebuild the Docker image |
| `cbox update` | Force-update Claude Code inside a running container |
| `cbox doctor` | Run environment diagnostics |
| `cbox list` | List all cbox containers |
| `cbox gc` | Remove all stopped cbox containers |

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

Create `~/.cbox.env` to override defaults. See [`cbox.env.example`](cbox.env.example) for all options.

| Variable | Default | Description |
|----------|---------|-------------|
| `CBOX_IMAGE` | `claude-dev` | Docker image name |
| `CBOX_DATA_DIR` | `~/.cbox` | State files directory |
| `CBOX_CLAUDE_DIR` | `~/.claude` | Claude Code config, mounted as `~/.claude` in container |
| `CBOX_HOST_CONFIG_DIR` | `~/.config` | Host config dir, mounted as `~/.config` in container (normal mode) |
| `CBOX_SHARE_DIR` | `~/.cbox/share` | Share folder, mounted as `~/share` in container; cleared on exit |
| `CBOX_SSH_DIR` | *(unset)* | SSH dir to mount as `~/.ssh` in container (normal mode); unset = no SSH mount |
| `CBOX_ZSHRC` | *(unset)* | Path to a `.zshrc` to source as `~/.zshrc.global` inside the container |
| `CBOX_DOTFILES_DIR` | *(unset)* | Directory to mount read-only inside the container at the same path |
| `CBOX_BUILD_DIR` | cbox.sh directory | Build context for `cbox rebuild` |
| `BUILD_PLAYWRIGHT` | `0` | Set to `1` to include Playwright + Chromium in the image |

### Example `~/.cbox.env`

```bash
CBOX_SSH_DIR="$HOME/.ssh/my-ssh-dir"
CBOX_ZSHRC="$HOME/.config/dotfiles/zshrc.global"
CBOX_DOTFILES_DIR="$HOME/.config/dotfiles"
CBOX_CLAUDE_DIR="$HOME/.claude"
CBOX_SHARE_DIR="$HOME/.cbox/share"
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

[`macos/screenshot.sh`](macos/screenshot.sh) captures an interactive screenshot (drag to select a region, same as ⇧⌘4) and saves it directly to the container's `~/share/` folder. It reads `~/.cbox.env` automatically so no path configuration is needed. See [`macos/README.md`](macos/README.md) for how to assign a keyboard shortcut via Automator, Hammerspoon, or Raycast.

## How It Works

- Container name is derived from the current directory name (e.g. `my-project`)
- Project directory is mounted at `/Workspace/<name>` inside the container
- Claude Code is updated automatically once per day on first use
- On exit, the container is stopped and the share folder is cleared
- `cbox keepalive` leaves the container running for 10 minutes (useful for follow-up `exec` calls)

## License

MIT
