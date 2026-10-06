# claude-code-status-line

A Claude Code status line, packaged as a plugin. Sections are separated by `|`:

```
proj | Sonnet 5.5 (x1.0) | [####------] 42% (200k) | cache 1h 25:00 | h/m/% 9/1/90% | 12% 2h 5m / 5h | 55% 2d 22h / 7d
```

dir · model (with price multiplier vs. Sonnet 5.5) · context bar · prompt-cache TTL and time left, hit/miss stats · rate-limit usage and reset time per window.

## Install

```
/plugin marketplace add sergemso/claude-code-status-line
/plugin install statusline@claude-code-status-line
/statusline:setup
```

`/statusline:setup` points `statusLine` in `~/.claude/settings.json` at `~/.claude/statusline/statusline.sh` (refuses to replace an existing different one unless you pass `--force`). A SessionStart hook keeps that copy in sync with the installed plugin version, so updates need no re-run.

Requires `bash`, `jq`, GNU `date`/`stat`, `curl`, `python3`, `flock` (Linux; macOS needs GNU coreutils).

## Options

- `STATUSLINE_CUSTOM_RESET="label|<anything GNU date -d accepts>"` adds a countdown section, e.g. `sprint|2026-10-17 09:00`.
- `CLAUDE_CONFIG_DIR` is honoured.
- Model price multipliers come from the public pricing page, cached in `~/.claude/model-prices.json` and refreshed hourly in the background. The base model is `BASE_MODEL` at the top of `bin/statusline.sh`.
