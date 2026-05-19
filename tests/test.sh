#!/bin/bash
# Test suite for statusline.sh
# Usage: ./tests/test.sh
# Exit code: 0 = all pass, 1 = any failure

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
FIXTURES="$SCRIPT_DIR/fixtures"
SCRIPT="$ROOT/statusline.sh"

PASS=0
FAIL=0

_pass() { echo "  ✓ $1"; PASS=$((PASS+1)); }
_fail() {
  echo "  ✗ $1"
  [ -n "${2:-}" ] && echo "    expected: $2"
  [ -n "${3:-}" ] && echo "    got:      $3"
  FAIL=$((FAIL+1))
}

assert_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -qF "$needle"; then
    _pass "$desc"
  else
    _fail "$desc" "contains '$needle'" "$(printf '%s' "$haystack" | head -3)"
  fi
}

assert_not_contains() {
  local desc="$1" needle="$2" haystack="$3"
  if printf '%s' "$haystack" | grep -qF "$needle"; then
    _fail "$desc" "NOT '$needle'" "$(printf '%s' "$haystack" | head -3)"
  else
    _pass "$desc"
  fi
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$actual" = "$expected" ]; then _pass "$desc"
  else _fail "$desc" "$expected" "$actual"; fi
}

cleanup() { rm -rf /tmp/claude_session_test-*; }
trap cleanup EXIT

strip_ansi() { sed 's/\x1b\[[0-9;]*[mGKHF]//g'; }

# ─── JSONL breakdown awk (mirrors statusline.sh exactly) ─────────────────────
run_breakdown() {
  awk '
/"role":"assistant"/ && /"usage"/ && /"model":"claude-/ {
  uuid = ""
  if (match($0, /"uuid":"[^"]*"/)) {
    f = substr($0, RSTART, RLENGTH); gsub(/"uuid":"/, "", f); gsub(/"$/, "", f); uuid = f
  }
  if (uuid == "" || uuid in seen) next
  seen[uuid] = 1
  model = ""
  if (match($0, /"model":"claude-[^"]*"/)) {
    f = substr($0, RSTART, RLENGTH); gsub(/"model":"/, "", f); gsub(/"$/, "", f); model = f
  }
  if (model == "") next
  in_tok = 0
  if (match($0, /"input_tokens":[0-9]+/))
    { f = substr($0, RSTART, RLENGTH); sub(/"input_tokens":/, "", f); in_tok = f+0 }
  cr = 0
  if (match($0, /"cache_read_input_tokens":[0-9]+/))
    { f = substr($0, RSTART, RLENGTH); sub(/"cache_read_input_tokens":/, "", f); cr = f+0 }
  cw5m = 0; cw1h = 0
  if (match($0, /"ephemeral_5m_input_tokens":[0-9]+/))
    { f = substr($0, RSTART, RLENGTH); sub(/"ephemeral_5m_input_tokens":/, "", f); cw5m = f+0 }
  if (match($0, /"ephemeral_1h_input_tokens":[0-9]+/))
    { f = substr($0, RSTART, RLENGTH); sub(/"ephemeral_1h_input_tokens":/, "", f); cw1h = f+0 }
  if (cw5m == 0 && cw1h == 0 && match($0, /"cache_creation_input_tokens":[0-9]+/))
    { f = substr($0, RSTART, RLENGTH); sub(/"cache_creation_input_tokens":/, "", f); cw1h = f+0 }
  web = 0; fetch = 0
  if (match($0, /"web_search_requests":[0-9]+/))
    { f = substr($0, RSTART, RLENGTH); sub(/"web_search_requests":/, "", f); web = f+0 }
  if (match($0, /"web_fetch_requests":[0-9]+/))
    { f = substr($0, RSTART, RLENGTH); sub(/"web_fetch_requests":/, "", f); fetch = f+0 }
  out = 0
  if (match($0, /"output_tokens":[0-9]+/))
    { f = substr($0, RSTART, RLENGTH); sub(/"output_tokens":/, "", f); out = f+0 }
  fingerprint = model ":" in_tok ":" out
  if (fingerprint == prev_fingerprint) next
  prev_fingerprint = fingerprint
  in_sum[model] += in_tok; cr_sum[model] += cr
  cw5m_sum[model] += cw5m; cw1h_sum[model] += cw1h
  out_sum[model] += out
  web_sum[model] += web; fetch_sum[model] += fetch
}
END {
  for (m in in_sum)
    print m, in_sum[m], cr_sum[m], cw5m_sum[m], cw1h_sum[m], out_sum[m], web_sum[m], fetch_sum[m]
}
' "$@"
}

# ─── Stdin extraction tests ───────────────────────────────────────────────────
echo "=== Stdin extraction ==="

echo "--- Test 1: compact JSON"
out=$(cat "$FIXTURES/stdin-compact.json" | bash "$SCRIPT" 2>/dev/null | strip_ansi)
assert_contains "model Opus 4.7"   "Opus 4.7"  "$out"
assert_contains "ctx 14%"          "ctx 14%"   "$out"
assert_contains "ctx 1000k"        "/1000k"    "$out"

echo "--- Test 2: pretty-printed JSON"
out=$(cat "$FIXTURES/stdin-pretty.json" | bash "$SCRIPT" 2>/dev/null | strip_ansi)
assert_contains "model Sonnet 4.6" "Sonnet 4.6" "$out"
assert_contains "ctx 9%"           "ctx 9%"     "$out"
assert_contains "ctx 200k"         "/200k"      "$out"

echo "--- Test 3: multiple display_name fields — model section wins"
out=$(cat "$FIXTURES/stdin-multi-display-name.json" | bash "$SCRIPT" 2>/dev/null | strip_ansi)
assert_contains     "model Opus 4.7 extracted"      "Opus 4.7" "$out"
assert_not_contains "effort display_name not used"  "High"     "$(echo "$out" | head -1)"
assert_not_contains "output_style not used"         "Default"  "$(echo "$out" | head -1)"

echo "--- Test 4: _snum regression guard (used_percentage:7 early; ctx_kb must not be 0)"
# If _snum still grabbed the first number in the line, context_window_size would
# extract 7 → 7/1000 = 0 → displays /0k.  With the fix it extracts 1000000 → /1000k.
out=$(cat "$FIXTURES/stdin-regression-snum.json" | bash "$SCRIPT" 2>/dev/null | strip_ansi)
assert_contains     "_snum extracts correct ctx_kb" "/1000k" "$out"
assert_not_contains "_snum does not return first num" "/0k"   "$out"

echo "--- Test 5: missing/empty JSON does not crash"
out=$(printf '{"session_id":"test-empty"}' | bash "$SCRIPT" 2>/dev/null; echo "exit:$?")
assert_contains "no crash on sparse JSON" "exit:0" "$out"

echo "--- Test 6: post-/compact ctx from compactMetadata.postTokens (15284/200000=7%)"
STALE_TRANSCRIPT="$FIXTURES/transcript-stale.jsonl"
out=$(sed "s|TRANSCRIPT_PATH|$STALE_TRANSCRIPT|" "$FIXTURES/stdin-stale-ctx.json" \
        | bash "$SCRIPT" 2>/dev/null | strip_ansi)
assert_contains     "stale ctx shows 7%"  "ctx 7%"  "$out"
assert_not_contains "stale ctx hides 0%"  "ctx 0%"  "$out"
assert_not_contains "no stale ? marker"   "ctx ?%"  "$out"

echo "--- Test 7: fresh session (used_percentage:0 + no transcript) shows 0%"
out=$(printf '{"session_id":"test-fresh","context_window":{"used_percentage":0,"context_window_size":200000}}' \
        | bash "$SCRIPT" 2>/dev/null | strip_ansi)
assert_contains     "fresh shows 0%"         "ctx 0%"  "$out"
assert_not_contains "fresh no compact-pct"   "ctx 7%"  "$out"

echo "--- Test 7b: float used_percentage rounds to integer"
out=$(printf '{"session_id":"test-float","context_window":{"used_percentage":56.99999999999999,"context_window_size":1000000},"current_usage":{"input_tokens":100,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":50}}' \
        | bash "$SCRIPT" 2>/dev/null | strip_ansi)
assert_contains     "rounded to 57%"         "ctx 57%"             "$out"
assert_not_contains "no raw float"           "56.99999999999999"   "$out"

echo "--- Test 7c: stale harness % with zero current_usage resets to 0%"
out=$(printf '{"session_id":"test-stale-fresh","context_window":{"used_percentage":59,"context_window_size":1000000},"current_usage":{"input_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":0}}' \
        | bash "$SCRIPT" 2>/dev/null | strip_ansi)
assert_contains     "stale fresh shows 0%"  "ctx 0%"   "$out"
assert_not_contains "stale 59% hidden"      "ctx 59%"  "$out"

# ─── JSONL aggregation tests ──────────────────────────────────────────────────
echo ""
echo "=== JSONL aggregation ==="

echo "--- Test 8: 2 Opus messages + 1 Sonnet → 2 model rows"
breakdown=$(run_breakdown "$FIXTURES/session.jsonl")
line_count=$(echo "$breakdown" | grep -c "^claude-" 2>/dev/null || true)
assert_eq "2 model rows" "2" "$line_count"

echo "--- Test 9: Opus input tokens summed (1000+2000=3000, dupe uuid excluded)"
opus_in=$(echo "$breakdown" | grep "^claude-opus-4-7 " | awk '{print $2}')
assert_eq "Opus in_tokens=3000" "3000" "$opus_in"

echo "--- Test 10: duplicate uuid counted once (not 12999)"
# uuid-opus-1 appears twice; second entry has in_tokens=9999.  If dedup fails → 12999.
assert_not_contains "dupe uuid not double-counted" "12999" "$breakdown"

echo "--- Test 11: ephemeral_5m_input_tokens aggregated into cw5m"
# uuid-opus-1 has ephemeral_5m=500; uuid-opus-2 has 0. Opus cw5m column should be 500.
opus_cw5m=$(echo "$breakdown" | grep "^claude-opus-4-7 " | awk '{print $4}')
assert_eq "Opus cw5m=500" "500" "$opus_cw5m"

echo "--- Test 11b: legacy cache_creation_input_tokens used as cw1h fallback"
# uuid-opus-2 has cache_creation_input_tokens=1000 and ephemeral_1h=0 → cw1h=1000
opus_cw1h=$(echo "$breakdown" | grep "^claude-opus-4-7 " | awk '{print $5}')
assert_eq "Opus cw1h=1000 (legacy fallback)" "1000" "$opus_cw1h"

echo "--- Test 12: synthetic model entry filtered out"
synth_breakdown=$(run_breakdown "$FIXTURES/session-synthetic.jsonl")
assert_not_contains "synthetic excluded" "synthetic" "$synth_breakdown"
assert_contains     "real haiku entry kept" "claude-haiku" "$synth_breakdown"

# ─── End-to-end render with Σ lines ──────────────────────────────────────────
echo ""
echo "=== End-to-end render ==="

echo "--- Test 13: Σ line appears when MODEL_BREAKDOWN is pre-populated"
SID="test-e2e-$$"
SDIR="/tmp/claude_session_${SID}"
mkdir -p "$SDIR"
echo "claude-opus-4-7 1234 87000 500 2000 312 0 0" > "$SDIR/model_breakdown.txt"
out=$(sed "s/test-compact/${SID}/" "$FIXTURES/stdin-compact.json" | bash "$SCRIPT" 2>/dev/null | strip_ansi)
assert_contains "Σ line rendered"      "Σ"       "$out"
assert_contains "Opus 4.7 in Σ line"  "Opus 4.7" "$(echo "$out" | grep 'Σ')"
assert_contains "cost in Σ line"      '$'       "$(echo "$out" | grep 'Σ')"

# ─── Streaming-checkpoint deduplication ─────────────────────────────────────
echo ""
echo "=== Streaming-checkpoint deduplication ==="

echo "--- Test 13b: 4 checkpoint copies of same call counted once, not 4"
bd13b=$(run_breakdown "$FIXTURES/session-streaming-checkpoints.jsonl")
# 4 copies of (in=3, out=3369) + 2 copies of (in=1, out=422); should count as 2 unique calls
sonnet_out_13b=$(echo "$bd13b" | grep "^claude-sonnet" | awk '{print $6}')  # col 6 = out
# Correct: 3369 + 422 = 3791. Wrong (no dedup): 3369*4 + 422*2 = 14320
assert_eq "streaming checkpoints counted once: out=3791" "3791" "$sonnet_out_13b"
assert_not_contains "not 4x inflated (14320)" "14320" "$bd13b"

# ─── Cache-write double-count regression ─────────────────────────────────────
echo ""
echo "=== Cache-write double-count regression ==="

echo "--- Test 14: cw5m-only message: cw5m=1000, cw1h=0 (not double-counted)"
bd14=$(run_breakdown "$FIXTURES/session-cw5m-only.jsonl")
cw5m_14=$(echo "$bd14" | grep "^claude-haiku" | awk '{print $4}')
cw1h_14=$(echo "$bd14" | grep "^claude-haiku" | awk '{print $5}')
assert_eq "cw5m=1000"         "1000" "$cw5m_14"
assert_eq "cw1h=0 (no dupe)"  "0"    "$cw1h_14"
assert_not_contains "cw1h is not 1000 (double-count regression)" "1000" "$cw1h_14"

# ─── Web-search billing ───────────────────────────────────────────────────────
echo ""
echo "=== Web-search billing ==="

echo "--- Test 15: websearch message: web=3, fetch=1 propagated"
bd15=$(run_breakdown "$FIXTURES/session-websearch.jsonl")
web_15=$(echo "$bd15"   | grep "^claude-haiku" | awk '{print $7}')
fetch_15=$(echo "$bd15" | grep "^claude-haiku" | awk '{print $8}')
assert_eq "web=3"   "3" "$web_15"
assert_eq "fetch=1" "1" "$fetch_15"

# ─── Harness cost.total_cost_usd as top-line ─────────────────────────────────
echo ""
echo "=== Harness cost.total_cost_usd as top-line ==="

echo "--- Test 16: harness cost.total_cost_usd shown on top line"
out16=$(cat "$FIXTURES/stdin-with-cost.json" | bash "$SCRIPT" 2>/dev/null | strip_ansi)
assert_contains 'harness cost $0.42 in top line' '$0.42' "$(echo "$out16" | head -1)"

echo "--- Test 17: both harness and local shown when both present"
SID17="test-cost-both-$$"
SDIR17="/tmp/claude_session_${SID17}"
mkdir -p "$SDIR17"
echo "9.99" > "$SDIR17/session_cost.txt"
out17=$(sed "s/test-harness-cost/${SID17}/" "$FIXTURES/stdin-with-cost.json" | bash "$SCRIPT" 2>/dev/null | strip_ansi)
assert_contains 'harness $0.42 shown'      '$0.42' "$(echo "$out17" | head -1)"
assert_contains 'local $9.99 also shown'   '$9.99' "$(echo "$out17" | head -1)"

echo "--- Test 18: local-only cost when harness absent"
SID18="test-cost-local-only-$$"
SDIR18="/tmp/claude_session_${SID18}"
mkdir -p "$SDIR18"
echo "9.99" > "$SDIR18/session_cost.txt"
out18=$(printf '{"session_id":"%s","context_window":{"used_percentage":5,"context_window_size":1000000},"current_usage":{"input_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":20}}' "$SID18" \
        | bash "$SCRIPT" 2>/dev/null | strip_ansi)
assert_contains     'local $9.99 shown'          '$9.99' "$(echo "$out18" | head -1)"
assert_not_contains 'no slash when harness absent' '/ $'  "$(echo "$out18" | head -1)"

# ─── Dual-TTL display ─────────────────────────────────────────────────────────
echo ""
echo "=== Dual-TTL display ==="

echo "--- Test 19: cache_log alive sums shown in TTL (both tiers, model-filtered)"
SID19="test-ttl-alive-$$"
SDIR19="/tmp/claude_session_${SID19}"
mkdir -p "$SDIR19"
_now19=$(date +%s)
# stdin-compact.json has model id "claude-opus-4-7"; tag entries with that model
echo "$((_now19 - 10)) 1000 2000 claude-opus-4-7" > "$SDIR19/cache_log.txt"
out19=$(sed "s/test-compact/${SID19}/" "$FIXTURES/stdin-compact.json" | bash "$SCRIPT" 2>/dev/null | strip_ansi)
assert_contains "TTL shows alive 5m (1.0k)"   "(1.0k)" "$(echo "$out19" | head -1)"
assert_contains "TTL shows alive 1h (2.0k)"   "(2.0k)" "$(echo "$out19" | head -1)"
assert_contains "1h countdown H:MM:SS format" "0:"     "$(echo "$out19" | head -1)"

echo "--- Test 20: no cache_log -> plain ttl (no parens)"
out20=$(cat "$FIXTURES/stdin-compact.json" | bash "$SCRIPT" 2>/dev/null | strip_ansi)
ttl_field20=$(echo "$out20" | head -1 | grep -oE '~ttl [^ ]+' | head -1)
assert_not_contains "plain ttl has no parens"  "(" "$ttl_field20"
assert_not_contains "plain ttl has no slash"   "/" "$ttl_field20"

# ─── Alive-cache TTL tracking ─────────────────────────────────────────────────
echo ""
echo "=== Alive-cache TTL tracking ==="

echo "--- Test 21: two fresh entries for same model, both tiers summed correctly"
SID21="test-cache-alive-$$"
SDIR21="/tmp/claude_session_${SID21}"
mkdir -p "$SDIR21"
_now21=$(date +%s)
echo "$((_now21 - 10)) 5000 100000 claude-opus-4-7"  > "$SDIR21/cache_log.txt"
echo "$((_now21 - 290)) 2000 0 claude-opus-4-7"     >> "$SDIR21/cache_log.txt"
out21=$(sed "s/test-compact/${SID21}/" "$FIXTURES/stdin-compact.json" | bash "$SCRIPT" 2>/dev/null | strip_ansi)
assert_contains "alive 5m sums 5k+2k = 7.0k" "(7.0k)"  "$(echo "$out21" | head -1)"
assert_contains "alive 1h = 100k"             "(100k)"  "$(echo "$out21" | head -1)"

echo "--- Test 22: expired 5m excluded; alive 1h shown; different model excluded"
SID22="test-cache-expired-$$"
SDIR22="/tmp/claude_session_${SID22}"
mkdir -p "$SDIR22"
_now22=$(date +%s)
echo "$((_now22 - 310)) 5000 0 claude-opus-4-7"      > "$SDIR22/cache_log.txt"   # expired 5m
echo "$((_now22 - 100)) 0 200000 claude-opus-4-7"   >> "$SDIR22/cache_log.txt"   # alive 1h
echo "$((_now22 - 50)) 9000 900000 claude-sonnet-4-6" >> "$SDIR22/cache_log.txt" # different model — must be excluded
out22=$(sed "s/test-compact/${SID22}/" "$FIXTURES/stdin-compact.json" | bash "$SCRIPT" 2>/dev/null | strip_ansi)
assert_not_contains "expired 5m not shown"         "(5.0k)"  "$(echo "$out22" | head -1)"
assert_not_contains "other model tokens excluded"  "(9.0k)"  "$(echo "$out22" | head -1)"
assert_contains     "alive 1h = 200k"              "(200k)"  "$(echo "$out22" | head -1)"

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "==========================================="
echo "  ${PASS} passed  |  ${FAIL} failed"
echo "==========================================="
[ "$FAIL" -eq 0 ]
