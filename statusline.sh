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
# serialized before context_window; still true on 2.1.290). Token keys stay whole-buffer: current_usage was top-level
# pre-2.1.187 and nested under context_window after, and a buffer-wide first match by exact key
# (the leading quote stops "input_tokens" matching "cache_*_input_tokens" or "total_input_tokens")
# finds the right value under both layouts. effort.level (2.1.29x: low|medium|high|xhigh|max)
# is scoped to the flat effort object, cut at its closing brace, so a later "level" key can
# never win; older CLIs sent a numeric level there, which the string match ignores.
# Emits 12 newline-separated values in a fixed order —
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
  read -r effort
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
  ei = index(buf, "\"effort\"")
  eseg = (ei > 0) ? substr(buf, ei) : ""
  ej = index(eseg, "}"); if (ej > 0) eseg = substr(eseg, 1, ej)
  print sval(eseg, "level")
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
# CC 2.1.290 sends current_usage:null and used_percentage:null there instead (both fall
# through to the 0 defaults above), and a resumed session sends zeros; kept for older CLIs.
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
  if [[ "$id" =~ ^claude-(opus|sonnet|haiku|fable|mythos)-([0-9].*)$ ]]; then
    family="${BASH_REMATCH[1]}"
    ver="${BASH_REMATCH[2]}"
    ver=$(echo "$ver" | sed -E 's/-[0-9]{8}.*//')  # strip date suffix
    ver="${ver//-/.}"                                # hyphens → dots
    case "$family" in opus) family="Opus";; sonnet) family="Sonnet";; haiku) family="Haiku";; fable) family="Fable";; mythos) family="Mythos";; esac
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
# Live rates read from /tmp/claude_pricing.txt if refresh-pricing.sh has run (requires jq).
# One variable for every reader: the Σ render cache key stats this same file, so a test that
# overrides the path can never reuse rows cached under the real file's mtime.
PRICING_CACHE="${CLAUDE_STATUSLINE_PRICING_CACHE:-/tmp/claude_pricing.txt}"  # env: tests only
pricing_for() {
  local cache="$PRICING_CACHE"
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

  # Fallback: family pattern match on the original model id, used when the LiteLLM cache
  # is missing (no jq, offline) or lacks the id. LiteLLM lists claude-fable-5(-1) and
  # claude-mythos-5(-1) at $10/$50 per Mtok since at least 2026-10 (it did not in 2026-06).
  # An unknown family gets Sonnet rates: a deliberate middle guess, not a known price.
  case "$model_id" in
    *opus*|*Opus*)     echo "5.00 25.00" ;;
    *sonnet*|*Sonnet*) echo "3.00 15.00" ;;
    *haiku*|*Haiku*)   echo "1.00 5.00"  ;;
    *fable*|*Fable*)   echo "10.00 50.00" ;;
    *mythos*|*Mythos*) echo "10.00 50.00" ;;
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
    # grep -a: transcripts can contain NUL crash-padding blocks (unclean-shutdown
    # zero-fill). Plain GNU grep flips to binary mode at the first NUL and silently
    # suppresses every match after it — a boundary logged past a padding block would
    # be invisible and the compact floor stuck at an older compact.
    _compact_line=$(grep -a '"subtype":"compact_boundary"' "$transcript_path" 2>/dev/null | tail -1)
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

# Model-family prefix used BOTH to tag new cache_log entries (write path, below) and to
# filter them when reading back (per-model ttl/ctx, further down). Deriving tag and filter
# from the same stdin value makes them consistent by construction. The tag used to come
# from the transcript's last assistant line instead — but that line lags the live session
# (appends to multi-hundred-MB transcripts trail the stdin usage update by whole turns)
# and predates any mid-session model switch, so entries got tagged with the PREVIOUS
# model. The reader, filtering by the active model, then matched nothing, and the ttl
# froze at the 5m tier showing "expired(0)" while real 1h cache writes were happening.
# model_id may be an alias like "opusplan" rather than a real Claude model ID, so derive
# the prefix from display_name ("Opus 4.7" → "claude-opus") when the family is known.
case "$model" in
  Opus*)   _cache_filter="claude-opus" ;;
  Sonnet*) _cache_filter="claude-sonnet" ;;
  Haiku*)  _cache_filter="claude-haiku" ;;
  Fable*)  _cache_filter="claude-fable" ;;
  Mythos*) _cache_filter="claude-mythos" ;;
  *)       _cache_filter="${model_id%%\[*}" ;;  # unknown display name: fall back to the
           # stdin id, stripped of a [1m]-style context-beta suffix. Tag and filter still
           # agree; at worst the family-scoped transcript grep below finds no line.
esac
_cache_filter="${_cache_filter:-unknown}"

# Σ breakdown regen — decide-and-spawn, shared by two call sites: per-turn inside the
# turn gate (as always) and the idle-render probe after it. Background Workflow fleets
# (CC 2.1.2xx) append subagent JSONLs and bill into the harness total for many minutes
# without any main-loop turn — regen gated on turns alone froze the local Σ for a
# fleet's whole duration. Ends by touching MB_PROBE, which rate-limits the idle probe.
MB_PROBE="${STATE_DIR}/mb_probe.ts"
mb_regen_check() {
  # Per-model breakdown from JSONL files (parent + sub-agents)
  if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
    session_uuid=$(basename "$transcript_path" .jsonl)
    project_dir=$(dirname "$transcript_path")
    subagent_dir="${project_dir}/${session_uuid}/subagents"

    # Σ regen throttle. Every regen rescans every JSONL (parent + subagents) — hundreds of
    # MB in long sessions — and this gate fires several times per streaming turn, so naive
    # respawning stacks concurrent full-corpus scans. Sweep regen scratch first: each
    # regen writes through a unique .tmp.<pid> (plus a .s scan-start marker), so scratch
    # younger than 600s means a regen is already in flight — don't stack another. Older
    # scratch (and any bare .tmp from an older statusline) is a leftover of a killed
    # render — remove it. Unique names make sweeping a slow-but-live regen benign: its
    # mv target is gone, so it just discards its result; it can never install another
    # regen's half-written file.
    _mb_inflight=0
    for _t in "${MODEL_BREAKDOWN}.tmp" "${MODEL_BREAKDOWN}".tmp.*; do
      [ -e "$_t" ] || continue
      _tm=$(stat -c '%Y' "$_t" 2>/dev/null || stat -f '%m' "$_t" 2>/dev/null)
      if [ -n "$_tm" ] && [ "$((now - _tm))" -lt 600 ]; then
        _mb_inflight=1
      else
        rm -f "$_t" 2>/dev/null
      fi
    done

    # Regen only when there is new data: the parent transcript OR any subagent JSONL
    # newer than the breakdown. Subagent fleets grow without the parent being appended —
    # keying on the parent's mtime alone would silently leave their cost out of Σ. The
    # finished breakdown's mtime is backdated to its scan START (the touch -r below), so
    # lines appended while a scan was already reading still compare newer and re-arm the
    # next regen instead of being shadowed forever.
    _regen=0
    if [ ! -s "$MODEL_BREAKDOWN" ] || [ "$transcript_path" -nt "$MODEL_BREAKDOWN" ]; then
      _regen=1
    elif [ -d "$subagent_dir" ] && \
         [ -n "$(find "$subagent_dir" -type f -name 'agent-*.jsonl' -newer "$MODEL_BREAKDOWN" 2>/dev/null | head -1)" ]; then
      _regen=1
    fi
    [ "$_mb_inflight" = 1 ] && _regen=0

    if [ "$_regen" = 1 ]; then
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
      _mb_tmp="${MODEL_BREAKDOWN}.tmp.$$"
      ( : > "${_mb_tmp}.s"
        awk '
# >>> SIGMA_AWK (tests/test.sh extracts and runs this exact program)
# Sum every occurrence of "<name>":<int> within s. CC 2.1.2xx usage lines can carry an
# iterations[] array of per-API-call usage objects whose TOP-LEVEL fields cover only one
# iteration — token fields must be summed across the segment, not first-matched, or
# multi-iteration turns (retries/multi-pass) silently undercount.
function sumf(s, name,   t, f, tot) {
  tot = 0; t = s
  while (match(t, "\"" name "\":[0-9]+")) {
    f = substr(t, RSTART, RLENGTH); sub(".*:", "", f); tot += f + 0
    t = substr(t, RSTART + RLENGTH)
  }
  return tot
}
function add(m, main, file, i, r, c5, c1, o, w, f) {
  seen_model[m] = 1
  if (main) {
    in_sum[m] += i; cr_sum[m] += r; cw5m_sum[m] += c5; cw1h_sum[m] += c1
    out_sum[m] += o; web_sum[m] += w; fetch_sum[m] += f
  } else {
    a_in[m] += i; a_cr[m] += r; a_cw5m[m] += c5; a_cw1h[m] += c1
    a_out[m] += o; a_web[m] += w; a_fetch[m] += f
    agent_seen[m, file] = 1
  }
}
# Origin: the parent transcript is the first file argument; every other file is one
# sub-agent (agent-*.jsonl). Sums are kept per (model, origin) so the render can show what
# sub-agents cost apart from the main conversation; the harness total (and /usage) cannot.
# The fingerprint fallback below compares consecutive lines, so it restarts per file.
FNR == 1 { is_main = (FILENAME == ARGV[1]); prev_fingerprint = "" }
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

  # Token scope: when iterations[] is present, sum within the array segment only —
  # the top-level keys (which precede it in key order) reflect a single iteration.
  # Without iterations, seg is the whole line and each key occurs once, so sumf
  # equals the old first-match (behavior-preserving for pre-2.1.2xx transcripts).
  # First "]" closes the array: elements only nest {} objects. Only a NON-EMPTY array
  # ("iterations":[{) scopes the segment: CC 2.1.28x+ writes "iterations":[] on every
  # main and sub-agent line, and scoping to that literal summed every field to 0 — the
  # Σ row of the main model vanished. [], null and an absent key all fall through to the
  # whole line, where each top-level key occurs once.
  seg = $0
  p = index($0, "\"iterations\":[{")
  if (p > 0) { seg = substr($0, p); q = index(seg, "]"); if (q > 0) seg = substr(seg, 1, q) }

  in_tok = sumf(seg, "input_tokens")
  cr = sumf(seg, "cache_read_input_tokens")
  cw5m = sumf(seg, "ephemeral_5m_input_tokens")
  cw1h = sumf(seg, "ephemeral_1h_input_tokens")
  if (cw5m == 0 && cw1h == 0) cw1h = sumf(seg, "cache_creation_input_tokens")

  # web/fetch counts live in top-level server_tool_use, serialized BEFORE iterations,
  # so whole-line first-match stays correct. On multi-iteration lines the top-level
  # count may itself cover one iteration (unverified) — accepted minor undercount.
  web = 0; fetch = 0
  if (match($0, /"web_search_requests":[0-9]+/))
    { f = substr($0, RSTART, RLENGTH); sub(/"web_search_requests":/, "", f); web = f+0 }
  if (match($0, /"web_fetch_requests":[0-9]+/))
    { f = substr($0, RSTART, RLENGTH); sub(/"web_fetch_requests":/, "", f); fetch = f+0 }

  # output_tokens already includes thinking (output_tokens_details.thinking_tokens is a
  # breakdown, not an addend — API semantics), so it is never summed separately.
  out = sumf(seg, "output_tokens")

  # One API message = one count. Claude Code writes one line per content block (thinking,
  # text, each tool_use), all sharing message.id; streaming checkpoints repeat the same
  # input/cache usage while output_tokens grows (2.1.290 sub-agents: 5, 5, 601). Keyed on
  # message.id the LAST line wins — it carries the final output count. message.id is
  # serialized before content, so the first "id":"msg_ is the right one (ids inside
  # content are JSON-escaped and cannot match).
  mid = ""
  if (match($0, /"id":"msg_[^"]*"/)) {
    mid = substr($0, RSTART + 6, RLENGTH - 7)
    mid_model[mid] = model; mid_in[mid] = in_tok; mid_cr[mid] = cr
    mid_cw5m[mid] = cw5m; mid_cw1h[mid] = cw1h; mid_out[mid] = out
    mid_web[mid] = web; mid_fetch[mid] = fetch
    mid_main[mid] = is_main; mid_file[mid] = FILENAME
    next
  }

  # Lines without message.id (older transcripts, hand-written fixtures): fall back to the
  # consecutive-fingerprint rule — the same response re-logged with an identical
  # (model, input_tokens, output_tokens) is a checkpoint; count only the first.
  fingerprint = model ":" in_tok ":" out
  if (fingerprint == prev_fingerprint) next
  prev_fingerprint = fingerprint
  add(model, is_main, FILENAME, in_tok, cr, cw5m, cw1h, out, web, fetch)
}
END {
  for (mid in mid_model)
    add(mid_model[mid], mid_main[mid], mid_file[mid], mid_in[mid], mid_cr[mid],
        mid_cw5m[mid], mid_cw1h[mid], mid_out[mid], mid_web[mid], mid_fetch[mid])
  for (k in agent_seen) { split(k, kp, SUBSEP); a_cnt[kp[1]]++ }
  # Columns 2-8 main, 9-15 sub-agents, 16 distinct agent files that used the model.
  for (m in seen_model)
    print m, in_sum[m]+0, cr_sum[m]+0, cw5m_sum[m]+0, cw1h_sum[m]+0, out_sum[m]+0, \
      web_sum[m]+0, fetch_sum[m]+0, a_in[m]+0, a_cr[m]+0, a_cw5m[m]+0, a_cw1h[m]+0, \
      a_out[m]+0, a_web[m]+0, a_fetch[m]+0, a_cnt[m]+0
}
# <<< SIGMA_AWK
' "${jsonl_files[@]}" > "$_mb_tmp" 2>/dev/null \
          && touch -r "${_mb_tmp}.s" "$_mb_tmp" 2>/dev/null \
          && mv "$_mb_tmp" "$MODEL_BREAKDOWN" 2>/dev/null
        rm -f "${_mb_tmp}.s" "$_mb_tmp" 2>/dev/null ) &
    fi
  fi
  touch "$MB_PROBE" 2>/dev/null
}

if [ "$tok_out" -gt 0 ] && [ "$tok_out" != "$prev_tout" ]; then
  prev_ts=$now
  mb_regen_check
  [ -x "${HOME}/.claude/refresh-pricing.sh" ] && "${HOME}/.claude/refresh-pricing.sh" &

  # Snapshot per-model display values at the time of this turn.
  # Written as cols 5-7 in cache_log so the per-model read below returns the
  # correct values for each model even after a model switch with no intervening call.
  cached_now=$((tok_cr + tok_cw))
  turn_ctx_pct=${ctx_pct:-0}
  turn_ctx_kb=${ctx_kb:-0}

  # Record this turn's 5m/1h cache writes in cache_log for alive-cache TTL tracking.
  # Format per line: "<unix_ts> <cw5m> <cw1h> <model_tag> <cached_now> <ctx_pct> <ctx_kb>". Entries older than 1h are pruned.
  # Each model (Opus, Sonnet, etc.) has a separate cache at Anthropic; entries are tagged
  # with the family prefix ($_cache_filter, derived from the live stdin above) so the
  # read-back filter matches them by construction. The 5m/1h split is read from the newest
  # transcript line OF THIS FAMILY: scoping by model keeps a foreign trailing line
  # (sidechains, compaction summaries, pre-switch turns of another model) from feeding
  # another model's tier into this one. tail -c bounds the scan — this gate fires several
  # times per streaming turn and transcripts reach hundreds of MB, while the line we want
  # only ever sits at the tail. A first-ever turn of a freshly switched model may find no
  # line yet (transcript appends lag stdin) — it extracts 0/0, which the tier inheritance
  # in the prune-and-append below converts to the previous entry's tier.
  # grep -a: transcripts can contain NUL crash-padding; without it GNU grep flips to
  # binary mode at the first NUL and suppresses every later match, so this chain silently
  # returned lines from BEFORE the padding block — weeks-stale tier values (see the
  # compact_boundary grep above for the same failure).
  turn_cw5m=0; turn_cw1h=0
  if [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
    _last=$(tail -c 8388608 "$transcript_path" 2>/dev/null | grep -a '"role":"assistant"' \
      | grep -a '"usage"' | grep -aF "\"model\":\"${_cache_filter}" | tail -1)
    if [ -n "$_last" ]; then
      # Sum the ephemeral fields across the iterations[] segment when present: the
      # top-level copy covers only ONE iteration and can read 0/0 when a later
      # iteration wrote the cache — which would flip the ttl display to the 5m tier
      # against a live 1h cache. Same segment rule as the Σ awk above, including the
      # non-empty-array match: 2.1.28x+ "iterations":[] must read the top level.
      _v=$(printf '%s\n' "$_last" | awk '{
        seg = $0
        p = index($0, "\"iterations\":[{")
        if (p > 0) { seg = substr($0, p); q = index(seg, "]"); if (q > 0) seg = substr(seg, 1, q) }
        c5 = 0; t = seg
        while (match(t, /"ephemeral_5m_input_tokens":[0-9]+/)) {
          f = substr(t, RSTART, RLENGTH); sub(".*:", "", f); c5 += f + 0
          t = substr(t, RSTART + RLENGTH)
        }
        c1 = 0; t = seg
        while (match(t, /"ephemeral_1h_input_tokens":[0-9]+/)) {
          f = substr(t, RSTART, RLENGTH); sub(".*:", "", f); c1 += f + 0
          t = substr(t, RSTART + RLENGTH)
        }
        print c5, c1
      }')
      turn_cw5m=${_v%% *}; turn_cw5m=${turn_cw5m:-0}
      turn_cw1h=${_v##* }; turn_cw1h=${turn_cw1h:-0}
    fi
  fi
  _inh_ts=0; _inh5=0; _inh1=0
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
      [ "$((_ts + 3600 - now))" -gt 0 ] || continue
      echo "$_ts $_5 $_1 $_m $_c $_cp $_ck"
      # Track the newest live same-family tier values for the inheritance below.
      # Compact-floor guard: a pre-compact entry describes a cache that /compact
      # invalidated — inheriting its 1h flag would resurrect a dead cache.
      case "$_m" in
        "${_cache_filter}"*)
          if [ "$_ts" -ge "$compact_floor_ts" ] && [ "$_ts" -gt "$_inh_ts" ]; then
            _inh_ts=$_ts; _inh5=$_5; _inh1=$_1
          fi ;;
      esac
    done < "${STATE_DIR}/cache_log.txt" 2>/dev/null
    # Whiff inheritance: 0/0 extraction means either the family grep found no fresh
    # line (flush race, first turn after a model switch) or the turn wrote nothing new
    # (pure cache-hit turn). Either way the previous cache still exists and reads
    # refresh its TTL server-side — keep the previous tier instead of letting the
    # reader flip the display to the 5m default against a live 1h cache.
    if [ "${turn_cw5m:-0}" -eq 0 ] && [ "${turn_cw1h:-0}" -eq 0 ] && [ "$_inh_ts" -gt 0 ]; then
      turn_cw5m=$_inh5; turn_cw1h=$_inh1
    fi
    echo "${now} ${turn_cw5m} ${turn_cw1h} ${_cache_filter} ${cached_now} ${turn_ctx_pct} ${turn_ctx_kb}"
  } > "${STATE_DIR}/cache_log.txt.tmp" 2>/dev/null && \
    mv "${STATE_DIR}/cache_log.txt.tmp" "${STATE_DIR}/cache_log.txt" 2>/dev/null

  # Commit the turn marker LAST — and atomically. The marker is what closes this gate
  # (tok_out == prev_tout on the next render), so it must land only after cache_log is
  # committed: statusline renders can be killed mid-run (huge-session renders get culled
  # by the harness), and a marker committed first records the turn as done while its
  # cache_log entry is lost — the gate never refires for that turn and the ttl display
  # freezes at expired(0). Marker-last turns a killed render into a plain retry.
  echo "${tok_out}:${now}:${_cc_now}" > "${LAST_STATE}.tmp" 2>/dev/null && \
    mv "${LAST_STATE}.tmp" "$LAST_STATE" 2>/dev/null   # col 3 = harness cost at this turn (compact baseline)
fi

# Idle-render Σ probe: catch background fleet growth between turns. Runs the same
# decide-and-spawn at most every 45s, keyed on the probe file's mtime — NOT breakdown
# age, which stops advancing during genuine quiet and would degenerate into a find(1)
# over thousands of subagent files on every 1s render. touch BEFORE probing so a killed
# render can't retry-storm. This path never writes LAST_STATE or cache_log, so the
# crash-safe marker-last ordering above is unaffected.
if [ "$tok_out" = "$prev_tout" ] && [ -n "$transcript_path" ] && [ -f "$transcript_path" ]; then
  _pb_m=$(stat -c '%Y' "$MB_PROBE" 2>/dev/null || stat -f '%m' "$MB_PROBE" 2>/dev/null)
  if [ -z "$_pb_m" ] || [ "$((now - _pb_m))" -ge 45 ]; then
    touch "$MB_PROBE" 2>/dev/null
    mb_regen_check
  fi
fi

# Find the most recent cache_log entry for the active model, filtered by $_cache_filter —
# derived from the live stdin above the turn gate, the same value used to tag entries on
# write, so tag and filter agree by construction (older entries with full-id tags still
# match: the filter is a prefix of them).
# Used for (a) per-model TTL timer base and (b) which TTL tier the last write used.
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

# Top-line cost: harness total_cost_usd first, local transcript sum second. The harness
# counter is per-PROCESS — it resets on CLI restart/resume and (CC 2.1.211+) on /clear —
# and on CC 2.1.2xx it folds in background Workflow-fleet usage in near-real-time. The
# local sum spans the whole transcript history (parent + subagents) at LiteLLM rates and
# may lag a running fleet by up to the idle-probe interval + scan time. So harness>local
# is normal shortly after fleet activity or on >8MB-per-turn undercount edge cases, and
# local>harness is normal on any restarted/resumed/cleared session. Neither figure is
# the authoritative Anthropic bill.
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
effort_str=""
[ -n "$effort" ] && effort_str="${DIM} (${effort})${RESET}"
printf "%s%s%s%s%s" \
  "${BOLD}${CYAN}${model}${RESET}" "$effort_str" "${sep}" \
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
  _pr_m=$(stat -c '%Y' "$PRICING_CACHE" 2>/dev/null || stat -f '%m' "$PRICING_CACHE" 2>/dev/null)
  _sigma_key="${_mb_m:-0}:${_pr_m:-0}"
  if [ -f "$SIGMA_TXT" ] && [ "$(cat "$SIGMA_KEY" 2>/dev/null)" = "$_sigma_key" ]; then
    cat "$SIGMA_TXT"
  else
    _sigma_out=""
    # Columns 2-8 main conversation, 9-15 sub-agents, 16 distinct agent files. An 8-column
    # file from the previous script (kept in /tmp until the next regen) mixes both origins
    # in 2-8: its agent fields read empty, so it renders totals with no attribution suffix.
    while IFS=' ' read -r m_id m_in m_cr m_cw5m m_cw1h m_out m_web m_fetch \
        a_in a_cr a_cw5m a_cw1h a_out a_web a_fetch a_cnt; do
      m_web="${m_web:-0}"; m_fetch="${m_fetch:-0}"
      _legacy=0; [ -z "$a_cnt" ] && _legacy=1
      a_in="${a_in:-0}"; a_cr="${a_cr:-0}"; a_cw5m="${a_cw5m:-0}"; a_cw1h="${a_cw1h:-0}"
      a_out="${a_out:-0}"; a_web="${a_web:-0}"; a_fetch="${a_fetch:-0}"; a_cnt="${a_cnt:-0}"
      _m_tok=$((m_in + m_cr + m_cw5m + m_cw1h + m_out))
      _a_tok=$((a_in + a_cr + a_cw5m + a_cw1h + a_out))
      [ "$((_m_tok + _a_tok))" -eq 0 ] && continue
      m_name=$(model_display "$m_id")
      read m_pin m_pout <<< "$(pricing_for "$m_id")"
      # One awk prices both origins: cache read 0.10x, write 5m 1.25x, write 1h 2.00x of base.
      read m_cost_main m_cost_agent <<< "$(echo "$m_pin $m_pout $m_in $m_cr $m_cw5m $m_cw1h $m_out $m_web $m_fetch $a_in $a_cr $a_cw5m $a_cw1h $a_out $a_web $a_fetch" | awk '
        function c(i, r, w5, w1, o, ws, wf) {
          return (i*$1 + r*$1*0.10 + w5*$1*1.25 + w1*$1*2.00 + o*$2) / 1000000 + (ws + wf) * 0.010
        }
        { printf "%.6f %.6f", c($3,$4,$5,$6,$7,$8,$9), c($10,$11,$12,$13,$14,$15,$16) }')"
      m_cost=$(awk -v a="$m_cost_main" -v b="$m_cost_agent" 'BEGIN {printf "%.6f", a+b}')
      total_cost=$(awk -v a="$total_cost" -v b="$m_cost" 'BEGIN {printf "%.6f", a+b}')
      m_web=$((m_web + a_web))
      ws_suffix=""
      [ "$m_web" -gt 0 ] 2>/dev/null && ws_suffix=" ${DIM}+${m_web}ws${RESET}"
      who_suffix=""
      if [ "$_legacy" = 0 ]; then
        if [ "$_a_tok" -eq 0 ]; then
          who_suffix=" ${DIM}(main)${RESET}"
        elif [ "$_m_tok" -eq 0 ]; then
          who_suffix=" ${DIM}(agents ×${a_cnt})${RESET}"
        else
          who_suffix=" ${DIM}(main $(fmt_c "$m_cost_main") · agents ×${a_cnt} $(fmt_c "$m_cost_agent"))${RESET}"
        fi
      fi
      _sigma_out="${_sigma_out}$(printf "${DIM}Σ ${CYAN}%s${RESET}${DIM}: ↑%s +%sr +%sw ↓%s = ${YELLOW}%s${RESET}%s%s" \
        "$m_name" \
        "$(fmt_tok $((m_in + a_in)))" "$(fmt_tok $((m_cr + a_cr)))" \
        "$(fmt_tok $((m_cw5m + m_cw1h + a_cw5m + a_cw1h)))" "$(fmt_tok $((m_out + a_out)))" \
        "$(fmt_c $m_cost)" "$ws_suffix" "$who_suffix")"$'\n'
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
