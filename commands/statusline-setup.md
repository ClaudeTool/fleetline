---
allowed-tools: AskUserQuestion, Read, Write, Edit, Bash(mkdir:*), Bash(cp:*), Bash(date:*), Bash(cat:*), Bash(jq:*)
description: Configure claude-statusline (layout, ASCII mode) and register it in settings.json
---

## Context

- Home settings file: !`cat "$HOME/.claude/settings.json" 2>/dev/null || echo "(không tồn tại)"`
- Existing config file (nếu đã setup trước đó): !`cat "$HOME/.claude/statusline-claude-statusline.config.json" 2>/dev/null || echo "(chưa có)"`

## Your task

You are setting up the `claude-statusline` plugin for the user. Follow these steps in order. Do not skip the backup step under any circumstances.

1. **Ask the user two questions with `AskUserQuestion`** (one call, two questions):
   - Layout: "Minimal" (1 line, model+context+git only), "Hardened" (2 lines, matches the classic model/context/lines/git + rate-limits layout), or "Power-user" (3 lines, adds cost/session/PR/effort/thinking/cache-TTL when those fields are present). Recommend "Hardened" as the default/first option since it has no missing information relative to what most people are used to.
   - ASCII-safe mode: on or off. Explain that ON replaces block characters (█░) and emoji (🌿⬡⚠) with plain ASCII, for terminals/fonts that don't render Unicode/Nerd Font glyphs well. Recommend OFF as the default unless the user says their terminal has rendering issues.

2. **Write the config file** at `$HOME/.claude/statusline-claude-statusline.config.json` (create the `$HOME/.claude` directory first if it doesn't exist) with this shape, filling in the user's choices and using these fixed defaults for the rest:
   ```json
   {
     "layout": "hardened",
     "asciiMode": false,
     "thresholds": { "warn": 70, "crit": 90 },
     "hints": { "compactHint": true }
   }
   ```
   This file lives outside the plugin's own directory on purpose — it must never be placed under `${CLAUDE_PLUGIN_ROOT}`, because a plugin update would wipe it.

3. **Read `$HOME/.claude/settings.json`** (shown above in Context; treat "(không tồn tại)" as "file does not exist yet").
   - If it exists and already has a `statusLine` key:
     - If that key's `command` already contains `claude-statusline` (i.e. this same plugin is already registered), just overwrite it with the new command below — no backup needed, this is an update, not a takeover.
     - Otherwise (a different statusline is registered — this is the user's own custom script), **back it up first**: copy the whole file to `$HOME/.claude/settings.json.bak-<unix-timestamp>` using `date +%s` for the timestamp, and tell the user the exact backup path in your final summary. Do not skip this even if the user seems to expect it to "just work" — an unannounced overwrite of someone's personal statusline is exactly the kind of silent data loss this step exists to prevent.
   - If the file doesn't exist yet, you'll create it fresh (see next step) — no backup needed.

4. **Write/merge the `statusLine` key** into `$HOME/.claude/settings.json`, preserving every other key already in the file (use `Read` + `Edit`, or `jq` via Bash, whichever preserves the rest of the file most reliably — do not regenerate the file from scratch if it already has content):
   ```json
   {
     "type": "command",
     "command": "${CLAUDE_PLUGIN_ROOT}/bin/statusline.sh",
     "refreshInterval": 30
   }
   ```
   If the file doesn't exist yet, create it containing just `{"statusLine": {...}}`.

5. **Print a short confirmation** (plain text, in Vietnamese, matching the user's language in this conversation): which layout and ASCII mode were set, the config file path, whether a backup was made and its exact path if so, and that the new statusline takes effect on the next render (no restart needed) — mirroring how a previous edit to the same statusline script in this project took effect immediately without a restart.

Do not do anything beyond these 5 steps — no extra refactors, no touching unrelated settings.json keys.
