#!/bin/bash
# Refresh ~/.claude/model-prices.json from the pricing page if older than TTL.
# Safe to run concurrently: flock admits one refresher, staleness is re-checked
# under the lock, and the file is replaced atomically (temp + mv).
D=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
OUT=$D/model-prices.json
TTL=3600          # data considered fresh for 1h
RETRY=300         # after a failed attempt, wait 5min
URL=https://platform.claude.com/docs/en/about-claude/pricing.md

age() { [ -e "$1" ] && echo $(( $(date +%s) - $(stat -c %Y "$1") )) || echo 999999999; }

exec 9>"$D/.model-prices.lock"
flock -n 9 || exit 0
[ "$(age "$OUT")" -lt "$TTL" ] && exit 0
[ "$(age "$D/.model-prices.fail")" -lt "$RETRY" ] && exit 0

tmp=$(mktemp "$D/.model-prices.XXXXXX") || exit 1
trap 'rm -f "$tmp"' EXIT
if curl -fsSL -m 20 "$URL" | python3 -c '
import sys, re, json
lines = sys.stdin.read().splitlines()
def block(start):
    rows = []
    for l in lines[start:]:
        if l.startswith("|"): rows.append([c.strip() for c in l.strip("|").split("|")])
        elif rows: break
    return rows
price = lambda c: float(m.group(1)) if (m := re.search(r"\$([0-9.]+)", c)) else None
models, fast = {}, {}
i = next(i for i, l in enumerate(lines) if "Base input tokens" in l)
for r in block(i)[2:]:
    n, a, b = re.split(r" \(", r[0])[0].strip(), price(r[1]), price(r[-1])
    if a and b: models.setdefault(n, {"in": a, "out": b})
j = next((i for i, l in enumerate(lines) if "provides significantly faster" in l), None)
if j is not None:
    for r in block(j)[2:]:
        if price(r[1]):
            for n in r[0].split(" / "): fast[n.strip()] = price(r[1])
for n, f in fast.items():
    if n in models: models[n]["fast_in"] = f
if len(models) < 3: sys.exit(1)
json.dump({"models": models}, sys.stdout)
' > "$tmp" && jq -e '.models | length > 2' "$tmp" >/dev/null 2>&1; then
  chmod 644 "$tmp" && mv -f "$tmp" "$OUT" && rm -f "$D/.model-prices.fail"
else
  touch "$D/.model-prices.fail"
fi
