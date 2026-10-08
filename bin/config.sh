#!/bin/bash
# Read and change the status line's settings (file: $CLAUDE_CONFIG_DIR/statusline/config).
# Costs no tokens when run directly:  ! bash ~/.claude/statusline/config.sh show
# Needs: bash, jq (model validation only).
CFG=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
CONF=$CFG/statusline/config
PRICES=$CFG/model-prices.json
ALL_SECTIONS=(model context cache stats resets limits)   # display order

usage() {
  cat <<'EOF'
Usage: config.sh <command>
  show                          current settings (value, and where it comes from)
  model [NAME|list]             base model for the price multiplier (x1.0); no NAME = show
  sections [list]               enabled/hidden sections and the valid names
  sections show|hide NAME...    enable/disable sections
  sections only NAME...         enable just these
  sections all                  enable all
      NAME: model context cache stats resets limits   (stats = cache hit rate, shown inside cache; limits = plan-specific rate limit windows)
  resets LIST|all|none          which reset windows to show, e.g. 5h,7d,spend
  thresholds context|resets WARN CRIT   yellow/red at WARN/CRIT percent used (0-100)
  thresholds cache WARN CRIT            yellow/red when WARN/CRIT minutes are left
  width [N|auto]                terminal columns to fit the line into (auto = detect from the tty;
                                if unknown the line is never compacted)
  margin N                      columns kept free at the right edge (default 2)
  dump [PATH|off]               write the raw status-line JSON + detected width/level to PATH on each run
  reset [KEY...]                drop saved settings (all if none given)
      KEY: BASE_MODEL SECTIONS RESETS CONTEXT_WARN CONTEXT_CRIT CACHE_WARN CACHE_CRIT RESET_WARN RESET_CRIT WIDTH MARGIN DUMP
EOF
}

die() { echo "error: $*" >&2; exit 1; }

# get KEY -> saved value (empty if unset)
get() { [ -r "$CONF" ] && awk -F= -v k="$1" '$1 == k { sub(/^[^=]*=/, ""); v = $0 } END { print v }' "$CONF"; }
# has KEY -> is the key saved?
has() { [ -r "$CONF" ] && grep -q "^$1=" "$CONF"; }

# put KEY VALUE ... (pairs) -> atomic rewrite of the file
put() {
  mkdir -p "$(dirname "$CONF")" || die "cannot create $(dirname "$CONF")"
  local tmp; tmp=$(mktemp "$CONF.XXXXXX") || die "cannot write $CONF"
  [ -r "$CONF" ] && cp "$CONF" "$tmp"
  while [ $# -ge 2 ]; do
    grep -v "^$1=" "$tmp" > "$tmp.n"; mv -f "$tmp.n" "$tmp"
    printf '%s=%s\n' "$1" "$2" >> "$tmp"
    shift 2
  done
  chmod 644 "$tmp"; mv -f "$tmp" "$CONF"
}

# drop KEY...
drop() {
  [ -r "$CONF" ] || return 0
  local tmp; tmp=$(mktemp "$CONF.XXXXXX") || die "cannot write $CONF"
  cp "$CONF" "$tmp"
  for k in "$@"; do grep -v "^$k=" "$tmp" > "$tmp.n"; mv -f "$tmp.n" "$tmp"; done
  if [ -s "$tmp" ]; then mv -f "$tmp" "$CONF"; else rm -f "$tmp" "$CONF"; fi
}

valid_section() { local s; for s in "${ALL_SECTIONS[@]}"; do [ "$s" = "$1" ] && return 0; done; return 1; }
is_int() { case $1 in ''|*[!0-9]*) return 1 ;; esac; }

current_sections() { local v; v=$(get SECTIONS); echo "${v:-$(IFS=,; echo "${ALL_SECTIONS[*]}")}"; }

# canonical-order SECTIONS value from a space-separated set of names; prints what changed
save_sections() {
  local out="" s n before after hidden=""
  before=$(current_sections)
  for s in "${ALL_SECTIONS[@]}"; do
    for n in "$@"; do [ "$n" = "$s" ] && { out="${out:+$out,}$s"; break; }; done
  done
  [ -n "$out" ] || die "at least one section must stay enabled"
  put SECTIONS "$out"
  for s in "${ALL_SECTIONS[@]}"; do case ",$out," in *",$s,"*) ;; *) hidden="$hidden $s" ;; esac; done
  if [ "$before" = "$out" ]; then echo "no change (already: $out)"; else echo "sections updated"; fi
  echo "enabled: ${out//,/ }"
  echo "hidden: ${hidden:- (none)}"
}

cmd_show() {
  local k def v src
  printf '%-14s %-38s %s\n' setting value source
  for pair in "BASE_MODEL:Claude Sonnet 5.5" "SECTIONS:model,context,cache,stats,resets,limits" "RESETS:5h,7d,spend" \
              "CONTEXT_WARN:50" "CONTEXT_CRIT:80" "CACHE_WARN:20" "CACHE_CRIT:5" "RESET_WARN:50" "RESET_CRIT:80" "WIDTH:0(auto)" "MARGIN:2"; do
    k=${pair%%:*}; def=${pair#*:}
    local e="STATUSLINE_$k"
    if [ -n "${!e}" ]; then v=${!e}; src="env $e"
    elif has "$k"; then v=$(get "$k"); src=saved
    else v=$def; src=default; fi
    printf '%-14s %-38s %s\n' "$k" "$v" "$src"
  done
  echo "file: $CONF"
}

cmd_model() {
  case $1 in
    list)
      [ -r "$PRICES" ] || die "no price table yet ($PRICES); open a session and wait a moment, then retry"
      jq -r '.models | to_entries[] | "\(.key)  (in $\(.value.in)/MTok)"' "$PRICES" ;;
    '')
      local v; v=$(get BASE_MODEL); echo "base model: ${v:-Claude Sonnet 5.5 (default)}" ;;
    *)
      local want="$*" name
      [ -r "$PRICES" ] || die "no price table yet ($PRICES); cannot validate '$want'"
      # exact (case-insensitive), with or without the "Claude " prefix
      name=$(jq -r --arg w "$want" '.models | keys[] | select((. | ascii_downcase) == ($w | ascii_downcase) or (. | ascii_downcase) == ("claude " + ($w | ascii_downcase)))' "$PRICES" | head -1)
      [ -n "$name" ] || { echo "error: unknown model '$want'. Known:" >&2; jq -r '.models | keys[]' "$PRICES" >&2; exit 1; }
      put BASE_MODEL "$name"; echo "base model: $name" ;;
  esac
}

# sections_status -> enabled/hidden lists plus the valid names and usage
sections_status() {
  local cur=() s hidden=""
  IFS=, read -r -a cur <<< "$(current_sections)"
  for s in "${ALL_SECTIONS[@]}"; do case " ${cur[*]} " in *" $s "*) ;; *) hidden="$hidden $s" ;; esac; done
  echo "enabled: ${cur[*]}"
  echo "hidden: ${hidden:- (none)}"
  echo "names:   ${ALL_SECTIONS[*]}   (stats = cache hit rate, shown inside cache; limits = plan-specific rate limit windows)"
  echo "change:  sections show|hide|only NAME...   or   sections all"
}

cmd_sections() {
  local sub=$1; [ $# -gt 0 ] && shift
  local cur=() names=() s n
  IFS=, read -r -a cur <<< "$(current_sections)"
  for n in "$@"; do valid_section "$n" || die "unknown section '$n' (one of: ${ALL_SECTIONS[*]})"; done
  case $sub in
    ''|list|status) sections_status ;;
    show|hide|only)
      # no names given: just show the state and how to change it
      [ $# -gt 0 ] || { sections_status; return; }
      case $sub in
        show) save_sections "${cur[@]}" "$@" ;;
        only) save_sections "$@" ;;
        hide) for s in "${cur[@]}"; do case " $* " in *" $s "*) ;; *) names+=("$s") ;; esac; done
              save_sections "${names[@]}" ;;
      esac ;;
    all)  drop SECTIONS; echo "sections: all enabled" ;;
    *)    die "sections: expected show|hide|only NAME..., all or list, got '$sub'" ;;
  esac
}

cmd_resets() {
  if [ $# -eq 0 ]; then local v; v=$(get RESETS); echo "resets: ${v:-5h,7d,spend (default)}"; return; fi
  [ $# -eq 1 ] || die "resets: one comma-separated list, e.g. 5h,7d,spend"
  case $1 in
    *[!A-Za-z0-9_,-]*) die "resets: use a comma list of window names, e.g. 5h,7d,spend" ;;
  esac
  put RESETS "$1"; echo "resets: $1"
  echo "only the windows named here are shown (default: 5h,7d,spend; spend exists only on gateway accounts). Undo: reset RESETS"
}

cmd_thresholds() {
  local what=$1 warn=$2 crit=$3 pre
  case $what in
    context) pre=CONTEXT ;; resets) pre=RESET ;; cache) pre=CACHE ;;
    *) die "thresholds: expected context|resets|cache WARN CRIT" ;;
  esac
  is_int "$warn" && is_int "$crit" || die "thresholds: WARN and CRIT must be whole numbers"
  if [ "$what" = cache ]; then
    [ "$crit" -lt "$warn" ] || die "cache: CRIT minutes must be lower than WARN (red comes later, as time runs out)"
  else
    [ "$warn" -lt "$crit" ] && [ "$crit" -le 100 ] || die "$what: need WARN < CRIT <= 100"
  fi
  put "${pre}_WARN" "$warn" "${pre}_CRIT" "$crit"
  echo "$what: yellow at $warn, red at $crit$([ "$what" = cache ] && echo ' minutes left' || echo '%')"
}

cmd_width() {
  if [ $# -eq 0 ]; then local v; v=$(get WIDTH); echo "width: ${v:-auto}"; return; fi
  if [ "$1" = auto ]; then drop WIDTH; echo "width: auto"; return; fi
  is_int "$1" && [ "$1" -gt 0 ] || die "width: a positive number of columns, or auto"
  put WIDTH "$1"; echo "width: $1"
}

cmd_margin() {
  if [ $# -eq 0 ]; then local v; v=$(get MARGIN); echo "margin: ${v:-2 (default)}"; return; fi
  is_int "$1" || die "margin: a number of columns"
  put MARGIN "$1"; echo "margin: $1"
}

cmd_dump() {
  if [ $# -eq 0 ]; then local v; v=$(get DUMP); echo "dump: ${v:-off}"; return; fi
  if [ "$1" = off ]; then drop DUMP; echo "dump: off"; return; fi
  put DUMP "$1"; echo "dump: $1"
}

cmd_reset() {
  if [ $# -eq 0 ]; then rm -f "$CONF"; echo "all saved settings removed"; else drop "$@"; echo "removed: $*"; fi
}

cmd=$1; [ $# -gt 0 ] && shift
case $cmd in
  show)       cmd_show ;;
  model)      cmd_model "$@" ;;
  sections)   cmd_sections "$@" ;;
  resets)     cmd_resets "$@" ;;
  thresholds) cmd_thresholds "$@" ;;
  width)      cmd_width "$@" ;;
  margin)     cmd_margin "$@" ;;
  dump)       cmd_dump "$@" ;;
  reset)      cmd_reset "$@" ;;
  ''|-h|--help|help) usage ;;
  *) usage >&2; exit 1 ;;
esac
