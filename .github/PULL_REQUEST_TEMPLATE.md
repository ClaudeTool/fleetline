## What this changes

## How you tested it

(See [CONTRIBUTING.md](../CONTRIBUTING.md) for the synthetic-payload
testing pattern — there's no test suite, so a description of what you
piped in and what came out is the actual test evidence here.)

## Checklist

- [ ] If `bin/lib.sh` or `bin/statusline.sh` changed, `install.sh` was
      regenerated (see the recipe in `CLAUDE.md`) and diff-tested against
      the two-file build
- [ ] If a config field was added/changed, `config/schema.json` and
      `README.md` were updated to match
- [ ] New user-facing strings in `bin/`/`install.sh` are in English
- [ ] Tested against a real payload where possible, not just reasoning
      about the diff
