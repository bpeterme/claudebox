# WhatsApp export format (schema version 2)

`cbox-whatsapp export` writes the WhatsApp chats shared with a project as
files, for the project's own code. It runs inside a claudebox container during
a `cbox` session and reaches the host through the same relay as Claude's
WhatsApp tools — with the same limits: only the chats of the resource the
project lists in its `.warden`, read-only, no phone numbers or WhatsApp IDs.
Setup: [WhatsApp chats](../README.md#whatsapp-chats).

```sh
cbox-whatsapp export --out data/raw/whatsapp/                      # everything
cbox-whatsapp export --out data/raw/whatsapp/ --since 2026-11-01   # newer messages only
cbox-whatsapp export --out data/raw/whatsapp/ --server family      # project with several resources
```

| Exit code | Meaning |
|-----------|---------|
| 0 | Written. Prints chats, messages and how many files changed |
| 1 | Not set up here: no WhatsApp resource for this project, or not in a cbox session |
| 2 | The host could not read WhatsApp (not installed, or macOS denies the terminal access to other apps' data) |

## Files

```
data/raw/whatsapp/
├── .gitignore              *  (written once: other people's messages stay out of git)
├── manifest.json
├── chats.json
├── identities.json
├── members/<chat_id>.json
└── messages/<chat_id>.jsonl
```

The same data always gives the same bytes: fixed order, sorted keys, UTF-8,
no export time in any file. Unchanged files are not rewritten. Files of chats
no longer shared are removed (only files the previous `manifest.json` listed).

### manifest.json

```json
{"files": ["chats.json", "identities.json", "members/c_…json", "…"], "resource": "tai", "schema_version": 2, "since": null}
```

### chats.json

A list, ordered by `chat_id`:

| Field | |
|-------|---|
| `chat_id` | `c_` + 10 hex characters; stable when a group is renamed |
| `name` | The group's name; for a direct chat the person's name |
| `kind` | `group`, `community` (a community's announcement chat) or `direct` |
| `community_id` | Always `null`: WhatsApp on the Mac does not record which community a group belongs to |
| `member_count` | Current members |
| `message_count` | All messages, also with `--since` |
| `last_message_at` | ISO 8601 with offset, or `null` |

### members/<chat_id>.json

A list, ordered by `id`: `{"id", "name", "status": "current" | "former", "is_admin"}`,
plus `joined_at` / `left_at` (ISO 8601) when a group event shows them. You are
`{"id": "me", "name": "me"}`. A former member left or was removed, and may
still have written messages.

### messages/<chat_id>.jsonl

One message per line, in date order:

| Field | |
|-------|---|
| `id` | WhatsApp's number for the message (unique on this Mac, not in date order) |
| `chat_id`, `ts` | `ts`: ISO 8601 with offset, e.g. `2026-10-30T07:03:12+09:00` |
| `sender` | `{"id", "name"}`; `{"id": "me", "name": "me"}` for you; `{"id": null, "name": "unknown"}` when WhatsApp names nobody |
| `type` | `text`, `link`, `image`, `video`, `audio`, `document`, `sticker`, `album`, `poll`, `contact`, `location`, `system`, `deleted`, `other` |
| `text` | The text or caption, or `null`. Mentions read `@Name [u_…]`; phone numbers `[phone number]` |
| `reply_to` | The `id` of the message it replies to, or `null` |
| `mentions` | `[{"id", "name"}]`, in order of appearance |
| `links` | URLs in the text, sorted |
| `forwarded` | `true` when WhatsApp shows "Forwarded" |
| `link_preview` | For `type: link`: `{"url", "title", "description"}` as WhatsApp shows the preview, or `null`. Written by the linked website |
| `attachment` | For images, videos, audio, documents, stickers and albums: `{"caption", "mime", "file_name", "size", "duration"}`, each `null` when unknown. `file_name`: documents only, a name without folders; `size` in bytes; `duration` in seconds (audio, video). Never the media itself |
| `system` | For `type: system`: `{"kind", "actor_id", "target_ids"}` |

`system.kind`: `added` (actor added the targets), `removed` (actor, an admin,
removed the target), `joined_via_link`, `joined_from_community`,
`changed_number` (actor's old account, target: the new one), `history_shared`
(actor, an admin, sent the target the group's earlier messages), or
`event_<n>` for events nobody has identified yet.

An `album` is several pictures or videos sent together: its text is their
caption, and they follow it as `image` / `video` messages.

Rows WhatsApp shows no message for (its type 10, probably reactions) are left
out. Not exported, because WhatsApp on the Mac does not record them in a way
that can be read reliably: whether a message was edited (an edited message's
`ts` is the time of the edit), and poll questions and votes.

### Changes from version 1

New: `forwarded`, `link_preview` and the `album` type on every message;
`attachment` now on every attached message (also without a caption), with
`mime`, `file_name`, `size` and `duration`; the `history_shared` event.

### identities.json

`{"<id>": {"name", "previous_ids": [...]}}` for everyone in the export, you
excepted. `previous_ids` lists the person's earlier accounts, newest first,
from WhatsApp's "changed their number" events. IDs are never merged: merge
them yourself if you need one ID per person.

## IDs

People are `u_` + 10 hex characters, chats `c_` + 10 hex characters: HMAC-SHA256
of the WhatsApp ID with a secret of the resource. The same person has the same
ID in every chat and every export of that resource, in every project that
lists it; another resource gives them another ID, so projects with different
resources cannot join their data about someone. The ID is never a phone number
and cannot be turned back into one.

The secret is `$CBOX_WARDEN_DIR/whatsapp/<resource>.key` on the Mac (default
`~/.local/share/claudebox/warden/whatsapp/`). **Back it up and never replace
it**: a new key changes every ID, and whatever keys on them downstream no
longer matches. Copy it to another Mac to get the same IDs there.
