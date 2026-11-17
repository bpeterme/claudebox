# Plan: more agents in claudebox (Codex, pi)

Status: draft, 2026-11-17. Nothing built yet.

## Goals

- **Claude leads for now.** Later, the lead should be switchable to another agent.
- **Agents are modules.** Adding, adapting or dropping one agent does not touch the others or cbox's core.
- **Two uses:** a reviewer from a different model (catches other mistakes), and spreading work across providers and subscriptions.
- **Sign-in:** the OpenRouter API through warden today; a Codex subscription later.
- **opencode stays.**

Not in this plan: building lead switching (phase 5 gets its own plan).

## Design

### 1. One folder per agent

```
agents/
  claude/    agent.conf  hooks.sh  install.sh
  opencode/  agent.conf  hooks.sh  install.sh
  codex/     ...
  pi/        ...
tests/agents/<name>.bats
```

- `agent.conf` (git-config format, like `.cbox`): command name, login folders kept across resets, hosts safe mode allows, and capabilities (below).
- `hooks.sh` (optional): functions cbox calls at fixed points, e.g. when a container is created, when config is written, at sign-in.
- `install.sh`: how the image gets the agent.
- **Drop an agent** = delete its folder and its test file. **Adapt one** = edit only its folder.
- The Homebrew formula installs `agents/` next to the dockerfile.

### 2. Capabilities, not names

cbox's core and `/team` never ask "is this Claude?". They ask what an agent can do:

| Capability | Meaning |
|---|---|
| `lead` | can run `/team` as the lead |
| `mcp` | can use MCP servers (relay, warden mail) |
| `mail` | can report "done" through warden mail |
| `voice` | voice mode |

This is what makes lead switching possible later: an agent becomes lead-capable by gaining the capability, not by changes to the core.

### 3. Sign-in

- **API key (OpenRouter):** a warden http resource, as today. The key never enters the container.
- **Codex subscription:** `codex login --device-auth` (the browser callback on localhost:1455 cannot reach the container). The login is kept in the agent's login folder, as Claude's is today. Warden routing does not apply to subscription traffic.

### 4. Workers in `/team`

- The `worker` command takes an agent name; the lead picks one per task, e.g. a Codex reviewer for Claude's work.
- "Done" signal: warden mail for agents with `mail`; the lead watches the pane for others (pi).

## Phases

| # | Step | Time | Result |
|---|---|---|---|
| 0 | Spike: Codex and pi in `cbox shell`, normal and safe mode | 30–60 min | Where install, sign-in, own sandbox, MCP config and egress break; findings added here |
| 1 | Module refactor: claude and opencode move into `agents/` | about 4 h | No behavior change; all existing tests pass |
| 2 | Codex, basic support | 2–3 h | `cbox codex`, login kept, safe mode, OpenRouter + subscription |
| 3 | pi, basic support | about 2 h | `cbox pi`, OpenRouter |
| 4 | Workers in `/team` (claudebox + cmux-safe-mcp) | about 3 h | Lead starts Codex/pi workers; non-Claude reviewer |
| 5 | Lead switching | own plan | — |

## Open decisions

1. **pi's "done" signal:** watch the pane (leaning) or a small `cbox-mail` command. Decide in phase 4.
2. **Install at image build or on first use:** every agent in the image makes it bigger for everyone. Decide after the spike.
3. **Codex full support (MCP relay, warden mail)?** Decide after the spike.
