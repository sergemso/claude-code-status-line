#!/bin/bash
# Refresh ~/.claude/model-prices.json from the pricing page if older than TTL.
# Safe to run concurrently: an mkdir lock admits one refresher, staleness is
# re-checked under the lock, and the file is replaced atomically (temp + mv).
# Needs: bash, curl, awk, jq.
D=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
OUT=$D/model-prices.json
TTL=${STATUSLINE_PRICES_TTL:-3600}   # seconds data is considered fresh
case $TTL in ''|*[!0-9]*) TTL=3600 ;; esac
RETRY=300         # after a failed attempt, wait 5min
LOCK=$D/.model-prices.lock.d
URL=https://platform.claude.com/docs/en/about-claude/pricing.md

mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }
age() { [ -e "$1" ] && echo $(( $(date +%s) - $(mtime "$1") )) || echo 999999999; }

[ "$(age "$LOCK")" -gt 120 ] && rmdir "$LOCK" 2>/dev/null   # stale lock
mkdir "$LOCK" 2>/dev/null || exit 0
tmp=
trap 'rmdir "$LOCK"; [ -n "$tmp" ] && rm -f "$tmp"' EXIT
[ "$(age "$OUT")" -lt "$TTL" ] && exit 0
[ "$(age "$D/.model-prices.fail")" -lt "$RETRY" ] && exit 0

tmp=$(mktemp "$D/.model-prices.XXXXXX") || exit 1
# Page tables -> TSV rows: "M<TAB>name<TAB>in<TAB>out" (main table, "Base input
# tokens") and "F<TAB>name<TAB>fast_in" (table after the "significantly faster" line).
if curl -fsSL -m 20 "$URL" | awk '
  function price(s) { return match(s, /\$[0-9.]+/) ? substr(s, RSTART + 1, RLENGTH - 1) : "" }
  function trim(s) { gsub(/^ +| +$/, "", s); return s }
  /Base input tokens/ && !m1 { m1 = mode = 1; row = 0 }
  /provides significantly faster/ && !m2 { m2 = mode = 2; row = 0 }
  mode && /^\|/ {
    row++
    if (row <= 2) next          # header + separator
    n = split($0, c, "|")
    if (mode == 1) {
      name = c[2]; sub(/ \(.*/, "", name)
      i = price(c[3]); o = price(c[n - 1])
      if (i != "" && o != "") print "M\t" trim(name) "\t" i "\t" o
    } else if ((f = price(c[3])) != "") {
      k = split(c[2], names, " / ")
      for (j = 1; j <= k; j++) print "F\t" trim(names[j]) "\t" f
    }
    next
  }
  mode && row { mode = 0 }      # table ended
' | jq -R -s '
  split("\n") | map(select(length > 0) | split("\t")) as $r
  | reduce ($r[] | select(.[0] == "M")) as $x ({};
      if has($x[1]) then . else .[$x[1]] = {in: ($x[2] | tonumber), out: ($x[3] | tonumber)} end)
  | reduce ($r[] | select(.[0] == "F")) as $f (.;
      if has($f[1]) then .[$f[1]].fast_in = ($f[2] | tonumber) else . end)
  | {models: .}' > "$tmp" && jq -e '.models | length > 2' "$tmp" >/dev/null 2>&1; then
  chmod 644 "$tmp" && mv -f "$tmp" "$OUT" && tmp= && rm -f "$D/.model-prices.fail"
else
  touch "$D/.model-prices.fail"
fi
