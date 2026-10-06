#!/bin/bash
# Claude Code status line. Sections joined by " | ":
# dir | model | context bar | prompt cache | rate-limit resets | custom reset
CFG=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

input=$(cat)

model=$(echo "$input" | jq -r '.model.display_name')
# Price multiplier vs base model, from prices cached by refresh-model-prices.sh
BASE_MODEL="Claude Sonnet 5.5"
PRICES=$CFG/model-prices.json
# Stale (>1h) or missing -> refresh in background (script is flock-guarded, atomic write)
if [ ! -e "$PRICES" ] || [ $(( $(date +%s) - $(stat -c %Y "$PRICES") )) -ge 3600 ]; then
  setsid nohup "$HERE/refresh-model-prices.sh" >/dev/null 2>&1 </dev/null &
fi
fast=$(echo "$input" | jq -r '.fast_mode // false')
mult=$(jq -r --arg m "Claude $(echo "$input" | jq -r '.model.display_name')" --arg b "$BASE_MODEL" --argjson fast "$fast" '
  .models as $p | ($p[$b].in // empty) as $base | $p[$m] // empty
  | (if $fast and .fast_in then .fast_in else .in end) / $base
  | . * 10 | round / 10' "$PRICES" 2>/dev/null)
[ -n "$mult" ] && model="$model (x$(printf '%.1f' "$mult"))"
used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')

# Colors (dim-friendly)
RESET=$'\033[0m'
DIM=$'\033[2m'
CYAN=$'\033[36m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
RED=$'\033[31m'

bar=""
if [ -n "$used" ]; then
  pct=$(printf '%.0f' "$used")
  width=10
  filled=$(( pct * width / 100 ))
  [ "$filled" -gt "$width" ] && filled=$width
  empty=$(( width - filled ))

  if [ "$pct" -ge 80 ]; then
    color=$RED
  elif [ "$pct" -ge 50 ]; then
    color=$YELLOW
  else
    color=$GREEN
  fi

  bar_filled=$(printf '%*s' "$filled" '' | tr ' ' '#')
  bar_empty=$(printf '%*s' "$empty" '' | tr ' ' '-')

  bar=$(printf "${DIM}[${color}%s${DIM}%s${DIM}]${RESET} ${color}%d%%${RESET}" "$bar_filled" "$bar_empty" "$pct")
else
  bar="${DIM}(no context data)${RESET}"
fi

cwd=$(echo "$input" | jq -r '.workspace.current_dir // .cwd')
# Last directory only, blue
dir=$(printf '\033[01;34m%s\033[00m' "$(basename "$cwd")")

# Prompt cache: TTL + time left until expiry
cache=""
ttl=$(echo "$input" | jq -r '.prompt_cache.ttl // empty')
if [ -n "$ttl" ]; then
  warm=$(echo "$input" | jq -r '.prompt_cache.warm // false')
  exp=$(echo "$input" | jq -r '.prompt_cache.expires_at // empty')
  left=""
  read -r sh sm sp < <(echo "$input" | jq -r '.prompt_cache | select(.requests != null) | "\(.requests - .misses) \(.misses) \((.hit_ratio * 100) | round)"')
  if [ -n "$sp" ]; then
    scolor=$GREEN; [ "$sp" -lt 80 ] && scolor=$RED
    stats=" ${DIM}h/m/% ${RESET}${scolor}${sh}/${sm}/${sp}%${RESET}"
  else
    stats=""
  fi
  if [ "$warm" = "true" ] && [ -n "$exp" ]; then
    rem=$(( exp - $(date +%s) ))
    if [ "$rem" -gt 0 ]; then
      left=$(printf '%d:%02d' $((rem / 60)) $((rem % 60)))
      # Absolute thresholds (time to react): yellow <20min, red <5min
      ccolor=$GREEN
      [ "$rem" -lt 1200 ] && ccolor=$YELLOW
      [ "$rem" -lt 300 ] && ccolor=$RED
      cache="${DIM}cache ${ttl}${RESET} ${ccolor}${left}${RESET}"
    fi
  fi
  [ -z "$cache" ] && cache="${DIM}cache ${ttl} ${RED}cold${RESET}"
fi

# Reset windows: "<pct>% <left>/<total>" for each limit the API reports.
# five_hour = session, seven_day = weekly, spend_limit = gateway (daily/weekly/monthly).
now=$(date +%s)
limits=()
# Seconds -> compact duration: 2d3h42m, 3h42m, 42m
fmt_dur() {
  local s=$1 d h m out=""
  [ "$s" -lt 0 ] && s=0
  d=$(( s / 86400 )); h=$(( (s % 86400) / 3600 )); m=$(( (s % 3600) / 60 ))
  [ "$d" -gt 0 ] && out="${d}d"
  { [ "$d" -gt 0 ] || [ "$h" -gt 0 ]; } && out="${out}${h}h"
  printf '%s%dm' "$out" "$m"
}
# Each row: percent, resets_at, total period label (monthly assumed 30d)
while IFS=$'\t' read -r lpct lreset ltotal; do
  [ -z "$lpct" ] && continue
  lleft=$(fmt_dur $(( lreset - now )))
  lcolor=$GREEN
  [ "$lpct" -ge 50 ] && lcolor=$YELLOW
  [ "$lpct" -ge 80 ] && lcolor=$RED
  limits+=("${lcolor}${lpct}%${RESET} ${lleft}${DIM}/${ltotal}${RESET}")
done < <(echo "$input" | jq -r '
  .rate_limits // {} | (
    (.five_hour   | select(.) | [.used_percentage, .resets_at, "5h"]),
    (.seven_day   | select(.) | [.used_percentage, .resets_at, "7d"]),
    (.spend_limit | select(.) | [.used_percentage, .resets_at,
       ((.period // "") | if . == "daily" then "1d" elif . == "weekly" then "7d" elif . == "monthly" then "30d" else "?" end)])
  ) | "\(.[0] | round)\t\(.[1])\t\(.[2])"')

# Optional custom reset (time only, no percentage): export
# STATUSLINE_CUSTOM_RESET="label|<anything GNU date -d accepts>", e.g. "sprint|2026-10-17 09:00"
if [ -n "$STATUSLINE_CUSTOM_RESET" ]; then
  clabel=${STATUSLINE_CUSTOM_RESET%%|*}
  cts=$(date -d "${STATUSLINE_CUSTOM_RESET#*|}" +%s 2>/dev/null)
  if [ -n "$cts" ]; then
    limits+=("${DIM}${clabel}${RESET} $(fmt_dur $(( cts - now )))")
  fi
fi

# Join non-empty sections with a dim " | "
sections=("$dir" "${CYAN}${model}${RESET}" "$bar")
[ -n "$cache" ] && sections+=("${cache}${stats}")
sections+=("${limits[@]}")
sep="${DIM} | ${RESET}"
out=""
for s in "${sections[@]}"; do
  [ -z "$s" ] && continue
  out="${out:+$out$sep}$s"
done
printf '%s\n' "$out"
