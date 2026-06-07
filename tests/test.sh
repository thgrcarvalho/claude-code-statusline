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

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "==========================================="
echo "  ${PASS} passed  |  ${FAIL} failed"
echo "==========================================="
[ "$FAIL" -eq 0 ]
