#!/usr/bin/env bash
# Claude Code status line
# Reads JSON input on stdin and prints a two-line status, with a per-session
# snowflake right-aligned across both lines when the terminal is wide enough.

# Extract every field in a single jq call, joined by the ASCII unit separator
# (non-whitespace, so `read` keeps empty fields in place). Usage/limit fields
# are optional (absent for non-subscribers or before the first API response),
# so they fall back to empty rather than failing when missing.
US=$'\x1f'
IFS="$US" read -r model cwd effort ctx_pct session_pct session_resets_at \
  week_pct week_resets_at lines_added lines_removed session_id cost_usd \
  cache_requests cache_warm cache_expires_at < <(
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
      (.cost.total_lines_removed // 0),
      (.session_id // ""),
      (.cost.total_cost_usd // ""),
      (.prompt_cache.requests // ""),
      (.prompt_cache.warm // ""),
      (.prompt_cache.expires_at // "")
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

# Session cost, e.g. "$0.35"; C locale so the decimal point is always ".".
cost_str=""
[ -n "$cost_usd" ] && cost_str=$(LC_ALL=C printf '$%.2f' "$cost_usd" 2>/dev/null)
[ "$cost_str" = '$0.00' ] && cost_str=""

# Prompt cache: minutes until the cached prefix expires, or "cold" once it has.
# Hidden before the first request, when there's nothing cached yet.
cache_mins=""
cache_cold=""
if [ "${cache_requests:-0}" -gt 0 ] 2>/dev/null; then
  now=$(date +%s)
  if [ "$cache_warm" = "true" ] && [ "${cache_expires_at:-0}" -gt "$now" ] 2>/dev/null; then
    cache_mins=$(( (cache_expires_at - now) / 60 ))
  else
    cache_cold=1
  fi
fi

# Git branch, dirty marker and ahead/behind from a single `git status` call,
# skipping optional locks for safety/speed. Empty outside a repo; in_repo is
# set from the "# branch.*" headers, which git always prints inside a repo.
in_repo=""
branch=""
dirty=""
ahead=0
behind=0
if [ -n "$cwd" ]; then
  while IFS= read -r line; do
    case "$line" in
      "# branch.head "*) branch="${line#\# branch.head }"; in_repo=1 ;;
      "# branch.ab "*)
        read -r _ _ a b <<< "$line"
        ahead="${a#+}"
        behind="${b#-}"
        in_repo=1
        ;;
      "# branch."*) in_repo=1 ;;
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
COLOR_COST="\033[97m"    # bright white
COLOR_CACHE="\033[96m"   # bright cyan
RESET="\033[0m"
DIM="\033[2m"
SEP=" \033[2m|\033[0m "
COLOR_TRACK="\033[38;5;243m" # mid grey (256-color, theme-independent) for unfilled bar cells

WARN_PCT=70
CRIT_PCT=90
BAR_WIDTH=8
CACHE_WARN_MINS=5 # cache countdown turns yellow below this

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
  meter="${base}${DIM}${label}${RESET} "
  [ "$BAR_WIDTH" -gt 0 ] && meter+="${color}${f}${RESET}${COLOR_TRACK}${e}${RESET} "
  meter+="${color}${pct}%${RESET}"
  [ -n "$suffix" ] && meter="${meter} ${DIM}(${suffix})${RESET}"
  return 0
}

# Assemble the git segment: branch + dirty marker + ahead/behind.
git_part=""
if [ -n "$branch" ]; then
  git_part="${COLOR_BRANCH}${branch}${COLOR_DIRTY}${dirty}${RESET}"
  [ "$ahead" -gt 0 ] 2>/dev/null && git_part="${git_part} ${COLOR_AHEAD}↑${ahead}${RESET}"
  [ "$behind" -gt 0 ] 2>/dev/null && git_part="${git_part} ${COLOR_BEHIND}↓${behind}${RESET}"
elif [ -n "$cwd" ] && [ -z "$in_repo" ]; then
  git_part="${DIM}no git${RESET}"
fi

# Render a seeded 7x4-pixel snowflake as two rows of 7 half-block cells into
# $flake1/$flake2 (ANSI colors embedded). Mirrored left/right and
# top/bottom: each pixel folds to (dx, dy) in a 4x2 quadrant, dx = distance
# from the centre column (0-3), dy = 0 for the inner rows, 1 for the outer.
flake() {
  # Random bytes come from the md5 of the seed string (md5sum on Linux, md5 on macOS).
  local hash pos=0 r dx dy x y q=() cell top bot row col
  hash=$(printf '%s' "$1" | { md5sum 2>/dev/null || md5; } | cut -c1-32)
  [ ${#hash} -eq 32 ] || return 1
  rnd() { r=$(( 16#${hash:pos:2} )); pos=$(( (pos + 2) % 32 )); }
  # Centre column is always the vertical spine. The other 6 quadrant cells
  # (dx 1-3, both rows) take one of the masks with 1-3 bits set: enough to
  # branch, sparse enough never to blob.
  local masks=() m n i
  for ((m = 1; m < 64; m++)); do
    n=0
    for ((i = 0; i < 6; i++)); do n=$(( n + (m >> i & 1) )); done
    [ $n -le 3 ] && masks+=($m)
  done
  rnd; m=${masks[r % ${#masks[@]}]}
  for ((dy = 0; dy < 2; dy++)); do
    q[dy*4]=1
    for ((dx = 1; dx < 4; dx++)); do
      q[dy*4+dx]=$(( m >> (dy * 3 + dx - 1) & 1 ))
    done
  done
  # Pixel (x, y) on the 7x4 grid -> $pc: its 256-color, or empty when off.
  # Colors radiate from the centre: ring = dx + dy (0-4) indexes a run of the
  # rainbow whose start, direction and spacing come from the seed.
  local rainbow=(196 202 208 214 220 226 190 154 118 82 46 48 50 51 45 39 33 27 21 57 93 129 165 201 199 197)
  local nr=${#rainbow[@]} start dir step ring=()
  rnd; start=$(( r % nr ))
  rnd; dir=$(( r & 1 ? 1 : -1 ))
  rnd; step=$(( 2 + r % 3 ))
  for ((i = 0; i < 5; i++)); do
    ring[i]=${rainbow[( (start + dir * step * i) % nr + nr ) % nr]}
  done
  px() {
    local dx=$(( $1 < 3 ? 3 - $1 : $1 - 3 )) dy=$(( $2 == 0 || $2 == 3 ))
    pc=""
    [ "${q[dy*4+dx]}" = 1 ] && pc=${ring[dx + dy]}
  }
  # Each cell is one half-block glyph: top pixel in the foreground, bottom in
  # the background when both are lit in different colors.
  flake1="" flake2=""
  local tc bc
  for ((row = 0; row < 2; row++)); do
    local line=""
    for ((x = 0; x < 7; x++)); do
      px $x $(( row * 2 )); tc=$pc
      px $x $(( row * 2 + 1 )); bc=$pc
      if [ -n "$tc" ] && [ -n "$bc" ]; then
        if [ "$tc" = "$bc" ]; then
          line+="\033[38;5;${tc}m█\033[0m"
        else
          line+="\033[38;5;${tc};48;5;${bc}m▀\033[0m"
        fi
      elif [ -n "$tc" ]; then
        line+="\033[38;5;${tc}m▀\033[0m"
      elif [ -n "$bc" ]; then
        line+="\033[38;5;${bc}m▄\033[0m"
      else
        line+=" "
      fi
    done
    [ $row -eq 0 ] && flake1=$line || flake2=$line
  done
}

# Join args with $SEP into $joined.
join_parts() {
  local out="" p
  for p in "$@"; do
    out="${out:+${out}${SEP}}${p}"
  done
  joined=$out
}

# Line 1: who/where — model, effort, dir, git, lines changed, cost, cache.
# Detail levels 0-4 drop, in order: cache, lines changed, effort, cost.
build_line1() {
  local level=$1 parts=()
  [ -n "$model" ] && parts+=("${COLOR_MODEL}${model}${RESET}")
  [ -n "$effort" ] && [ "$level" -lt 3 ] && parts+=("${COLOR_EFFORT}${effort}${RESET}")
  [ -n "$dir_name" ] && parts+=("${COLOR_DIR}${dir_name}${RESET}")
  [ -n "$git_part" ] && parts+=("$git_part")
  if [ "$level" -lt 2 ] && { [ "$lines_added" -gt 0 ] || [ "$lines_removed" -gt 0 ]; } 2>/dev/null; then
    parts+=("${COLOR_ADD}+${lines_added}${RESET} ${COLOR_DEL}-${lines_removed}${RESET}")
  fi
  [ -n "$cost_str" ] && [ "$level" -lt 4 ] && parts+=("${COLOR_COST}${cost_str}${RESET}")
  if [ "$level" -lt 1 ]; then
    if [ -n "$cache_mins" ]; then
      local c=$COLOR_CACHE m="${cache_mins}m"
      [ "$cache_mins" -lt "$CACHE_WARN_MINS" ] && c=$COLOR_WARN
      [ "$cache_mins" -lt 1 ] && m="<1m"
      parts+=("${c}${DIM}cache${RESET} ${c}${m}${RESET}")
    elif [ -n "$cache_cold" ]; then
      parts+=("${DIM}cache cold${RESET}")
    fi
  fi
  join_parts "${parts[@]}"
}

# Line 2: usage meters. Detail levels 0-3: drop reset times, then halve the
# bars, then drop the bars entirely.
build_line2() {
  local level=$1 parts=() s5="$session_reset_str" swk="$week_reset_str"
  local BAR_WIDTH=$BAR_WIDTH
  [ "$level" -ge 1 ] && s5="" swk=""
  [ "$level" -ge 2 ] && BAR_WIDTH=$(( BAR_WIDTH / 2 ))
  [ "$level" -ge 3 ] && BAR_WIDTH=0
  [ -n "$ctx_pct" ] && meter ctx "$ctx_pct" "$COLOR_CTX" && parts+=("$meter")
  [ -n "$session_pct" ] && meter 5h "$session_pct" "$COLOR_SESSION" "$s5" && parts+=("$meter")
  [ -n "$week_pct" ] && meter wk "$week_pct" "$COLOR_WEEK" "$swk" && parts+=("$meter")
  joined=""
  [ "${#parts[@]}" -gt 0 ] && join_parts "${parts[@]}"
  return 0
}

# Visible width of a %b-formatted string (ANSI stripped, UTF-8 chars counted).
vis_width() {
  # Count characters, not bytes, even if the inherited locale isn't UTF-8.
  local plain LC_ALL=C.UTF-8
  plain=$(printf '%b' "$1" | sed $'s/\x1b\\[[0-9;]*m//g')
  vis=${#plain}
}

# Claude Code indents the status line 2 columns and truncates overflow with
# "…" at about COLUMNS-4 visible chars; keep this many columns free.
RIGHT_MARGIN=5

# Build a line at the lowest detail level that fits: fit_line <builder> <max>.
# Without a known width, always use full detail.
fit_line() {
  local builder=$1 max=$2 level
  for ((level = 0; level <= max; level++)); do
    "$builder" "$level"
    [ "${COLUMNS:-0}" -gt 0 ] || return 0
    vis_width "$joined"
    [ "$vis" -le $(( COLUMNS - RIGHT_MARGIN )) ] && return 0
  done
  return 0 # still too long at minimum detail; let Claude Code truncate
}
fit_line build_line1 4; out1=$joined
fit_line build_line2 3; out2=$joined

# Session snowflake, right-aligned across both rows. Progressive enhancement:
# skipped when COLUMNS is unknown or the lines leave no room for it.
FLAKE_W=7
FLAKE_GAP=2 # min spaces between text and flake
if [ -n "$session_id" ] && [ "${COLUMNS:-0}" -gt 0 ] && flake "$session_id"; then
  vis_width "$out1"; w1=$vis
  vis_width "$out2"; w2=$vis
  widest=$(( w1 > w2 ? w1 : w2 ))
  flake_col=$(( COLUMNS - RIGHT_MARGIN - FLAKE_W ))
  if [ $(( widest + FLAKE_GAP )) -le "$flake_col" ]; then
    out1="${out1}$(printf '%*s' $(( flake_col - w1 )) '')${flake1}"
    out2="${out2}$(printf '%*s' $(( flake_col - w2 )) '')${flake2}"
  fi
fi

printf "%b\n" "$out1"
[ -n "$out2" ] && printf "%b\n" "$out2"
exit 0
