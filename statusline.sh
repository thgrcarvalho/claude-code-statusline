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

# Extract a top-level string field (unambiguous keys like session_id, transcript_path)
_str()  { echo "$input" | grep "\"$1\"" | head -1 | sed -E 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/'; }
# Extract a string field scoped to a parent section (avoids matching duplicate keys in other sections)
_sstr() { echo "$input" | grep -A20 "\"$1\"[[:space:]]*:" | grep "\"$2\"" | head -1 | sed -E 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/'; }
# Convert ISO 8601 UTC timestamp to epoch seconds (cross-platform: GNU date and BSD date).
iso_to_epoch() {
  local iso="$1" e
  e=$(date -d "$iso" +%s 2>/dev/null) && [ -n "$e" ] && echo "$e" && return
  local clean="${iso%.*Z}"; clean="${clean%Z}"        # strip fractional seconds + Z for BSD date
  date -j -u -f "%Y-%m-%dT%H:%M:%S" "$clean" +%s 2>/dev/null && return
  echo 0
}
# Extract a numeric field scoped to a parent section
_snum() {
  echo "$input" \
    | grep -A20 "\"$1\"[[:space:]]*:" \
    | grep -oE "\"$2\"[[:space:]]*:[[:space:]]*[0-9]+\.?[0-9]*" \
    | head -1 \
    | grep -oE '[0-9]+\.?[0-9]*$'
}

model=$(         _sstr model           display_name)
model_id=$(      _sstr model           id)
ctx_pct=$(       _snum context_window  used_percentage)
ctx_kb=$(        _snum context_window  context_window_size | awk '{printf "%d", $1/1000}')
cost=$(          _snum cost            total_cost_usd)
tok_fresh=$(     _snum current_usage   input_tokens)
tok_cr=$(        _snum current_usage   cache_read_input_tokens)
tok_cw=$(        _snum current_usage   cache_creation_input_tokens)
tok_out=$(       _snum current_usage   output_tokens)
session_id=$(    _str  session_id)
transcript_path=$(_str transcript_path)

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

  # New-gen IDs: claude-{family}-{major}[-minor][-YYYYMMDD][...]
  # e.g. claude-opus-4-7-20260416  →  Opus 4.7
  if [[ "$id" =~ ^claude-(opus|sonnet|haiku)-([0-9].*)$ ]]; then
    family="${BASH_REMATCH[1]}"
    ver="${BASH_REMATCH[2]}"
    ver=$(echo "$ver" | sed -E 's/-[0-9]{8}.*//')  # strip date suffix
    ver="${ver//-/.}"                                # hyphens → dots
    case "$family" in opus) family="Opus";; sonnet) family="Sonnet";; haiku) family="Haiku";; esac
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
  norm_id=$(echo "$model_id" | sed -E 's|^anthropic/||; s|-[0-9]{8}$||')

  if [ -f "$cache" ]; then
    local rates
    rates=$(grep -m1 "^${norm_id} " "$cache" | awk '{print $2, $3}')
    if [ -n "$rates" ]; then
      echo "$rates"
      return
    fi
  fi

  # Fallback: family pattern match on the original model id
  case "$model_id" in
    *opus*|*Opus*)     echo "5.00 25.00" ;;
    *sonnet*|*Sonnet*) echo "3.00 15.00" ;;
    *haiku*|*Haiku*)   echo "1.00 5.00"  ;;
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

# Locate the most recent compact_boundary in the transcript (always, not just when ctx_pct==0).
# Used both for ctx% recovery and for the cache_log floor that guards stale pre-compact entries.
_compact_line=""
if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
  _compact_line=$(grep '"subtype":"compact_boundary"' "$transcript_path" 2>/dev/null | tail -1)
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

# State dir per session
STATE_DIR="/tmp/claude_session_${session_id}"
mkdir -p "$STATE_DIR" 2>/dev/null
LAST_STATE="${STATE_DIR}/last_api.ts"
SESSION_COST="${STATE_DIR}/session_cost.txt"
MODEL_BREAKDOWN="${STATE_DIR}/model_breakdown.txt"  # space-delimited: model in cr cw5m cw1h out

now=$(date +%s)
prev_tout="-1"
prev_ts=$now
if [ -f "$LAST_STATE" ]; then
  prev_tout=$(cut -d: -f1 "$LAST_STATE" 2>/dev/null)
  prev_ts=$(cut -d: -f2 "$LAST_STATE" 2>/dev/null)
fi

if [ "$tok_out" -gt 0 ] && [ "$tok_out" != "$prev_tout" ]; then
  echo "${tok_out}:${now}" > "$LAST_STATE"
  prev_ts=$now

  # Per-model breakdown from JSONL files (parent + sub-agents)
  if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
    session_uuid=$(basename "$transcript_path" .jsonl)
    project_dir=$(dirname "$transcript_path")
    subagent_dir="${project_dir}/${session_uuid}/subagents"

    # Collect all files: parent JSONL + sub-agent JSONLs
    jsonl_files=("$transcript_path")
    if [ -d "$subagent_dir" ]; then
      for f in "$subagent_dir"/agent-*.jsonl; do
        [ -e "$f" ] && jsonl_files+=("$f")
      done
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

  # Record this turn's 5m/1h cache writes in cache_log for alive-cache TTL tracking.
  # Format per line: "<unix_ts> <cw5m> <cw1h> <model_id>". Entries older than 1h are pruned.
  # Each model (Opus, Sonnet, etc.) has a separate cache at Anthropic; we tag entries
  # with the model so that alive sums are filtered to the currently active model only.
  turn_cw5m=0; turn_cw1h=0; turn_model_id="${model_id:-unknown}"
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
    while IFS=' ' read -r _ts _5 _1 _m; do
      [ "$((_ts + 3600 - now))" -gt 0 ] && echo "$_ts $_5 $_1 $_m"
    done < "${STATE_DIR}/cache_log.txt" 2>/dev/null
    echo "${now} ${turn_cw5m} ${turn_cw1h} ${turn_model_id}"
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
  *)       _cache_filter="$model_id" ;;  # best effort for unknown display names
esac
model_last_ts=0; model_last_is_1h=0
if [ -f "${STATE_DIR}/cache_log.txt" ]; then
  while IFS=' ' read -r _ts _5 _1 _m; do
    # Skip entries from a different model; skip old 3-column entries (no model tag)
    [ -z "$_m" ] && continue
    # Skip entries that predate the last /compact — that cache no longer exists at Anthropic
    [ "$_ts" -lt "$compact_floor_ts" ] && continue
    case "$_m" in
      "${_cache_filter}"*) ;;
      *) continue ;;
    esac
    if [ "$_ts" -gt "$model_last_ts" ]; then
      model_last_ts=$_ts
      [ "${_1:-0}" -gt 0 ] && model_last_is_1h=1 || model_last_is_1h=0
    fi
  done < "${STATE_DIR}/cache_log.txt"
fi

# Cached portion of the current context = cache_read + cache_write for the active model's
# last API call. This matches the user's mental model: cache_read+cache_write ≈ context size.
# Unlike summing all alive writes (which over-counts by accumulating prefix deltas across turns),
# this shows how much of the CURRENT context is cached at Anthropic right now.
cached_now=$((tok_cr + tok_cw))

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
if [ "$cached_now" -gt 0 ]; then
  cache_timer_display="${_ttl_color}${_ttl_timer}($(fmt_tok $cached_now))${RESET}"
else
  cache_timer_display="${_ttl_color}${_ttl_timer}${RESET}"
fi

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
    printf "${DIM}Σ ${CYAN}%s${RESET}${DIM}: ↑%s +%sr +%sw ↓%s = ${YELLOW}%s${RESET}%s\n" \
      "$m_name" \
      "$(fmt_tok $m_in)" "$(fmt_tok $m_cr)" "$(fmt_tok $m_cw_total)" "$(fmt_tok $m_out)" \
      "$(fmt_c $m_cost)" "$ws_suffix"
  done < "$MODEL_BREAKDOWN"
  # Write local sum as fallback for when harness omits cost.total_cost_usd
  echo "$total_cost" > "$SESSION_COST"
fi
