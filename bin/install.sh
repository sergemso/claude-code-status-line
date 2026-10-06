#!/bin/bash
# Copy the status line scripts to a stable path (the plugin cache path changes
# per version) and, with --configure, point settings.json's statusLine at it.
# Runs on every SessionStart, so a plugin update reaches the copy by itself.
# Usage: install.sh [--configure [--force]]
set -e
SRC=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CFG=${CLAUDE_CONFIG_DIR:-$HOME/.claude}
DEST=$CFG/statusline
mkdir -p "$DEST"
for f in statusline.sh refresh-model-prices.sh; do
  cmp -s "$SRC/$f" "$DEST/$f" || { cp "$SRC/$f" "$DEST/$f.tmp" && chmod +x "$DEST/$f.tmp" && mv -f "$DEST/$f.tmp" "$DEST/$f"; }
done

[ "$1" = "--configure" ] || exit 0
command -v jq >/dev/null || { echo "jq is required" >&2; exit 1; }
S=$CFG/settings.json
[ -f "$S" ] || echo '{}' > "$S"
CMD="bash $DEST/statusline.sh"
cur=$(jq -r '.statusLine.command // empty' "$S")
if [ -n "$cur" ] && [ "$cur" != "$CMD" ] && [ "$2" != "--force" ]; then
  echo "statusLine already set to: $cur (re-run with --force to replace)"
  exit 0
fi
tmp=$(mktemp "$S.XXXXXX")
jq --arg c "$CMD" '.statusLine = {type: "command", command: $c, refreshInterval: 15}' "$S" > "$tmp" && mv -f "$tmp" "$S"
echo "statusLine set to: $CMD"
