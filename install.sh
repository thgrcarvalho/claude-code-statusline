#!/bin/bash
set -e

INSTALL_DIR="$HOME/.claude"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS="$INSTALL_DIR/settings.json"
CMD_PATH="$INSTALL_DIR/statusline.sh"

# Pre-flight checks
check_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "Error: '$1' is required but not installed."; echo "  $2"; exit 1; }
}
check_cmd curl "macOS: pre-installed  |  Linux: apt install curl"
# jq is optional: enables auto-pricing updates from LiteLLM; statusline works without it

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
if [ -f "$SETTINGS" ]; then
  cp "$SETTINGS" "$SETTINGS.bak.$TS"
  echo "Backed up $SETTINGS  →  settings.json.bak.$TS"
fi

# Install scripts
cp "$SCRIPT_DIR/statusline.sh"      "$INSTALL_DIR/"
cp "$SCRIPT_DIR/refresh-pricing.sh" "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/statusline.sh" "$INSTALL_DIR/refresh-pricing.sh"
echo "Installed scripts to $INSTALL_DIR/"

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
