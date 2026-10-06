#!/bin/bash
# Refresh Anthropic model pricing from LiteLLM's community database.
# Requires jq to parse the LiteLLM JSON — exits silently if jq is not installed.
# Output: /tmp/claude_pricing.txt  (space-delimited, USD per Mtok:
#   "model-id base_input output cache_read cache_write_5m cache_write_1h" per line).
#   Cache columns are written only when LiteLLM lists all three: per-model since the
#   x.5/x.1 models (Opus 5.5 reads 0.05x, Fable/Mythos 5.1 reads 0.025x of base input).
#   statusline.sh falls back to the classic 0.10/1.25/2.00 multipliers on 3-column lines.
command -v jq >/dev/null 2>&1 || exit 0   # optional enhancement — skip silently if no jq

CACHE="/tmp/claude_pricing.txt"
URL="https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
MAX_AGE=86400   # 24h

# A cache written before the cache-rate columns existed (no line with 6 fields) is stale
# regardless of age: it would keep pricing Opus 5.5 / Fable 5.1 reads at 0.10x for a day.
# Any 6-field line counts, so a model LiteLLM lists without cache rates can't force a
# refetch every turn. An empty file (no lines) keeps the age check.
_old_format() { awk 'NF >= 6 { f = 1 } NF > 0 { n = 1 } END { exit !(n && !f) }' "$1" 2>/dev/null; }
if [ -f "$CACHE" ] && ! _old_format "$CACHE"; then
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
            output: ((.value.output_cost_per_token // 0) * 1000000),
            cr:  .value.cache_read_input_token_cost,
            cw5: .value.cache_creation_input_token_cost,
            cw1: .value.cache_creation_input_token_cost_above_1hr
          }
        })
      | unique_by(.key)
      | .[]
      | def mtok: (. * 1e12 | round) / 1e6;
        "\(.key) \(.value.input) \(.value.output)"
        + (if .value.cr != null and .value.cw5 != null and .value.cw1 != null
           then " \(.value.cr | mtok) \(.value.cw5 | mtok) \(.value.cw1 | mtok)" else "" end)
    ' > "${CACHE}.tmp" 2>/dev/null \
  && [ -s "${CACHE}.tmp" ] \
  && mv "${CACHE}.tmp" "$CACHE" \
  || rm -f "${CACHE}.tmp"
