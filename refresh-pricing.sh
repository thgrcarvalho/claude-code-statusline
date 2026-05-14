#!/bin/bash
# Refresh Anthropic model pricing from LiteLLM's community database.
# Writes /tmp/claude_pricing.json; no-op if cache < 24h old.
CACHE="/tmp/claude_pricing.json"
URL="https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
MAX_AGE=86400   # 24h

if [ -f "$CACHE" ]; then
  age=$(( $(date +%s) - $(stat -c %Y "$CACHE" 2>/dev/null || stat -f %m "$CACHE" 2>/dev/null || echo 0) ))
  [ "$age" -lt "$MAX_AGE" ] && exit 0
fi

curl -fsSL --max-time 5 "$URL" 2>/dev/null \
  | jq '
      to_entries
      | map(select(.key | test("^(anthropic/)?claude-")))
      | map({
          key: (.key | sub("^anthropic/"; "") | sub("-[0-9]{8}$"; "")),
          value: {
            input:  ((.value.input_cost_per_token  // 0) * 1000000),
            output: ((.value.output_cost_per_token // 0) * 1000000)
          }
        })
      | unique_by(.key)
      | from_entries
    ' > "${CACHE}.tmp" 2>/dev/null \
  && [ -s "${CACHE}.tmp" ] \
  && mv "${CACHE}.tmp" "$CACHE" \
  || rm -f "${CACHE}.tmp"
