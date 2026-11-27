# Plan: switching Claude accounts (`cbox account`)

Status: draft, 2026-11-27. Nothing built yet.

## Goals

- **Several Claude subscriptions on one Mac**, switched with one command.
- **A global default** for all containers, and a **per-project pin** in `.cbox` that always wins.
- **Zero config stays zero config:** without saved accounts, cbox behaves exactly as today.
- **Safe mode keeps sharing the login** with normal containers (hard link, see `_cbox_safe_claude_dir`).

Not in this plan: switching accounts automatically when usage runs out, and other agents' logins (opencode, Codex).

## Background

- Containers are Linux: Claude Code's login is the file `.credentials.json` in `$CBOX_CLAUDE_DIR`, never the macOS Keychain. Tools that switch the Mac's own login (e.g. claude-swap) do not reach containers.
- Claude Code **rewrites** that file in place when it refreshes the token, and **replaces** it on `/login`.
- Refresh tokens rotate: two copies of one login cannot both stay valid. The first refresh kills the other copy.
- `oauthAccount` (the account shown in Claude Code) is in each project's `~/.claude.json` (`$CBOX_DATA_DIR/.claude-<name>.json`), not in the login file.

## Design

### 1. One file per account

```
$CBOX_DATA_DIR/accounts/            (700)
  <alias>/
    .credentials.json               (600)  the only copy of this login
    account.json                           oauthAccount, saved at add
  active                                   alias of the global default
```

Everything a container sees as `.credentials.json` is a hard link to, or a mount of, the alias's file. So a refresh in any container updates the one copy, and no copy goes stale.

| Container | Its `.credentials.json` |
|---|---|
| normal, no pin | `$CBOX_CLAUDE_DIR/.credentials.json`, a hard link to the active alias's file |
| normal, pinned | the pinned alias's file, mounted over that path (`-v <file>:…/.credentials.json`) |
| safe, no pin | hard link to the global file (as today) |
| safe, pinned | hard link to the pinned alias's file |

Saved accounts sit outside every folder a container mounts: a container can only ever read the login it uses.

### 2. Commands

| You type | What happens |
|---|---|
| `cbox account add <alias>` | Saves the current login as `<alias>` and makes it the global default. Adding an alias again updates it (after a new `/login`). |
| `cbox account use <alias>` | Makes `<alias>` the global default: re-points the global hard link, writes its `oauthAccount` into every `.claude-<name>.json` of projects without a pin. |
| `cbox account list` | Alias, email, global default, token expiry, and which projects pin it. |
| `cbox account remove <alias>` | Asks first. Refused while it is the global default or a pin of a known project. |

- Adding a second account: `/login` inside a container with the other account, then `cbox account add <alias>`. **No `/logout` first**: it can revoke the token just saved.
- Alias names: letters, digits, `.`, `_`, `-` (as MCP server names).

### 3. Pin in `.cbox`

```
[container]
  account = work
```

- Parsed with the other `[container]` keys (`_cbox_project_settings`); a bad alias name is refused there.
- Applied at create (the mount). A changed pin warns and resets the container, as a changed `ports =` does.
- At session start: `account: work (pinned in .cbox)` or `account: personal (global)`.
- `cbox account use` in a pinned project says so: "this project is pinned to work; other containers now use personal".
- **Pin to an alias this Mac does not have: the session stops** with "run `cbox account add work`". A silent fallback would bill the wrong subscription.

### 4. When the link breaks

`/login` inside a container replaces the file, so it no longer is the alias's file. At the next session start cbox finds the global (or pinned) file and the alias's file differ:

- The newer one is a fresh login. cbox does **not** guess which account it is: it keeps it as the global login, marks no alias active, and prints "new login found — save it with `cbox account add <alias>`".
- Without any saved accounts this check is off (today's behavior).

### 5. Across Macs (claudedot)

- Nothing changes in cdot: its allowlist never included `.credentials.json`, and `$CBOX_DATA_DIR/accounts/` is outside `$CBOX_CLAUDE_DIR`.
- Saved accounts are per Mac (`cbox account add` once per Mac and account). Syncing them would be wrong: each Mac's login is its own OAuth grant.
- A pin travels with the project's repo, so a new Mac hits the "run `cbox account add`" stop once.
- Memory, transcripts and settings are per project, not per account: switching accounts keeps them.

### 6. Limits

- Hard links need `$CBOX_DATA_DIR` and `$CBOX_CLAUDE_DIR` on one disk. Otherwise: the same warning safe mode prints today, and `cbox account` refuses to start.
- Safe containers switch at their next session start (their hard link is fixed while they run). Normal containers switch on their next message.

## Open questions

1. **Single-file mounts in Apple's `container`:** does `-v <file>:<file>` work, and does an in-place rewrite inside reach the host file? Test on the Mac (10 minutes). If not: a pinned normal container gets its own `~/.claude` of links, as safe mode does (`_cbox_safe_claude_dir`).
2. **Claude Code's credential lock:** does it lock `.credentials.json` during a refresh, and can `cbox account use` take that lock? Otherwise a switch during a refresh can lose the rotated token.
3. **Is `oauthAccount` needed for anything but display?** If Claude Code rebuilds it from the token, step 2 can skip writing `.claude-<name>.json`.

## Phases

1. **Spike** (open questions 1–3), ~1 hour, on the Mac.
2. **Global accounts:** `add`, `use`, `list`, `remove`, link-break check, safe-mode links. ~½ day incl. bats tests.
3. **Pins:** `.cbox` key, mount or link folder, start message, reset on change, missing-alias stop. ~1 day incl. tests.
4. **Docs:** README section, `cbox --help`.

## Tests (bats)

- `use` re-points the global link; a safe container's link follows at its next start.
- A refresh (in-place rewrite) through any link updates the alias's file.
- `/login` (file replaced) is detected; no alias is overwritten.
- Pin wins over the global default; missing alias stops the session; changed pin resets.
- No saved accounts: nothing changes compared with today.
- Different disks: clear message, no partial state.
