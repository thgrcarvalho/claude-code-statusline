#!/bin/bash
# Revert to the statusline configuration you had before install.sh was run.
# Backups are stored as ~/.claude/<file>.bak.<unix-timestamp>.

INSTALL_DIR="$HOME/.claude"
INSTALLED_FILES=(statusline.sh refresh-pricing.sh)

# ── Find available backup timestamps ────────────────────────────────────────
TIMESTAMPS=$(find "$INSTALL_DIR" -maxdepth 1 -name "*.bak.[0-9]*" 2>/dev/null \
  | sed -E 's/.*\.bak\.([0-9]+)$/\1/' | sort -un)

if [ -z "$TIMESTAMPS" ]; then
  echo "No backups found in $INSTALL_DIR."
  echo "If you want to remove this statusline, delete the files manually:"
  for f in "${INSTALLED_FILES[@]}"; do echo "  rm -f $INSTALL_DIR/$f"; done
  echo "  and remove the 'statusLine' key from $INSTALL_DIR/settings.json"
  exit 1
fi

# ── If more than one backup, show list and let user pick ────────────────────
TS_ARRAY=($TIMESTAMPS)
if [ "${#TS_ARRAY[@]}" -gt 1 ]; then
  # Negative subscripts (${arr[-1]}) need bash 4.3+; macOS ships bash 3.2, so
  # index the last element explicitly for portability.
  LAST_IDX=$((${#TS_ARRAY[@]} - 1))
  echo "Multiple installs found. Choose which backup to restore:"
  echo ""
  for ts in "${TS_ARRAY[@]}"; do
    # date -d (Linux) or date -r (macOS)
    human=$(date -d "@$ts" 2>/dev/null || date -r "$ts" 2>/dev/null || echo "timestamp $ts")
    echo "  [$ts]  $human"
  done
  echo ""
  printf "Enter timestamp (or press Enter for most recent [%s]): " "${TS_ARRAY[$LAST_IDX]}"
  read -r choice
  TARGET_TS="${choice:-${TS_ARRAY[$LAST_IDX]}}"
else
  TARGET_TS="${TS_ARRAY[0]}"
fi

# Validate chosen timestamp
if ! echo "$TIMESTAMPS" | grep -qx "$TARGET_TS"; then
  echo "Error: timestamp '$TARGET_TS' not found in backups."
  exit 1
fi

human=$(date -d "@$TARGET_TS" 2>/dev/null || date -r "$TARGET_TS" 2>/dev/null || echo "timestamp $TARGET_TS")
echo ""
echo "Reverting to backup from: $human"
echo ""

# ── Restore each installed script ──────────────────────────────────────────
for f in "${INSTALLED_FILES[@]}"; do
  BAK="$INSTALL_DIR/$f.bak.$TARGET_TS"
  if [ -f "$BAK" ]; then
    cp "$BAK" "$INSTALL_DIR/$f"
    echo "  Restored  $INSTALL_DIR/$f"
  else
    rm -f "$INSTALL_DIR/$f"
    echo "  Removed   $INSTALL_DIR/$f  (did not exist before install)"
  fi
done

# ── Restore ONLY the statusLine key in settings.json ───────────────────────
# NEVER restore a whole settings.json backup: a stale full file silently wipes unrelated keys
# added since install and can break the CLI. We only ever touch the statusLine key — restoring
# the exact previous value (captured at install) or, if there was none / no record, removing
# just the key we added. Any legacy settings.json.bak.<ts> full-file backup is left untouched.
SETTINGS="$INSTALL_DIR/settings.json"
SL_BAK="$SETTINGS.statusLine.bak.$TARGET_TS"

_remove_statusline() {
  if command -v jq >/dev/null 2>&1; then
    jq 'del(.statusLine)' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$SETTINGS" <<'PY'
import json, sys
with open(sys.argv[1]) as f: d = json.load(f)
d.pop('statusLine', None)
with open(sys.argv[1], 'w') as f: json.dump(d, f, indent=2)
PY
  else
    echo "  Note: neither jq nor python3 found — remove the 'statusLine' key from $SETTINGS manually."
    return 1
  fi
}

_restore_statusline() {
  if command -v jq >/dev/null 2>&1; then
    jq --argjson sl "$(cat "$SL_BAK")" '.statusLine = $sl' "$SETTINGS" > "$SETTINGS.tmp" \
      && mv "$SETTINGS.tmp" "$SETTINGS"
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$SETTINGS" "$SL_BAK" <<'PY'
import json, sys
settings, valfile = sys.argv[1], sys.argv[2]
with open(settings) as f: d = json.load(f)
with open(valfile) as f: d['statusLine'] = json.load(f)
with open(settings, 'w') as f: json.dump(d, f, indent=2)
PY
  else
    echo "  Note: neither jq nor python3 found — restore the 'statusLine' key in $SETTINGS manually."
    return 1
  fi
}

if [ -f "$SETTINGS" ]; then
  if [ -f "$SL_BAK" ]; then
    _prev=$(cat "$SL_BAK" 2>/dev/null)
    if [ -z "$_prev" ] || [ "$_prev" = "null" ]; then
      _remove_statusline && echo "  Removed statusLine key from $SETTINGS (none before install)"
    else
      _restore_statusline && echo "  Restored previous statusLine value in $SETTINGS"
    fi
  else
    # No saved value for this generation (older install format, or first-ever install) —
    # safest action is to remove just the statusLine key. All other keys are left intact.
    _remove_statusline && echo "  Removed statusLine key from $SETTINGS"
  fi
fi

echo ""
echo "Done. Restart Claude Code to apply."
