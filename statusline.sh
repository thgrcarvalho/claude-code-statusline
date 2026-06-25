#!/bin/bash
# Claude Code status line — model · context % · cost · cache breakdown · per-model totals (incl. sub-agents)
# Dependencies: bash 3.2+, awk, sed, grep (POSIX standard — no jq or python required)
input=$(cat)
export LC_ALL=C   # force period as decimal separator regardless of system locale

# Colors
RESET=$'\033[0m'
BOLD=$'\033[1m'
DIM=$'\033[2m'
WHITE=$'\033[97m'
CYAN=$'\033[36m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
RED=$'\033[91m'
BLUE=$'\033[34m'

# Convert ISO 8601 UTC timestamp to epoch seconds (cross-platform: GNU date and BSD date).
iso_to_epoch() {
  local iso="$1" e
  e=$(date -d "$iso" +%s 2>/dev/null) && [ -n "$e" ] && echo "$e" && return
  local clean="${iso%.*Z}"; clean="${clean%Z}"        # strip fractional seconds + Z for BSD date
  date -j -u -f "%Y-%m-%dT%H:%M:%S" "$clean" +%s 2>/dev/null && return
  echo 0
}
# Extract every stdin field in ONE awk pass (was ~11 grep|sed pipelines ≈ 55 forks per render).
# Handles compact and pretty-printed JSON by joining all input into one buffer, then matching by
# exact key name. display_name/id are scoped to the model section (effort/output_style also carry
# display_name); used_percentage/context_window_size are scoped to the context_window section
# (Claude Code 2.1.187+ added a rate_limits block whose five_hour/seven_day tiers ALSO carry
# used_percentage — a whole-buffer match would grab a rate-limit % whenever rate_limits is
# serialized before context_window). Token keys stay whole-buffer: current_usage was top-level
# pre-2.1.187 and nested under context_window after, and a buffer-wide first match by exact key
# (the leading quote stops "input_tokens" matching "cache_*_input_tokens" or "total_input_tokens")
# finds the right value under both layouts. Emits 11 newline-separated values in a fixed order —
# empty when a key is absent, so the reads below stay in sync.
{
  read -r model
  read -r model_id
  read -r ctx_pct
  read -r ctx_kb
  read -r cost
  read -r tok_fresh
  read -r tok_cr
  read -r tok_cw
  read -r tok_out
  read -r session_id
  read -r transcript_path
} < <(printf '%s\n' "$input" | awk '
function sval(s, key,   m) {
  if (match(s, "\"" key "\"[[:space:]]*:[[:space:]]*\"[^\"]*\"")) {
    m = substr(s, RSTART, RLENGTH)
    sub("\"" key "\"[[:space:]]*:[[:space:]]*\"", "", m); sub("\".*", "", m)
    return m
  }
  return ""
}
function nval(s, key,   m) {
  if (match(s, "\"" key "\"[[:space:]]*:[[:space:]]*-?[0-9]+\\.?[0-9]*")) {
    m = substr(s, RSTART, RLENGTH); sub(".*:[[:space:]]*", "", m)
    return m
  }
  return ""
}
{ buf = buf $0 " " }
END {
  mi = index(buf, "\"model\"")
  mseg = (mi > 0) ? substr(buf, mi) : ""
  # Scope to the context_window object so a rate_limits.*.used_percentage (CC 2.1.187+)
  # can never win. index() finds the real "context_window" key, not "context_window_size"
  # (the trailing quote in the search string stops that), and substr from there excludes any
  # rate_limits block serialized earlier. Falls back to the whole buffer when the key is
  # absent, preserving pre-2.1.187 behavior.
  ci = index(buf, "\"context_window\"")
  cwseg = (ci > 0) ? substr(buf, ci) : buf
  size = nval(cwseg, "context_window_size")
  print sval(mseg, "display_name")
  print sval(mseg, "id")
  print nval(cwseg, "used_percentage")
  print (size == "" ? "" : int(size / 1000))
  print nval(buf, "total_cost_usd")
  print nval(buf, "input_tokens")
  print nval(buf, "cache_read_input_tokens")
  print nval(buf, "cache_creation_input_tokens")
  print nval(buf, "output_tokens")
  print sval(buf, "session_id")
  print sval(buf, "transcript_path")
}
')

model="${model:-?}"
ctx_pct="${ctx_pct:-0}"
ctx_kb="${ctx_kb:-0}"
cost="${cost:-0}"
tok_fresh="${tok_fresh:-0}"
tok_cr="${tok_cr:-0}"
tok_cw="${tok_cw:-0}"
tok_out="${tok_out:-0}"
session_id="${session_id:-default}"

# Fresh session: harness used_percentage is stale until the first API call.
# When all current_usage tokens are 0, no turn has completed — treat as 0.
if [ "$tok_out" = "0" ] && [ "$tok_fresh" = "0" ] && [ "$tok_cr" = "0" ]; then
  ctx_pct=0
fi
ctx_pct=$(echo "$ctx_pct" | awk '{printf "%d", $1 + 0.5}')

# Derive a friendly display name from an API model ID.
# Handles all current and future Claude models without hardcoding versions.
model_display() {
  local id="$1" family ver minor
  id="${id%%\[*}"   # strip context-beta suffix: claude-fable-5[1m] → claude-fable-5

  # New-gen IDs: claude-{family}-{major}[-minor][-YYYYMMDD][...]
  # e.g. claude-opus-4-7-20260416  →  Opus 4.7
  if [[ "$id" =~ ^claude-(opus|sonnet|haiku|fable)-([0-9].*)$ ]]; then
    family="${BASH_REMATCH[1]}"
    ver="${BASH_REMATCH[2]}"
    ver=$(echo "$ver" | sed -E 's/-[0-9]{8}.*//')  # strip date suffix
    ver="${ver//-/.}"                                # hyphens → dots
    case "$family" in opus) family="Opus";; sonnet) family="Sonnet";; haiku) family="Haiku";; fable) family="Fable";; esac
    echo "$family $ver"
    return
  fi

  # Old-gen IDs: claude-3[-minor]-{family}[-YYYYMMDD]
  # e.g. claude-3-5-sonnet-20241022  →  Sonnet 3.5
  if [[ "$id" =~ ^claude-3(-([0-9]+))?-(opus|sonnet|haiku) ]]; then
    minor="${BASH_REMATCH[2]}"
    family="${BASH_REMATCH[3]}"
    case "$family" in opus) family="Opus";; sonnet) family="Sonnet";; haiku) family="Haiku";; esac
    [ -n "$minor" ] && echo "$family 3.$minor" || echo "$family 3"
    return
  fi

  # Already a display name from harness JSON ("Opus 4.7"), or unknown — pass through
  echo "$id"
}

# Pricing: base_input, output (USD per million tokens)
# Cache prices derived at use-time: read=0.10×, write_5m=1.25×, write_1h=2.00× of base
# Live rates read from /tmp/claude_pricing.txt if refresh-pricing.sh has run (requires jq)
pricing_for() {
  local cache="/tmp/claude_pricing.txt"
  local model_id="$1"
  local norm_id
  norm_id=$(echo "$model_id" | sed -E 's|^anthropic/||; s|\[[^]]*\]$||; s|-[0-9]{8}$||')

  if [ -f "$cache" ]; then
    local rates
    rates=$(grep -m1 "^${norm_id} " "$cache" | awk '{print $2, $3}')
    if [ -n "$rates" ]; then
      echo "$rates"
      return
    fi
  fi

  # Fallback: family pattern match on the original model id.
  # Fable is hardcoded because LiteLLM does not list it yet (checked 2026-06):
  # official rates are $10/$50 per Mtok (docs.anthropic.com/en/docs/about-claude/pricing).
  case "$model_id" in
    *opus*|*Opus*)     echo "5.00 25.00" ;;
    *sonnet*|*Sonnet*) echo "3.00 15.00" ;;
    *haiku*|*Haiku*)   echo "1.00 5.00"  ;;
    *fable*|*Fable*)   echo "10.00 50.00" ;;
    *)                 echo "3.00 15.00" ;;
  esac
}

# Format token count
fmt_tok() {
  local n=$1
  if [ "$n" -ge 1000000 ]; then
    echo "$(echo "$n" | awk '{printf "%.1fM", $1/1000000}')"
  elif [ "$n" -ge 10000 ]; then
    echo "$(echo "$n" | awk '{printf "%dk", int($1/1000+0.5)}')"
  elif [ "$n" -ge 1000 ]; then
    echo "$(echo "$n" | awk '{printf "%.1fk", $1/1000}')"
  else
    echo "$n"
  fi
}

# Format cost
fmt_c() {
  echo "$1" | awk '{
    if ($1 < 0.0001) printf "$0"
    else if ($1 < 0.01)  printf "$%.4f", $1
    else if ($1 < 1)     printf "$%.3f", $1
    else                 printf "$%.2f", $1
  }'
}

cost_fmt=$(echo "$cost" | awk '{
  if ($1 < 0.01)      printf "$0.00"
  else if ($1 < 10)   printf "$%.2f", $1
  else if ($1 < 1000) printf "$%.1f", $1
  else                printf "$%.0f", $1
}')

cache_pct=$(echo "$tok_fresh $tok_cr $tok_cw" | awk '{
  total = $1 + $2 + $3
  if (total > 0) printf "%d", ($2 / total) * 100
  else printf "0"
}')

if [ "$ctx_pct" -lt 50 ]; then ctx_color=$GREEN
elif [ "$ctx_pct" -lt 80 ]; then ctx_color=$YELLOW
else ctx_color=$RED; fi

# State dir per session (defined early so the compact-boundary cache below can live here).
STATE_DIR="/tmp/claude_session_${session_id}"
mkdir -p "$STATE_DIR" 2>/dev/null
LAST_STATE="${STATE_DIR}/last_api.ts"
SESSION_COST="${STATE_DIR}/session_cost.txt"
MODEL_BREAKDOWN="${STATE_DIR}/model_breakdown.txt"  # space-delimited: model in cr cw5m cw1h out

# Locate the most recent compact_boundary in the transcript (always, not just when ctx_pct==0).
# Used for ctx% recovery and for the cache_log floor that guards stale pre-compact entries.
# A bare grep would rescan the whole transcript (multi-MB in long sessions) on every 1s render,
# yet the boundary only changes when a compaction occurs. Cache the matched line keyed on the
# transcript's size+mtime and re-scan only when the file changes; idle renders reuse the cache.
_compact_line=""
if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
  _bcache="${STATE_DIR}/compact_boundary.cache"
  _tstat=$(stat -c '%s:%Y' "$transcript_path" 2>/dev/null || stat -f '%z:%m' "$transcript_path" 2>/dev/null)
  _bkey=""; _bval=""
  [ -f "$_bcache" ] && IFS=$'\t' read -r _bkey _bval < "$_bcache"
  if [ -n "$_tstat" ] && [ "$_tstat" = "$_bkey" ]; then
    _compact_line="$_bval"
  else
    _compact_line=$(grep '"subtype":"compact_boundary"' "$transcript_path" 2>/dev/null | tail -1)
    if [ -n "$_tstat" ]; then
      printf '%s\t%s\n' "$_tstat" "$_compact_line" > "${_bcache}.tmp" 2>/dev/null \
        && mv "${_bcache}.tmp" "$_bcache" 2>/dev/null
    fi
  fi
fi

# cache_log floor: any cache_log entry written before the most recent compact is stale —
# /compact rewrites conversation history, which invalidates Anthropic's prompt cache.
compact_floor_ts=0
if [ -n "$_compact_line" ]; then
  _compact_iso=$(echo "$_compact_line" \
    | grep -oE '"timestamp"[[:space:]]*:[[:space:]]*"[^"]*"' \
    | head -1 | grep -oE '"[^"]*"$' | tr -d '"')
  [ -n "$_compact_iso" ] && compact_floor_ts=$(iso_to_epoch "$_compact_iso")
fi

# Post-/compact ctx% recovery: harness resets used_percentage to 0, but the JSONL records
# the real surviving context size in compact_boundary.compactMetadata.postTokens.
ctx_post=""
if [ "$ctx_pct" = "0" ] && [ -n "$_compact_line" ]; then
  ctx_post=$(echo "$_compact_line" \
    | grep -oE '"postTokens"[[:space:]]*:[[:space:]]*[0-9]+' \
    | grep -oE '[0-9]+$')
fi

if [ -n "$ctx_post" ] && [ "$ctx_post" -gt 0 ]; then
  ctx_pct_calc=$(awk -v p="$ctx_post" -v w="${ctx_kb}000" 'BEGIN {
    if (w > 0) printf "%d", (p * 100) / w; else printf "0"
  }')
  if [ "$ctx_pct_calc" -lt 50 ]; then ctx_color=$GREEN
  elif [ "$ctx_pct_calc" -lt 80 ]; then ctx_color=$YELLOW
  else ctx_color=$RED; fi
  ctx_str="ctx ${ctx_color}${ctx_pct_calc}%${RESET}${DIM}/${ctx_kb}k${RESET}"
else
  ctx_str="ctx ${ctx_color}${ctx_pct}%${RESET}${DIM}/${ctx_kb}k${RESET}"
fi

if [ "$cache_pct" -gt 80 ]; then hit_color=$GREEN
elif [ "$cache_pct" -gt 40 ]; then hit_color=$YELLOW
else hit_color=$RED; fi

now=$(date +%s)

# /compact cost capture. Claude Code folds the /compact summarization cost into
# cost.total_cost_usd (verified empirically: total_cost_usd steps up by the exact
# compaction cost at the render where a new compact_boundary appears). The transcript
# carries no cost fields, so the only source is the live harness total. We track the
# harness total across renders and, when a new compact floor appears, attribute the cost
# rise since the last completed turn to that compaction (see the baseline note below).
# State (single line): "<count> <total_cost> <prev_cost> <prev_floor>"
COMPACT_STATE="${STATE_DIR}/compact_cost.txt"
_cc_now=$(echo "${cost:-0}" | awk '{printf "%.6f", $1+0}')
_cc_floor="${compact_floor_ts:-0}"
compact_count=0; compact_total=0; _cc_prev_cost=""; _cc_prev_floor=""
if [ -f "$COMPACT_STATE" ]; then
  read -r compact_count compact_total _cc_prev_cost _cc_prev_floor < "$COMPACT_STATE"
fi
compact_count="${compact_count:-0}"; compact_total="${compact_total:-0}"
# Only count once we have a prior baseline (don't retroactively price compacts that
# predate this feature — their deltas were never captured). A non-zero floor change
# since the last render means a new compaction just completed.
if [ -n "$_cc_prev_floor" ] && [ "$_cc_floor" != "$_cc_prev_floor" ] && [ "$_cc_floor" != "0" ]; then
  # Baseline = cost at the last completed turn, not the previous render. A long compaction
  # (seconds to minutes) makes the harness bump total_cost_usd a render or two BEFORE the
  # compact_boundary line lands in the transcript, so the previous render already shows the
  # higher cost and a render-to-render delta collapses to 0. The last *turn* cost is a stable
  # pre-compact anchor — nothing meaningful bills between a turn and a compaction except the
  # compaction itself (plus negligible internal Haiku). LAST_STATE col 3 holds it; fall back
  # to the previous render's cost for pre-upgrade sessions that haven't rewritten LAST_STATE.
  _cc_base=$(cut -d: -f3 "$LAST_STATE" 2>/dev/null)
  [ -z "$_cc_base" ] && _cc_base="${_cc_prev_cost:-$_cc_now}"
  _cc_delta=$(awk -v a="$_cc_now" -v b="$_cc_base" 'BEGIN{d=a-b; if(d<0)d=0; printf "%.6f", d}')
  compact_count=$((compact_count + 1))
  compact_total=$(awk -v a="$compact_total" -v b="$_cc_delta" 'BEGIN{printf "%.6f", a+b}')
  # Advance the turn baseline (LAST_STATE col 3) to the post-compaction cost so a *subsequent*
  # compaction with no real turn in between measures only its own incremental cost, not this
  # one's again. Preserve cols 1-2 (tok_out, ts) so turn detection and the TTL base are intact.
  if [ -f "$LAST_STATE" ]; then
    _ls1=$(cut -d: -f1 "$LAST_STATE" 2>/dev/null); _ls2=$(cut -d: -f2 "$LAST_STATE" 2>/dev/null)
    echo "${_ls1:-0}:${_ls2:-$now}:${_cc_now}" > "${LAST_STATE}.tmp" && mv "${LAST_STATE}.tmp" "$LAST_STATE"
  fi
fi
echo "${compact_count} ${compact_total} ${_cc_now} ${_cc_floor}" > "${COMPACT_STATE}.tmp" \
  && mv "${COMPACT_STATE}.tmp" "$COMPACT_STATE"

prev_tout="-1"
prev_ts=$now
if [ -f "$LAST_STATE" ]; then
  prev_tout=$(cut -d: -f1 "$LAST_STATE" 2>/dev/null)
  prev_ts=$(cut -d: -f2 "$LAST_STATE" 2>/dev/null)
fi

if [ "$tok_out" -gt 0 ] && [ "$tok_out" != "$prev_tout" ]; then
  echo "${tok_out}:${now}:${_cc_now}" > "$LAST_STATE"   # col 3 = harness cost at this turn (compact baseline)
  prev_ts=$now

  # Per-model breakdown from JSONL files (parent + sub-agents)
  if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
    session_uuid=$(basename "$transcript_path" .jsonl)
    project_dir=$(dirname "$transcript_path")
    subagent_dir="${project_dir}/${session_uuid}/subagents"

    # Collect all files: parent JSONL + sub-agent JSONLs (recursively).
    # Subagents nest: inline Agent-tool subagents land in subagents/agent-*.jsonl,
    # while ultracode/Workflow fleets land in subagents/workflows/wf_*/agent-*.jsonl.
    # A non-recursive glob misses the nested fleets, so their (often large) cost never
    # folds into the per-model Σ. find(1) catches every depth and is portable (BSD + GNU).
    jsonl_files=("$transcript_path")
    if [ -d "$subagent_dir" ]; then
      while IFS= read -r f; do
        [ -n "$f" ] && jsonl_files+=("$f")
      done < <(find "$subagent_dir" -type f -name 'agent-*.jsonl' 2>/dev/null)
    fi

    # Parse JSONL with awk: deduplicate by uuid, group by model, sum token counts
    # Output format: "<model> <in> <cr> <cw5m> <cw1h> <out>" — one line per model
    (awk '
/\"role\":\"assistant\"/ && /\"usage\"/ && /\"model\":\"claude-/ {
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

  # Skip streaming checkpoints: Claude Code writes the same API response to the JSONL
  # multiple times (different UUIDs) as it streams. Consecutive entries sharing the same
  # (model, input_tokens, output_tokens) fingerprint are duplicates — count only the first.
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
' "${jsonl_files[@]}" > "${MODEL_BREAKDOWN}.tmp" 2>/dev/null && \
      mv "${MODEL_BREAKDOWN}.tmp" "$MODEL_BREAKDOWN") &
  fi
  [ -x "${HOME}/.claude/refresh-pricing.sh" ] && "${HOME}/.claude/refresh-pricing.sh" &

  # Snapshot per-model display values at the time of this turn.
  # Written as cols 5-7 in cache_log so the per-model read below returns the
  # correct values for each model even after a model switch with no intervening call.
  cached_now=$((tok_cr + tok_cw))
  turn_ctx_pct=${ctx_pct:-0}
  turn_ctx_kb=${ctx_kb:-0}

  # Record this turn's 5m/1h cache writes in cache_log for alive-cache TTL tracking.
  # Format per line: "<unix_ts> <cw5m> <cw1h> <model_id> <cached_now> <ctx_pct> <ctx_kb>". Entries older than 1h are pruned.
  # Each model (Opus, Sonnet, etc.) has a separate cache at Anthropic; we tag entries
  # with the model so that alive sums are filtered to the currently active model only.
  # Tag fallback: stdin model.id may carry a [1m] context-beta suffix the transcript id
  # lacks; strip it so every cache_log entry for the model shares one comparable tag.
  turn_cw5m=0; turn_cw1h=0; turn_model_id="${model_id%%\[*}"; turn_model_id="${turn_model_id:-unknown}"
  if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
    _last=$(grep '"role":"assistant"' "$transcript_path" 2>/dev/null | grep '"usage"' | tail -1)
    if echo "$_last" | grep -qF '"ephemeral_5m_input_tokens"' 2>/dev/null; then
      _v=$(echo "$_last" | grep -oE '"ephemeral_5m_input_tokens":[0-9]+' | head -1)
      turn_cw5m=${_v##*:}; turn_cw5m=${turn_cw5m:-0}
    fi
    if echo "$_last" | grep -qF '"ephemeral_1h_input_tokens"' 2>/dev/null; then
      _v=$(echo "$_last" | grep -oE '"ephemeral_1h_input_tokens":[0-9]+' | head -1)
      turn_cw1h=${_v##*:}; turn_cw1h=${turn_cw1h:-0}
    fi
    _m=$(echo "$_last" | grep -oE '"model":"claude-[^"]*"' | head -1 | grep -oE 'claude-[^"]+')
    [ -n "$_m" ] && turn_model_id="$_m"
  fi
  {
    while IFS=' ' read -r _ts _5 _1 _m _c _cp _ck; do
      # Carry forward only well-formed entries within the last hour. Dropping malformed lines
      # here purges any poison a garbled parser wrote, so the corruption can't persist past the
      # next turn. Every numeric column must be a plain integer (a multi-token _ck — extra
      # trailing fields from a corrupt line — contains a space and fails this), the model tag
      # must be present, and ctx must be in range.
      [ -z "$_m" ] && continue
      _bad=0
      for _v in "$_ts" "$_5" "$_1" "$_c" "$_cp" "$_ck"; do
        case "$_v" in ''|*[!0-9]*) _bad=1; break ;; esac
      done
      [ "$_bad" = 1 ] && continue
      { [ "$_cp" -le 100 ] && [ "$_ck" -le 100000 ]; } || continue
      [ "$((_ts + 3600 - now))" -gt 0 ] && echo "$_ts $_5 $_1 $_m $_c $_cp $_ck"
    done < "${STATE_DIR}/cache_log.txt" 2>/dev/null
    echo "${now} ${turn_cw5m} ${turn_cw1h} ${turn_model_id} ${cached_now} ${turn_ctx_pct} ${turn_ctx_kb}"
  } > "${STATE_DIR}/cache_log.txt.tmp" 2>/dev/null && \
    mv "${STATE_DIR}/cache_log.txt.tmp" "${STATE_DIR}/cache_log.txt" 2>/dev/null
fi

# Find the most recent cache_log entry for the active model.
# Used for (a) per-model TTL timer base and (b) which TTL tier the last write used.
# model_id may be an alias like "opusplan" rather than a real Claude model ID, so
# derive the filter prefix from display_name ("Opus 4.7" → "claude-opus") instead.
case "$model" in
  Opus*)   _cache_filter="claude-opus" ;;
  Sonnet*) _cache_filter="claude-sonnet" ;;
  Haiku*)  _cache_filter="claude-haiku" ;;
  Fable*)  _cache_filter="claude-fable" ;;
  *)       _cache_filter="${model_id%%\[*}" ;;  # best effort for unknown display names;
           # strip a [1m]-style context-beta suffix — the stdin id carries it but the
           # transcript model (used to tag cache_log entries) does not, so an unstripped
           # filter matches no (or only stale fallback-tagged) entries → frozen ttl/ctx.
esac
model_last_ts=0; model_last_is_1h=0; model_last_cached=0
model_last_ctx_pct=""; model_last_ctx_kb=""
if [ -f "${STATE_DIR}/cache_log.txt" ]; then
  while IFS=' ' read -r _ts _5 _1 _m _c _cp _ck; do
    # Skip entries from a different model; skip old 3-column entries (no model tag)
    [ -z "$_m" ] && continue
    # Reject corrupt entries. A garbled parser (e.g. an old statusline.sh meeting a newer
    # stdin schema) can write a bogus huge value here; without this guard such an entry would
    # win the "most recent" test below and wedge the ctx display indefinitely — clearing /tmp
    # was the only recovery. _ts must be a plain integer and not implausibly far in the future.
    case "$_ts" in ''|*[!0-9]*) continue ;; esac
    [ "$_ts" -gt "$((now + 300))" ] && continue
    # Skip entries that predate the last /compact — that cache no longer exists at Anthropic
    [ "$_ts" -lt "$compact_floor_ts" ] && continue
    case "$_m" in
      "${_cache_filter}"*) ;;
      *) continue ;;
    esac
    [ "$_ts" -le "$model_last_ts" ] && continue
    model_last_ts=$_ts
    case "$_1" in ''|*[!0-9]*) model_last_is_1h=0 ;; *) [ "$_1" -gt 0 ] && model_last_is_1h=1 || model_last_is_1h=0 ;; esac
    case "$_c" in ''|*[!0-9]*) model_last_cached=0 ;; *) model_last_cached=$_c ;; esac
    # Adopt stored ctx only when sane: pct in 0..100, kb a plain int within a generous bound.
    # Otherwise leave them empty so the override below is skipped and ctx keeps the freshly
    # parsed stdin value — corrupt state can never clobber a correct live read.
    model_last_ctx_pct=""; model_last_ctx_kb=""
    case "$_cp" in ''|*[!0-9]*) ;; *) [ "$_cp" -le 100 ]    && model_last_ctx_pct=$_cp ;; esac
    case "$_ck" in ''|*[!0-9]*) ;; *) [ "$_ck" -le 100000 ] && model_last_ctx_kb=$_ck ;; esac
  done < "${STATE_DIR}/cache_log.txt"
fi

# Per-model ctx override: use cache_log stored ctx values so switching models in
# opusplan reflects each model's own context immediately without waiting for a new API call.
# Skip when stored ctx_pct=0 — compact or fresh state where the first-pass post-compact
# recovery already produced the correct ctx_str; don't clobber it.
if [ -n "$model_last_ctx_pct" ] && [ "$model_last_ctx_pct" != "0" ] && [ -n "$model_last_ctx_kb" ]; then
  ctx_pct=$model_last_ctx_pct
  ctx_kb=$model_last_ctx_kb
  if [ "$ctx_pct" -lt 50 ]; then ctx_color=$GREEN
  elif [ "$ctx_pct" -lt 80 ]; then ctx_color=$YELLOW
  else ctx_color=$RED; fi
  ctx_str="ctx ${ctx_color}${ctx_pct}%${RESET}${DIM}/${ctx_kb}k${RESET}"
fi

# Per-model TTL: base the countdown on the last cache_log entry for the active model so
# switching models shows the correct elapsed time for that model's cache, not a global one.
# Falls back to prev_ts (most recent overall API call) when the model has no log entries yet.
ttl_base_ts=$model_last_ts
[ "$ttl_base_ts" -eq 0 ] && ttl_base_ts=$prev_ts

# TTL countdown — 5m tier
elapsed=$((now - ttl_base_ts))
remaining=$((300 - elapsed))
cache_color=$GREEN
if [ "$remaining" -le 0 ]; then
  cache_timer="expired"; cache_color=$RED
else
  mins=$((remaining / 60)); secs=$((remaining % 60))
  cache_timer=$(printf "%d:%02d" "$mins" "$secs")
  if [ "$remaining" -lt 60 ]; then cache_color=$RED
  elif [ "$remaining" -lt 120 ]; then cache_color=$YELLOW; fi
fi

# TTL countdown — 1h tier (same timestamp base; shown only when split data available)
remaining_1h=$((3600 - elapsed))
cache_1h_color=$GREEN
if [ "$remaining_1h" -le 0 ]; then
  cache_1h_timer="expired"; cache_1h_color=$RED
else
  h=$((remaining_1h / 3600)); m=$(( (remaining_1h % 3600) / 60 )); s=$((remaining_1h % 60))
  cache_1h_timer=$(printf "%d:%02d:%02d" "$h" "$m" "$s")
  if [ "$remaining_1h" -lt 600 ]; then cache_1h_color=$RED
  elif [ "$remaining_1h" -lt 1200 ]; then cache_1h_color=$YELLOW; fi
fi

# Build TTL display: show how much of the current context is cached and when it expires.
# Use the 1h-tier countdown when the most recent cache write used the 1h tier (common in
# Claude Code), so the timer reflects the actual expiry of the user's cached context.
if [ "$model_last_is_1h" -eq 1 ]; then
  _ttl_timer="$cache_1h_timer"; _ttl_color="$cache_1h_color"
else
  _ttl_timer="$cache_timer"; _ttl_color="$cache_color"
fi
cache_timer_display="${_ttl_color}${_ttl_timer}($(fmt_tok $model_last_cached))${RESET}"

# Top-line cost: show both harness (matches /usage, excludes subagents) and local sum
# (includes subagents, uses LiteLLM rates). Neither is the authoritative Anthropic bill.
local_cost_val=$(cat "$SESSION_COST" 2>/dev/null | tr -d '[:space:]')
have_harness=0; have_local=0
[ -n "$cost" ] && awk -v v="$cost" 'BEGIN{exit !(v+0 > 0)}' 2>/dev/null && have_harness=1
[ -n "$local_cost_val" ] && awk -v v="$local_cost_val" 'BEGIN{exit !(v+0 > 0)}' 2>/dev/null && have_local=1
if [ $have_harness -eq 1 ] && [ $have_local -eq 1 ]; then
  cost_display="${YELLOW}$(fmt_c "$cost")${RESET}${DIM} / ${RESET}${YELLOW}$(fmt_c "$local_cost_val")${RESET}"
elif [ $have_harness -eq 1 ]; then
  cost_display="${YELLOW}$(fmt_c "$cost")${RESET}"
elif [ $have_local -eq 1 ]; then
  cost_display="${YELLOW}$(fmt_c "$local_cost_val")${RESET}"
else
  cost_display="${DIM}\$0.00${RESET}"
fi

sep="${DIM} │ ${RESET}"

# Line 1: current turn
printf "%s%s%s%s" \
  "${BOLD}${CYAN}${model}${RESET}" "${sep}" \
  "${ctx_str}" "${sep}"
printf "%s%s" "$cost_display" "${sep}"
printf "↑${WHITE}%s${RESET} ${GREEN}+%sr${RESET} ${YELLOW}+%sw${RESET} ↓${BLUE}%s${RESET}" \
  "$(fmt_tok $tok_fresh)" "$(fmt_tok $tok_cr)" "$(fmt_tok $tok_cw)" "$(fmt_tok $tok_out)"
printf "%s hit ${hit_color}%s%%${RESET}" "${sep}" "$cache_pct"
printf "%s ~ttl %s\n" "${sep}" "$cache_timer_display"

# NOTE: Σ rows are computed from transcript JSONLs (parent + subagents). They
# WILL NOT match /usage's per-model rows — /usage excludes subagent activity.
# See README "Why the two cost figures differ".
# Lines 2+: per-model totals — read directly from flat-text breakdown (no jq needed)
# Columns: model in cr cw5m cw1h out web fetch
total_cost=0
if [ -f "$MODEL_BREAKDOWN" ] && [ -s "$MODEL_BREAKDOWN" ]; then
  # The Σ rows depend only on model_breakdown.txt (rewritten per-turn) and the pricing file
  # (refreshed at most daily) — yet this loop reran every 1s render, re-deriving pricing and
  # formatting per model. Cache the rendered rows keyed on both files' mtimes; on idle renders
  # reuse the cache. total_cost is persisted in SESSION_COST, which the top-line reads directly,
  # so a cache hit needn't recompute it. stat() the mtime BEFORE reading the file so a concurrent
  # background rewrite can only cause an extra recompute, never a stale row cached under a new key.
  SIGMA_TXT="${STATE_DIR}/sigma_render.txt"
  SIGMA_KEY="${STATE_DIR}/sigma_render.key"
  _mb_m=$(stat -c '%Y' "$MODEL_BREAKDOWN" 2>/dev/null || stat -f '%m' "$MODEL_BREAKDOWN" 2>/dev/null)
  _pr_m=$(stat -c '%Y' /tmp/claude_pricing.txt 2>/dev/null || stat -f '%m' /tmp/claude_pricing.txt 2>/dev/null)
  _sigma_key="${_mb_m:-0}:${_pr_m:-0}"
  if [ -f "$SIGMA_TXT" ] && [ "$(cat "$SIGMA_KEY" 2>/dev/null)" = "$_sigma_key" ]; then
    cat "$SIGMA_TXT"
  else
    _sigma_out=""
    while IFS=' ' read -r m_id m_in m_cr m_cw5m m_cw1h m_out m_web m_fetch; do
      m_web="${m_web:-0}"; m_fetch="${m_fetch:-0}"
      [ "$((m_in + m_cr + m_cw5m + m_cw1h + m_out))" -eq 0 ] && continue
      m_name=$(model_display "$m_id")
      read m_pin m_pout <<< "$(pricing_for "$m_id")"
      m_pcr=$(awk   -v b="$m_pin" 'BEGIN {printf "%.4f", b * 0.10}')
      m_pcw5m=$(awk -v b="$m_pin" 'BEGIN {printf "%.4f", b * 1.25}')
      m_pcw1h=$(awk -v b="$m_pin" 'BEGIN {printf "%.4f", b * 2.00}')
      m_cw_total=$((m_cw5m + m_cw1h))
      m_cost=$(echo "$m_in $m_pin $m_cr $m_pcr $m_cw5m $m_pcw5m $m_cw1h $m_pcw1h $m_out $m_pout $m_web $m_fetch" | awk '{
        web_cost = ($11 + $12) * 0.010
        printf "%.6f", ($1*$2 + $3*$4 + $5*$6 + $7*$8 + $9*$10) / 1000000 + web_cost
      }')
      total_cost=$(awk -v a="$total_cost" -v b="$m_cost" 'BEGIN {printf "%.6f", a+b}')
      ws_suffix=""
      [ "$m_web" -gt 0 ] 2>/dev/null && ws_suffix=" ${DIM}+${m_web}ws${RESET}"
      _sigma_out="${_sigma_out}$(printf "${DIM}Σ ${CYAN}%s${RESET}${DIM}: ↑%s +%sr +%sw ↓%s = ${YELLOW}%s${RESET}%s" \
        "$m_name" \
        "$(fmt_tok $m_in)" "$(fmt_tok $m_cr)" "$(fmt_tok $m_cw_total)" "$(fmt_tok $m_out)" \
        "$(fmt_c $m_cost)" "$ws_suffix")"$'\n'
    done < "$MODEL_BREAKDOWN"
    printf '%s' "$_sigma_out"
    printf '%s' "$_sigma_out" > "${SIGMA_TXT}.tmp" 2>/dev/null && mv "${SIGMA_TXT}.tmp" "$SIGMA_TXT" 2>/dev/null
    echo "$_sigma_key" > "${SIGMA_KEY}.tmp" 2>/dev/null && mv "${SIGMA_KEY}.tmp" "$SIGMA_KEY" 2>/dev/null
    # Write local sum as fallback for when harness omits cost.total_cost_usd
    echo "$total_cost" > "$SESSION_COST"
  fi
fi

# Σ /compact line: cumulative cost of /compact summarizations this session.
# Exact, not estimated — each value is the harness total_cost_usd delta captured
# at the compact boundary (see the /compact cost capture above). Shown only once a
# compaction has occurred while this feature was active.
if [ "${compact_count:-0}" -gt 0 ]; then
  printf "${DIM}Σ ${CYAN}/compact${RESET}${DIM} ×%s: ${YELLOW}%s${RESET}\n" \
    "$compact_count" "$(fmt_c "$compact_total")"
fi
