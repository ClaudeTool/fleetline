# fleetline

A pluggable statusline for [Claude Code](https://claude.com/claude-code): model, context, git, rate limits, cost burn-rate, and background-agent tracking — three layout presets, an ASCII-safe mode, a hardened bash renderer, and a second surface that renders rows in the multi-agent fleet view.

```
[Sonnet 5] v2.1.4 | Ctx [███░░░░░░░] 34%/200k | +120/-45 | ⬡ feature-x | 🌿 main +2 ~5
Rate: 5h:[███████░░░] 72% (↻ Fri 21/08 09:00) | 7d:[███░░░░░░░] 31% (↻ Tue 25/08 00:00) | $1.20/h · hết 5h ~40m
$0.842 | PR #128 (review: approved) | effort:high | session:refactor-auth | thinking:on | bg:2 (w:1 b:1) | TTL:58m
```

## Install

### Option A — plugin marketplace (recommended)

```
/plugin marketplace add <your-github-user>/fleetline
/plugin install fleetline
/statusline-setup
```

`/statusline-setup` asks which layout, ASCII mode, and whether to enable the optional background-agent segment / fleet-view row renderer — then writes your config and registers everything in `~/.claude/settings.json`, backing up any statusline you already have first.

### Option B — one-line curl install

```bash
curl -fsSL https://raw.githubusercontent.com/<your-github-user>/fleetline/main/install.sh | bash
```

Writes the script to `~/.claude/statusline-command.sh` and merges `statusLine` into `~/.claude/settings.json` (existing settings preserved; an existing `statusLine` key is overwritten **without** a backup — use the plugin path if you want that safety net). The background-agent hook counter and the fleet-view row renderer (`subagentStatusLine`) are **plugin-only** — not available through this path.

### Manual (no auto-write)

```json
{
  "statusLine": {
    "type": "command",
    "command": "${CLAUDE_PLUGIN_ROOT}/bin/statusline.sh",
    "refreshInterval": 30
  }
}
```

## Layouts

| Layout | Lines | Shows |
|---|---|---|
| `minimal` | 1 | model, context bar, git branch |
| `hardened` | 2 | + version, lines added/removed, worktree, rate limits (Pro/Max only), burn-rate, small feature bundle |
| `power` | 3 | + cost, PR, effort, session name, thinking mode, background-agent count, cache-TTL |

## Config

`~/.claude/statusline-fleetline.config.json` (overridable via `$STATUSLINE_CONFIG`). Lives outside the plugin's own directory on purpose, so a plugin update never wipes it. Full shape and every default documented in [`config/schema.json`](config/schema.json):

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

- **`thresholds`** governs the context bar, both rate-limit bars, and each per-task context bar in the fleet view.
- **`hints.compactHint`** appends a red `· /compact?` to the context segment once usage crosses `crit`, in every layout.
- **`features.burnRate`** shows `$/h` plus an ETA to exhaust the 5h rate-limit window, from two samples at least 30s apart — nothing shows until a second sample exists.
- **`features.widthAwareTruncate`** drops the least-important pieces (worktree, idle indicator, vim/output-style, add-dir count on line 1; cache-TTL, bg-agents, thinking, session name on line 3) instead of letting the terminal hard-wrap when a line would exceed `$COLUMNS`/`tput cols`/120 (whichever resolves).
- **`features.clickableLinks`** wraps the git branch and PR number in OSC-8 hyperlinks, built only from `workspace.repo.host/owner/name` + the branch/PR number after a strict charset check — never from free-text fields. Off by default (OSC-8 support isn't universal).
- **`agents.bgAgentSegment`** shows `bg:N (w:.. b:..)` from `claude agents --json --cwd <cwd>`, throttled by `agents.bgAgentPollSeconds` since each poll spawns a full CLI process (~0.4s observed). Off by default.
- **`agents.hookCounterEnabled`** fills the gap between polls with a `~N` estimate from `hooks/hooks.json` (SubagentStart/SubagentStop) — plugin-only, requires restarting Claude Code to load, can drift high if a subagent is killed abnormally (self-corrects at the next poll).

## The cache-TTL segment (power layout)

Not a real cache-hit gauge — Claude Code's statusline payload doesn't expose cache token counts. It's a countdown inferred from wall-clock time since your last distinct turn in this session, using the documented sliding-window TTL: 60 minutes if the payload carries `rate_limits` (subscription plans), 5 minutes otherwise (API key). Shows `TTL:58m` (green) → `TTL:6m` (yellow, ≤10 min left) → `❄ TTL hết` (red). If your Claude Code version doesn't send `prompt_id`, the countdown can't detect new turns and just shows the full window every time — a known, harmless degradation.

## Fleet view: `bin/subagent-statusline.sh`

A second, independent settings key (`subagentStatusLine`, distinct from `statusLine`) that renders rows in Claude Code's multi-agent/fleet view instead of the main terminal line. Shows, per background task: elapsed time, a context-usage bar (red past `thresholds.crit`), model, effort, and a "⚠ stuck" / `[STUCK]` marker once a task has stayed blocked for over 2 minutes.

**This is the least-verified part of the plugin.** It was built from documented field names (`id, name, type, status, description, label, startTime, model, effort, contextWindowSize, tokenCount, tokenSamples, cwd`) and tested only against synthetic payloads matching that shape — there was no live multi-agent fleet session available to capture a real one. The `status` enum values in particular aren't confirmed, so the stuck-agent match is a loose substring check (`*block*`/`*wait*`), not an exact string. Report back if the real payload differs.

## What a statusline can and can't see

Most of Claude Code's `/config` toggles have no corresponding field in the statusline JSON at all — a statusline script literally cannot react to them:

| `/config` setting | Visible to statusline? |
|---|---|
| Model, effort, output style, vim mode, extended thinking | ✅ yes (used above) |
| **Permission mode** (Shift+Tab: default/acceptEdits/plan/bypass) | ❌ no dedicated field. *Can* be read by tailing `transcript_path` for the last `permissionMode`, but that's stale right at the moment you switch modes, and Claude Code already shows a native ⏸ badge for manual mode — not worth the duplication, deliberately not built here. |
| Auto-compact, auto-scroll, session recap, notifications, checkpointing/rewind, prompt suggestions, artifacts | ❌ no field, no workaround found |

## Security

Two issues found and fixed while hardening the personal script this plugin is based on:

1. **`git core.fsmonitor` RCE** — a repo can declare an arbitrary command in `core.fsmonitor`, run on every `git diff`/`git status`. Since the statusline re-runs on every refresh, a malicious cloned repo as cwd would re-run that command indefinitely. Fixed: every git call runs with `-c core.fsmonitor= --no-optional-locks`.
2. **ANSI/OSC injection via `printf '%b'`** — `%b` reinterprets backslash-escape text in its argument. A crafted `model.display_name`, `git_worktree`, or `session_name` (via literal `\033[...]` text, or a real ESC byte through a JSON `` escape) could repaint the line, retitle the terminal, or trigger an OSC-52 clipboard write. Fixed: every session-derived field is sanitized (control bytes stripped) before use, all rendering uses `printf '%s'`, and color constants are real escape bytes set once rather than re-interpreted at print time.

Both were verified empirically at the byte level (not just read from the diff), including the width-truncation and OSC-8 link features added later — `is_url_safe_token`/`is_path_safe_token` in `bin/lib.sh` gate link construction to a strict charset before it ever touches an OSC-8 sequence.

## Requirements

- `bash`, `jq` — required. `git` is optional (the git segment is skipped gracefully if missing or cwd isn't a repo). `claude` on `$PATH` is required only for `agents.bgAgentSegment`. `awk` is required only for `features.burnRate` (both degrade silently, not fatally, if missing).
- Tested on Linux/WSL; not yet verified on macOS (ships bash 3.2 by default — this script avoids bash-4+-only syntax where practical) or native Windows.

## Known limitations

- No true cache-hit percentage — see "The cache-TTL segment" above.
- `subagent-statusline.sh` is untested against a real fleet-view payload — see that section above.
- `asciiMode` swaps glyphs but doesn't auto-detect terminal capability.
- `features.widthAwareTruncate` reads `$COLUMNS`/`tput cols`; if neither is available in your environment (no controlling tty), it falls back to a 120-column assumption.

## License

MIT — see [LICENSE](LICENSE).
