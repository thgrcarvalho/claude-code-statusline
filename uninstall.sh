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
  echo "Multiple installs found. Choose which backup to restore:"
  echo ""
  for ts in "${TS_ARRAY[@]}"; do
    # date -d (Linux) or date -r (macOS)
    human=$(date -d "@$ts" 2>/dev/null || date -r "$ts" 2>/dev/null || echo "timestamp $ts")
    echo "  [$ts]  $human"
  done
  echo ""
  printf "Enter timestamp (or press Enter for most recent [%s]): " "${TS_ARRAY[-1]}"
  read -r choice
  TARGET_TS="${choice:-${TS_ARRAY[-1]}}"
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

# ── Restore settings.json ──────────────────────────────────────────────────
SETTINGS="$INSTALL_DIR/settings.json"
BAK_SETTINGS="$SETTINGS.bak.$TARGET_TS"

if [ -f "$BAK_SETTINGS" ]; then
  cp "$BAK_SETTINGS" "$SETTINGS"
  echo "  Restored  $SETTINGS"
else
  # settings.json didn't exist before — just remove our statusLine key
  if [ -f "$SETTINGS" ] && command -v jq >/dev/null 2>&1; then
    jq 'del(.statusLine)' "$SETTINGS" > "$SETTINGS.tmp" \
      && mv "$SETTINGS.tmp" "$SETTINGS"
    echo "  Removed statusLine key from $SETTINGS"
  fi
fi

echo ""
echo "Done. Restart Claude Code to apply."
