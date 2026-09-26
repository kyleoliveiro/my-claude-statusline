# my-claude-statusline

A compact, colorful status line for [Claude Code](https://claude.com/claude-code).

![Status line screenshot](screenshot.png)

## What it shows

The status line spans two rows, with the session snowflake (see the
screenshot) right-aligned beside them:

```
Opus 5.5 1M | high | my-app | main* ↑2 | +128 -37 | $1.84 | cache 42m
ctx ━━━━━━━━ 42% | 5h ━━━━━━━━ 31% (21:45) | wk ━━━━━━━━ 74% (Wed 07:05)
```

**Row 1: session and location**

| Segment | Example | Notes |
| --- | --- | --- |
| Model | `Opus 5.5 1M` | `(1M context)` is shortened to `1M` |
| Effort | `high` | Hidden on models without effort levels |
| Directory | `my-app` | Current working directory name |
| Git | `main* ↑2 ↓1` | Branch, `*` if dirty, commits ahead/behind upstream; `no git` outside a repo |
| Lines changed | `+128 -37` | Hidden until something changes |
| Cost | `$1.84` | Session cost so far |
| Prompt cache | `cache 42m` | Minutes until the prompt cache expires; yellow under 5 minutes, `cache cold` once expired, hidden before the first request |

**Row 2: usage** (omitted when there's no usage data)

| Segment | Example | Notes |
| --- | --- | --- |
| Context | `ctx ━━━━ 42%` | Context window usage |
| 5-hour limit | `5h ━━━━ 31% (21:45)` | Usage and local reset time |
| Weekly limit | `wk ━━━━ 74% (Wed 07:05)` | Usage and reset day/time |

**Session snowflake**

A small multicolored snowflake sits right-aligned across both rows. It is
drawn with half-block characters (7 columns wide) and generated from the
session id, so each session gets its own shape and colors: the arm pattern
(one of 41) plus a rainbow gradient radiating from the centre, with its
starting hue, direction and spacing all seeded. It's a progressive
enhancement: if the terminal is too narrow to fit it beside the text, it's
simply left out.

**Narrow terminals**

Rather than letting Claude Code cut lines off with `…`, each row sheds
detail until it fits. Row 1 drops the cache timer, then lines changed, then
effort, then cost. Row 2 drops the reset times, then halves the bars, then
drops the bars entirely. The snowflake only appears when there's room left
over at full detail.

Usage bars turn yellow at 70% and red at 90%. The rate-limit segments only
appear on Claude subscription plans, once the first response has come back.

## Requirements

- `bash` and `jq`
- `git` (optional, for the git segment)
- macOS or Linux

## Install

```bash
git clone https://github.com/kyleoliveiro/my-claude-statusline.git ~/Projects/my-claude-statusline
ln -sf ~/Projects/my-claude-statusline/statusline.sh ~/.claude/statusline.sh
```

Then add this to `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash ~/.claude/statusline.sh"
  }
}
```

The status line picks up changes on its next refresh; no restart needed. With
the symlink in place, a `git pull` updates it.

## Customize

Edit the variables near the top of the rendering section in `statusline.sh`:

- `WARN_PCT` / `CRIT_PCT`: thresholds for yellow and red bars (default `70` / `90`)
- `BAR_WIDTH`: number of cells in each bar (default `8`)
- `CACHE_WARN_MINS`: minutes left at which the cache timer turns yellow (default `5`)
- `COLOR_*`: ANSI colors for each segment
- `FLAKE_GAP`: minimum spaces between the text and the snowflake (default `2`)
- `RIGHT_MARGIN`: columns kept free at the right edge (default `5`). Claude
  Code indents the status line and truncates overflow with `…`, so raise this
  if lines or the snowflake get cut off.

To try a change without waiting for Claude Code, pipe sample JSON in (set `COLUMNS`, which Claude Code normally provides, to
see the snowflake):

```bash
echo '{"session_id":"demo","model":{"display_name":"Opus 5.5 (1M context)"},"cwd":"'"$PWD"'","context_window":{"used_percentage":42}}' \
  | COLUMNS=100 bash statusline.sh
```
