# macOS Extras

## Screenshot Script

`screenshot.sh` captures an interactive screenshot (drag to select a region, or click a window — same as ⇧⌘4) and saves it directly into the cbox share folder. The running container sees it immediately at `~/share/`.

The script reads `~/.config/claudebox/cbox.env` automatically, so it picks up your `CBOX_SHARE_DIR` without any extra configuration.

### Assigning a keyboard shortcut

#### Option A — Automator Quick Action (no extra tools)

1. Open **Automator** → New Document → **Quick Action**
2. Set "Workflow receives" to **no input** in **any application**
3. Add a **Run Shell Script** action
4. Set Shell to `/bin/bash`, pass input to **stdin**
5. Paste:
   ```bash
   bash /path/to/claudebox/macos/screenshot.sh
   ```
6. Save as `claudebox Screenshot`
7. Open **System Settings** → Keyboard → Keyboard Shortcuts → Services
8. Find `claudebox Screenshot` under General and assign a shortcut (e.g. `⇧⌘5`)

#### Option B — Hammerspoon

```lua
hs.hotkey.bind({"shift", "cmd"}, "5", function()
  hs.execute("bash /path/to/claudebox/macos/screenshot.sh")
end)
```

#### Option C — Raycast / Alfred

Add `screenshot.sh` as a Script Command (Raycast) or Shell Script workflow (Alfred) and bind your preferred hotkey.

### Notes

- The share folder is created automatically if it does not exist
- Files are deleted when the container stops (normal cbox exit behaviour)
- If no container is running, the file lands in the share folder but nothing reads it until the next `cbox` session
- To capture the full screen without interaction, remove the `-i` flag from `screenshot.sh`
