#!/bin/bash
# Refresh Anthropic model pricing from LiteLLM's community database.
# Requires jq to parse the LiteLLM JSON — exits silently if jq is not installed.
# Output: /tmp/claude_pricing.txt  (space-delimited: "model-id base_input output" per line)
command -v jq >/dev/null 2>&1 || exit 0   # optional enhancement — skip silently if no jq

CACHE="/tmp/claude_pricing.txt"
URL="https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
MAX_AGE=86400   # 24h

if [ -f "$CACHE" ]; then
  age=$(( $(date +%s) - $(stat -c %Y "$CACHE" 2>/dev/null || stat -f %m "$CACHE" 2>/dev/null || echo 0) ))
  [ "$age" -lt "$MAX_AGE" ] && exit 0
fi

curl -fsSL --max-time 5 "$URL" 2>/dev/null \
  | jq -r '
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
      | .[]
      | "\(.key) \(.value.input) \(.value.output)"
    ' > "${CACHE}.tmp" 2>/dev/null \
  && [ -s "${CACHE}.tmp" ] \
  && mv "${CACHE}.tmp" "$CACHE" \
  || rm -f "${CACHE}.tmp"
