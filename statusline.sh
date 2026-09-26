#!/usr/bin/env bash
# Claude Code status line
# Reads JSON input on stdin and prints a single-line status.

# Extract every field in a single jq call, joined by the ASCII unit separator
# (non-whitespace, so `read` keeps empty fields in place). Usage/limit fields
# are optional (absent for non-subscribers or before the first API response),
# so they fall back to empty rather than failing when missing.
US=$'\x1f'
IFS="$US" read -r model cwd effort ctx_pct session_pct session_resets_at \
  week_pct week_resets_at lines_added lines_removed < <(
  jq -r '
    def pct: if type == "number" then round else "" end;
    [
      (.model.display_name // ""),
      (.workspace.current_dir // .cwd // ""),
      (.effort.level // ""),
      (.context_window.used_percentage | pct),
      (.rate_limits.five_hour.used_percentage | pct),
      (.rate_limits.five_hour.resets_at // ""),
      (.rate_limits.seven_day.used_percentage | pct),
      (.rate_limits.seven_day.resets_at // ""),
      (.cost.total_lines_added // 0),
      (.cost.total_lines_removed // 0)
    ] | map(tostring) | join("\u001f")
  '
)

dir_name="${cwd##*/}"

# Shorten "Opus 5.5 (1M context)" to "Opus 5.5 1M".
model_re='^(.*) \(([0-9.]+[KkMm]) context\)$'
[[ $model =~ $model_re ]] && model="${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"

# Format a unix timestamp in local time: macOS `date -r`, then GNU `date -d`.
fmt_time() {
  date -r "$1" "$2" 2>/dev/null || date -d "@$1" "$2" 2>/dev/null
}
session_reset_str=""
[ -n "$session_resets_at" ] && session_reset_str=$(fmt_time "$session_resets_at" "+%H:%M")
week_reset_str=""
[ -n "$week_resets_at" ] && week_reset_str=$(fmt_time "$week_resets_at" "+%a %H:%M")

# Git branch, dirty marker and ahead/behind from a single `git status` call,
# skipping optional locks for safety/speed. Empty outside a repo.
branch=""
dirty=""
ahead=0
behind=0
if [ -n "$cwd" ]; then
  while IFS= read -r line; do
    case "$line" in
      "# branch.head "*) branch="${line#\# branch.head }" ;;
      "# branch.ab "*)
        read -r _ _ a b <<< "$line"
        ahead="${a#+}"
        behind="${b#-}"
        ;;
      "#"*) ;;
      *) dirty="*" ;;
    esac
  done < <(git -C "$cwd" --no-optional-locks status --porcelain=v2 --branch 2>/dev/null)
  [ "$branch" = "(detached)" ] && branch=""
fi

# ANSI colors (dimmed-friendly)
COLOR_MODEL="\033[36m"   # cyan
COLOR_EFFORT="\033[37m"  # light grey (90 was near-invisible on dark bg)
COLOR_CTX="\033[35m"     # magenta
COLOR_SESSION="\033[95m" # bright magenta
COLOR_WEEK="\033[94m"    # bright blue (34 was too dark on dark bg)
COLOR_WARN="\033[93m"    # bright yellow, usage >= WARN_PCT
COLOR_CRIT="\033[91m"    # bright red, usage >= CRIT_PCT
COLOR_ADD="\033[32m"     # green
COLOR_DEL="\033[31m"     # red
COLOR_DIR="\033[33m"     # yellow
COLOR_BRANCH="\033[32m"  # green
COLOR_DIRTY="\033[31m"   # red
COLOR_AHEAD="\033[36m"   # cyan
COLOR_BEHIND="\033[31m"  # red
RESET="\033[0m"
DIM="\033[2m"
SEP=" \033[2m|\033[0m "
COLOR_TRACK="\033[38;5;243m" # mid grey (256-color, theme-independent) for unfilled bar cells

WARN_PCT=70
CRIT_PCT=90
BAR_WIDTH=8

# Render a usage meter into $meter: meter <label> <pct> <base color> [suffix].
# The bar and percentage switch to warn/crit colors as usage climbs; the label
# keeps the base color so each meter stays identifiable.
meter() {
  local label=$1 pct=$2 base=$3 suffix=$4 color=$3 filled empty f="" e="" i
  if [ "$pct" -ge "$CRIT_PCT" ]; then
    color=$COLOR_CRIT
  elif [ "$pct" -ge "$WARN_PCT" ]; then
    color=$COLOR_WARN
  fi
  filled=$(( (pct * BAR_WIDTH + 50) / 100 ))
  [ "$filled" -gt "$BAR_WIDTH" ] && filled=$BAR_WIDTH
  [ "$filled" -lt 0 ] && filled=0
  empty=$(( BAR_WIDTH - filled ))
  for ((i = 0; i < filled; i++)); do f+="━"; done
  for ((i = 0; i < empty; i++)); do e+="━"; done
  meter="${base}${DIM}${label}${RESET} ${color}${f}${RESET}${COLOR_TRACK}${e}${RESET} ${color}${pct}%${RESET}"
  [ -n "$suffix" ] && meter="${meter} ${DIM}(${suffix})${RESET}"
  return 0
}

# Assemble the git segment: branch + dirty marker + ahead/behind.
git_part=""
if [ -n "$branch" ]; then
  git_part="${COLOR_BRANCH}${branch}${COLOR_DIRTY}${dirty}${RESET}"
  [ "$ahead" -gt 0 ] 2>/dev/null && git_part="${git_part} ${COLOR_AHEAD}↑${ahead}${RESET}"
  [ "$behind" -gt 0 ] 2>/dev/null && git_part="${git_part} ${COLOR_BEHIND}↓${behind}${RESET}"
fi

parts=()
[ -n "$model" ] && parts+=("${COLOR_MODEL}${model}${RESET}")
[ -n "$effort" ] && parts+=("${COLOR_EFFORT}${effort}${RESET}")
[ -n "$ctx_pct" ] && meter ctx "$ctx_pct" "$COLOR_CTX" && parts+=("$meter")
[ -n "$session_pct" ] && meter 5h "$session_pct" "$COLOR_SESSION" "$session_reset_str" && parts+=("$meter")
[ -n "$week_pct" ] && meter wk "$week_pct" "$COLOR_WEEK" "$week_reset_str" && parts+=("$meter")
{ [ "$lines_added" -gt 0 ] || [ "$lines_removed" -gt 0 ]; } 2>/dev/null && \
  parts+=("${COLOR_ADD}+${lines_added}${RESET} ${COLOR_DEL}-${lines_removed}${RESET}")
[ -n "$dir_name" ] && parts+=("${COLOR_DIR}${dir_name}${RESET}")
[ -n "$git_part" ] && parts+=("$git_part")

output=""
for i in "${!parts[@]}"; do
  if [ "$i" -eq 0 ]; then
    output="${parts[$i]}"
  else
    output="${output}${SEP}${parts[$i]}"
  fi
done

printf "%b\n" "$output"
