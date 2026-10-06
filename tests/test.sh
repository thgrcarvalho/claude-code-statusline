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

cleanup() { rm -rf /tmp/claude_session_test-*; rm -f "${SIGMA_AWK:-}"; }
trap cleanup EXIT

strip_ansi() { sed 's/\x1b\[[0-9;]*[mGKHF]//g'; }

# ─── JSONL breakdown awk: the production program, extracted from statusline.sh ──
# Never mirror it here: a fix applied to only one copy passed CI while production broke
# (CC 2.1.28x "iterations":[] — the mirror and the script drifted independently).
SIGMA_AWK="/tmp/sltest-sigma-$$.awk"
sed -n '/^# >>> SIGMA_AWK/,/^# <<< SIGMA_AWK/p' "$SCRIPT" > "$SIGMA_AWK"
if [ ! -s "$SIGMA_AWK" ]; then
  echo "FATAL: SIGMA_AWK markers not found in statusline.sh" >&2; exit 1
fi
run_breakdown() { awk -f "$SIGMA_AWK" "$@"; }

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

echo "--- Test 19: annotation shows active model's cached value from cache_log (89k)"
# cache_log entry has _c=89000 (5th col) → model_last_cached=89000 → "(89k)"
# stdin-compact.json has cache_read=87000, cache_write=2000 (these are now ignored for annotation)
# cache_log 1h-tier entry → model_last_is_1h=1 → shows H:MM:SS timer
# Suppress new-turn by pre-populating last_api.ts with tok_out=312 (matches stdin-compact)
SID19="test-ttl-anno-$$"
SDIR19="/tmp/claude_session_${SID19}"
mkdir -p "$SDIR19"
_now19=$(date +%s)
echo "312:${_now19}" > "$SDIR19/last_api.ts"
echo "$((_now19 - 30)) 0 50000 claude-opus-4-7 89000" > "$SDIR19/cache_log.txt"
out19=$(sed "s/test-compact/${SID19}/" "$FIXTURES/stdin-compact.json" | bash "$SCRIPT" 2>/dev/null | strip_ansi)
assert_contains "annotation = cache_log _c (89k)"  "(89k)" "$(echo "$out19" | head -1)"
assert_contains "1h tier → H:MM:SS format"         "0:"    "$(echo "$out19" | head -1)"

echo "--- Test 20: no cache activity → annotation shows (0)"
SID20="test-ttl-nocache-$$"
SDIR20="/tmp/claude_session_${SID20}"
mkdir -p "$SDIR20"
_stdin20=$(printf '{"session_id":"%s","transcript_path":"/dev/null","model":{"id":"claude-opus-4-7","display_name":"Opus 4.7","provider":"anthropic"},"context_window":{"used_percentage":5,"context_window_size":1000000},"current_usage":{"input_tokens":0,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":0}}' "$SID20")
out20=$(echo "$_stdin20" | bash "$SCRIPT" 2>/dev/null | strip_ansi)
ttl_field20=$(echo "$out20" | head -1 | grep -oE '~ttl [^ ]+' | head -1)
assert_contains "no cache data: shows (0)" "(0)" "$ttl_field20"

# ─── Cache annotation and timer tier ──────────────────────────────────────────
echo ""
echo "=== Cache annotation and timer tier ==="

echo "--- Test 21: annotation = cache_log 5th-col value; stdin tok_cr+tok_cw ignored"
SID21="test-ttl-value-$$"
SDIR21="/tmp/claude_session_${SID21}"
mkdir -p "$SDIR21"
_now21=$(date +%s)
# stdin: tok_cr=100000, tok_cw=5000 → old behavior would show (105k); new: cache_log wins
_stdin21=$(printf '{"session_id":"%s","transcript_path":"/dev/null","model":{"id":"claude-opus-4-7","display_name":"Opus 4.7","provider":"anthropic"},"context_window":{"used_percentage":5,"context_window_size":1000000},"current_usage":{"input_tokens":1,"cache_read_input_tokens":100000,"cache_creation_input_tokens":5000,"output_tokens":50}}' "$SID21")
echo "50:${_now21}" > "$SDIR21/last_api.ts"
# cache_log _c=7000 — this value should appear in annotation, not stdin's 105k
echo "$((_now21 - 10)) 0 200000 claude-opus-4-7 7000" > "$SDIR21/cache_log.txt"
out21=$(echo "$_stdin21" | bash "$SCRIPT" 2>/dev/null | strip_ansi)
assert_contains     "annotation = cache_log _c (7.0k)"   "(7.0k)"  "$(echo "$out21" | head -1)"
assert_not_contains "stdin 105k not in annotation"        "(105k)"  "$(echo "$out21" | head -1)"

echo "--- Test 22: 1h-tier cache_log entry → H:MM:SS timer; 5m-only → M:SS timer"
SID22="test-ttl-tier-$$"
SDIR22="/tmp/claude_session_${SID22}"
mkdir -p "$SDIR22"
_now22=$(date +%s)
_stdin22=$(printf '{"session_id":"%s","transcript_path":"/dev/null","model":{"id":"claude-opus-4-7","display_name":"Opus 4.7","provider":"anthropic"},"context_window":{"used_percentage":5,"context_window_size":1000000},"current_usage":{"input_tokens":1,"cache_read_input_tokens":1000,"cache_creation_input_tokens":1000,"output_tokens":50}}' "$SID22")
echo "50:${_now22}" > "$SDIR22/last_api.ts"
# 1h-tier entry (cw1h=80000) → model_last_is_1h=1 → H:MM:SS
echo "$((_now22 - 20)) 0 80000 claude-opus-4-7 2000" > "$SDIR22/cache_log.txt"
out22_1h=$(echo "$_stdin22" | bash "$SCRIPT" 2>/dev/null | strip_ansi)
assert_contains "1h entry → H:MM:SS timer" "0:59:" "$(echo "$out22_1h" | head -1)"
# 5m-only entry (cw1h=0) → model_last_is_1h=0 → M:SS
echo "$((_now22 - 20)) 80000 0 claude-opus-4-7 2000" > "$SDIR22/cache_log.txt"
out22_5m=$(echo "$_stdin22" | bash "$SCRIPT" 2>/dev/null | strip_ansi)
assert_not_contains "5m entry → M:SS, not H:MM:SS" "0:59:" "$(echo "$out22_5m" | head -1)"

# ─── compact_boundary cache_log floor ────────────────────────────────────────
echo ""
echo "=== compact_boundary cache_log floor ==="

echo "--- Test 23: compact floor excludes pre-compact entry from model_last_ts"
# Scenario: ONLY a pre-compact cache_log entry exists (no post-compact calls yet).
# With compact floor: entry excluded → model_last_ts=0 → fallback to prev_ts=now → ~5:00 timer.
# Without floor it would show ~2:30 (entry at now-150 → remaining=150s → 2:30).
SID23="test-compact-floor-$$"
SDIR23="/tmp/claude_session_${SID23}"
mkdir -p "$SDIR23"
_now23=$(date +%s)
_compact_ts23=$((_now23 - 100))  # compact 100s ago
_compact_iso23=$(date -u -d "@${_compact_ts23}" +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null || \
                  date -u -r "${_compact_ts23}" +"%Y-%m-%dT%H:%M:%S.000Z")
_compact_fixture23="/tmp/test23-compact-$$.jsonl"
printf '{"type":"user","subtype":"compact_boundary","uuid":"uuid-compact-23","timestamp":"%s","message":{"role":"user","content":"compact"},"compactMetadata":{"postTokens":5000}}\n' \
  "$_compact_iso23" > "$_compact_fixture23"
printf '{"type":"assistant","uuid":"uuid-a23","message":{"role":"assistant","model":"claude-opus-4-7","usage":{"input_tokens":5,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":100,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0}}}}\n' \
  >> "$_compact_fixture23"
# Only a pre-compact entry (now-150, 50s before compact at now-100)
echo "$((_now23 - 150)) 0 50000 claude-opus-4-7 89000" > "$SDIR23/cache_log.txt"
# prev_ts = now (via last_api.ts); tok_out=100 suppresses new-turn
echo "100:${_now23}" > "$SDIR23/last_api.ts"
_stdin23=$(printf '{"session_id":"%s","transcript_path":"%s","model":{"id":"claude-opus-4-7","display_name":"Opus 4.7","provider":"anthropic"},"context_window":{"used_percentage":14,"context_window_size":1000000},"current_usage":{"input_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":100}}' \
  "$SID23" "$_compact_fixture23")
out23=$(echo "$_stdin23" | bash "$SCRIPT" 2>/dev/null | strip_ansi)
# With floor: fallback timer ≈ 5:00 (fresh). Without floor it would be ~2:30.
assert_not_contains "compact excludes pre-compact from timer (no 2:3x)" "2:3" "$(echo "$out23" | head -1)"
rm -f "$_compact_fixture23"

echo "--- Test 24: no compact_boundary → pre-compact entry used for model_last_ts (~57min)"
SID24="test-no-compact-floor-$$"
SDIR24="/tmp/claude_session_${SID24}"
mkdir -p "$SDIR24"
_now24=$(date +%s)
# Same 1h-tier entry at now-150 but no compact → model_last_ts=now-150, model_last_is_1h=1
echo "$((_now24 - 150)) 0 50000 claude-opus-4-7 89000" > "$SDIR24/cache_log.txt"
echo "100:${_now24}" > "$SDIR24/last_api.ts"
_stdin24=$(printf '{"session_id":"%s","transcript_path":"/dev/null","model":{"id":"claude-opus-4-7","display_name":"Opus 4.7","provider":"anthropic"},"context_window":{"used_percentage":14,"context_window_size":1000000},"current_usage":{"input_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":100}}' \
  "$SID24")
out24=$(echo "$_stdin24" | bash "$SCRIPT" 2>/dev/null | strip_ansi)
# elapsed=150, remaining_1h=3450 → 0:57:30 → contains "0:5"
assert_contains "no compact: entry used → ~57min 1h timer" "0:5" "$(echo "$out24" | head -1)"

# ─── Per-model TTL timer ─────────────────────────────────────────────────────
echo ""
echo "=== Per-model TTL timer ==="

echo "--- Test 25: per-model cached annotation — Sonnet shows its own value, not Opus's"
SID25="test-model-timer-$$"
SDIR25="/tmp/claude_session_${SID25}"
mkdir -p "$SDIR25"
_now25=$(date +%s)
# Opus called 10s ago (cached=89k); Sonnet called 600s ago (cached=60k, 10 min stale)
echo "$((_now25 - 10))  1000 50000 claude-opus-4-7 89000"  > "$SDIR25/cache_log.txt"
echo "$((_now25 - 600)) 0 80000 claude-sonnet-4-6 60000"  >> "$SDIR25/cache_log.txt"
# Active model = Sonnet 4.6 — should show Sonnet's model_last_cached=60000 → "(60k)"
_stdin25=$(printf '{"session_id":"%s","transcript_path":"/dev/null","model":{"id":"claude-sonnet-4-6","display_name":"Sonnet 4.6","provider":"anthropic"},"context_window":{"used_percentage":6,"context_window_size":1000000},"current_usage":{"input_tokens":1,"cache_read_input_tokens":80000,"cache_creation_input_tokens":0,"output_tokens":50}}' "$SID25")
# Prime LAST_STATE so prev_ts = now (fresh global), confirming timer is NOT using it for Sonnet
echo "50:${_now25}" > "$SDIR25/last_api.ts"
out25=$(echo "$_stdin25" | bash "$SCRIPT" 2>/dev/null | strip_ansi)
# If timer used Opus (last 10s): 1h countdown ~59:50. Sonnet (600s ago): ~50:00.
assert_not_contains "Sonnet timer not using Opus (59min)"  "0:59:" "$(echo "$out25" | head -1)"
assert_contains     "Sonnet annotation = Sonnet's 60k"     "(60k)" "$(echo "$out25" | head -1)"
assert_not_contains "Sonnet annotation not Opus's 89k"     "(89k)" "$(echo "$out25" | head -1)"

echo "--- Test 26: active model has no cache_log entries — timer falls back, annotation shows (0)"
SID26="test-model-fallback-$$"
SDIR26="/tmp/claude_session_${SID26}"
mkdir -p "$SDIR26"
_now26=$(date +%s)
# cache_log has only Sonnet (with _c=50k); active model = Opus → no match → model_last_cached=0
echo "$((_now26 - 30)) 1000 0 claude-sonnet-4-6 50000" > "$SDIR26/cache_log.txt"
echo "0:${_now26}" > "$SDIR26/last_api.ts"
_stdin26=$(printf '{"session_id":"%s","transcript_path":"/dev/null","model":{"id":"claude-opus-4-7","display_name":"Opus 4.7","provider":"anthropic"},"context_window":{"used_percentage":6,"context_window_size":1000000},"current_usage":{"input_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":0}}' "$SID26")
out26=$(echo "$_stdin26" | bash "$SCRIPT" 2>/dev/null | strip_ansi)
# When tok_out=0 no new turn, prev_ts from last_api.ts (set to now → ~5:00 remaining)
# Sonnet's 50k not shown; Opus has no entry → model_last_cached=0 → (0)
assert_contains     "fallback timer renders without crash" "ttl"   "$(echo "$out26" | head -1)"
assert_contains     "no Opus entry: annotation shows (0)" "(0)"    "$(echo "$out26" | head -1)"
assert_not_contains "Sonnet 50k not leaked to Opus"       "(50k)"  "$(echo "$out26" | head -1)"

# ─── Per-model ctx override ───────────────────────────────────────────────────
echo ""
echo "=== Per-model ctx override ==="

echo "--- Test 27: Sonnet uses its own stored ctx%, not stale Opus harness value"
SID27="test-ctx-model-$$"
SDIR27="/tmp/claude_session_${SID27}"
mkdir -p "$SDIR27"
_now27=$(date +%s)
# cache_log: Opus (ctx=14%/200k), Sonnet (ctx=6%/1000k) — 7-col format
echo "$((_now27 - 10))  1000 50000 claude-opus-4-7 89000 14 200"  > "$SDIR27/cache_log.txt"
echo "$((_now27 - 600)) 0 80000 claude-sonnet-4-6 60000 6 1000"  >> "$SDIR27/cache_log.txt"
# stdin: Sonnet active, but harness context_window is stale — reports Opus values (14%/200k)
_stdin27=$(printf '{"session_id":"%s","transcript_path":"/dev/null","model":{"id":"claude-sonnet-4-6","display_name":"Sonnet 4.6","provider":"anthropic"},"context_window":{"used_percentage":14,"context_window_size":200000},"current_usage":{"input_tokens":1,"cache_read_input_tokens":60000,"cache_creation_input_tokens":0,"output_tokens":50}}' "$SID27")
echo "50:${_now27}" > "$SDIR27/last_api.ts"
out27=$(echo "$_stdin27" | bash "$SCRIPT" 2>/dev/null | strip_ansi)
assert_contains     "Sonnet ctx: stored 6%, not stale 14%"  "ctx 6%"   "$(echo "$out27" | head -1)"
assert_contains     "Sonnet ctx: stored 1000k"              "/1000k"   "$(echo "$out27" | head -1)"
assert_not_contains "Stale Opus 14% not shown for Sonnet"   "ctx 14%"  "$(echo "$out27" | head -1)"
assert_not_contains "Stale Opus 200k not shown for Sonnet"  "/200k"    "$(echo "$out27" | head -1)"

echo "--- Test 28: active model has no cache_log entry — ctx falls back to harness value"
SID28="test-ctx-fallback-$$"
SDIR28="/tmp/claude_session_${SID28}"
mkdir -p "$SDIR28"
_now28=$(date +%s)
# cache_log: only Sonnet entry (ctx=6%/1000k); active model = Opus → no match → harness fallback
echo "$((_now28 - 10)) 0 80000 claude-sonnet-4-6 60000 6 1000" > "$SDIR28/cache_log.txt"
# stdin: Opus active, harness says 33%/200k
_stdin28=$(printf '{"session_id":"%s","transcript_path":"/dev/null","model":{"id":"claude-opus-4-7","display_name":"Opus 4.7","provider":"anthropic"},"context_window":{"used_percentage":33,"context_window_size":200000},"current_usage":{"input_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":50}}' "$SID28")
echo "50:${_now28}" > "$SDIR28/last_api.ts"
out28=$(echo "$_stdin28" | bash "$SCRIPT" 2>/dev/null | strip_ansi)
assert_contains     "Opus ctx falls back to harness 33%"  "ctx 33%"  "$(echo "$out28" | head -1)"
assert_contains     "Opus ctx falls back to harness 200k" "/200k"    "$(echo "$out28" | head -1)"
assert_not_contains "Sonnet 6% not leaked to Opus"        "ctx 6%"   "$(echo "$out28" | head -1)"
assert_not_contains "Sonnet 1000k not leaked to Opus"     "/1000k"   "$(echo "$out28" | head -1)"

# ─── /compact cost capture ───────────────────────────────────────────────────
echo ""
echo "=== /compact cost capture ==="

# Helper: emit harness stdin with a given total_cost_usd and transcript path.
_compact_stdin() { # $1=session_id  $2=cost  $3=transcript_path  $4=output_tokens (default 50)
  printf '{"session_id":"%s","transcript_path":"%s","model":{"id":"claude-opus-4-8","display_name":"Opus 4.8","provider":"anthropic"},"context_window":{"used_percentage":50,"context_window_size":1000000},"cost":{"total_cost_usd":%s},"current_usage":{"input_tokens":100,"cache_read_input_tokens":200,"cache_creation_input_tokens":0,"output_tokens":%s}}' "$1" "$3" "$2" "${4:-50}"
}
_boundary() { # $1=iso_timestamp
  printf '{"type":"system","subtype":"compact_boundary","timestamp":"%s","compactMetadata":{"trigger":"manual","preTokens":79508,"postTokens":4450}}\n' "$1"
}

echo "--- Test 29: cost delta captured at each compact boundary, accumulated"
SID29="test-compact-$$"
SDIR29="/tmp/claude_session_${SID29}"
TR29="/tmp/claude_session_${SID29}_tr.jsonl"
mkdir -p "$SDIR29"; : > "$TR29"

# Render 1: baseline, no compact in transcript → no Σ /compact line
out29a=$(_compact_stdin "$SID29" 2.00 "$TR29" | bash "$SCRIPT" 2>/dev/null | strip_ansi)
assert_not_contains "R1 baseline: no /compact line yet" "/compact" "$out29a"

# Render 2: first compact appears + cost jumps 2.00 → 2.30 (delta 0.30)
_boundary "2026-06-06T22:00:00.000Z" >> "$TR29"
out29b=$(_compact_stdin "$SID29" 2.30 "$TR29" | bash "$SCRIPT" 2>/dev/null | strip_ansi)
assert_contains "R2 first compact: x1 \$0.300" "Σ /compact ×1: \$0.300" "$out29b"

# Render 3: a real normal turn (output_tokens changes 50→60), cost rises 2.30 → 2.50,
# same floor → must NOT count, but advances the turn baseline used by the next compact
out29c=$(_compact_stdin "$SID29" 2.50 "$TR29" 60 | bash "$SCRIPT" 2>/dev/null | strip_ansi)
assert_contains "R3 normal turn: still x1 \$0.300" "Σ /compact ×1: \$0.300" "$out29c"

# Render 4: second compact (not a turn, output_tokens stays 60), cost 2.50 → 2.90
# (delta from the R3 turn baseline = 0.40) → x2 total 0.70
_boundary "2026-06-06T22:05:00.000Z" >> "$TR29"
out29d=$(_compact_stdin "$SID29" 2.90 "$TR29" 60 | bash "$SCRIPT" 2>/dev/null | strip_ansi)
assert_contains "R4 second compact: x2 \$0.700" "Σ /compact ×2: \$0.700" "$out29d"
rm -f "$TR29"

echo "--- Test 30: compact predating the feature is not retroactively counted"
SID30="test-compact-pre-$$"
SDIR30="/tmp/claude_session_${SID30}"
TR30="/tmp/claude_session_${SID30}_tr.jsonl"
mkdir -p "$SDIR30"
# Transcript already has a boundary before the statusline's first-ever render
_boundary "2026-06-06T21:00:00.000Z" > "$TR30"
out30=$(_compact_stdin "$SID30" 5.00 "$TR30" | bash "$SCRIPT" 2>/dev/null | strip_ansi)
assert_not_contains "pre-existing compact not counted on first render" "/compact" "$out30"
# A subsequent NEW compact is still counted (baseline now established)
_boundary "2026-06-06T21:30:00.000Z" >> "$TR30"
out30b=$(_compact_stdin "$SID30" 5.25 "$TR30" | bash "$SCRIPT" 2>/dev/null | strip_ansi)
assert_contains "new compact after baseline: x1 \$0.250" "Σ /compact ×1: \$0.250" "$out30b"
rm -f "$TR30"

echo "--- Test 31: long-compaction lead race — cost rises a render before the boundary"
# Regression for a slow /compact: the harness bumps total_cost_usd a render or two BEFORE
# the compact_boundary line lands in the transcript. Baselining on the previous render then
# sees the higher cost already and computes a 0 delta. Baselining on the last *turn* cost
# captures it. (Old code produced "×1: $0" here; this is the bug fix.)
SID31="test-compact-lead-$$"
SDIR31="/tmp/claude_session_${SID31}"
TR31="/tmp/claude_session_${SID31}_tr.jsonl"
mkdir -p "$SDIR31"; : > "$TR31"
# R1: a real turn at cost 3.00, no compaction yet → establishes the turn baseline
out31a=$(_compact_stdin "$SID31" 3.00 "$TR31" 10 | bash "$SCRIPT" 2>/dev/null | strip_ansi)
assert_not_contains "lead R1: no /compact yet" "/compact" "$out31a"
# R2: cost jumps 3.00 → 3.50 (compaction billed early), boundary NOT landed, not a turn → no count
out31b=$(_compact_stdin "$SID31" 3.50 "$TR31" 10 | bash "$SCRIPT" 2>/dev/null | strip_ansi)
assert_not_contains "lead R2: cost rose pre-boundary, still no /compact" "/compact" "$out31b"
# R3: boundary appears, cost unchanged 3.50, not a turn → delta measured from the last turn
# (3.00) not the previous render (3.50) → x1 $0.500
_boundary "2026-06-06T23:00:00.000Z" >> "$TR31"
out31c=$(_compact_stdin "$SID31" 3.50 "$TR31" 10 | bash "$SCRIPT" 2>/dev/null | strip_ansi)
assert_contains "lead R3: captured from turn baseline x1 \$0.500" "Σ /compact ×1: \$0.500" "$out31c"
rm -f "$TR31"

echo "--- Test 32: consecutive compacts with no turn between → no double-count"
# Two compactions and no real turn between them (output_tokens stays 50). The baseline must
# advance to the post-compaction cost after the first, so the second measures only its own
# delta. Without baseline advancement the second would re-measure from the original turn.
SID32="test-compact-back2back-$$"
SDIR32="/tmp/claude_session_${SID32}"
TR32="/tmp/claude_session_${SID32}_tr.jsonl"
mkdir -p "$SDIR32"; : > "$TR32"
# R1: turn at cost 1.00, no compaction → turn baseline = 1.00
out32a=$(_compact_stdin "$SID32" 1.00 "$TR32" | bash "$SCRIPT" 2>/dev/null | strip_ansi)
assert_not_contains "b2b R1: no /compact yet" "/compact" "$out32a"
# R2: first compact, cost 1.00 → 1.40 (delta 0.40) → x1 $0.400
_boundary "2026-06-06T23:30:00.000Z" >> "$TR32"
out32b=$(_compact_stdin "$SID32" 1.40 "$TR32" | bash "$SCRIPT" 2>/dev/null | strip_ansi)
assert_contains "b2b R2: x1 \$0.400" "Σ /compact ×1: \$0.400" "$out32b"
# R3: second compact, no turn between, cost 1.40 → 1.60 (delta 0.20 from advanced baseline)
# → x2 $0.600  (a non-advancing baseline would give 1.60-1.00=0.60 → x2 $1.000)
_boundary "2026-06-06T23:35:00.000Z" >> "$TR32"
out32c=$(_compact_stdin "$SID32" 1.60 "$TR32" | bash "$SCRIPT" 2>/dev/null | strip_ansi)
assert_contains "b2b R3: x2 \$0.600 (no double-count)" "Σ /compact ×2: \$0.600" "$out32c"
rm -f "$TR32"

# ─── Subagent collection ─────────────────────────────────────────────────────
echo ""
echo "=== subagent JSONL collection ==="

echo "--- Test 33: subagent transcripts are collected recursively (workflow fleets nest)"
# The per-model Σ folds subagents in. Inline Agent-tool subagents land directly in
# subagents/agent-*.jsonl, but ultracode/Workflow fleets nest under
# subagents/workflows/wf_*/agent-*.jsonl. A non-recursive glob silently dropped the
# nested fleet, so its (often large) cost never showed in Σ. Build parent + inline +
# nested-workflow transcripts with distinct token counts and assert the rebuilt
# breakdown sums all three.
SID33="test-subagent-recurse-$$"
SDIR33="/tmp/claude_session_${SID33}"
TDIR33="/tmp/test33-proj-$$"                       # holds <uuid>.jsonl and <uuid>/subagents/...
UUID33="aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
TR33="$TDIR33/${UUID33}.jsonl"
SUB33="$TDIR33/${UUID33}/subagents"
rm -rf "$SDIR33" "$TDIR33"
mkdir -p "$SUB33/workflows/wf_test33"
# parent: in 1000 / out 100
printf '{"type":"assistant","uuid":"p33","message":{"role":"assistant","model":"claude-opus-4-8","usage":{"input_tokens":1000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":100}}}\n' > "$TR33"
# inline (top-level) subagent: in 2000 / out 200
printf '{"type":"assistant","uuid":"s33","message":{"role":"assistant","model":"claude-opus-4-8","usage":{"input_tokens":2000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":200}}}\n' > "$SUB33/agent-top.jsonl"
# nested workflow subagent: in 4000 / out 400  (this is what the old non-recursive glob dropped)
printf '{"type":"assistant","uuid":"w33","message":{"role":"assistant","model":"claude-opus-4-8","usage":{"input_tokens":4000,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":400}}}\n' > "$SUB33/workflows/wf_test33/agent-nested.jsonl"
# One render forces the turn-gated rebuild. Command substitution captures the script's
# stdout, which keeps the pipe open until the backgrounded awk rebuild closes fd1 — so
# model_breakdown.txt is guaranteed fresh by the time the render returns.
_stdin33=$(printf '{"session_id":"%s","transcript_path":"%s","model":{"id":"claude-opus-4-8","display_name":"Opus 4.8","provider":"anthropic"},"context_window":{"used_percentage":50,"context_window_size":1000000},"current_usage":{"input_tokens":1,"cache_read_input_tokens":0,"cache_creation_input_tokens":0,"output_tokens":50}}' "$SID33" "$TR33")
_=$(echo "$_stdin33" | bash "$SCRIPT" 2>/dev/null)
bd33=$(cat "$SDIR33/model_breakdown.txt" 2>/dev/null)
# expected sum: in 1000+2000+4000=7000, out 100+200+400=700 (cr/cw all 0)
assert_contains     "recursive collect sums parent+inline+nested" "claude-opus-4-8 7000 0 0 0 700 0 0" "$bd33"
# guard: the old non-recursive result (nested fleet dropped) must NOT be what we get
assert_not_contains "non-recursive sum (nested dropped) gone"      "claude-opus-4-8 3000 0 0 0 300 0 0" "$bd33"
rm -rf "$SDIR33" "$TDIR33"

# ─── Unknown-family model (Fable) ────────────────────────────────────────────
echo ""
echo "=== unknown-family model (Fable 5) ==="

echo "--- Test 34: Fable 5 with [1m] stdin id — ttl filter, ctx override, Σ display, pricing"
# Fable is not an Opus/Sonnet/Haiku display name, so _cache_filter used to fall back to
# the raw stdin id "claude-fable-5[1m]". Transcript-extracted cache_log tags lack the
# [1m] suffix, so only the stale first-turn fallback entry (tagged with the raw id)
# matched → frozen ttl base ("expired"), stale cached count, stale ctx%. Σ rows showed
# the raw id (no display mapping) and billed at the $3/$15 default (no fable pricing).
SID34="test-fable-$$"
SDIR34="/tmp/claude_session_${SID34}"
rm -rf "$SDIR34"; mkdir -p "$SDIR34"
_now34=$(date +%s)
# Suppress the turn-gate (tok_out=50 matches last_api col 1) so the prewritten
# breakdown and cache_log survive the render untouched.
echo "50:${_now34}" > "$SDIR34/last_api.ts"
# cache_log: stale first-turn entry tagged with the raw [1m] id (no tier split, 25k
# cached, ctx 3%), then a fresh transcript-tagged entry (1h tier, 73k cached, ctx 7%).
# The fixed family filter ("claude-fable") must pick the fresh one.
{
  echo "$((_now34 - 3000)) 0 0 claude-fable-5[1m] 25312 3 1000"
  echo "$((_now34 - 20)) 0 6801 claude-fable-5 73499 7 1000"
} > "$SDIR34/cache_log.txt"
# Σ input: token sums from a real Fable session; the $10/$50 fable fallback prices this
# at $3.73 (the old $3/$15 default gave $1.12). If this assertion ever fails on the cost
# value, LiteLLM has likely added claude-fable-5 with different rates — re-check pricing.
echo "claude-fable-5 7966 395502 0 69712 37272 0 0" > "$SDIR34/model_breakdown.txt"
_stdin34=$(printf '{"session_id":"%s","transcript_path":"/dev/null","model":{"id":"claude-fable-5[1m]","display_name":"Fable 5","provider":"anthropic"},"context_window":{"used_percentage":3,"context_window_size":1000000},"current_usage":{"input_tokens":2,"cache_read_input_tokens":54000,"cache_creation_input_tokens":37,"output_tokens":50}}' "$SID34")
out34=$(echo "$_stdin34" | bash "$SCRIPT" 2>/dev/null | strip_ansi)
l1_34=$(echo "$out34" | head -1)
assert_contains     "ttl annotation = fresh entry (73k)"    "(73k)"    "$l1_34"
assert_not_contains "stale [1m]-entry 25k gone"             "(25k)"    "$l1_34"
assert_contains     "1h tier countdown (0:59:..)"           "0:59:"    "$l1_34"
assert_not_contains "ttl not expired"                       "expired"  "$l1_34"
assert_contains     "ctx override from fresh entry (7%)"    "ctx 7%"   "$l1_34"
assert_not_contains "stale ctx 3% gone"                     "ctx 3%"   "$l1_34"
assert_contains     "Σ row uses display name Fable 5"       "Fable 5:" "$out34"
assert_contains     "fable fallback pricing 10/50 → \$3.73" "\$3.73"   "$out34"
rm -rf "$SDIR34"

# ─── New stdin schema (Claude Code 2.1.187+) ─────────────────────────────────
echo ""
echo "=== new stdin schema (CC 2.1.187+) ==="

echo "--- Test 35: nested current_usage + rate_limits.used_percentage disambiguation"
# CC 2.1.187+ moved current_usage INSIDE context_window and added a rate_limits block whose
# five_hour/seven_day tiers each carry their own used_percentage. The fixture serializes
# rate_limits BEFORE context_window on purpose: a whole-buffer "used_percentage" match would
# grab the five_hour value (18) instead of the real context 33% — this is the class of bug
# that garbled the status line on newer CLIs. Extraction is now scoped to the context_window
# object, so ctx must read 33%, and the nested current_usage tokens must still be summed.
out35=$(cat "$FIXTURES/stdin-new-schema.json" | bash "$SCRIPT" 2>/dev/null | strip_ansi)
l1_35=$(echo "$out35" | head -1)
assert_contains     "ctx from context_window (33%)"        "ctx 33%"               "$l1_35"
assert_not_contains "rate_limits five_hour % not used"     "ctx 18%"               "$l1_35"
assert_not_contains "rate_limits seven_day % not used"     "ctx 54%"               "$l1_35"
assert_contains     "context_window_size → /1000k"         "/1000k"                "$l1_35"
assert_contains     "1M-context display name passes through" "Opus 4.8 (1M context)" "$l1_35"
assert_contains     "nested current_usage cache_read (324k)" "+324kr"               "$l1_35"
assert_not_contains "resets_at timestamp not leaked into line" "1782366000"         "$l1_35"
rm -rf /tmp/claude_session_test-newschema

# ─── install / uninstall settings.json safety ────────────────────────────────
echo ""
echo "=== install/uninstall settings safety ==="

echo "--- Test 36: uninstall touches only the statusLine key, never the whole settings.json"
# Regression for the footgun where uninstall restored a full settings.json backup and wiped
# unrelated keys (could break the CLI). install/uninstall must read/write ONLY .statusLine.
# Runs the real install.sh + uninstall.sh in a throwaway HOME. Needs jq to assert; skip if absent.
if command -v jq >/dev/null 2>&1; then
  touch /tmp/claude_pricing.txt 2>/dev/null   # fresh cache → refresh-pricing.sh exits early (no network)
  # CASE A: a prior custom statusLine + unrelated keys → uninstall restores the OLD statusLine verbatim
  HA="/tmp/sltest-a-$$"; rm -rf "$HA"; mkdir -p "$HA/.claude"
  printf '%s' '{"model":"opus","permissions":{"allow":["Bash"]},"statusLine":{"type":"command","command":"/old/sl.sh","refreshInterval":5}}' > "$HA/.claude/settings.json"
  HOME="$HA" bash "$ROOT/install.sh" >/dev/null 2>&1
  a_installed=$(jq -r '.statusLine.command' "$HA/.claude/settings.json" 2>/dev/null)
  HOME="$HA" bash "$ROOT/uninstall.sh" >/dev/null 2>&1 </dev/null
  assert_contains "A: install repoints statusLine into HOME" "$HA/.claude/statusline.sh" "$a_installed"
  assert_eq "A: uninstall restores prior statusLine verbatim" '"/old/sl.sh"'       "$(jq -c '.statusLine.command' "$HA/.claude/settings.json" 2>/dev/null)"
  assert_eq "A: unrelated model key preserved"                '"opus"'             "$(jq -c '.model' "$HA/.claude/settings.json" 2>/dev/null)"
  assert_eq "A: unrelated permissions preserved"              '{"allow":["Bash"]}' "$(jq -c '.permissions' "$HA/.claude/settings.json" 2>/dev/null)"
  rm -rf "$HA"
  # CASE B: no prior statusLine → uninstall removes just the key, leaves the rest intact
  HB="/tmp/sltest-b-$$"; rm -rf "$HB"; mkdir -p "$HB/.claude"
  printf '%s' '{"model":"opus","permissions":{"allow":["Bash"]}}' > "$HB/.claude/settings.json"
  HOME="$HB" bash "$ROOT/install.sh" >/dev/null 2>&1
  HOME="$HB" bash "$ROOT/uninstall.sh" >/dev/null 2>&1 </dev/null
  assert_eq "B: statusLine key removed (none before install)" 'false'  "$(jq 'has("statusLine")' "$HB/.claude/settings.json" 2>/dev/null)"
  assert_eq "B: unrelated model key preserved"                '"opus"' "$(jq -c '.model' "$HB/.claude/settings.json" 2>/dev/null)"
  rm -rf "$HB"
else
  echo "  (skipped: jq not available to assert settings contents)"
fi

echo "--- Test 37: install fails early & clean when a source file (statusline.sh) is missing"
# A plain `git pull` won't restore a working-tree file the incoming commits didn't touch, so
# statusline.sh can be absent at install time. install.sh must error before backing up or
# editing settings.json — not die on a cryptic mid-run `cp: No such file`. Run a copied
# install.sh from a SCRIPT_DIR that has refresh-pricing.sh but NOT statusline.sh.
SRC37="/tmp/sltest-missing-src-$$"; H37="/tmp/sltest-missing-home-$$"
rm -rf "$SRC37" "$H37"; mkdir -p "$SRC37" "$H37/.claude"
cp "$ROOT/install.sh" "$ROOT/refresh-pricing.sh" "$SRC37/"   # deliberately omit statusline.sh
_settings37='{"model":"opus"}'
printf '%s' "$_settings37" > "$H37/.claude/settings.json"
out37=$(HOME="$H37" bash "$SRC37/install.sh" 2>&1; echo "exit:$?")
assert_contains "names the missing file"          "statusline.sh is missing"       "$out37"
assert_contains "prints the recovery command"     "git checkout -- statusline.sh"  "$out37"
assert_contains "exits non-zero"                  "exit:1"                          "$out37"
assert_eq       "settings.json left untouched"    "$_settings37"  "$(cat "$H37/.claude/settings.json")"
rm -rf "$SRC37" "$H37"

# ─── Corrupt cache_log resilience ────────────────────────────────────────────
echo ""
echo "=== corrupt cache_log resilience ==="

echo "--- Test 38: a poisoned cache_log entry can't wedge the ctx display"
# An old/garbled statusline.sh meeting a newer stdin schema wrote bogus values into the ctx
# columns of cache_log (e.g. a 18-digit "percentage"). The per-model ctx override trusted it,
# so the live status line showed `ctx 251782361782363775%/…` until /tmp was cleared by hand.
# The read-path guard must IGNORE such an entry (ctx falls back to the parsed stdin value), and
# the prune-path must PURGE it on the next turn.
_pstdin() { printf '{"session_id":"%s","transcript_path":"/dev/null","model":{"id":"claude-opus-4-8","display_name":"Opus 4.8"},"context_window":{"context_window_size":1000000,"current_usage":{"input_tokens":2,"output_tokens":5951,"cache_creation_input_tokens":5000,"cache_read_input_tokens":242636},"used_percentage":23}}' "$1"; }
_NOW=$(date +%s)
_POISON="${_NOW} 0 5000 claude-opus-4-8 242636 251782361782363775 242484 0 claude-opus-4-8 242636"
# (a) poison present, turn-gate suppressed → read-path guard ignores it, ctx from stdin (23%)
SID38a="test-poison-read-$$"; SDIR38a="/tmp/claude_session_${SID38a}"; rm -rf "$SDIR38a"; mkdir -p "$SDIR38a"
echo "5951:${_NOW}" > "$SDIR38a/last_api.ts"      # tok_out 5951 matches → no new turn
echo "$_POISON" > "$SDIR38a/cache_log.txt"
out38a=$(_pstdin "$SID38a" | bash "$SCRIPT" 2>/dev/null | strip_ansi | head -1)
assert_contains     "read-path: ctx falls back to stdin (23%)"   "ctx 23%"               "$out38a"
assert_not_contains "read-path: bogus 18-digit pct gone"         "251782361782363775"    "$out38a"
assert_not_contains "read-path: leaked model token gone"         "claude-opus-4-8 242636" "$out38a"
rm -rf "$SDIR38a"
# (b) poison present, new turn fires → prune-path drops the corrupt line
SID38b="test-poison-prune-$$"; SDIR38b="/tmp/claude_session_${SID38b}"; rm -rf "$SDIR38b"; mkdir -p "$SDIR38b"
echo "1:1" > "$SDIR38b/last_api.ts"               # tok_out 5951 != 1 → new turn
echo "$_POISON" > "$SDIR38b/cache_log.txt"
_pstdin "$SID38b" | bash "$SCRIPT" >/dev/null 2>&1
cl38=$(cat "$SDIR38b/cache_log.txt" 2>/dev/null)
assert_not_contains "prune-path: poison line purged"       "251782361782363775" "$cl38"
assert_contains     "prune-path: clean fresh entry written" "claude-opus 247636 23 1000" "$cl38"
rm -rf "$SDIR38b"

# ─── Per-model TTL after a mid-session model switch ──────────────────────────
echo ""
echo "=== ttl after mid-session model switch ==="

echo "--- Test 39: cache_log tag comes from live stdin, tier from the active model's own line"
# Long-lived sessions switched Opus→Fable mid-session showed "~ttl 4:59(0)": entries were
# tagged with the TRANSCRIPT's last assistant model (stale — appends lag stdin by whole
# turns, and pre-switch turns belong to the old model), so the reader filtering by the
# active model matched nothing → 5m default tier, zero cached. The tag must come from the
# same stdin-derived family prefix the reader filters by, and the 5m/1h split must be read
# from the newest transcript line OF THAT FAMILY, not whatever model wrote last.
T39="/tmp/sltest-switch-$$.jsonl"; SID39="test-switch-$$"; SDIR39="/tmp/claude_session_${SID39}"
rm -rf "$SDIR39"
cat > "$T39" <<'EOF'
{"type":"assistant","message":{"model":"claude-fable-5","role":"assistant","content":[],"usage":{"input_tokens":2,"cache_creation_input_tokens":4242,"cache_read_input_tokens":100,"output_tokens":50,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":4242}}},"uuid":"t39-a"}
{"type":"assistant","message":{"model":"claude-opus-4-8","role":"assistant","content":[],"usage":{"input_tokens":5,"cache_creation_input_tokens":777,"cache_read_input_tokens":50,"output_tokens":60,"cache_creation":{"ephemeral_5m_input_tokens":777,"ephemeral_1h_input_tokens":0}}},"uuid":"t39-b"}
EOF
_swstdin() { printf '{"session_id":"%s","transcript_path":"%s","model":{"id":"claude-fable-5[1m]","display_name":"Fable 5"},"cost":{"total_cost_usd":1.0},"context_window":{"context_window_size":1000000,"used_percentage":23,"current_usage":{"input_tokens":2,"cache_creation_input_tokens":225,"cache_read_input_tokens":340000,"output_tokens":%s}}}' "$SID39" "$T39" "$1"; }
out39=$(_swstdin 416 | bash "$SCRIPT" 2>/dev/null | strip_ansi | head -1)
cl39=$(cat "$SDIR39/cache_log.txt" 2>/dev/null)
assert_contains     "entry tagged with active family, not transcript" " claude-fable " "$cl39"
assert_not_contains "no opus tag despite opus trailing line"          "claude-opus"    "$cl39"
assert_eq "cw1h from the fable line (not opus's 5m 777)" "4242" "$(printf '%s' "$cl39" | awk 'END{print $3}')"
_ttl39=$(printf '%s' "$out39" | grep -oE '[0-9]+:[0-9]{2}:[0-9]{2}' | head -1)
assert_eq       "1h-tier h:mm:ss countdown shown" "1" "$([ -n "$_ttl39" ] && echo 1 || echo 0)"
assert_contains "cached amount shown, not (0)"    "(340k)" "$out39"
assert_not_contains "the 4:59(0) failure mode is gone" "(0)" "$out39"
# Same stdin again → marker matches → gate closed, no duplicate entry
_swstdin 416 | bash "$SCRIPT" >/dev/null 2>&1
assert_eq "gate closed on re-render (single entry)" "1" "$(wc -l < "$SDIR39/cache_log.txt" | tr -d ' ')"

echo "--- Test 40: turn marker commits AFTER cache_log (killed render = plain retry)"
# Giant-session renders get killed mid-run. The marker (last_api.ts) is what closes the
# turn gate, so committing it first recorded the turn as done while its cache_log entry
# was lost — the gate never refired and ttl froze at expired(0) (observed live: state dir
# with last_api.ts present and cache_log.txt never created). Marker must commit last.
_ln_cl=$(grep -nF 'cache_log.txt.tmp"' "$SCRIPT" | head -1 | cut -d: -f1)
_ln_mk=$(grep -nF 'echo "${tok_out}:${now}:${_cc_now}"' "$SCRIPT" | head -1 | cut -d: -f1)
assert_eq "marker write is after cache_log write in the gate" "1" \
  "$([ -n "$_ln_cl" ] && [ -n "$_ln_mk" ] && [ "$_ln_mk" -gt "$_ln_cl" ] && echo 1 || echo 0)"
# Functional: losing the marker (killed render) makes the gate refire and rewrite the turn
rm -f "$SDIR39/last_api.ts"
_swstdin 416 | bash "$SCRIPT" >/dev/null 2>&1
assert_eq "gate refires when marker is missing (retry)" "2" "$(wc -l < "$SDIR39/cache_log.txt" | tr -d ' ')"
assert_contains "marker rewritten on retry" "416:" "$(cat "$SDIR39/last_api.ts" 2>/dev/null)"
rm -rf "$SDIR39" "$T39"

echo "--- Test 41: Σ regen is throttled — skip when current or in flight, redo orphans"
# Every regen rescans every JSONL (hundreds of MB in long sessions) and the gate fires
# several times per streaming turn: naive respawning stacked concurrent full-corpus scans
# (a plausible WSL killer) and a killed regen left a 0-byte .tmp decoy forever.
T41="/tmp/sltest-throttle-$$.jsonl"; SID41="test-throttle-$$"; SDIR41="/tmp/claude_session_${SID41}"
rm -rf "$SDIR41"
printf '%s\n' '{"type":"assistant","message":{"model":"claude-fable-5","role":"assistant","content":[],"usage":{"input_tokens":9,"cache_creation_input_tokens":10,"cache_read_input_tokens":11,"output_tokens":12,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":10}}},"uuid":"t41-a"}' > "$T41"
_thstdin() { printf '{"session_id":"%s","transcript_path":"%s","model":{"id":"claude-fable-5","display_name":"Fable 5"},"cost":{"total_cost_usd":1.0},"context_window":{"context_window_size":1000000,"used_percentage":10,"current_usage":{"input_tokens":2,"cache_creation_input_tokens":1,"cache_read_input_tokens":1,"output_tokens":%s}}}' "$SID41" "$T41" "$1"; }
MB41="$SDIR41/model_breakdown.txt"
# (a) stale breakdown → regen runs (background: poll briefly for the mv)
_thstdin 100 | bash "$SCRIPT" >/dev/null 2>&1
_i=0; while [ $_i -lt 30 ] && [ ! -s "$MB41" ]; do sleep 0.1; _i=$((_i+1)); done
assert_contains "regen produced the breakdown" "claude-fable-5" "$(cat "$MB41" 2>/dev/null)"
# (b) breakdown newer than transcript, no subagents → regen skipped entirely
touch -t 202001010000 "$T41"
printf '%s\n' "SENTINEL-KEEP 1 2 3 4 5 6 7" > "$MB41"
_thstdin 200 | bash "$SCRIPT" >/dev/null 2>&1
sleep 0.7
assert_contains "breakdown untouched when already current" "SENTINEL-KEEP" "$(cat "$MB41" 2>/dev/null)"
assert_eq       "no regen scratch spawned" "0" "$(ls "$MB41".tmp* 2>/dev/null | wc -l | tr -d ' ')"
# (c) fresh scratch (regen in flight) blocks a second spawn
touch "$T41"; touch -t 202001010000 "$MB41"
: > "$MB41.tmp.99999"
_thstdin 300 | bash "$SCRIPT" >/dev/null 2>&1
sleep 0.7
assert_contains "in-flight scratch blocks respawn (sentinel kept)" "SENTINEL-KEEP" "$(cat "$MB41" 2>/dev/null)"
assert_eq       "in-flight scratch left alone"                     "1" "$([ -e "$MB41.tmp.99999" ] && echo 1 || echo 0)"
# (d) old orphaned scratch (killed regen) — both unique and legacy bare .tmp — is purged, regen redone
touch -t 202001010000 "$MB41.tmp.99999"
: > "$MB41.tmp"; touch -t 202001010000 "$MB41.tmp"
_thstdin 400 | bash "$SCRIPT" >/dev/null 2>&1
_i=0; while [ $_i -lt 30 ] && ! grep -q 'claude-fable-5' "$MB41" 2>/dev/null; do sleep 0.1; _i=$((_i+1)); done
assert_contains "orphans purged, breakdown regenerated" "claude-fable-5" "$(cat "$MB41" 2>/dev/null)"
assert_eq "unique orphan swept" "0" "$([ -e "$MB41.tmp.99999" ] && echo 1 || echo 0)"
assert_eq "legacy bare .tmp orphan swept" "0" "$([ -e "$MB41.tmp" ] && echo 1 || echo 0)"
# (e) subagent JSONL growth re-arms regen even when the parent transcript is untouched
# (fleets write subagents/**/agent-*.jsonl without a parent append; their cost must fold into Σ)
SUB41="${T41%.jsonl}/subagents"
mkdir -p "$SUB41"
printf '%s\n' '{"type":"assistant","message":{"model":"claude-opus-4-8","role":"assistant","content":[],"usage":{"input_tokens":7,"cache_creation_input_tokens":8,"cache_read_input_tokens":9,"output_tokens":13,"cache_creation":{"ephemeral_5m_input_tokens":8,"ephemeral_1h_input_tokens":0}}},"uuid":"t41-sub"}' > "$SUB41/agent-sub.jsonl"
touch -t 202001010000 "$T41" "$MB41"   # parent and breakdown equally old — only the subagent is new
_thstdin 500 | bash "$SCRIPT" >/dev/null 2>&1
_i=0; while [ $_i -lt 30 ] && ! grep -q 'claude-opus-4-8' "$MB41" 2>/dev/null; do sleep 0.1; _i=$((_i+1)); done
assert_contains "subagent growth re-armed the regen" "claude-opus-4-8" "$(cat "$MB41" 2>/dev/null)"
assert_contains "parent still folded in alongside"   "claude-fable-5"  "$(cat "$MB41" 2>/dev/null)"
rm -rf "$SDIR41" "$T41" "${T41%.jsonl}"

# ─── CC 2.1.2xx: NUL padding, iterations[], idle probe, tier inheritance ─────
echo ""
echo "=== CC 2.1.2xx regressions ==="

echo "--- Test 42: NUL crash-padding can't hide transcript lines from grep"
# Host crashes (WSL) leave zero-fill padding blocks inside transcripts. GNU grep flips
# to binary mode at the first NUL and SUPPRESSES every later match: the ttl read
# returned lines from BEFORE the padding (observed live: a month-stale line won a fresh
# read), and a compact_boundary logged after a NUL block became invisible. grep -a fixes both.
T42="/tmp/sltest-nul-$$.jsonl"; SID42="test-nul-$$"; SDIR42="/tmp/claude_session_${SID42}"
rm -rf "$SDIR42"
printf '%s\n' '{"type":"assistant","message":{"model":"claude-fable-5","role":"assistant","content":[],"usage":{"input_tokens":1,"cache_creation_input_tokens":1111,"cache_read_input_tokens":10,"output_tokens":5,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":1111}}},"uuid":"t42-a"}' > "$T42"
head -c 512 /dev/zero >> "$T42"; printf '\n' >> "$T42"
printf '%s\n' '{"type":"assistant","message":{"model":"claude-fable-5","role":"assistant","content":[],"usage":{"input_tokens":2,"cache_creation_input_tokens":2222,"cache_read_input_tokens":20,"output_tokens":6,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":2222}}},"uuid":"t42-b"}' >> "$T42"
printf '{"session_id":"%s","transcript_path":"%s","model":{"id":"claude-fable-5","display_name":"Fable 5"},"cost":{"total_cost_usd":1.0},"context_window":{"context_window_size":1000000,"used_percentage":15,"current_usage":{"input_tokens":2,"cache_creation_input_tokens":100,"cache_read_input_tokens":50000,"output_tokens":42}}}' "$SID42" "$T42" \
  | bash "$SCRIPT" >/dev/null 2>&1
assert_eq "ttl read sees the line AFTER the NUL block (cw1h=2222)" "2222" \
  "$(awk 'END{print $3}' "$SDIR42/cache_log.txt" 2>/dev/null)"
rm -rf "$SDIR42" "$T42"
# compact_boundary behind a NUL block must still be found (post-compact ctx recovery)
T42b="/tmp/sltest-nulb-$$.jsonl"; SID42b="test-nulb-$$"; SDIR42b="/tmp/claude_session_${SID42b}"
rm -rf "$SDIR42b"; mkdir -p "$SDIR42b"
_now42=$(date +%s)
_iso42=$(date -u -d "@${_now42}" +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null || \
         date -u -r "${_now42}" +"%Y-%m-%dT%H:%M:%S.000Z")
printf '%s\n' '{"type":"user","message":{"role":"user","content":"hi"},"uuid":"t42b-u"}' > "$T42b"
head -c 512 /dev/zero >> "$T42b"; printf '\n' >> "$T42b"
_boundary "$_iso42" >> "$T42b"
echo "9:${_now42}:1.0" > "$SDIR42b/last_api.ts"   # gate closed: recovery path only
out42b=$(printf '{"session_id":"%s","transcript_path":"%s","model":{"id":"claude-fable-5","display_name":"Fable 5"},"cost":{"total_cost_usd":1.0},"context_window":{"context_window_size":200000,"used_percentage":0,"current_usage":{"input_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0,"output_tokens":9}}}' "$SID42b" "$T42b" \
  | bash "$SCRIPT" 2>/dev/null | strip_ansi | head -1)
assert_contains "boundary behind NUL still found (ctx recovered 2%)" "ctx 2%" "$out42b"
rm -rf "$SDIR42b" "$T42b"

echo "--- Test 43: iterations[] token sums (multi-pass turns undercounted before)"
# CC ≥~2.1.212 writes usage.iterations[] on turns with internal retries/multi-pass
# calls; the TOP-LEVEL usage fields cover only ONE iteration. First-match extraction
# dropped the rest (observed live: a hidden 202k-token 1h cache write) — harness
# total_cost_usd bills all iterations, so the local Σ ran systematically low.
T43="/tmp/sltest-iter-$$.jsonl"; SID43="test-iter-$$"; SDIR43="/tmp/claude_session_${SID43}"
rm -rf "$SDIR43"
cat > "$T43" <<'EOF'
{"type":"assistant","message":{"model":"claude-fable-5","role":"assistant","content":[],"usage":{"input_tokens":2,"cache_creation_input_tokens":0,"cache_read_input_tokens":130494,"output_tokens":60,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0},"iterations":[{"type":"message","input_tokens":2,"output_tokens":60,"cache_read_input_tokens":130494,"cache_creation_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0}},{"type":"message","input_tokens":2,"output_tokens":8,"cache_read_input_tokens":152709,"cache_creation_input_tokens":822,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":822}}],"speed":"standard"}},"uuid":"t43-a"}
{"type":"assistant","message":{"model":"claude-opus-4-8","role":"assistant","content":[],"usage":{"input_tokens":10,"cache_creation_input_tokens":30,"cache_read_input_tokens":20,"output_tokens":40,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":30},"iterations":[{"type":"message","input_tokens":10,"output_tokens":40,"cache_read_input_tokens":20,"cache_creation_input_tokens":30,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":30}}],"speed":"standard"}},"uuid":"t43-b"}
EOF
bd43=$(run_breakdown "$T43")
assert_contains "2-iteration line summed (in=4 cr=283203 cw1h=822 out=68)" \
  "claude-fable-5 4 283203 0 822 68 0 0" "$bd43"
assert_contains "1-iteration line == top-level (no double count)" \
  "claude-opus-4-8 10 20 0 30 40 0 0" "$bd43"
# End-to-end: the full script path (background regen) must produce the same row
printf '{"session_id":"%s","transcript_path":"%s","model":{"id":"claude-fable-5","display_name":"Fable 5"},"cost":{"total_cost_usd":1.0},"context_window":{"context_window_size":1000000,"used_percentage":10,"current_usage":{"input_tokens":2,"cache_creation_input_tokens":1,"cache_read_input_tokens":1,"output_tokens":111}}}' "$SID43" "$T43" \
  | bash "$SCRIPT" >/dev/null 2>&1
MB43="$SDIR43/model_breakdown.txt"
_i=0; while [ $_i -lt 30 ] && ! grep -q 'claude-fable-5' "$MB43" 2>/dev/null; do sleep 0.1; _i=$((_i+1)); done
assert_contains "script Σ awk sums iterations too" "claude-fable-5 4 283203 0 822 68 0 0" "$(cat "$MB43" 2>/dev/null)"
rm -rf "$SDIR43" "$T43"

echo "--- Test 44: ttl tier survives top-level 0/0 with the 1h write inside iterations[]"
# Multi-iteration lines can report cache_creation {5m:0,1h:0} at top level while a later
# iteration wrote the 1h cache — first-match logged "0 0" and the ttl display flipped to
# the 5m tier/expired against a live 1h cache.
T44="/tmp/sltest-itertier-$$.jsonl"; SID44="test-itertier-$$"; SDIR44="/tmp/claude_session_${SID44}"
rm -rf "$SDIR44"
cat > "$T44" <<'EOF'
{"type":"assistant","message":{"model":"claude-fable-5","role":"assistant","content":[],"usage":{"input_tokens":2,"cache_creation_input_tokens":0,"cache_read_input_tokens":130494,"output_tokens":60,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0},"iterations":[{"type":"message","input_tokens":2,"output_tokens":60,"cache_read_input_tokens":130494,"cache_creation_input_tokens":0,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":0}},{"type":"message","input_tokens":2,"output_tokens":8,"cache_read_input_tokens":152709,"cache_creation_input_tokens":822,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":822}}],"speed":"standard"}},"uuid":"t44-a"}
EOF
out44=$(printf '{"session_id":"%s","transcript_path":"%s","model":{"id":"claude-fable-5","display_name":"Fable 5"},"cost":{"total_cost_usd":1.0},"context_window":{"context_window_size":1000000,"used_percentage":14,"current_usage":{"input_tokens":2,"cache_creation_input_tokens":822,"cache_read_input_tokens":140000,"output_tokens":68}}}' "$SID44" "$T44" \
  | bash "$SCRIPT" 2>/dev/null | strip_ansi | head -1)
assert_eq "cache_log cw1h from iterations (822), not top-level 0" "822" \
  "$(awk 'END{print $3}' "$SDIR44/cache_log.txt" 2>/dev/null)"
_ttl44=$(printf '%s' "$out44" | grep -oE '[0-9]+:[0-9]{2}:[0-9]{2}' | head -1)
assert_eq           "1h-tier h:mm:ss countdown shown" "1" "$([ -n "$_ttl44" ] && echo 1 || echo 0)"
assert_not_contains "not expired against a live 1h cache" "expired" "$out44"
rm -rf "$SDIR44" "$T44"

echo "--- Test 45: idle probe regenerates Σ during background fleets (no turn needed)"
# Background Workflow fleets append subagent JSONLs and bill into the harness total for
# many minutes without a main-loop turn; regen used to fire only inside the turn gate,
# freezing the local Σ (observed live: \$24.71 harness vs \$0.51 local). Idle renders now
# probe at most every 45s, keyed on mb_probe.ts mtime.
T45="/tmp/sltest-idle-$$.jsonl"; SID45="test-idle-$$"; SDIR45="/tmp/claude_session_${SID45}"
rm -rf "$SDIR45"; mkdir -p "$SDIR45"
printf '%s\n' '{"type":"assistant","message":{"model":"claude-fable-5","role":"assistant","content":[],"usage":{"input_tokens":9,"cache_creation_input_tokens":10,"cache_read_input_tokens":11,"output_tokens":12,"cache_creation":{"ephemeral_5m_input_tokens":0,"ephemeral_1h_input_tokens":10}}},"uuid":"t45-a"}' > "$T45"
_now45=$(date +%s)
echo "700:${_now45}:1.0" > "$SDIR45/last_api.ts"   # marker matches stdin → gate closed
_idstdin() { printf '{"session_id":"%s","transcript_path":"%s","model":{"id":"claude-fable-5","display_name":"Fable 5"},"cost":{"total_cost_usd":1.0},"context_window":{"context_window_size":1000000,"used_percentage":10,"current_usage":{"input_tokens":2,"cache_creation_input_tokens":1,"cache_read_input_tokens":1,"output_tokens":700}}}' "$SID45" "$T45"; }
MB45="$SDIR45/model_breakdown.txt"
# (a) no probe file → idle render probes immediately and builds the breakdown
_idstdin | bash "$SCRIPT" >/dev/null 2>&1
_i=0; while [ $_i -lt 30 ] && ! grep -q 'claude-fable-5' "$MB45" 2>/dev/null; do sleep 0.1; _i=$((_i+1)); done
assert_contains "idle render built the breakdown (gate closed)" "claude-fable-5" "$(cat "$MB45" 2>/dev/null)"
assert_eq       "probe marker written" "1" "$([ -e "$SDIR45/mb_probe.ts" ] && echo 1 || echo 0)"
# (b) fresh probe → no rescan even though the breakdown is stale
printf '%s\n' "SENTINEL-45 1 2 3 4 5 6 7" > "$MB45"
touch -t 202001010000 "$MB45"   # transcript newer than breakdown → regen WOULD fire if probed
_idstdin | bash "$SCRIPT" >/dev/null 2>&1
sleep 0.7
assert_contains "fresh probe blocks the rescan" "SENTINEL-45" "$(cat "$MB45" 2>/dev/null)"
# (c) aged probe → rescan runs and folds in new subagent fleet data
SUB45="${T45%.jsonl}/subagents"
mkdir -p "$SUB45"
printf '%s\n' '{"type":"assistant","message":{"model":"claude-opus-4-8","role":"assistant","content":[],"usage":{"input_tokens":7,"cache_creation_input_tokens":8,"cache_read_input_tokens":9,"output_tokens":13,"cache_creation":{"ephemeral_5m_input_tokens":8,"ephemeral_1h_input_tokens":0}}},"uuid":"t45-sub"}' > "$SUB45/agent-fleet.jsonl"
touch -t 202001010000 "$SDIR45/mb_probe.ts"
_idstdin | bash "$SCRIPT" >/dev/null 2>&1
_i=0; while [ $_i -lt 30 ] && ! grep -q 'claude-opus-4-8' "$MB45" 2>/dev/null; do sleep 0.1; _i=$((_i+1)); done
assert_contains "aged probe re-armed regen (fleet cost folded in)" "claude-opus-4-8" "$(cat "$MB45" 2>/dev/null)"
rm -rf "$SDIR45" "$T45" "${T45%.jsonl}"

echo "--- Test 46: 0/0 whiff inherits the previous tier instead of flipping to 5m"
# The gate can fire before the new model's first line is flushed (or on a pure cache-hit
# turn): the family grep finds nothing and a raw "0 0" entry flipped the reader to the
# 5m countdown against a live 1h cache (observed live at session starts/model switches).
T46="/tmp/sltest-whiff-$$.jsonl"; SID46="test-whiff-$$"; SDIR46="/tmp/claude_session_${SID46}"
rm -rf "$SDIR46"; mkdir -p "$SDIR46"
printf '%s\n' '{"type":"assistant","message":{"model":"claude-opus-4-8","role":"assistant","content":[],"usage":{"input_tokens":5,"cache_creation_input_tokens":777,"cache_read_input_tokens":50,"output_tokens":60,"cache_creation":{"ephemeral_5m_input_tokens":777,"ephemeral_1h_input_tokens":0}}},"uuid":"t46-x"}' > "$T46"
_now46=$(date +%s)
echo "$((_now46 - 60)) 0 500 claude-fable 99000 10 1000" > "$SDIR46/cache_log.txt"
_whstdin() { printf '{"session_id":"%s","transcript_path":"%s","model":{"id":"claude-fable-5","display_name":"Fable 5"},"cost":{"total_cost_usd":1.0},"context_window":{"context_window_size":1000000,"used_percentage":10,"current_usage":{"input_tokens":2,"cache_creation_input_tokens":1,"cache_read_input_tokens":99000,"output_tokens":%s}}}' "$1" "$2" "$3"; }
out46=$(_whstdin "$SID46" "$T46" 77 | bash "$SCRIPT" 2>/dev/null | strip_ansi | head -1)
assert_eq "whiffed entry inherited cw1h=500" "500" \
  "$(awk 'END{print $3}' "$SDIR46/cache_log.txt" 2>/dev/null)"
_ttl46=$(printf '%s' "$out46" | grep -oE '[0-9]+:[0-9]{2}:[0-9]{2}' | head -1)
assert_eq "1h tier kept on whiff (h:mm:ss shown)" "1" "$([ -n "$_ttl46" ] && echo 1 || echo 0)"
rm -rf "$SDIR46" "$T46"
# (b) entries from BEFORE the last /compact are NOT inherited — that cache is dead
T46b="/tmp/sltest-whiffb-$$.jsonl"; SID46b="test-whiffb-$$"; SDIR46b="/tmp/claude_session_${SID46b}"
rm -rf "$SDIR46b"; mkdir -p "$SDIR46b"
_now46b=$(date +%s)
_iso46b=$(date -u -d "@$((_now46b - 30))" +"%Y-%m-%dT%H:%M:%S.000Z" 2>/dev/null || \
          date -u -r "$((_now46b - 30))" +"%Y-%m-%dT%H:%M:%S.000Z")
printf '%s\n' '{"type":"assistant","message":{"model":"claude-opus-4-8","role":"assistant","content":[],"usage":{"input_tokens":5,"cache_creation_input_tokens":777,"cache_read_input_tokens":50,"output_tokens":60,"cache_creation":{"ephemeral_5m_input_tokens":777,"ephemeral_1h_input_tokens":0}}},"uuid":"t46b-x"}' > "$T46b"
_boundary "$_iso46b" >> "$T46b"
echo "$((_now46b - 120)) 0 500 claude-fable 99000 10 1000" > "$SDIR46b/cache_log.txt"
_whstdin "$SID46b" "$T46b" 88 | bash "$SCRIPT" >/dev/null 2>&1
assert_eq "pre-compact tier NOT inherited (cw1h stays 0)" "0" \
  "$(awk 'END{print $3}' "$SDIR46b/cache_log.txt" 2>/dev/null)"
rm -rf "$SDIR46b" "$T46b"

# ─── CC 2.1.29x: usage.iterations is [] on every line ────────────────────────
echo ""
echo "=== CC 2.1.29x regressions ==="

echo "--- Test 47: iterations:[] / null / absent all sum the top-level usage"
# CC 2.1.28x+ writes "iterations":[] on every main AND sub-agent assistant line. The
# 2.1.2xx segment rule matched the bare "iterations":[ prefix, so the token segment became
# the literal "iterations":[] and every sum was 0 — the main model's Σ row vanished
# (rows with sum 0 are hidden) and only pre-2.1.28x sub-agent lines survived.
# Runs through statusline.sh itself (production awk), with the fixture's sub-agent dir.
T47="$FIXTURES/jsonl_iterations_empty.jsonl"; SID47="test-iterempty-$$"; SDIR47="/tmp/claude_session_${SID47}"
rm -rf "$SDIR47"
printf '{"session_id":"%s","transcript_path":"%s","model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"},"cost":{"total_cost_usd":1.0},"context_window":{"context_window_size":200000,"used_percentage":33,"current_usage":{"input_tokens":1,"cache_creation_input_tokens":500,"cache_read_input_tokens":66335,"output_tokens":45}}}' "$SID47" "$T47" \
  | bash "$SCRIPT" >/dev/null 2>&1
MB47="$SDIR47/model_breakdown.txt"
_i=0; while [ $_i -lt 30 ] && ! grep -q 'claude-' "$MB47" 2>/dev/null; do sleep 0.1; _i=$((_i+1)); done
mb47=$(cat "$MB47" 2>/dev/null)
assert_contains "main [] + null lines summed (opus row non-zero)" \
  "claude-opus-5-5 6 195787 0 2518 1001 1 0" "$mb47"
assert_contains "2.1.290 sub-agent [] line summed" \
  "claude-sonnet-5 2 32353 1396 0 4277 0 0" "$mb47"
assert_contains "pre-iterations sub-agent line still summed" \
  "claude-haiku-4-5-20251001 5 2000 100 0 50 0 0" "$mb47"
rm -rf "$SDIR47"

echo "--- Test 48: ttl tier read from top level when iterations is []"
# Same root cause in the cache_log tier awk: [] made it log "0 0" for a live 1h write,
# so the ttl countdown fell back to the 5m tier / expired.
T48="/tmp/sltest-iterempty-ttl-$$.jsonl"; SID48="test-iterempty-ttl-$$"; SDIR48="/tmp/claude_session_${SID48}"
rm -rf "$SDIR48"
head -1 "$FIXTURES/jsonl_iterations_empty.jsonl" > "$T48"
printf '{"session_id":"%s","transcript_path":"%s","model":{"id":"claude-opus-5-5","display_name":"Opus 5.5"},"cost":{"total_cost_usd":1.0},"context_window":{"context_window_size":200000,"used_percentage":33,"current_usage":{"input_tokens":2,"cache_creation_input_tokens":818,"cache_read_input_tokens":64317,"output_tokens":836}}}' "$SID48" "$T48" \
  | bash "$SCRIPT" >/dev/null 2>&1
assert_eq "cache_log cw1h=818 from top level when iterations is []" "818" \
  "$(awk 'END{print $3}' "$SDIR48/cache_log.txt" 2>/dev/null)"
rm -rf "$SDIR48" "$T48"

echo "--- Test 49: one API message = one count, keyed on message.id"
# CC writes one JSONL line per content block, all sharing message.id. Sub-agent
# streaming checkpoints repeat input/cache usage with GROWING output_tokens
# (observed 2.1.290: 5, 5, 601), so the (model,in,out) fingerprint let 2-4 copies of
# each call through and inflated input/cache sums 2-4x. Conversely two distinct calls
# with identical small (in,out) were wrongly merged. message.id fixes both.
bd49=$(run_breakdown "$FIXTURES/jsonl_msgid_checkpoints.jsonl")
assert_contains "4 calls, last checkpoint wins (in=8 cr=58297 cw5m=350 out=1724)" \
  "claude-sonnet-5 8 58297 350 0 1724 0 0" "$bd49"

echo "--- Test 50: real 2.1.290 stdin (pretty + compact; mid-session and fresh)"
# Captured from the live CLI 2.1.290 (paths anonymized). New since 2.1.2xx:
# context_window.total_input_tokens/total_output_tokens (must not shadow current_usage),
# a prompt_cache block, and on a fresh session current_usage:null + used_percentage:null
# instead of zeros. rate_limits follows context_window in this sample; the scoping
# keeps rate_limits.*.used_percentage out in either order.
for _v in pretty compact; do
  if [ "$_v" = pretty ]; then _in=$(cat "$FIXTURES/stdin_2.1.290.json")
  else _in=$(tr -d '\n' < "$FIXTURES/stdin_2.1.290.json" | sed 's/  */ /g'); fi
  out50=$(printf '%s' "$_in" | bash "$SCRIPT" 2>/dev/null | strip_ansi | head -1)
  assert_contains "$_v: model Opus 5.5"            "Opus 5.5"            "$out50"
  assert_contains "$_v: ctx 14%/1000k"             "ctx 14%/1000k"       "$out50"
  assert_contains "$_v: harness cost"              "\$17.99"             "$out50"
  assert_contains "$_v: tokens from current_usage" "↑2 +135kr +929w ↓577" "$out50"
done
out50f=$(bash "$SCRIPT" < "$FIXTURES/stdin_2.1.290_fresh.json" 2>/dev/null | strip_ansi | head -1)
assert_contains "fresh (null usage): ctx 0%/1000k" "ctx 0%/1000k" "$out50f"
assert_contains "fresh (null usage): zero tokens"  "↑0 +0r +0w ↓0" "$out50f"
rm -rf /tmp/claude_session_test-stdin290*

echo "--- Test 51: Mythos family — display name, ttl filter, fallback pricing"
# claude-mythos-* ids rendered raw in Σ rows and priced at the $3/$15 unknown default
# whenever the LiteLLM cache was missing. An empty cache file forces the fallback table.
SID51="test-mythos-$$"; SDIR51="/tmp/claude_session_${SID51}"
rm -rf "$SDIR51"; mkdir -p "$SDIR51"
_now51=$(date +%s)
echo "50:${_now51}" > "$SDIR51/last_api.ts"   # turn gate closed: prewritten files survive
echo "$((_now51 - 20)) 0 6801 claude-mythos 73499 7 1000" > "$SDIR51/cache_log.txt"
{
  echo "claude-mythos-5-1 100000 0 0 0 20000 0 0"
  echo "claude-fable-5-1[1m] 1000 0 0 0 1000 0 0"
} > "$SDIR51/model_breakdown.txt"
: > "/tmp/sltest-emptyprice-$$.txt"
out51=$(printf '{"session_id":"%s","transcript_path":"/dev/null","model":{"id":"claude-mythos-5-1","display_name":"Mythos 5.1"},"cost":{"total_cost_usd":1.0},"context_window":{"used_percentage":3,"context_window_size":1000000,"current_usage":{"input_tokens":2,"cache_read_input_tokens":54000,"cache_creation_input_tokens":37,"output_tokens":50}}}' "$SID51" \
  | CLAUDE_STATUSLINE_PRICING_CACHE="/tmp/sltest-emptyprice-$$.txt" bash "$SCRIPT" 2>/dev/null | strip_ansi)
assert_contains "Σ row: claude-mythos-5-1 → Mythos 5.1"   "Mythos 5.1:" "$out51"
assert_contains "Σ row: claude-fable-5-1[1m] → Fable 5.1" "Fable 5.1:"  "$out51"
assert_contains "mythos fallback 10/50 → \$2.00 (not \$0.60)" "\$2.00" "$out51"
assert_contains "ttl uses the claude-mythos family entry (73k)" "(73k)" "$(echo "$out51" | head -1)"
rm -rf "$SDIR51" "/tmp/sltest-emptyprice-$$.txt"

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "==========================================="
echo "  ${PASS} passed  |  ${FAIL} failed"
echo "==========================================="
[ "$FAIL" -eq 0 ]
