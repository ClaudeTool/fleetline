# fleetline — project context for Claude

This file exists so a fresh Claude Code session (different machine, no
memory of the original conversation) can pick this project back up with
full context. Read this before touching any code here.

## What this is

A Claude Code statusline plugin, distributed two ways: the plugin
marketplace (`.claude-plugin/plugin.json` + `commands/statusline-setup.md`
does the setup interview and writes config/settings.json) and a
standalone `install.sh` (curl-installable, no marketplace needed, but
missing the hook-based and fleet-view features — see below).

Originally started as the user's own personal statusline script
(`~/.claude/statusline-command.sh`), shared informally as a one-file
installer. This repo is that script turned into a proper, hardened,
shareable plugin — first named `claude-statusline`, renamed to
`fleetline` after discovering the original name was already taken by
an unrelated project (verified via web search: felipeelias.github.io
blog post, plus `ccstatusline`/`starship-claude`/`cship`/`ccsidekick`/
`codachi` already crowding the space).

## File map

```
.claude-plugin/plugin.json    plugin manifest (name, version, description)
bin/lib.sh                    shared helpers — colors, sanitize(), cfg_bool(),
                               draw_bar()/rate_bar(), fit_line() (width-aware
                               truncation), OSC-8 link builders. Sourced by
                               both scripts below; not executed directly.
bin/statusline.sh             the main statusLine renderer (1-3 lines)
bin/subagent-statusline.sh    the subagentStatusLine renderer (fleet/agent
                               panel view) — LEAST-VERIFIED file, see below
hooks/hooks.json + agent-count.sh   optional SubagentStart/Stop counter,
                               plugin-only (see "Open questions")
config/schema.json            documents every config field + default
commands/statusline-setup.md  the /statusline-setup interview + settings.json
                               writer (with backup-before-overwrite)
install.sh                    curl-installable single-file build — bin/lib.sh
                               is INLINED into it (regenerate if you edit
                               lib.sh or statusline.sh — see below)
docs/index.html               GitHub Pages landing page (self-contained,
                               dark-only by deliberate choice, no build step)
README.md                     user-facing docs (install, config, limitations)
```

## Non-obvious things you need to know before editing

**If you edit `bin/lib.sh` or `bin/statusline.sh`, you MUST regenerate
`install.sh`'s inlined copy** — it's not a symlink or an `include`, it's a
literal copy-paste inside a heredoc (`cat > "$SCRIPT_DEST" << 'STATUSLINE_EOF'`)
because the curl-install path writes one self-contained file and can't
rely on a sibling `lib.sh` existing. The regen recipe (works from repo root):

```bash
grep -n "STATUSLINE_EOF" install.sh   # confirm both marker line numbers before trusting the two sed calls below — they drift every time the inlined content changes size (currently 37 open, 582 close)
{ sed -n '1,37p' install.sh; } > /tmp/header.sh
{ sed -n '583,$p' install.sh; } > /tmp/footer.sh
{
  echo '#!/usr/bin/env bash'
  echo '# fleetline — pluggable Claude Code statusline (curl-install build: lib.sh'
  echo '# inlined below since this installer writes a single self-contained file).'
  echo
  tail -n +2 bin/lib.sh
  echo
  sed -n '2,17p;22,$p' bin/statusline.sh
} > /tmp/inlined.sh
cat /tmp/header.sh /tmp/inlined.sh > install.sh; echo STATUSLINE_EOF >> install.sh; cat /tmp/footer.sh >> install.sh
bash -n install.sh   # then diff-test 2-file vs inlined output on the same payload before trusting it
```
The `2,17p;22,$p` range in statusline.sh skips its own shebang and the
`source ./lib.sh` lines (currently lines 18-21) — re-check those line
numbers if you've edited the top of the file.

**jq's `//` treats a stored `false` the same as `null`/missing.** This bit
us twice: once in config reading (fixed via `cfg_bool()` in lib.sh — never
use `cfg '.foo // true'` for a boolean, always `cfg_bool '.foo' true`),
and once in stdin JSON reading (`.thinking.enabled // empty` silently
turned an explicit `false` into "absent", so "thinking:off" could never
render — fixed by switching to an explicit null-check in the jq filter).
If you add a new boolean field anywhere, use the null-check pattern, not
`//`.

**Bash's `read` treats tab as "IFS whitespace" no matter what you set
`IFS` to**, which collapses consecutive delimiters (i.e. drops empty
fields) and silently misaligns everything after the first gap. Both
`bin/statusline.sh` (extracting ~26 stdin fields) and
`bin/subagent-statusline.sh` (7 fields per task) consolidate what used to
be one-`jq`-call-per-field into a single `jq` call joined with `\x1f`
(Unit Separator, not `@tsv`'s tab) and split back out with
`IFS=$'\x1f' read -r var1 var2 ...`. If you add a field to either
extraction, add it to the jq array/join AND the read var list, in the
same position, or you'll get silent field-shift corruption — this
happened during development and looked like completely unrelated fields
(model name showing up as a directory path) before the cause was found.

**Claude Code plugins cannot auto-register `statusLine` or
`subagentStatusLine`** — these are user-facing `settings.json` keys, not
a plugin-contributed component type. That's why `/statusline-setup`
exists: it's the workaround, and it must back up any existing
`statusLine`/`subagentStatusLine` before overwriting (already implemented
— don't remove that check).

**Plugin-contributed hooks (`hooks/hooks.json`) DO auto-load** once the
plugin is installed/enabled — no settings.json edit needed for those,
unlike the two keys above. But hooks only load at session start; editing
`hooks/hooks.json` or the plugin needs a `claude` restart to take effect.
This is why `agents.hookCounterEnabled` in the config docs/README warn
about needing a restart.

**`claude agents --json` spawns a real process (~0.4s observed)** — this
is why `agents.bgAgentSegment` defaults to `false` and is throttled by
`agents.bgAgentPollSeconds` (default 60s) rather than polled every
render tick.

## Verified vs. not verified — be honest about this with the user

**Verified empirically** (byte-level checks, real browser via
chrome-devtools MCP, or a real live `claude agents --json` call in the
dev environment — not just read-and-assumed-correct):
- Both security fixes (`git core.fsmonitor` RCE, ANSI/OSC injection via
  `printf '%b'`) — tested with payloads containing a real raw ESC byte
  and a textual `\033[...` escape sequence, confirmed neither survives
  into rendered output.
- All three layouts, ASCII mode, width-aware truncation, burn-rate math,
  cache-TTL countdown (including same-prompt-id-doesn't-reset), the
  bg-agent segment against this environment's real `claude agents --json`
  output, the hook counter's increment/decrement/floor-at-zero.
- The landing page in a real headless browser: no console errors, correct
  animation timeline (captured via an injected page-load logger, not
  guessed from reading the code), pxbar rendering, aria attributes.

**NOT verified — genuinely unknown, say so if asked:**
- `bin/subagent-statusline.sh` — built entirely from documented field
  names (`tasks[]` shape: id, name, type, status, description, label,
  startTime, model, effort, contextWindowSize, tokenCount, tokenSamples,
  cwd). No live multi-agent fleet-view session was available to capture
  a real payload. The `status` enum values are guessed (matches
  substrings "block"/"wait" loosely, not an exact string). **This is the
  single most likely place for a real bug if someone reports the fleet
  view looking wrong.**
- `agents.hookCounterEnabled`'s core assumption: that a `SubagentStart`/
  `SubagentStop` hook payload's `session_id` matches the *main* session's
  `session_id` (which `bin/statusline.sh` reads). If Claude Code instead
  reports the spawned subagent's own session_id to the hook, the two
  never match and the feature silently never activates (no crash, no
  error — the `~N` between-poll estimate just never appears). Documented
  in README; not resolved either way.
- Never tested on macOS (ships bash 3.2 by default) or native Windows.
  Linux/WSL only so far.

## Open TODOs for whoever picks this up next

1. **Replace the `haib` GitHub-username placeholder** throughout
   (README.md, docs/index.html, install.sh's curl URL) with the real
   account before this goes public — it was a guess, never confirmed.
2. **No git remote is configured yet.** Create the GitHub repo, push,
   then enable GitHub Pages (Settings → Pages → Deploy from branch →
   `main` → `/docs`) to publish `docs/index.html`.
3. Once live and stable, consider a PR to the official
   `claude-plugins-official` marketplace — re-check for name collisions
   again first, the landscape moves.
4. If anyone can capture a real `subagentStatusLine` payload or a real
   `SubagentStart`/`SubagentStop` hook payload from an actual multi-agent
   session, that resolves the two "not verified" items above — worth
   prioritizing over new features.
5. macOS/Windows testing (see above) — nothing is known to be broken
   there, it's just never been tried.

## How testing was actually done in this project (reuse this pattern)

No test framework — plain bash, piping synthetic JSON payloads into the
scripts and checking output, plus `STATUSLINE_CONFIG=/path/to/cfg.json`
to override the config path per test without touching `~/.claude/`:

```bash
echo '{"model":{"display_name":"Sonnet 5"},"workspace":{"current_dir":"/some/git/repo"},"context_window":{"used_percentage":34,"context_window_size":200000},"cost":{}}' \
  | STATUSLINE_CONFIG=/tmp/test-cfg.json bash bin/statusline.sh
```

For anything security-relevant, verify at the byte level with Python
rather than trusting a terminal's rendering of the output — a raw ESC
byte and the 4-character text `\033[` look identical printed to a
screenshot but are very different security properties:

```bash
your_script < payload.json > /tmp/out.bin
python3 -c "print(b'\x1b[31m' in open('/tmp/out.bin','rb').read())"
```

For the landing page, use a real browser (chrome-devtools MCP or
equivalent) — reading the HTML/CSS/JS and reasoning about it missed real
bugs twice in this project (a font-fallback bar-height mismatch, and a
`display:flex` + bare-text-node bug that broke word-wrapping inside a
`<code>` tag) that only showed up in an actual screenshot.
