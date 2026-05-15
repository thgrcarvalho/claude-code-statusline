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
  cw5m = 0
  if (match($0, /"ephemeral_5m_input_tokens":[0-9]+/))
    { f = substr($0, RSTART, RLENGTH); sub(/"ephemeral_5m_input_tokens":/, "", f); cw5m = f+0 }
  cw1h = 0
  if (match($0, /"ephemeral_1h_input_tokens":[0-9]+/))
    { f = substr($0, RSTART, RLENGTH); sub(/"ephemeral_1h_input_tokens":/, "", f); cw1h = f+0 }
  if (cw1h == 0 && match($0, /"cache_creation_input_tokens":[0-9]+/))
    { f = substr($0, RSTART, RLENGTH); sub(/"cache_creation_input_tokens":/, "", f); cw1h = f+0 }
  out = 0
  if (match($0, /"output_tokens":[0-9]+/))
    { f = substr($0, RSTART, RLENGTH); sub(/"output_tokens":/, "", f); out = f+0 }
  in_sum[model] += in_tok; cr_sum[model] += cr
  cw5m_sum[model] += cw5m; cw1h_sum[model] += cw1h
  out_sum[model] += out
}
END {
  for (m in in_sum)
    print m, in_sum[m], cr_sum[m], cw5m_sum[m], cw1h_sum[m], out_sum[m]
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
echo "claude-opus-4-7 1234 87000 500 2000 312" > "$SDIR/model_breakdown.txt"
out=$(sed "s/test-compact/${SID}/" "$FIXTURES/stdin-compact.json" | bash "$SCRIPT" 2>/dev/null | strip_ansi)
assert_contains "Σ line rendered"      "Σ"       "$out"
assert_contains "Opus 4.7 in Σ line"  "Opus 4.7" "$(echo "$out" | grep 'Σ')"
assert_contains "cost in Σ line"      '$'       "$(echo "$out" | grep 'Σ')"

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "==========================================="
echo "  ${PASS} passed  |  ${FAIL} failed"
echo "==========================================="
[ "$FAIL" -eq 0 ]
