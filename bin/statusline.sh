#!/bin/bash
# Claude Code status line. Sections joined by " | ":
# model | context bar | prompt cache (time left, hit rate) | rate-limit resets | custom reset
# Needs: bash, jq (+ curl, awk for the background price refresh).
CFG=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }   # GNU || BSD
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

# Seconds -> two most significant units of mo(30d)/d/h/m/s:
# "2mo 3d", "6d 23h", "5h 12m", "1d 0h", "42m 5s", "59s"
fmt_dur() {
  local s=$1 i n out="" started="" parts=0
  local units=(2592000 86400 3600 60 1) labels=(mo d h m s)
  [ "$s" -lt 0 ] && s=0
  for i in 0 1 2 3 4; do
    n=$(( s / ${units[i]} )); s=$(( s % ${units[i]} ))
    if [ -n "$started" ] || [ "$n" -gt 0 ]; then
      started=1; parts=$(( parts + 1 ))
      out="${out:+$out }${n}${labels[i]}"
      [ "$parts" -ge 2 ] && break
    fi
  done
  printf '%s' "${out:-0s}"
}
# Settings: env STATUSLINE_<KEY> > config file ($CFG/statusline/config, KEY=value lines,
# written by config.sh / /statusline:config) > default.
CONF=$CFG/statusline/config
if [ -r "$CONF" ]; then
  while IFS== read -r k v; do
    case $k in
      BASE_MODEL|SECTIONS|RESETS|PRICES_TTL|CONTEXT_WARN|CONTEXT_CRIT|CACHE_WARN|CACHE_CRIT|RESET_WARN|RESET_CRIT|WIDTH|MARGIN|DUMP)
        printf -v "cf_$k" '%s' "$v" ;;
    esac
  done < "$CONF"
fi
# setting KEY DEFAULT -> env, else file, else default
setting() { local e="STATUSLINE_$1" f="cf_$1"; echo "${!e:-${!f:-$2}}"; }
# num KEY DEFAULT -> setting, or DEFAULT if not a non-negative integer
num() { local v; v=$(setting "$1" "$2"); case $v in ''|*[!0-9]*) v=$2 ;; esac; echo "$v"; }
BASE_MODEL=$(setting BASE_MODEL "Claude Sonnet 5.5")
SECTIONS=$(setting SECTIONS "model,context,cache,stats,resets")
PRICES_TTL=$(num PRICES_TTL 3600)
CONTEXT_WARN=$(num CONTEXT_WARN 50); CONTEXT_CRIT=$(num CONTEXT_CRIT 80)   # context used, %
CACHE_WARN=$(num CACHE_WARN 20);     CACHE_CRIT=$(num CACHE_CRIT 5)        # cache time left, minutes
RESET_WARN=$(num RESET_WARN 50);     RESET_CRIT=$(num RESET_CRIT 80)       # reset window used, %
WIDTH=$(num WIDTH 0)      # terminal columns; 0 = detect from /dev/tty, unknown = never compact
MARGIN=$(num MARGIN 2)    # columns kept free at the right edge when fitting
sec() { case ",$SECTIONS," in *",$1,"*) return 0 ;; esac; return 1; }   # is section enabled?

input=$(cat)
# DUMP (env STATUSLINE_DUMP or config.sh dump) = path: write the raw status-line JSON there, plus
# a line with the detected width and compaction level (to see what the API sends / why it compacts)
DUMP=$(setting DUMP "")
[ -n "$DUMP" ] && printf '%s\n' "$input" > "$DUMP"

model=$(echo "$input" | jq -r '.model.display_name')
model_plain=$model
# Price multiplier vs base model, from prices cached by refresh-model-prices.sh
PRICES=$CFG/model-prices.json
# Stale (> PRICES_TTL s) or missing -> refresh in background (script is lock-guarded, atomic write)
if [ ! -e "$PRICES" ] || [ $(( $(date +%s) - $(mtime "$PRICES") )) -ge "$PRICES_TTL" ]; then
  STATUSLINE_PRICES_TTL=$PRICES_TTL nohup "$HERE/refresh-model-prices.sh" >/dev/null 2>&1 </dev/null &
fi
fast=$(echo "$input" | jq -r '.fast_mode // false')
mult=$(jq -r --arg m "Claude $(echo "$input" | jq -r '.model.display_name')" --arg b "$BASE_MODEL" --argjson fast "$fast" '
  .models as $p | ($p[$b].in // empty) as $base | $p[$m] // empty
  | (if $fast and .fast_in then .fast_in else .in end) / $base
  | . * 10 | round / 10' "$PRICES" 2>/dev/null)
[ -n "$mult" ] && model="$model (x$(printf '%.1f' "$mult"))"
used=$(echo "$input" | jq -r '.context_window.used_percentage // empty')
# Context window size -> "200k" / "1M"
csize=$(echo "$input" | jq -r '.context_window.context_window_size // empty')
if [ -n "$csize" ]; then
  if [ "$csize" -ge 1000000 ]; then csize="$(( csize / 1000000 ))M"; else csize="$(( csize / 1000 ))k"; fi
fi

# Colors (dim-friendly)
RESET=$'\033[0m'
DIM=$'\033[2m'
CYAN=$'\033[36m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
RED=$'\033[31m'

bar=""; bar_s=""
if [ -n "$used" ]; then
  pct=$(printf '%.0f' "$used")
  # 5 cells x 4 shades (░ ▒ ▓ █) = 15 steps, Norton-Commander style
  width=5
  steps=$(( (pct * width * 3 + 50) / 100 ))
  [ "$steps" -gt $(( width * 3 )) ] && steps=$(( width * 3 ))
  full=$(( steps / 3 )); part=$(( steps % 3 ))

  if [ "$pct" -ge "$CONTEXT_CRIT" ]; then
    color=$RED
  elif [ "$pct" -ge "$CONTEXT_WARN" ]; then
    color=$YELLOW
  else
    color=$GREEN
  fi

  cells=""
  for (( i = 0; i < width; i++ )); do
    if   [ "$i" -lt "$full" ]; then cells+="█"
    elif [ "$i" -eq "$full" ] && [ "$part" -gt 0 ]; then cells+=$([ "$part" -eq 1 ] && echo "▒" || echo "▓")
    else cells+="${DIM}░${RESET}${color}"
    fi
  done

  bar_s="${color}${cells}${RESET} ${color}${pct}%${RESET}"                # no window size
  bar="${bar_s}${csize:+ ${DIM}(${csize})${RESET}}"
else
  bar="${DIM}(no context data)${RESET}"; bar_s=$bar
fi

# Prompt cache: time left until expiry + hit rate (the "stats" section toggles the rate)
cache=""; cache_s=""
ttl=$(echo "$input" | jq -r '.prompt_cache.ttl // empty')
if [ -n "$ttl" ]; then
  warm=$(echo "$input" | jq -r '.prompt_cache.warm // false')
  exp=$(echo "$input" | jq -r '.prompt_cache.expires_at // empty')
  sp=$(echo "$input" | jq -r '.prompt_cache | select(.requests != null) | (.hit_ratio * 100) | round')
  stats=""
  if sec stats && [ -n "$sp" ]; then
    scolor=$GREEN; [ "$sp" -lt 80 ] && scolor=$RED
    stats=" ${scolor}${sp}%${RESET}"
  fi
  if [ "$warm" = "true" ] && [ -n "$exp" ]; then
    rem=$(( exp - $(date +%s) ))
    if [ "$rem" -gt 0 ]; then
      # Absolute thresholds (time to react), minutes left
      ccolor=$GREEN
      [ "$rem" -lt $(( CACHE_WARN * 60 )) ] && ccolor=$YELLOW
      [ "$rem" -lt $(( CACHE_CRIT * 60 )) ] && ccolor=$RED
      cache="${DIM}cache${RESET} ${ccolor}$(fmt_dur "$rem")${RESET}"
    fi
  fi
  [ -z "$cache" ] && cache="${RED}no cache${RESET}"
  cache_s=$cache                 # no hit rate
  cache="${cache}${stats}"
fi

# Reset sections, "[name] <pct>% <left> / <total>" for every rate_limits window the
# API sends (five_hour, seven_day, spend_limit, and any it adds later).
# STATUSLINE_RESETS (or RESETS in the config file) = comma list of what to show, in order. Each item is an API
# key (seven_day_opus) or its alias (5h, 7d, spend, 7d-opus). Default "5h,7d,spend";
# "all" = everything the API sent, "none" = hide all.
now=$(date +%s)
rows=()
# Row (tab-separated, "-" = empty): key alias name pct resets_at total.
# total comes from spend_limit.period or the key name (five_hour -> 5h).
while IFS= read -r line; do
  [ -n "$line" ] && rows+=("$line")
done < <(echo "$input" | jq -r '
  {one:1,two:2,three:3,four:4,five:5,six:6,seven:7,eight:8,nine:9,ten:10,thirty:30} as $nums
  | .rate_limits // {} | to_entries[]
  | select(.value | type == "object" and .resets_at != null)
  | .key as $k | .value as $v
  | (($k | capture("^(?<n>[a-z]+)_(?<u>hour|day|week|month)(?:_(?<s>.+))?$")) // null) as $c
  | (if $k == "spend_limit" then ({daily:"1d",weekly:"7d",monthly:"30d"}[$v.period // ""] // "?")
     elif $c and $nums[$c.n] then ($nums[$c.n] | tostring) + ({hour:"h",day:"d",week:"w",month:"mo"}[$c.u])
     else "" end) as $total
  | (if $k == "spend_limit" then "spend"
     elif $total != "" then $total + (if $c.s then "-" + ($c.s | gsub("_"; "-")) else "" end)
     else $k end) as $alias
  | (if $k == "spend_limit" then ""
     elif $total == "" then $k
     elif $c.s then ($c.s | gsub("_"; " "))
     else "" end) as $name
  | [$k, $alias, $name, ($v.used_percentage | if . == null then "" else round end | tostring), ($v.resets_at | tostring), $total]
  | map(if . == "" then "-" else . end) | join("\t")')

resets=${STATUSLINE_RESETS-${cf_RESETS-5h,7d,spend}}
if [ "$resets" = all ]; then
  want=()
  for row in "${rows[@]}"; do IFS=$'\t' read -r rk _ <<< "$row"; want+=("$rk"); done
else
  IFS=, read -r -a want <<< "$resets"
fi
build_limits() {   # $1 = show named extra windows, $2 = show "/ total"
  limits=()
  local tok row rk ralias rname rpct rres rtot namepart pctpart totpart lcolor
  for tok in "${want[@]}"; do
  [ "$tok" = none ] && continue
  for row in "${rows[@]}"; do
    IFS=$'\t' read -r rk ralias rname rpct rres rtot <<< "$row"
    [ "$tok" = "$rk" ] || [ "$tok" = "$ralias" ] || continue
    [ "$rname" != "-" ] && [ "$1" != 1 ] && continue
    namepart=""; [ "$rname" != "-" ] && namepart="${DIM}${rname}${RESET} "
    pctpart=""
    if [ "$rpct" != "-" ]; then
      lcolor=$GREEN
      [ "$rpct" -ge "$RESET_WARN" ] && lcolor=$YELLOW
      [ "$rpct" -ge "$RESET_CRIT" ] && lcolor=$RED
      pctpart="${lcolor}${rpct}%${RESET} "
    fi
    totpart=""; [ "$2" = 1 ] && [ "$rtot" != "-" ] && totpart=" ${DIM}/ ${rtot}${RESET}"
    limits+=("${namepart}${pctpart}$(fmt_dur $(( rres - now )))${totpart}")
  done
done
}

# Optional custom reset (time only, no percentage): export
# STATUSLINE_CUSTOM_RESET="label|YYYY-MM-DD HH:MM" (GNU date also accepts any date -d string)
custom=""
if [ -n "$STATUSLINE_CUSTOM_RESET" ]; then
  clabel=${STATUSLINE_CUSTOM_RESET%%|*}
  cts_in=${STATUSLINE_CUSTOM_RESET#*|}
  cts=$(date -d "$cts_in" +%s 2>/dev/null || date -j -f "%Y-%m-%d %H:%M" "$cts_in" +%s 2>/dev/null)
  [ -n "$cts" ] && custom="${DIM}${clabel}${RESET} $(fmt_dur $(( cts - now )))"
fi

# Terminal width: WIDTH setting, else /dev/tty (re-read on every run, so a resize shows
# up at the next refresh). Unknown (0) = never compact.
# detect_cols -> columns of the terminal Claude Code runs in. The script may have no controlling
# tty (then /dev/tty fails), so fall back to the tty of the nearest ancestor process that has one.
detect_cols() {
  local out pid=$$ t i
  out=$({ stty size </dev/tty; } 2>/dev/null) && { echo "${out#* }"; return; }
  for i in 1 2 3 4 5 6 7 8; do
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    { [ -z "$pid" ] || [ "$pid" = 1 ]; } && return
    t=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
    case $t in ''|'?'|'??'|'-') continue ;; esac
    out=$(stty size < "/dev/$t" 2>/dev/null) && { echo "${out#* }"; return; }
  done
}
cols=$WIDTH
[ "$cols" -eq 0 ] && cols=$(detect_cols)
case $cols in ''|*[!0-9]*) cols=0 ;; esac

sep="${DIM} | ${RESET}"
# render LEVEL -> sets $line. Higher level = more compact, each step drops one thing:
#   1 context size, named extra windows, custom reset | 2 cache hit rate | 3 "/ total" on windows
#   4 price multiplier, all windows but the first | 5 cache | 6 reset windows
render() {
  local lvl=$1 parts=() p m=$model b=$bar c=$cache ext=1 tot=1 only1=0
  [ "$lvl" -ge 1 ] && { b=$bar_s; ext=0; }
  [ "$lvl" -ge 2 ] && c=$cache_s
  [ "$lvl" -ge 3 ] && tot=0
  [ "$lvl" -ge 4 ] && { m=$model_plain; only1=1; }
  [ "$lvl" -ge 5 ] && c=""
  build_limits "$ext" "$tot"
  [ "$lvl" -ge 6 ] && limits=()
  [ "$only1" = 1 ] && limits=("${limits[@]:0:1}")
  [ "$lvl" -eq 0 ] && [ -n "$custom" ] && limits+=("$custom")
  sec model   && parts+=("${CYAN}${m}${RESET}")
  sec context && parts+=("$b")
  sec cache   && parts+=("$c")
  sec resets  && parts+=("${limits[@]}")
  line=""
  for p in "${parts[@]}"; do [ -z "$p" ] && continue; line="${line:+$line$sep}$p"; done
}
# visible width: strip color codes, count each block char as one column (locale-proof)
shopt -s extglob
visible() { local t=${1//$'\033'\[+([0-9;])m/}; t=${t//█/x}; t=${t//▓/x}; t=${t//▒/x}; t=${t//░/x}; echo "${#t}"; }

level=0
render 0
if [ "$cols" -gt 0 ]; then
  while [ "$(visible "$line")" -gt $(( cols - MARGIN )) ] && [ "$level" -lt 6 ]; do
    level=$(( level + 1 )); render "$level"
  done
fi
[ -n "$DUMP" ] && printf 'cols=%s margin=%s level=%s visible=%s\n' "$cols" "$MARGIN" "$level" "$(visible "$line")" >> "$DUMP"
printf '%s\n' "$line"
