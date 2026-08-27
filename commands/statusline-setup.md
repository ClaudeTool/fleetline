---
allowed-tools: AskUserQuestion, Read, Write, Edit, Bash(mkdir:*), Bash(cp:*), Bash(date:*), Bash(cat:*), Bash(jq:*)
description: Configure fleetline (layout, ASCII mode, background-agent tracking, fleet-view rows, custom segment order) and register it in settings.json
---

## Context

- Home settings file: !`cat "$HOME/.claude/settings.json" 2>/dev/null || echo "(không tồn tại)"`
- Existing config file (nếu đã setup trước đó): !`cat "$HOME/.claude/statusline-fleetline.config.json" 2>/dev/null || echo "(chưa có)"`

## Your task

You are setting up the `fleetline` plugin for the user. Follow these steps in order. Do not skip the backup step under any circumstances.

1. **Ask with `AskUserQuestion`** (one call, up to 4 questions):
   - Layout: "Minimal" (1 line), "Hardened" (2 lines, matches the classic layout — recommend this as default), or "Power-user" (3 lines, adds cost/session/PR/thinking/bg-agents/cache-TTL when present).
   - ASCII-safe mode: on/off. Recommend OFF unless the user says their terminal/font doesn't render Unicode or Nerd Font glyphs well.
   - Background-agent segment: on/off. Explain the real cost/benefit honestly: it calls `claude agents --json` to show how many background agents are running, but each call spawns a full CLI process (~0.4s observed) — throttled to once every N seconds (ask for N, default 60, minimum 5), not on every render. Recommend OFF as the default; only worth it if the user regularly runs multiple background/dispatched sessions.
   - If background-agent segment is ON: ask a follow-up whether to also enable the hook-based approximate counter (fills the gap between polls with a `~N` estimate; requires restarting Claude Code for the new hooks to load per Claude Code's hook-loading model, and can drift high if an agent is killed abnormally — self-corrects at the next poll). Recommend OFF unless the user wants faster-updating estimates and is fine with the restart.

2. **Ask separately whether to also enable the fleet-view row renderer** (`subagentStatusLine` — a DIFFERENT settings key from the main statusline, rendering rows in Claude Code's multi-agent/fleet view). Be upfront: this is the least-verified part of the plugin — it was built from documented field names but never tested against a real live multi-agent payload, only synthetic data matching the documented shape. Default recommendation: skip it unless the user specifically wants to try it and is fine with rough edges.

3. **Ask which segment separator to use** (`separator` config key — see `config/schema.json`'s `separator` property and the README's "Segment separator" table). `AskUserQuestion` single-select with the presets as options — show each one's rendered glyph in the option description (`pipe` "|" / `dot` "·" / `chevron` "›" / `bar` "│" / `diamond` "◆") plus an option for "type your own" (use the "Other" free-text input) which becomes `{"preset":"custom","custom":"<what they typed>"}`. Recommend `pipe` (the original look) as default if they have no preference.

4. **Ask whether the user wants to customize which segments show and in what order** (the `segments` config key — a FLAT ordered list of ids with a reserved `"newline"` id to break lines, modeled after powerlevel10k's prompt-elements array; see `config/schema.json`'s `segments` property and the README's "Custom segment order" section for the full id list and what each one renders). Be upfront about the platform limit before asking: there's no drag-and-drop reordering UI available here — `AskUserQuestion`'s picker is the only interactive control this runs in. If the user says no (expected default — most people are fine with the layout's built-in order), skip straight to step 5 and don't write a `segments` key at all.

   If yes, run this as an interactive drill-down loop. Start from the chosen layout's default lines as the starting point, and give each one a **temporary, conversation-only name** so you can refer back to it (these names exist only in this conversation — never written to the config, which only stores the flat id+"newline" list): for `minimal` call it "Line 1"; for `hardened` call them "Line 1" and "Line 2"; for `power`, "Line 1", "Line 2", "Line 3". Then loop:
   - `AskUserQuestion` single-select: "Which line do you want to edit?" with one option per current line (label = its temporary name, description = its current id list joined with " → ") plus "Add a new line" and "Done — save this layout".
   - If an existing line is picked: `AskUserQuestion` with `multiSelect: true` listing **every** segment id (not just that line's current ones — any id can move to any line; pull the id → description table from the README section so options carry real explanations, not bare ids), pre-noting in each currently-included id's description "(currently on this line)". This decides the new membership, not order.
     Then a follow-up free-text question asking for the exact left-to-right order as a comma-separated id list drawn only from what they just selected — validate it only contains those ids; if they typo one, ask again rather than silently dropping it. Update that line's id list in memory.
   - If "Add a new line": ask for a temporary name (free text) and run the same multiSelect + order question against the full id list; append it as a new line in memory.
   - If "Done": exit the loop.
   - Repeat until the user picks "Done".

   Build the final flat `segments` array from the in-memory lines, in the order they'll render, joining each line's ids and inserting `"newline"` between lines (not after the last one). If the user ends up with the exact same lines/order/ids as the layout default they started from, omit the `segments` key entirely rather than writing out a no-op copy of the default.

5. **Write the config file** at `$HOME/.claude/statusline-fleetline.config.json` (create `$HOME/.claude` first if needed) with the user's choices from steps 1-4, and sensible fixed defaults for everything else (all individually documented in `config/schema.json` — mention that file in your final summary so the user can hand-tune further, e.g. `features.burnRate`, `features.clickableLinks`, `hints.idleThresholdMin`):
   ```json
   {
     "layout": "hardened",
     "asciiMode": false,
     "thresholds": { "warn": 70, "crit": 90 },
     "hints": { "compactHint": true, "idleThresholdMin": 5 },
     "features": {
       "burnRate": true,
       "idleIndicator": true,
       "widthAwareTruncate": true,
       "outputStyleSegment": true,
       "vimModeSegment": true,
       "addDirSegment": true,
       "clickableLinks": false
     },
     "agents": {
       "bgAgentSegment": false,
       "bgAgentPollSeconds": 60,
       "hookCounterEnabled": false
     },
     "separator": { "preset": "pipe" }
   }
   ```
   If step 3's choice wasn't the `pipe` default, set `separator` accordingly (`{"preset":"dot"}`, or `{"preset":"custom","custom":"..."}`). If step 4 produced a custom layout, add a `"segments": [...]` key with the flat id+`"newline"` list built there.
   This file lives outside the plugin's own directory on purpose — never place it under `${CLAUDE_PLUGIN_ROOT}`, a plugin update would wipe it.

6. **Read `$HOME/.claude/settings.json`** (shown above in Context).
   - If it exists and already has a `statusLine` key:
     - If that key's `command` already contains `fleetline`, just overwrite it — this is an update, not a takeover, no backup needed.
     - Otherwise (a different statusline is registered), **back it up first**: copy the whole file to `$HOME/.claude/settings.json.bak-<unix-timestamp>` (via `date +%s`), and report the exact path. Never skip this — an unannounced overwrite of someone's personal statusline is exactly the silent data loss this step prevents.
   - Same backup rule applies independently to an existing `subagentStatusLine` key, if the user opted into step 2.
   - If the file doesn't exist yet, no backup needed — you're creating it fresh.

7. **Write/merge into `$HOME/.claude/settings.json`**, preserving every other key already there (prefer `Read` + `Edit`, or `jq` via Bash — do not regenerate the file from scratch if it has content):
   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "${CLAUDE_PLUGIN_ROOT}/bin/statusline.sh",
       "refreshInterval": 30
     }
   }
   ```
   And, only if the user opted into step 2:
   ```json
   {
     "subagentStatusLine": {
       "type": "command",
       "command": "${CLAUDE_PLUGIN_ROOT}/bin/subagent-statusline.sh"
     }
   }
   ```

8. **Print a short confirmation** (plain text, in Vietnamese, matching the user's language): the choices made, the config file path, any backup path(s) made, and — if hooks (step 1's follow-up) or `subagentStatusLine` were enabled — an explicit note that **Claude Code loads hooks and this settings key only at session start**, so the user needs to exit and restart `claude` before either takes effect. Mention the config file's full option set lives in `config/schema.json` for later tuning.

Do not do anything beyond these 8 steps — no extra refactors, no touching unrelated settings.json keys.
