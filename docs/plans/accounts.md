# Plan: switching Claude accounts (`cbox account`)

Status: rebuilt 2026-11-28 on dev with long-lived tokens (design below). The first design (hard-linked login files, a single-file mount per pinned container) was dropped after a Mac test; see "Why not shared login files".

## Goals

- **Several Claude subscriptions on one Mac**, switched with one command.
- **A default** for all projects, and a **per-project pin** in `.cbox` that always wins.
- **Zero config stays zero config:** without saved accounts, cbox behaves exactly as before (Claude Code's own login, `/login`).

Not in this plan: switching accounts automatically when usage runs out, and other agents' logins (opencode, Codex).

## Design

### 1. One token per account

```
$CBOX_DATA_DIR/accounts/            (700)
  <alias>/token                     (600)  from `claude setup-token`
  .default                                 the default alias (cbox account use)
  .pins/<container>                        the alias pinned for a container
  .last/<container>                        the alias its last session used
```

- `claude setup-token` makes a long-lived OAuth token (a year) for a subscription. It does not rotate, so copies stay valid: nothing is linked or mounted.
- Each session start hands Claude Code the container's token as `CLAUDE_CODE_OAUTH_TOKEN` (`container exec -e`). Claude Code prefers it over its login file.
- Docker gets the value from its environment (`-e NAME`), not its arguments, which other users can read on Linux. macOS shows a process's arguments only to its own user.
- Saved tokens sit outside every folder a container mounts: a container only gets the token of the account it uses.

### 2. Commands

| You type | What happens |
|---|---|
| `cbox account add <alias>` | Asks for the token (hidden input; or reads it from stdin). Refuses what does not look like a token, and a token saved under another name. The first account becomes the default. Adding an alias again replaces its token. |
| `cbox account use <alias>` | Makes `<alias>` the default for projects without a pin, from their next session start. |
| `cbox account list` | Alias, date saved, the default, which projects pin it. Never the token. |
| `cbox account remove <alias>` | Asks first (terminal only). Refused while a project pins it. Removing the default leaves none: those projects use Claude Code's own login. |

Alias names: letters, digits, `.`, `_`, `-`.

### 3. Pin in `.cbox`

```
[container]
  account = work
```

- A new container takes the pin (`.pins/<container>`). The container can write `.cbox`, so afterwards the record counts: a changed pin asks in the host terminal at the next session start ("Use 'work' here from now on?"). Yes updates the record; no container is recreated. Without a terminal: a warning, the record stays.
- **Pin to an alias this Mac does not have: the session stops** with "run `cbox account add work`". A silent fallback would bill the wrong subscription.
- At session start: `Claude account: work (pinned in .cbox)` or `Claude account: personal (default)`.

### 4. oauthAccount

Each project's `~/.claude.json` caches `oauthAccount` (the account Claude Code shows, with its organization and account IDs). When a container's account differs from its last session's (`.last/<container>`), the session start drops that entry (in place: the file is a single-file mount) so Claude Code fetches the profile for the new token.

### 5. Across Macs (claudedot)

- Nothing changes in cdot: `$CBOX_DATA_DIR/accounts/` is outside `$CBOX_CLAUDE_DIR`.
- Saved accounts are per Mac (`cbox account add` once per Mac and account; one token can serve all Macs, e.g. piped from a keychain). A pin travels with the project's repo, so a new Mac hits the "run `cbox account add`" stop once.

### 6. Limits

- Tokens expire after a year: `claude setup-token` again, then `cbox account add <alias>` with the same alias.
- While accounts are saved, `/login` inside a container does not change which account is used.
- Features that need a claude.ai sign-in (e.g. Claude in Chrome) do not work with these tokens.

## Why not shared login files

The first design kept one `.credentials.json` per account, hard-linked as the global login, and mounted a pinned account's file over `~/.claude/.credentials.json`. Two findings ended it (2026-11-28):

1. **Claude Code replaces the file.** Version 2.1.325 saves every login write, token refreshes included, to a temp file and renames it over the target. It writes in place only when the rename fails (as on a mounted file). A rename breaks a hard link, and refresh tokens rotate, so the saved copy would go stale.
2. **Apple `container` hides a file seen twice.** A non-root user gets "Permission denied" on a file mounted inside a mounted folder when the same file (a hard link) is also visible through that folder. That is every pinned container whose account is also the global one. Mounted alone, or nested without the link, the file reads fine.

## Tests (bats)

- `add`: token saved 600 in a 700 folder; the first becomes the default; non-tokens, duplicates and bad names refused; re-add updates.
- `use`, `list` (default, pins, no token shown), `remove` (pins, terminal only, default cleared).
- Session start: default's token; pin wins; missing pinned account stops; changed pin asks (yes, no, removed pin, no terminal); oauthAccount dropped on a switch only.
- Session: the token reaches `container exec` (Apple: `-e NAME=value`; Docker: `-e NAME` only).
- No saved accounts: silent, nothing written.
