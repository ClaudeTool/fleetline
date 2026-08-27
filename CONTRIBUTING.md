# Contributing to fleetline

fleetline is plain bash + `jq` — no build step, no test framework. This
keeps the bar for contributing low, but it also means testing is manual;
see below for the pattern this project actually uses.

## Before you start

- Read [`CLAUDE.md`](CLAUDE.md) first. It documents the non-obvious traps
  in this codebase (jq's `//` treating `false` as falsy, bash's `read`
  collapsing tab-delimited empty fields, the `install.sh` regen step) —
  the kind of thing that's easy to reintroduce a bug by not knowing about.
- Check [`config/schema.json`](config/schema.json) before adding a config
  field — every field is documented there, and the docs should stay in
  sync with the code.

## Reporting a bug

Open an issue with:

- What you expected vs. what happened
- Your OS/shell (`bash --version`, `uname -a`) — this project is only
  verified on Linux/WSL so far; macOS and native Windows reports are
  genuinely useful
- Your `~/.claude/statusline-fleetline.config.json`, if you have one
- If possible, the raw stdin payload — capture it with `cat > /tmp/payload.json`
  temporarily piped in front of the script, redacting anything sensitive

## Testing a change

There's no test suite — synthetic JSON payloads piped into the script,
diffed against expected output, is the whole pattern:

```bash
echo '{"model":{"display_name":"Sonnet 5"},"workspace":{"current_dir":"/some/git/repo"},"context_window":{"used_percentage":34,"context_window_size":200000},"cost":{}}' \
  | STATUSLINE_CONFIG=/tmp/test-cfg.json bash bin/statusline.sh
```

For state that persists across renders (burn-rate, cache-TTL, the
rate-limit flicker guard), reuse the same `session_id` across multiple
piped-in payloads — state lives in `~/.claude/cache-state/<session_id>.*`.
See "How testing was actually done" in `CLAUDE.md` for the exact pattern,
including cleanup.

## If you touch `bin/lib.sh` or `bin/statusline.sh`

`install.sh` inlines a copy of both files for the curl-install path. You
**must** regenerate it — the exact recipe (including how to diff-test the
two-file build against the regenerated one before trusting it) is in
`CLAUDE.md` under "Non-obvious things you need to know before editing".
A PR that changes `bin/` without a matching `install.sh` regen will drift
the two install paths out of sync.

## Style

- No comments explaining *what* code does — names should do that. Only
  comment a non-obvious *why* (a workaround, an invariant, a bug this is
  avoiding).
- Bash 3.2 compatible where practical — no associative arrays, no
  `mapfile`/`readarray`, no `${var,,}`. macOS ships 3.2 by default.
- Keep user-facing strings in `bin/`/`install.sh` in English (see
  `CLAUDE.md` TODO #3 for why).

## Pull requests

Small, focused PRs are easier to review than large ones. If a change
touches the config schema, update `config/schema.json` and `README.md`
in the same PR — they're meant to stay in sync.
