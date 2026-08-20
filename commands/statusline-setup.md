---
allowed-tools: AskUserQuestion, Read, Write, Edit, Bash(mkdir:*), Bash(cp:*), Bash(date:*), Bash(cat:*), Bash(jq:*)
description: Configure fleetline (layout, ASCII mode, background-agent tracking, fleet-view rows) and register it in settings.json
---

## Context

- Home settings file: !`cat "$HOME/.claude/settings.json" 2>/dev/null || echo "(không tồn tại)"`
- Existing config file (nếu đã setup trước đó): !`cat "$HOME/.claude/statusline-fleetline.config.json" 2>/dev/null || echo "(chưa có)"`

## Your task

You are setting up the `fleetline` plugin for the user. Follow these steps in order. Do not skip the backup step under any circumstances.

1. **Ask with `AskUserQuestion`** (one call, up to 4 questions):
   - Layout: "Minimal" (1 line), "Hardened" (2 lines, matches the classic layout — recommend this as default), or "Power-user" (3 lines, adds cost/session/PR/effort/thinking/bg-agents/cache-TTL when present).
   - ASCII-safe mode: on/off. Recommend OFF unless the user says their terminal/font doesn't render Unicode or Nerd Font glyphs well.
   - Background-agent segment: on/off. Explain the real cost/benefit honestly: it calls `claude agents --json` to show how many background agents are running, but each call spawns a full CLI process (~0.4s observed) — throttled to once every N seconds (ask for N, default 60, minimum 5), not on every render. Recommend OFF as the default; only worth it if the user regularly runs multiple background/dispatched sessions.
   - If background-agent segment is ON: ask a follow-up whether to also enable the hook-based approximate counter (fills the gap between polls with a `~N` estimate; requires restarting Claude Code for the new hooks to load per Claude Code's hook-loading model, and can drift high if an agent is killed abnormally — self-corrects at the next poll). Recommend OFF unless the user wants faster-updating estimates and is fine with the restart.

2. **Ask separately whether to also enable the fleet-view row renderer** (`subagentStatusLine` — a DIFFERENT settings key from the main statusline, rendering rows in Claude Code's multi-agent/fleet view). Be upfront: this is the least-verified part of the plugin — it was built from documented field names but never tested against a real live multi-agent payload, only synthetic data matching the documented shape. Default recommendation: skip it unless the user specifically wants to try it and is fine with rough edges.

3. **Write the config file** at `$HOME/.claude/statusline-fleetline.config.json` (create `$HOME/.claude` first if needed) with the user's choices from steps 1-2, and sensible fixed defaults for everything else (all individually documented in `config/schema.json` — mention that file in your final summary so the user can hand-tune further, e.g. `features.burnRate`, `features.clickableLinks`, `hints.idleThresholdMin`):
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
     }
   }
   ```
   This file lives outside the plugin's own directory on purpose — never place it under `${CLAUDE_PLUGIN_ROOT}`, a plugin update would wipe it.

4. **Read `$HOME/.claude/settings.json`** (shown above in Context).
   - If it exists and already has a `statusLine` key:
     - If that key's `command` already contains `fleetline`, just overwrite it — this is an update, not a takeover, no backup needed.
     - Otherwise (a different statusline is registered), **back it up first**: copy the whole file to `$HOME/.claude/settings.json.bak-<unix-timestamp>` (via `date +%s`), and report the exact path. Never skip this — an unannounced overwrite of someone's personal statusline is exactly the silent data loss this step prevents.
   - Same backup rule applies independently to an existing `subagentStatusLine` key, if the user opted into step 2.
   - If the file doesn't exist yet, no backup needed — you're creating it fresh.

5. **Write/merge into `$HOME/.claude/settings.json`**, preserving every other key already there (prefer `Read` + `Edit`, or `jq` via Bash — do not regenerate the file from scratch if it has content):
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

6. **Print a short confirmation** (plain text, in Vietnamese, matching the user's language): the choices made, the config file path, any backup path(s) made, and — if hooks (step 1's follow-up) or `subagentStatusLine` were enabled — an explicit note that **Claude Code loads hooks and this settings key only at session start**, so the user needs to exit and restart `claude` before either takes effect. Mention the config file's full option set lives in `config/schema.json` for later tuning.

Do not do anything beyond these 6 steps — no extra refactors, no touching unrelated settings.json keys.
