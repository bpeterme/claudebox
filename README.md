# claudebox

A shell utility that runs AI coding agents ([Claude Code](https://github.com/anthropics/claude-code) or [opencode](https://github.com/opencode-ai/opencode)) inside an isolated container, scoped to your current project directory. Uses [Apple Container](https://github.com/apple/container) on macOS and Docker on Linux, including WSL2 on Windows.

Each project gets its own container, named after the directory. Two modes are available: **normal** (full access to your config and SSH keys) and **safe** (sandboxed with dropped capabilities, memory/CPU limits, and internet access only to hosts you allow).

## Prerequisites

- **macOS:** [Apple Container](https://github.com/apple/container) 1.0.0+ — requires macOS 26 and Apple Silicon (`cbox doctor` tells you when newer releases fix security issues)
- **Linux (incl. WSL2):** Docker — see [Linux and WSL](#linux-and-wsl)

### Linux and WSL

claudebox uses Docker on Linux. On WSL2 that is either Docker Engine installed in
the distro (behaves like any Linux) or Docker Desktop with WSL integration.

warden keeps secrets in the desktop keyring through `secret-tool`, as flux does:

```bash
sudo apt install libsecret-tools        # Fedora: sudo dnf install libsecret
```

WSL2 and servers usually run no keyring; start one per session first:

```bash
sudo apt install gnome-keyring dbus-x11
[ -n "$DBUS_SESSION_BUS_ADDRESS" ] || eval "$(dbus-launch --sh-syntax)"
read -rsp "Keyring password: " pw; echo   # the first unlock creates the keyring with it
printf '%s' "$pw" | gnome-keyring-daemon --unlock --components=secrets >/dev/null; unset pw
```

Docker Desktop: turn on Settings → Resources → WSL integration for your distro,
and add yourself to the `docker` group (`sudo usermod -aG docker $USER`, then
`wsl --shutdown`). `cbox` says which of these is missing.

The warden broker listens on the Docker bridge address (`docker0`). Docker
Desktop on WSL has none inside the distro; there `cbox` uses the distro's `eth0`
address, which Docker Desktop's containers reach (WSL 2 distros share one
network). Set `CBOX_WARDEN_HOST` to choose another address.

Mac-only features (iMCP and other host MCP servers that need macOS apps,
WhatsApp chats) are not available on Linux.

## Installation

### Homebrew (macOS)

```bash
brew tap bpeterme/claudebox
brew install bpeterme/claudebox/claudebox
cbox --help
```

### Manual (Linux, WSL — or macOS)

Homebrew on Linux is untested; use a clone:

```bash
git clone https://github.com/bpeterme/claudebox.git ~/claudebox
# update later: git -C ~/claudebox pull
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

The image is built once before the first session: on Linux the first `cbox`
does it (about 5–10 minutes); on macOS run `cbox rebuild` once.

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
| `cbox shell` | Open a zsh shell in the container, in whatever mode it has (a new one is normal) |
| `cbox keepalive` | Run agent; keep container alive for 10 min after exit |
| `cbox oc [...]` | Same as above but use opencode (e.g. `cbox oc safe`, `cbox oc shell`) |

**Container management**

| Command | Description |
|---------|-------------|
| `cbox stop` | Stop the current project's container |
| `cbox reset [<name>]` | Remove the current project's container (or a named container) |
| `cbox rebuild` | Rebuild the container image |
| `cbox list` | List all cbox containers |
| `cbox prune` | Remove all stopped cbox containers; on macOS also reclaim unused disk space in running ones |

**Maintenance**

| Command | Description |
|---------|-------------|
| `cbox update` | Force-update the active agent inside a running container |
| `cbox doctor` | Run environment diagnostics: where your settings, data and logs are, companion tool status and, on macOS, whether Apple container is up to date |
| `cbox mcp` | Show host MCP servers and relay status |
| `cbox mcp import` | Import MCP servers from Claude Desktop / Claude Code on the host |
| `cbox warden` | List credential resources (APIs, storage, ssh keys, MCP servers, WhatsApp chats, mail groups) and what this project gets (see [Credentials (warden)](#credentials-warden)) |
| `cbox warden edit` | Define resources the container may use |
| `cbox warden secret set <resource>` | Store a resource's secret in the macOS Keychain (Linux: keyring) |
| `cbox warden approve` | Approve this project's `.warden` file |
| `cbox warden test <resource>` | Check a resource from the host |
| `cbox warden whatsapp pick <resource>` | Choose the WhatsApp chats Claude may read (read-only) |
| `cbox warden mail [show <thread>\|-f]` | Read what agents sent each other; `resume <thread>` lets a paused thread go on (see [Agent mail](#agent-mail)) |
| `cbox warden log` | Show recent broker requests |
| `cbox version` | Show version |

## Container Modes

### Normal mode (`cbox`)
- Mounts your Claude config and optionally SSH keys and dotfiles
- Intended for trusted development work

### Safe mode (`cbox safe`, `cbox oc safe`)
- All Linux capabilities dropped (`--cap-drop=ALL`)
- No privilege escalation: `sudo` cannot switch to root without capabilities (Docker also sets `--security-opt no-new-privileges`)
- 4 GB memory limit, 2 CPU cores, 512 max processes
- Agent config read-only, except the login: safe and normal containers share one login, and a refresh in either keeps it valid for both. Each safe container has its own `~/.claude` (in `$CBOX_DATA_DIR/safe-claude/<name>`) whose entries link to the shared folder; its `.credentials.json` is the shared file itself (a hard link). A safe container can therefore change the shared login, but not your settings, hooks or skills
- Claude Code's telemetry and error reports are off (`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`)
- Internet access only to allowed hosts (see below)
- Secret files in the project read as empty (see below)

#### Outbound traffic in safe mode

A safe container has no network of its own: Docker gives it none, and Apple's runtime puts it on a host-only network (`cbox-safe`). Its only way out is a proxy on your Mac, reached through the tunnel (not the network) at `127.0.0.1:3128` inside the container. The session sets `HTTPS_PROXY` and `HTTP_PROXY` to it. The proxy lets through only the hosts on its allow list, so code that a prompt talked the agent into running cannot send your project anywhere else. The list lives on your Mac, so nothing in the container can change it.

Allowed by default:

- the agents and their sign-in: `api.anthropic.com`, `statsig.anthropic.com`, `claude.ai`, `console.anthropic.com`, `platform.claude.com`, `opencode.ai`, `models.dev`
- packages and git over https: `registry.npmjs.org`, `pypi.org`, `files.pythonhosted.org`, `github.com`, `api.github.com`, `codeload.github.com`, `*.githubusercontent.com`

Add more in `cbox.env`; they apply from the next session:

```bash
CBOX_EGRESS_ALLOW="openrouter.ai *.example.com registry.example.com:8443"
```

An entry without a port allows ports 443 and 80. `*.example.com` allows every subdomain, but not `example.com` itself. A blocked request gets `403`; for plain http it carries a note naming the host and the setting, while https clients only report it, e.g. curl's `CONNECT tunnel failed, response 403`. Blocked hosts are also logged in `$CBOX_DATA_DIR/.tunnel-<name>.log`.

Limits:

- Only programs that use the proxy settings get out: curl, git over https, npm, pip, uv, Claude Code, opencode. git over ssh does not work in safe mode.
- A host name never leads to this machine itself or a link-local address. To reach a server on your local network, list its IP address.
- On Apple's runtime the host-only network still reaches services on your Mac that listen on all interfaces.
- Safe containers created by an older cbox can still reach everything, or cannot keep the login fresh; cbox says so at session start. Recreate one with `cbox reset`.

#### Hidden secret files

A safe container sees secret files in the project as empty files: it cannot read them, and what it writes to them is discarded. The files on your Mac stay as they are. By default this covers:

- `.env` and `.env.*`, but not `.env.example`, `.env.sample` or `.env.template`
- `*.pem`, `*.key`, and private SSH keys (`id_rsa*`, `id_ecdsa*`, `id_ed25519*`, but not `*.pub`)

Change the list in `cbox.env`. It applies to both modes once set; `CBOX_MASK=""` hides nothing:

```bash
CBOX_MASK=".env .env.* !.env.example *.pem secrets/ config/prod.yml"
```

`name` or `*.ext` matches a file anywhere in the project, `dir/` a folder (shown empty), `a/b` a path from the project root, and `!pattern` keeps a match visible. `.git` and `node_modules` are not searched.

Limits:

- The list is fixed when the container is created. A secret file added later stays visible until `cbox reset`; cbox names such files at session start.
- Code in the container cannot use the hidden values either. To let it use a credential without seeing it, use [warden](#credentials-warden).
- A hidden file that git tracks shows up as changed in the container; do not commit it from there (cbox warns when it creates the container). Secrets that were ever committed are still in `.git`.
- `*.key` also matches Keynote files. If a project has Keynote files, set `CBOX_MASK` with `!*.key` and name its real key files instead.
- Apple's runtime needs container 1.2.1 or newer (`--masked-path`). With an older one cbox does not create the container, rather than create it without hiding.

### Reaching a server in the container (`.cbox`)

A web server in the container can be opened on your host at `http://localhost:<port>`, at the same address every session. List its ports in a `.cbox` file in the project folder:

```ini
# .cbox (in the project folder, e.g. tracked in git)
ports = 47821 3000
```

- **localhost only:** each port is published on the host's `127.0.0.1`, never to your network. `localhost` also counts as a secure origin, so browser features that need HTTPS (e.g. `crypto.subtle`) work over plain http.
- **Listen on `0.0.0.0`:** the server inside must listen on all addresses (`0.0.0.0`), not only on the container's `127.0.0.1`.
- **Set at creation:** a runtime publishes ports when it creates a container. After you change `.cbox`, cbox says so at the next start; apply it with `cbox reset`.
- **Normal mode only:** safe containers publish no ports.
- Ports 1024–65535; a port another program on the host already uses cannot be published.

### Git safety (both modes)

git on your host runs commands that a repository names: hooks in `.git/hooks`, and settings in `.git/config` such as `core.fsmonitor`, filters or `core.sshCommand`. Such a command runs with your Keychain (or keyring) and SSH keys, so code in the container must not be able to plant one.

- **Read-only:** the project's `.git/config` and `.git/hooks` are mounted read-only. Git commands that write the config fail inside the container (`git remote add`, `git config`, the upstream part of `git push -u`); run them on the host. A config change made on the Mac may only show up in the container after its next start. `CBOX_PROTECT_GIT=0` turns this off.
- **Check at the end:** when the last session of a container ends, cbox looks for git settings that run commands and were not there at the start: in nested repositories, submodules, worktrees, or a replaced `.git`. It names each one with its location and offers to put `.git/config` and `.git/hooks` back as they were (the changed files are kept in `$CBOX_DATA_DIR/git-guard/`). Repositories cloned in the container without such settings are not reported.
- **git-crypt:** `git-crypt init` writes its own path into `.git/config` (on a Mac `/opt/homebrew/bin/git-crypt`), which does not exist in the container. The image overrides the git-crypt filter through git's environment config, so git uses the container's `git-crypt` and `.git/config` stays as the host needs it.
- **Claude and config folders:** if the folder mounted as `~/.claude` or `~/.config` is a git repository (e.g. claudedot's sync repo), its whole `.git` is read-only in the container, because claudedot runs git there on the host.

## Configuration

Create `~/.config/claudebox/cbox.env` to override defaults. See [`cbox.env.example`](cbox.env.example) for all options. If `$XDG_CONFIG_HOME` is set, the file goes in `$XDG_CONFIG_HOME/claudebox/cbox.env` instead.

| Variable | Default | Description |
|----------|---------|-------------|
| `CBOX_AGENT` | `claude` | Agent to run: `claude` (Claude Code) or `opencode`. Can also be set per-invocation with `cbox oc` |
| `CBOX_IMAGE` | `claudebox` | Docker image name |
| `CBOX_LABEL` | `cbox.project=true` | Label applied to all cbox containers |
| `CBOX_KEEPALIVE_SECONDS` | `600` | Seconds container stays alive before auto-stop in keepalive mode |
| `CBOX_DATA_DIR` | `~/.local/share/claudebox` | Per-project container config files (`.claude-<name>.json`) and logs; `cbox doctor` shows the folder in use |
| `CBOX_CLAUDE_DIR` | `~/.config/claudebox/.claude` | The container's Claude Code folder, mounted as `~/.claude` (read-write; read-only in safe mode, except the login). Not your Mac's `~/.claude`: Claude Code on the Mac runs the hooks in its `settings.json`, so cbox refuses it. On first use cbox copies your settings, `CLAUDE.md`, keybindings, agents, commands, skills and output styles into it (copies, not links); log in once inside the container |
| `CBOX_HOST_CONFIG_DIR` | `~/.config/claudebox/.config` | The container's own `~/.config` (normal mode, read-write). Not your real `~/.config`: that holds config that runs on your Mac and tokens, so cbox refuses it |
| `CBOX_SHARE_CONFIG` | *(unset)* | Folders of your real `~/.config` to share **read-only** into the container's `~/.config`, e.g. `"opencode nvim"`. Code in the container can read them, so leave out folders holding tokens (`gh`, `gcloud`). `claudebox` is never shared. Applies to newly created containers: `cbox reset` |
| `CBOX_SHARE_DIR` | `~/.cache/claudebox/share` | Share folder, mounted as `~/share` in container; cleared when the last cbox session on this Mac closes (read-write) |
| `CBOX_PLAYWRIGHT_DIR` | `$CBOX_DATA_DIR/ms-playwright` | Playwright browser cache, mounted as `/opt/ms-playwright` (read-write; read-only in safe mode). Shared by all projects, kept across resets and rebuilds |
| `CBOX_SSH_DIR` | *(unset)* | SSH dir to mount as `~/.ssh` in container (normal mode, **read-only**); unset = no SSH mount. With a warden ssh resource, only `config`, `known_hosts` and `*.pub` are mounted |
| `CBOX_ZSHRC` | *(unset)* | `.zshrc` to source as `~/.zshrc.global` inside the container (**read-only**); unset = none. The container also sources `~/.zshrc.local`, but that file lives in the container only: `cbox rebuild` and `cbox reset` remove it, so use it for temporary tweaks |
| `CBOX_BUILD_DIR` | cbox.sh directory | Build context for `cbox rebuild` |
| `BUILD_PLAYWRIGHT` | `0` | Set to `1` to bake Playwright + Chromium into the image on the next `cbox rebuild` (or pass it inline). Decides whether the browser download happens at build time or on first use |
| `CBOX_AUDIO` | *(unset)* | Set to `1` to enable Claude Code voice mode (requires PulseAudio on host) |
| `CBOX_MCP_CONFIG` | `~/.config/claudebox/mcp.json` | MCP servers that run on the host and are relayed into the container (see [Host MCP Servers](#host-mcp-servers)) |
| `CBOX_WARDEN_DIR` | `$CBOX_DATA_DIR/warden` | warden resources, approvals and session tokens — host only, never mounted |
| `CBOX_WARDEN_PORT` | `47100` | Port of the warden broker, bound only to the container-facing host address |
| `CBOX_MEMORY` | `4g` | Memory of each container (both modes). Applies to newly created containers: `cbox reset` |
| `CBOX_EGRESS_ALLOW` | *(unset)* | Hosts a safe container may reach besides the defaults, e.g. `"openrouter.ai *.example.com host:8443"` (see [Outbound traffic in safe mode](#outbound-traffic-in-safe-mode)). Applies from the next session |
| `CBOX_MASK` | *(safe mode: secret files)* | Files and folders in the project the container sees empty (see [Hidden secret files](#hidden-secret-files)). Unset: the default list in safe mode, nothing in normal mode; once set, it applies to both modes; `""` = nothing. Applies to newly created containers: `cbox reset` |
| `CBOX_PROTECT_GIT` | `1` | Mount the project's `.git/config` and `.git/hooks` read-only (see [Git safety](#git-safety-both-modes)); `0` = writable. Applies to newly created containers: `cbox reset` |
| `CBOX_WARDEN_HOST` | Apple: the default network's gateway (usually `192.168.64.1`) / `docker0` IP (WSL without it: `eth0`) | Host address containers reach the broker on |
| `CBOX_WARDEN_SECRET_CMD` | *(unset)* | Instead of the Keychain or keyring: command that prints the secret for an item name |

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
Keychain. List those in `$CBOX_MCP_CONFIG` (default `~/.config/claudebox/mcp.json`), in the usual format:

```json
{
  "mcpServers": {
    "imcp": { "command": "/Applications/iMCP.app/Contents/MacOS/imcp-server" }
  }
}
```

Or import them from Claude Desktop / Claude Code on the host with `cbox mcp import`.
Both agents get them: Claude Code in its `~/.claude.json`, opencode through an extra
config file cbox writes in the container (`OPENCODE_CONFIG`, merged over your own).
Changes take effect with the next `cbox` session; `cbox mcp` shows what is configured.

**How it works.** The server runs on the host; Claude in the container talks to it over
the container runtime's own `exec` channel. Nothing listens on the network — neither
on the host nor in the container — so the server is not reachable from your LAN.
Each connection starts a fresh server process, just like a local stdio server.

**What belongs where.**

| Server | Where |
|--------|-------|
| Needs macOS (apps, Keychain, local hardware) | `$CBOX_MCP_CONFIG` (host) |
| Works on files or repositories (filesystem, git, …) | Inside the container: the project's `.mcp.json` or `claude mcp add` — a host server would see host paths, not `/Workspace` |
| Remote (`https://…`) without a token | `mcp.json` (passed through as-is) or inside the container |
| Remote with an API key or token | A warden resource with `type = mcp` (see [Credentials](#credentials-warden)) — the token stays on the host |
| WhatsApp chats | A warden resource with `type = whatsapp` (see [WhatsApp chats](#whatsapp-chats)) — only the chats you choose, per project |

A remote entry in `mcp.json` is copied into the container as-is, `headers`
included — anything in them is readable there, and cbox warns about it.
URLs on the host's `localhost` are not supported and are skipped with a warning.
Host MCP servers are not available in safe mode.

### Troubleshooting host MCP servers

If Claude reports that a host server failed to connect (for example after its 30 s
connect timeout), start with `cbox mcp`: it shows the latest problem under each server.
The full log is on the host; `cbox mcp` prints its path.

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
Keychain or Linux keyring), checks each request against what you allowed, and adds the
credential on the way out. Inside the container, requests go to
`$WARDEN_URL/<resource>/...` — the key a client sends is always replaced.

| You have | Resource | The container gets |
|----------|----------|--------------------|
| An API key (OpenRouter, OpenAI, …) | `type = http` | `$WARDEN_URL/<resource>` plus the env vars you choose |
| S3-compatible storage keys (R2, S3, MinIO) | `type = http`, `auth = sigv4` | An AWS profile with dummy keys |
| An SSH key (GitHub, GitLab, servers) | `type = ssh` | An ssh agent that signs only for the hosts you list |
| A remote MCP server's token | `type = mcp` | The server in Claude's and opencode's MCP list |
| WhatsApp chats you choose (WhatsApp Desktop on this Mac) | `type = whatsapp` | A read-only MCP server that knows only those chats (see [WhatsApp chats](#whatsapp-chats)) |
| Messages between the agents of your projects | `type = mail` | An MCP server to message the other projects in the group (see [Agent mail](#agent-mail)) |

```sh
cbox warden secret set openrouter   # paste the key; stored in the Keychain (Linux: keyring)
cbox warden edit                    # define the resource (template included)
cbox warden test openrouter         # check it from the host
```

Resources live in `$CBOX_WARDEN_DIR/resources` (default `~/.local/share/claudebox/warden/resources`).
The file holds no secrets — only Keychain/keyring item names and URLs — so it can be
kept in a dotfiles repo and symlinked there. Keep it out of anything a container
mounts: if a container could edit it, it could point a resource at its own
server. warden checks this and stays off, with a message, when the file or its
directory is visible inside a container.

Each `[section]` names a resource: lowercase letters, digits, `.`, `_` and `-`,
up to 64 characters, starting with a letter or digit (e.g. `[github]`, `[build.server]`).

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

**SSH keys** (`type = ssh`) stay on the host. The container gets an ssh agent
(`SSH_AUTH_SOCK`) instead of the key file, so `git push` and `ssh` work as
usual, but nothing in the container can copy the key. Keys come only from
`CBOX_SSH_DIR`, the claudebox ssh folder set in `cbox.env` — never from your own
`~/.ssh`:

```ini
[github]
type  = ssh
key   = id_ed25519            # a key file in CBOX_SSH_DIR; id_ed25519.pub must sit next to it
hosts = github.com            # the key signs only for these hosts
```

`hosts` takes names, IP addresses and `host:port`, e.g.
`hosts = github.com 203.0.113.5 198.51.100.7:2222` — the servers as the
container reaches them. Where ssh connects (IP, port, user) still comes from
the ssh command or `$CBOX_SSH_DIR/config`. A key outside `CBOX_SSH_DIR` is
refused; without `CBOX_SSH_DIR`, ssh resources stay off.

- warden runs an agent of its own (not your usual one) and adds the key with
  `ssh-add -h <host>`, so the agent itself refuses to sign for any other host.
  The first `cbox` session after a restart unlocks it; on macOS, ssh-add
  takes the passphrase from the Keychain, and asks once otherwise.
- The agent recognises each server by its host key. warden keeps its own list
  of confirmed server keys (`$CBOX_WARDEN_DIR/ssh/known_hosts`, never mounted).
  For a new server, the next `cbox` session shows the key's fingerprint and asks
  once whether to trust it. The key comes from `$CBOX_SSH_DIR/known_hosts`
  if it lists the server, otherwise from the server itself (`ssh-keyscan` from
  the host). It is never trusted from that file alone, because containers can
  write it. If a server's key changes, delete its line from warden's list.
  The container's ssh gets the confirmed keys of its granted servers as its
  system list (`/etc/ssh/ssh_known_hosts`), so it does not ask again.
- Several resources may use the same key, e.g. `[github]` for every
  container and `[build.server]` with `availability = project`. Before each signature,
  ssh tells the agent which server it is connected to; warden signs only when
  that server belongs to a resource granted to the container. Adding, removing
  or locking keys is refused. Signatures are logged with the resource
  (`cbox warden log`).
- Once any ssh resource exists, `CBOX_SSH_DIR` mounts only `config`,
  `known_hosts` and `*.pub` files — no private keys (from the next `cbox reset`).

**Remote MCP servers** that take an API key (`type = mcp`) are added to Claude's
MCP servers in the container with a warden URL; the broker adds the key and
passes only the server's own endpoint:

```ini
[linear]
type   = mcp
url    = https://mcp.linear.app/mcp
auth   = bearer                  # bearer | basic | header:<Name> | query:<param>
secret = cbox.warden.linear      # cbox warden secret set linear
```

`cbox warden test linear` sends an MCP `initialize` from the host. Claude Code
and opencode both get these servers. Servers that only offer an OAuth login (no
API key) are not supported through warden.

**opencode providers.** `opencode = <provider id>` on an http resource points
that opencode provider at warden (base URL and a dummy key), so the API key can
leave `opencode.json` — which a container can read when it is shared:

```ini
[openrouter]
upstream = https://openrouter.ai/api/v1
auth     = bearer
secret   = cbox.warden.openrouter
opencode = openrouter
```

**One endpoint outside the upstream path.** A request to
`$WARDEN_URL/<resource>/<path>` goes to the upstream URL plus `<path>`, and
`..` is refused, so an endpoint beside the upstream path needs a resource of
its own. Give it the same secret and allow just that one call. Example:
OpenRouter's decisions models (e.g. TypeSafe Jev, used for classification)
only answer at `https://openrouter.ai/api/alpha/decisions`, next to `/api/v1`:

```ini
[openrouter-decisions]
upstream = https://openrouter.ai/api/alpha
auth     = bearer
secret   = cbox.warden.openrouter            # the same Keychain item as [openrouter]
allow    = POST /decisions                   # this one call, nothing else
env      = OPENROUTER_DECISIONS_URL={url}/decisions
```

The container then posts to `$OPENROUTER_DECISIONS_URL`. A new resource
reaches a container at its next session start (exit its sessions, start
`cbox` again); a changed `allow` on an existing one applies at once.

Not available in safe mode.

### WhatsApp chats

Claude can read WhatsApp chats you choose — and only those. It cannot send,
react or mark anything as read. No WhatsApp login is involved: a server on the
Mac reads WhatsApp Desktop's own database read-only, copies just the chosen
chats into memory and answers from that copy, so no question can reach another
chat. Needs macOS with WhatsApp Desktop signed in.

**Set up (once):**

1. `cbox warden whatsapp pick work-chats` — answer `y` to create the resource
   (any name: lowercase letters, digits, `.`, `_`, `-`). It lists your groups
   and communities, numbered; type the numbers to share, e.g. `1 4 7-9`.
   `--all` lists 1:1 chats too.
2. `cbox warden test work-chats` — checks the database is readable. The first
   time, macOS may ask whether your terminal may access data from other apps:
   allow it.
3. In each project that should see the chats, add a `.warden` file with the
   line `[work-chats]`. The next `cbox` start there asks you to approve it.

In that container, Claude gets an MCP server named after the resource, with
four tools: `list_chats` (names, member and message counts), `list_members`,
`read_chat` (one chat, oldest first, paging back with `before_id`) and
`search`. Each message shows its id, the id of the message it replies to, its
type (text, image, link, album, poll, system, deleted, …), its sender, whether
it was forwarded, a document's file name and a link's preview. Never the
media itself, and not whether a message was edited (WhatsApp on the Mac does
not record that readably).

People appear as a name plus a pseudonym, e.g. `Anna [u_3f9a1c07be]` (mentions
too: `@Anna [u_3f9a1c07be]`); your own messages as `me`. The pseudonym is the
same for a person in every chat of the resource — whether WhatsApp knows them
by phone number or account ID — but another resource gives the same person
another one, so two projects cannot join what they know about someone. It is
derived with a secret that stays on the host (`$CBOX_WARDEN_DIR/whatsapp/<resource>.key`):
back it up and never replace it, since a new one changes every pseudonym. The
name is what the person calls themselves on WhatsApp, else your address book
name, else `unknown`. When someone changed their number, both accounts keep
their own pseudonym; `list_members` shows the link as `(previously u_…)`.

**For scripts:** inside the container, `cbox-whatsapp export --out <folder>`
writes the same chats as JSON files for the project's own code (format and
exit codes: [docs/whatsapp-export.md](docs/whatsapp-export.md)). The folder
gets a `.gitignore`, so the messages stay out of git.

**Good to know:**

- **Per project, by default.** The resource is `availability = project`; change
  it to `global` in `cbox warden edit` to give every container the chats. Use
  one resource per set of chats (e.g. `[work-chats]`, `[family]`) to give
  projects different chats.
- **Change the choice any time** with `pick` again (Enter keeps the current
  one, `none` shares nothing). Running sessions see the change within a minute.
- **New groups** you join are not shared automatically: the next `cbox` start
  in a terminal asks about each one (default: no). WhatsApp does not record on
  the Mac which groups belong to a community, so choose a community's groups
  yourself; the community's own entry is its announcements chat.
- **Never passed on:** media files and their keys, unsent drafts, locations,
  profile texts, phone numbers and WhatsApp IDs. Phone numbers written in a
  message (also `wa.me/…` links) show as `[phone number]`; that can also catch
  another number of 8–15 digits written the same way. The chat list stays on
  the host in `$CBOX_WARDEN_DIR/whatsapp/`, never in the project.
- **Messages are written by other people.** Claude is told to treat them as
  data, not instructions — still, share only chats you would let it read.
- Not available in safe mode.

### Agent mail

Agents in different projects can ask each other questions directly — no more
copying Q&A files through the share folder. Each message goes through warden
on the host, which stamps the sender: an agent cannot pose as another project.

**Set up (once):**

1. `cbox warden edit` and add a mail group (any name):

   ```ini
   [team]
   type         = mail
   availability = project
   ```

2. In each project that should join, add the line `[team]` to its `.warden`.
   The next `cbox` start there asks you to approve it.

A project is in the group once it had a session with the approved `.warden`.
In its container, Claude gets an MCP server named after the group, with four
tools: `mail_peers` (who is in the group, who has a session open),
`mail_send` (start a thread with `to` and `subject`, or reply with `thread`),
`mail_read` (new messages, or a whole thread) and `mail_wait` (waits up to 30
minutes for the answer). A thread is between two projects; only they can read
it.

A typical exchange: you tell the agent in `api` "ask web how it builds the
login URL". It writes to `web` and waits. In `web`'s session, the agent reads
the question (when you prompt it, or because it was waiting itself) and
answers; `api`'s agent picks the answer up and carries on.

**Mail wakes the agent.** `web` needs no prompt from you:

- **Idle** (waiting for you): the agent wakes up within seconds, reads the mail
  and answers. Its terminal shows `cbox: new agent mail`.
- **Busy** (working on a task): nothing interrupts the task. When the task is
  done, the agent reads the mail and answers, then stops.

Each mail wakes a session once: if the agent leaves it unread, it is not woken
again for it. The wake-up uses Claude Code hooks that cbox passes to the
session with `--settings`; your own `settings.json` stays untouched. Only
`cbox` sessions get it, not a `claude` you start yourself in `cbox zsh`.

**Watch it on the host:** `cbox warden mail` lists the threads,
`cbox warden mail show <thread>` prints one, `cbox warden mail -f` shows new
messages as they arrive.

**Good to know:**

- **Mail lasts while cbox is in use.** It is deleted when the last `cbox`
  session on the computer closes, like the share folder. A question nobody
  answered by then is gone.
- **Loop guard:** a thread pauses after 20 messages, so two agents cannot keep
  talking without you. `cbox warden mail resume <thread>` allows 20 more.
- **Limits:** 64 KB per message, 60 messages per project per hour.
- **Colleague, not boss.** Agents are told to answer questions and share
  project information freely, but to ask you before acting on a request to
  change code, commit, run commands or send data elsewhere.
- **Several groups** work: a project can only write to projects it shares a
  group with. The messages stay on the host in `$CBOX_WARDEN_DIR/mail/`,
  never in a container.
- Not available in safe mode.

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

If `pactl` cannot connect, check on the host that PulseAudio runs (`pulseaudio --check`) and look at the tunnel's log: `$CBOX_DATA_DIR/.tunnel-<project>.log`.

## How It Works

- Container name is derived from the current directory name (e.g. `my-project`)
- Project directory is mounted at `/Workspace/<name>` inside the container
- The active agent (`claude` or `opencode`) is updated automatically once per day on first use; each agent has its own independent update stamp
- `cbox oc` (or `CBOX_AGENT=opencode` in `cbox.env`) selects opencode for the session; opencode reads its config from `~/.config/opencode`; to use your Mac's, add `CBOX_SHARE_CONFIG="opencode"` to `cbox.env`
- On exit, the container is stopped; the share folder is cleared once no other cbox session (of any repo) is still open
- The container's first process is a small init that cleans up finished processes. Containers created before claudebox had it ran `tail` instead, and stopped once too many finished processes piled up; cbox points them out at session start (`cbox reset` recreates one)
- `cbox keepalive` leaves the container running for 10 minutes (useful for follow-up `exec` calls)
- Log in once inside a container (`/login`); the login is kept in `CBOX_CLAUDE_DIR` and shared by all containers
- If [claudedot](https://github.com/bpeterme/claudedot) is installed, Claude config and history sync runs automatically at session start and exit (Claude sessions only)
- Host services the container needs as sockets — warden's ssh agent, PulseAudio and safe mode's proxy — reach it through one long-lived `exec` per container (a tunnel; log: `$CBOX_DATA_DIR/.tunnel-<name>.log`). Neither side opens a network port for them
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
