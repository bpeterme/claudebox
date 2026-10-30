# claudebox

A shell utility that runs AI coding agents ([Claude Code](https://github.com/anthropics/claude-code) or [opencode](https://github.com/opencode-ai/opencode)) inside an isolated container, scoped to your current project directory. Uses [Apple Container](https://github.com/apple/container) on macOS and Docker on Linux.

Each project gets its own container, named after the directory. Two modes are available: **normal** (full access to your config and SSH keys) and **safe** (sandboxed with dropped capabilities, memory/CPU limits, and an isolated network).

## Prerequisites

- **macOS:** [Apple Container](https://github.com/apple/container) 1.0.0+ — requires macOS 26 and Apple Silicon
- **Linux:** Docker

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
cbox oc        # use opencode instead of Claude Code
cbox oc safe   # opencode in safe mode
```

## Commands

| Command | Description |
|---------|-------------|
| `cbox` | Start or enter normal container (Claude Code) |
| `cbox safe` | Start or enter sandboxed container |
| `cbox shell` | Open a zsh shell in the container |
| `cbox keepalive` | Run agent; keep container alive for 10 min after exit |
| `cbox oc [...]` | Same as above but use opencode (e.g. `cbox oc safe`, `cbox oc shell`) |

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
| `cbox update` | Force-update the active agent inside a running container |
| `cbox doctor` | Run environment diagnostics (includes companion tool status) |
| `cbox mcp` | Show host MCP servers and relay status |
| `cbox mcp import` | Import MCP servers from Claude Desktop / Claude Code on the host |
| `cbox warden` | List credential resources and what this project gets (see [Credentials (warden)](#credentials-warden)) |
| `cbox warden edit` | Define resources the container may use |
| `cbox warden secret set <resource>` | Store a resource's secret in the macOS Keychain |
| `cbox warden approve` | Approve this project's `.warden` file |
| `cbox warden test <resource>` | Check a resource from the host |
| `cbox warden log` | Show recent broker requests |
| `cbox version` | Show version |

## Container Modes

### Normal mode (`cbox`)
- Mounts your Claude config and optionally SSH keys and dotfiles
- Intended for trusted development work

### Safe mode (`cbox safe`, `cbox oc safe`)
- All Linux capabilities dropped (`--cap-drop=ALL`)
- No privilege escalation (`--security-opt no-new-privileges`)
- 4 GB memory limit, 2 CPU cores, 512 max PIDs
- Isolated network bridge (`cbox-bridge`)
- Agent config mounted read-only

### Git safety (both modes)

git on your Mac runs commands that a repository names: hooks in `.git/hooks`, and settings in `.git/config` such as `core.fsmonitor`, filters or `core.sshCommand`. Such a command runs with your Keychain and SSH keys, so code in the container must not be able to plant one.

- **Read-only:** the project's `.git/config` and `.git/hooks` are mounted read-only. Git commands that write the config fail inside the container (`git remote add`, `git config`, the upstream part of `git push -u`); run them on the Mac. A config change made on the Mac may only show up in the container after its next start. `CBOX_PROTECT_GIT=0` turns this off.
- **Check at the end:** when the last session of a container ends, cbox looks for git settings that run commands and were not there at the start: in nested repositories, submodules, worktrees, or a replaced `.git`. It names each one with its location and offers to put `.git/config` and `.git/hooks` back as they were (the changed files are kept in `~/.local/share/claudebox/git-guard/`). Repositories cloned in the container without such settings are not reported.
- **Claude and config folders:** if the folder mounted as `~/.claude` or `~/.config` is a git repository (e.g. claudedot's sync repo), its whole `.git` is read-only in the container, because claudedot runs git there on the Mac.

## Configuration

Create `~/.config/claudebox/cbox.env` to override defaults. See [`cbox.env.example`](cbox.env.example) for all options. If `$XDG_CONFIG_HOME` is set, the file goes in `$XDG_CONFIG_HOME/claudebox/cbox.env` instead.

| Variable | Default | Description |
|----------|---------|-------------|
| `CBOX_AGENT` | `claude` | Agent to run: `claude` (Claude Code) or `opencode`. Can also be set per-invocation with `cbox oc` |
| `CBOX_IMAGE` | `claudebox` | Docker image name |
| `CBOX_LABEL` | `cbox.project=true` | Label applied to all cbox containers |
| `CBOX_KEEPALIVE_SECONDS` | `600` | Seconds container stays alive before auto-stop in keepalive mode |
| `CBOX_DATA_DIR` | `~/.local/share/claudebox` | Per-project container config files (`.claude-<name>.json`), one per project |
| `CBOX_CLAUDE_DIR` | `~/.config/claudebox/.claude` | The container's Claude Code folder, mounted as `~/.claude` (read-write; read-only in safe mode). Not your Mac's `~/.claude`: Claude Code on the Mac runs the hooks in its `settings.json`, so cbox refuses it. On first use cbox copies your settings, `CLAUDE.md`, keybindings, agents, commands, skills and output styles into it (copies, not links); log in once inside the container |
| `CBOX_HOST_CONFIG_DIR` | `~/.config/claudebox/.config` | The container's own `~/.config` (normal mode, read-write). Not your real `~/.config`: that holds config that runs on your Mac and tokens, so cbox refuses it |
| `CBOX_SHARE_CONFIG` | *(unset)* | Folders of your real `~/.config` to share **read-only** into the container's `~/.config`, e.g. `"opencode nvim"`. Code in the container can read them, so leave out folders holding tokens (`gh`, `gcloud`). `claudebox` is never shared. Applies to newly created containers: `cbox reset` |
| `CBOX_SHARE_DIR` | `~/.cache/claudebox/share` | Share folder, mounted as `~/share` in container; cleared on exit (read-write) |
| `CBOX_PLAYWRIGHT_DIR` | `$CBOX_DATA_DIR/ms-playwright` | Playwright browser cache, mounted as `/opt/ms-playwright` (read-write; read-only in safe mode). Shared by all projects, kept across resets and rebuilds |
| `CBOX_SSH_DIR` | *(unset)* | SSH dir to mount as `~/.ssh` in container (normal mode, **read-only**); unset = no SSH mount. With a warden ssh resource, only `config`, `known_hosts` and `*.pub` are mounted |
| `CBOX_ZSHRC` | *(unset)* | `.zshrc` to source as `~/.zshrc.global` inside the container (**read-only**); unset = none |
| `CBOX_BUILD_DIR` | cbox.sh directory | Build context for `cbox rebuild` |
| `BUILD_PLAYWRIGHT` | `0` | Set to `1` to bake Playwright + Chromium into the image on the next `cbox rebuild` (or pass it inline). Decides whether the browser download happens at build time or on first use |
| `CBOX_AUDIO` | *(unset)* | Set to `1` to enable Claude Code voice mode (requires PulseAudio on host) |
| `CBOX_MCP_CONFIG` | `~/.config/claudebox/mcp.json` | MCP servers that run on the host and are relayed into the container (see [Host MCP Servers](#host-mcp-servers)) |
| `CBOX_WARDEN_DIR` | `$CBOX_DATA_DIR/warden` | warden resources, approvals and session tokens — host only, never mounted |
| `CBOX_WARDEN_PORT` | `47100` | Port of the warden broker, bound only to the container-facing host address |
| `CBOX_MEMORY` | `4g` | Memory of each container (both modes). Applies to newly created containers: `cbox reset` |
| `CBOX_PROTECT_GIT` | `1` | Mount the project's `.git/config` and `.git/hooks` read-only (see [Git safety](#git-safety-both-modes)); `0` = writable. Applies to newly created containers: `cbox reset` |
| `CBOX_WARDEN_HOST` | `192.168.64.1` (Apple) / `docker0` IP | Host address containers reach the broker on |
| `CBOX_WARDEN_SECRET_CMD` | *(unset)* | Hosts without the macOS Keychain: command that prints the secret for an item name |

> [!WARNING]
> **Do not place `CBOX_CLAUDE_DIR` (default `~/.config/claudebox/.claude`) or your project directories on iCloud Drive, Dropbox Smart Sync, Google Drive Stream, or any on-demand cloud storage.** These services evict file contents to stubs when not recently accessed. A container mounting an evicted path will fail to read files that appear to exist on disk — a subtle failure that is hard to diagnose.
>
> **Do not use continuous sync tools (Syncthing, rsync daemons, etc.) on `CBOX_CLAUDE_DIR`.** They can write into the directory while Claude is actively appending to a conversation file, risking corruption or lost writes. If you need to sync it across machines, use [claudedot](https://github.com/bpeterme/claudedot) — it only touches the directory at explicit session boundaries.

## Container Image

The image is based on Ubuntu 24.04 and includes:

- Node.js 22, Claude Code, opencode
- Python 3, [uv](https://github.com/astral-sh/uv)
- Git, git-crypt, openssh-client
- ripgrep, fd-find, jq, eza
- zsh with autosuggestions and syntax highlighting
- SoX + PulseAudio client (for voice mode)
- Playwright + Chromium (opt-in via `BUILD_PLAYWRIGHT=1`), installed into
  `/opt/ms-playwright`. That path is bind-mounted from `CBOX_PLAYWRIGHT_DIR` on the
  host, so browsers are downloaded once per machine rather than once per container —
  and survive `cbox reset`, `cbox prune` and image rebuilds

The container user is `claude` (UID matches your host UID to avoid permission issues on mounted volumes).

## Host MCP Servers

Some MCP servers only work on the Mac itself — [iMCP](https://github.com/mattt/iMCP)
(Reminders, Calendar, Contacts, Messages), anything that talks to a macOS app or the
Keychain. List those in `~/.config/claudebox/mcp.json`, in the usual format:

```json
{
  "mcpServers": {
    "imcp": { "command": "/Applications/iMCP.app/Contents/MacOS/imcp-server" }
  }
}
```

Or import them from Claude Desktop / Claude Code on the host with `cbox mcp import`.
Changes take effect with the next `cbox` session; `cbox mcp` shows what is configured.

**How it works.** The server runs on the host; Claude in the container talks to it over
the container runtime's own `exec` channel. Nothing listens on the network — neither
on the host nor in the container — so the server is not reachable from your LAN.
Each connection starts a fresh server process, just like a local stdio server.

**What belongs where.**

| Server | Where |
|--------|-------|
| Needs macOS (apps, Keychain, local hardware) | `~/.config/claudebox/mcp.json` (host) |
| Works on files or repositories (filesystem, git, …) | Inside the container: the project's `.mcp.json` or `claude mcp add` — a host server would see host paths, not `/Workspace` |
| Remote (`https://…`) | Either; entries with a `url` in `mcp.json` are passed through as-is |

URLs on the host's `localhost` are not supported and are skipped with a warning.
Host MCP servers are not available in safe mode.

### Troubleshooting host MCP servers

If Claude reports that a host server failed to connect (for example after its 30 s
connect timeout), start with `cbox mcp`: it shows the latest problem under each server.
The full log is on the host:

```bash
tail ~/.local/share/claudebox/.mcp-relay-<project>.log
```

"no response from the server … after a client connected" means the server started
but never answered. The relay is fine in that case; the server is stuck. Check
whether it answers outside cbox (iMCP shown; use your server's command):

```bash
(printf '%s\n' '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"test","version":"0"}}}'; sleep 10) \
  | /Applications/iMCP.app/Contents/MacOS/imcp-server
```

A JSON response within a few seconds means the server works. If there is no output,
the server is stuck. For iMCP, the two known causes are:

- **Local Network access is off.** `imcp-server` finds iMCP.app via Bonjour and
  needs its own permission, separate from iMCP and from your terminal app. Turn on
  both `imcp-server` and iMCP in System Settings → Privacy & Security → Local Network.
  Without it, discovery silently times out and retries forever.
- **Another Mac on the network runs iMCP.** The other Mac's instance can claim the
  Bonjour name "iMCP", and `imcp-server` then connects to the wrong one and retries
  silently. This command should list exactly one service, named plain `iMCP`
  (stop it with Ctrl-C):

  ```bash
  dns-sd -B _mcp._tcp local.
  ```

  If it shows `iMCP (2)` or more than one entry, quit iMCP on the other Mac.

Server processes end together with their connection. Anything left over from an
earlier failure is cleared by restarting the session: exit every `cbox` session for
the project (or run `cbox stop`) and start `cbox` again.

## Credentials (warden)

Code in the container can use API keys and other credentials **without the
container ever holding them**. A broker on the host keeps the secret (macOS
Keychain), checks each request against what you allowed, and adds the
credential on the way out. Inside the container, requests go to
`$WARDEN_URL/<resource>/...` — the key a client sends is always replaced.

```sh
cbox warden secret set openrouter   # paste the key; stored in the Keychain
cbox warden edit                    # define the resource (template included)
cbox warden test openrouter         # check it from the host
```

Resources live in `~/.local/share/claudebox/warden/resources` (`$CBOX_WARDEN_DIR`).
The file holds no secrets — only Keychain item names and URLs — so it can be
kept in a dotfiles repo and symlinked there. Keep it out of anything a container
mounts: if a container could edit it, it could point a resource at its own
server. warden checks this and stays off, with a message, when the file or its
directory is visible inside a container.

A resource is either available to every container (`availability = global`)
or only to projects that list it in a tracked `.warden` file **and** whose
`.warden` you approved on the host (`project`). Editing `.warden` — also from
inside the container — needs a new approval at the next session start.

**S3-compatible storage** (AWS S3, Cloudflare R2, MinIO, …) uses `auth = sigv4`:
the container gets an AWS profile with dummy keys (`AWS_CONFIG_FILE`), and the
broker re-signs every request with the real ones. `policy = dvc` limits a
resource to DVC's data layout in one bucket and prefix, with no deletes. The
prefix comes from the project's `.warden`, so one resource serves every
project in a bucket:

```ini
# .warden (tracked in the project)
[storage]
prefix = my-project
```

**SSH keys** (`type = ssh`) stay on the Mac. The container gets an ssh agent
(`SSH_AUTH_SOCK`) instead of the key file, so `git push` and `ssh` work as
usual, but nothing in the container can copy the key:

```ini
[github]
type  = ssh
key   = ~/.ssh/id_ed25519     # id_ed25519.pub must sit next to it
hosts = github.com            # the key signs only for these hosts
```

- warden runs an agent of its own (not your usual one) and adds the key with
  `ssh-add -h <host>`, so the agent itself refuses to sign for any other host.
  The first `cbox` session after a Mac restart unlocks it; on macOS, ssh-add
  takes the passphrase from the Keychain, and asks once otherwise.
- `ssh-add -h` needs the host's key in `~/.ssh/known_hosts` on the Mac. If it
  says none were found, connect once from the Mac (`ssh -T git@github.com`).
- The container may only list the keys granted to it and sign with them;
  adding, removing or locking keys is refused. Signatures are logged
  (`cbox warden log`).
- Once any ssh resource exists, `CBOX_SSH_DIR` mounts only `config`,
  `known_hosts` and `*.pub` files — no private keys (from the next `cbox reset`).

Not available in safe mode.

## macOS: Screenshot Script

[`macos/screenshot.sh`](macos/screenshot.sh) captures an interactive screenshot (drag to select a region, same as ⇧⌘4) and saves it directly to the container's `~/share/` folder. It reads `~/.config/claudebox/cbox.env` automatically so no path configuration is needed. See [`macos/README.md`](macos/README.md) for how to assign a keyboard shortcut via Automator, Hammerspoon, or Raycast.

## Voice Mode

> [!NOTE]
> Voice mode is Claude Code only. It has no equivalent in opencode and is not activated for `cbox oc` sessions.

Claude Code's `/voice` command lets you dictate prompts using your microphone. Inside a container there is no direct audio device, so claudebox bridges your Mac's microphone through PulseAudio. The container reaches it through a private socket that only cbox relays — PulseAudio opens no network port.

### Setup (one time)

**1. Install PulseAudio on your Mac:**

```bash
brew install pulseaudio
```

**2. Enable audio in your claudebox config:**

```bash
# ~/.config/claudebox/cbox.env
CBOX_AUDIO=1
```

**3. Rebuild the container image** to include the SoX PulseAudio backend:

```bash
cbox rebuild
```

That's it. claudebox starts PulseAudio with the first `cbox` session and stops it when the last one closes (only if it started it). Inside the container, run `/voice` to activate dictation.

Older claudebox versions opened PulseAudio on TCP port 4713 for every private network. claudebox now removes that line from `~/.config/pulse/default.pa` and closes a listener that is still open.

### Requirements

- Claude.ai account (voice dictation is not available with a raw API key or third-party providers)
- macOS with Apple Container or Docker Desktop; not available in `cbox safe` mode

### Troubleshooting

Run `cbox doctor` to check PulseAudio status. If voice fails inside the container:

```bash
# Test PulseAudio connectivity from inside the container
pactl info
```

If `pactl` cannot connect, check on the host that PulseAudio runs (`pulseaudio --check`) and look at the tunnel's log: `~/.local/share/claudebox/.tunnel-<project>.log`.

## How It Works

- Container name is derived from the current directory name (e.g. `my-project`)
- Project directory is mounted at `/Workspace/<name>` inside the container
- The active agent (`claude` or `opencode`) is updated automatically once per day on first use; each agent has its own independent update stamp
- `cbox oc` (or `CBOX_AGENT=opencode` in `cbox.env`) selects opencode for the session; opencode reads its config from `~/.config/opencode`; to use your Mac's, add `CBOX_SHARE_CONFIG="opencode"` to `cbox.env`
- On exit, the container is stopped and the share folder is cleared
- `cbox keepalive` leaves the container running for 10 minutes (useful for follow-up `exec` calls)
- Log in once inside a container (`/login`); the login is kept in `CBOX_CLAUDE_DIR` and shared by all containers
- If [claudedot](https://github.com/bpeterme/claudedot) is installed, Claude config and history sync runs automatically at session start and exit (Claude sessions only)
- If [flux](https://github.com/bpeterme/flux) is installed, the container runs the host's flux version, and flux projects reach their storage through warden: `dvc pull` and a plain `git push` (flux's pre-push hook uploads the data first) work inside the container

## Companion Tools

### [claudedot](https://github.com/bpeterme/claudedot)

[claudedot](https://github.com/bpeterme/claudedot) (`cdot`) syncs your Claude config and per-project conversation history across machines via a private git remote. Config (settings, keybindings, global instructions) syncs automatically on every session; project history is opt-in per project. claudebox calls `cdot` automatically at session boundaries if it is installed — no manual steps needed. It syncs the folder containers use (`CBOX_CLAUDE_DIR`), unless `CDOT_CLAUDE_DIR` in `cdot.env` names another.

```bash
brew tap bpeterme/claudedot
brew install bpeterme/claudedot/claudedot
cdot config    # connect to your sync remote
```

### [flux](https://github.com/bpeterme/flux)

[flux](https://github.com/bpeterme/flux) handles automatic file routing between any Git remote and Cloudflare R2 object storage. If your projects involve large assets alongside code, claudebox and flux complement each other naturally — claudebox scopes Claude Code to your project, flux manages the file transport layer for assets that don't belong in a regular git repo. Inside a claudebox container, flux projects use their storage through warden (see Credentials): the container never holds the R2 keys.

```bash
brew tap bpeterme/flux
brew install bpeterme/flux/flux
flux add       # initialise flux in a git repository
```

## License

MIT
