# claude-statusline

A pluggable statusline for [Claude Code](https://claude.com/claude-code): model, context-window usage, lines changed, git branch, rate limits — with three layout presets, an ASCII-safe mode for terminals without Unicode/Nerd Font support, and a hardened bash renderer.

```
[Sonnet 5] v2.1.4 | Ctx [███░░░░░░░] 34%/200k | +120/-45 | ⬡ feature-x | 🌿 main +2 ~5
Rate: 5h:[███████░░░] 72% (↻ Fri 21/08 09:00) | 7d:[███░░░░░░░] 31% (↻ Tue 25/08 00:00)
```

## Install

### Option A — plugin marketplace (recommended)

```
/plugin marketplace add <your-github-user>/claude-statusline
/plugin install claude-statusline
/statusline-setup
```

`/statusline-setup` asks which layout and whether to use ASCII-safe mode, writes your config file, and registers the statusline in `~/.claude/settings.json` — backing up any statusline you already have first.

### Option B — one-line curl install

For anyone who doesn't want to add a marketplace:

```bash
curl -fsSL https://raw.githubusercontent.com/<your-github-user>/claude-statusline/main/install.sh | bash
```

This writes the script straight to `~/.claude/statusline-command.sh` and merges `statusLine` into `~/.claude/settings.json` (existing settings are preserved; if a `statusLine` key is already there, it's overwritten — the plugin path's setup command is the one that backs it up first, this one-liner does not).

### Manual (no auto-write)

If you'd rather not grant either path permission to edit `settings.json`, add this yourself:

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
| `hardened` | 2 | + version, lines added/removed, worktree, rate limits (Pro/Max only) |
| `power` | 3 | + cost, session name, PR number/review state, effort level, thinking mode, cache-TTL — each shown only when that field is present in the current turn's payload |

Pick one during `/statusline-setup`, or edit the config file directly (see below) to change later.

## Config

`~/.claude/statusline-claude-statusline.config.json` (path overridable via `$STATUSLINE_CONFIG`). Lives outside the plugin's own directory on purpose, so a plugin update never wipes it. Full shape documented in [`config/schema.json`](config/schema.json):

```json
{
  "layout": "hardened",
  "asciiMode": false,
  "thresholds": { "warn": 70, "crit": 90 },
  "hints": { "compactHint": true }
}
```

- **`thresholds`** governs the context bar and both rate-limit bars: green below `warn`, yellow in `[warn, crit)`, red at `crit` and above.
- **`hints.compactHint`** appends a red `· /compact?` to the context segment once usage crosses `crit`, in every layout — a nudge to compact while the prompt cache is still warm, cheaper than letting it go cold.

## The cache-TTL segment (power layout)

Claude Code's statusline payload does not expose actual cache hit/write token counts, so this is not a real cache-hit gauge — it's a countdown inferred from wall-clock time since your last distinct turn in this session, using the documented sliding-window TTL: 60 minutes if the payload carries `rate_limits` (subscription plans), 5 minutes otherwise (API key / pay-as-you-go). State is tracked per `session_id` in `~/.claude/cache-state/`. Shows `TTL:58m` (green) → `TTL:6m` (yellow, ≤10 min left) → `❄ TTL hết` (red, past the window). If your Claude Code version doesn't send `prompt_id`, the countdown can't detect new turns and will just show the full window every time — a known, harmless degradation, not a crash.

## Security

Two issues found and fixed while hardening the original personal script this plugin is based on:

1. **`git core.fsmonitor` RCE** — a repo can declare an arbitrary command in `core.fsmonitor`, run on every `git diff`/`git status`. Since the statusline re-runs on every refresh (every 30s by default), simply having your cwd inside a malicious cloned repo would re-run that command indefinitely. Fixed by always running git with `-c core.fsmonitor= --no-optional-locks`.
2. **ANSI/OSC injection via `printf '%b'`** — `%b` reinterprets backslash-escape text in its argument. A crafted `model.display_name`, `git_worktree`, or `session_name` containing literal `\033[...` text, or a real `ESC` byte via a JSON `` escape, could repaint the line, retitle the terminal, or trigger an OSC-52 clipboard write. Fixed by sanitizing every session-derived field (stripping control bytes) and switching all rendering to `printf '%s'`, with colors stored as real escape bytes set once at the top of the script instead of being re-interpreted at print time.

Both fixes were verified empirically (not just read from the diff) — see the project history if you want the exact test payloads.

## Requirements

- `bash`, `jq`, `git` (git is optional — the git segment is skipped gracefully if it's missing or the cwd isn't a repo). Tested on Linux and WSL; should work on macOS and Git-Bash on Windows, but hasn't been verified there yet.
- If `jq` is missing, the script prints one line saying so instead of crashing.

## Known limitations

- No true cache-hit percentage — see "The cache-TTL segment" above.
- `asciiMode` swaps glyphs but the underlying data is unchanged; it doesn't detect terminal capability automatically.
- macOS ships bash 3.2 by default; this script avoids bash-4+-only syntax where practical, but hasn't been tested against 3.2.
- Plugin name may change before a submission to the official Claude Code plugin marketplace, to avoid colliding with existing tools in the space (`ccstatusline`, `starship-claude`).

## License

MIT — see [LICENSE](LICENSE).
