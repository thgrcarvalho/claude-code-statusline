#!/bin/bash
set -e

INSTALL_DIR="$HOME/.claude"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS="$INSTALL_DIR/settings.json"
CMD_PATH="$INSTALL_DIR/statusline.sh"
MAX_BACKUPS=3   # keep only the most recent N backup generations; older ones are pruned on install

# Pre-flight checks
check_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Error: '$1' is required but not installed."; echo "  $2"; exit 1; }
}
check_cmd curl "macOS: pre-installed  |  Linux: apt install curl"
# jq is optional: enables auto-pricing updates from LiteLLM; statusline works without it

# Verify the source files we're about to install exist BEFORE touching anything. statusline.sh
# can go missing from the working tree (e.g. deleted by hand), and a plain `git pull` won't
# restore a file the incoming commits didn't modify — leaving a cryptic mid-run `cp: No such
# file`. Fail early with the exact recovery command instead, before any backup or settings edit.
for f in statusline.sh refresh-pricing.sh; do
  if [ ! -f "$SCRIPT_DIR/$f" ]; then
    echo "Error: $f is missing from $SCRIPT_DIR"
    echo "  It's tracked in git but absent from your working copy. Restore it and re-run:"
    echo "    git checkout -- $f && ./install.sh"
    exit 1
  fi
done

# Warn on bash < 4 (scripts work on 3.2 but bash 4+ is recommended)
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
  echo "Warning: bash ${BASH_VERSION} detected. Scripts work on bash 3.2+ but bash 4+ is recommended."
  echo "  macOS: brew install bash"
fi

mkdir -p "$INSTALL_DIR"

# Backup existing files
TS=$(date +%s)
for f in statusline.sh refresh-pricing.sh; do
  if [ -f "$INSTALL_DIR/$f" ]; then
    cp "$INSTALL_DIR/$f" "$INSTALL_DIR/$f.bak.$TS"
    echo "Backed up $INSTALL_DIR/$f  →  $f.bak.$TS"
  fi
done
# NOTE: we deliberately do NOT back up the whole settings.json. The previous statusLine
# *value* (only that key) is captured just before patching, below. uninstall restores only
# that key — restoring a stale full settings.json can silently wipe unrelated keys added
# since install and break the CLI.

# Prune old backups: keep only the most recent $MAX_BACKUPS backup generations.
# Each install writes <file>.bak.<TS> for several files sharing one timestamp, so we
# dedupe to distinct timestamps, keep the newest $MAX_BACKUPS, and delete every file
# belonging to the older ones. Portable: avoids GNU-only `head -n -N` (BSD/macOS lacks it).
_old_ts=$(find "$INSTALL_DIR" -maxdepth 1 -name "*.bak.[0-9]*" 2>/dev/null \
  | sed -E 's/.*\.bak\.([0-9]+)$/\1/' | sort -run | tail -n +$((MAX_BACKUPS + 1)))
for ts in $_old_ts; do
  rm -f "$INSTALL_DIR"/*.bak."$ts"
  echo "Pruned old backup set: *.bak.$ts"
done

# Install scripts
cp "$SCRIPT_DIR/statusline.sh"      "$INSTALL_DIR/"
cp "$SCRIPT_DIR/refresh-pricing.sh" "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/statusline.sh" "$INSTALL_DIR/refresh-pricing.sh"
echo "Installed scripts to $INSTALL_DIR/"

# Capture the PRIOR statusLine value (only that key) so uninstall can restore exactly it —
# never the whole settings.json. Writes the JSON value compactly, or `null` if statusLine was
# absent (uninstall reads `null` as "delete the key we added"). Keyed by the install timestamp
# so it shares a backup generation with the script-file backups above.
_backup_statusline_value() {
  local out="$SETTINGS.statusLine.bak.$TS"
  if command -v jq >/dev/null 2>&1; then
    jq -c '.statusLine // null' "$SETTINGS" > "$out" 2>/dev/null \
      && echo "Saved previous statusLine value  →  $(basename "$out")"
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$SETTINGS" "$out" <<'PY' \
      && echo "Saved previous statusLine value  →  $(basename "$out")"
import json, sys
src, out = sys.argv[1], sys.argv[2]
try:
    with open(src) as f: d = json.load(f)
except Exception:
    d = {}
with open(out, 'w') as f: json.dump(d.get('statusLine', None), f)
PY
  fi
}

# Patch ~/.claude/settings.json (use jq or python3 if available; else print manual instructions)
_patch_settings() {
  local cmd_esc="${CMD_PATH//\//\\/}"
  local block='"statusLine":{"type":"command","command":"'"$CMD_PATH"'","refreshInterval":1}'

  if command -v jq >/dev/null 2>&1; then
    jq --arg cmd "$CMD_PATH" '.statusLine = {type: "command", command: $cmd, refreshInterval: 1}' \
      "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$SETTINGS" "$CMD_PATH" <<'PY'
import json, sys
path, cmd = sys.argv[1], sys.argv[2]
with open(path) as f: d = json.load(f)
d['statusLine'] = {'type': 'command', 'command': cmd, 'refreshInterval': 1}
with open(path, 'w') as f: json.dump(d, f, indent=2)
PY
  else
    echo ""
    echo "  Note: neither jq nor python3 found — please add this to $SETTINGS manually:"
    echo "    $block"
    return
  fi
  echo "Updated $SETTINGS"
}

if [ -f "$SETTINGS" ]; then
  _backup_statusline_value
  _patch_settings
else
  printf '{"statusLine":{"type":"command","command":"%s","refreshInterval":1}}\n' "$CMD_PATH" > "$SETTINGS"
  echo "Created $SETTINGS"
fi

# Warm pricing cache
echo "Fetching initial pricing data..."
"$INSTALL_DIR/refresh-pricing.sh" && echo "Pricing cache ready." || echo "Warning: pricing fetch failed (will retry on next Claude session)."

echo ""
echo "Done. Restart Claude Code to see the statusline."
echo "To revert to your previous setup, run: $(cd "$(dirname "$0")" && pwd)/uninstall.sh"
