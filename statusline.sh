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

# Extract a string value from harness JSON: grep the field name, capture the quoted value
_str() { echo "$input" | grep "\"$1\"" | sed -E 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/'; }
# Extract a numeric value (int or float): find the digit sequence after the field name
_num() { echo "$input" | grep "\"$1\"" | grep -oE '[0-9]+\.?[0-9]*' | head -1; }

model=$(         _str display_name)
ctx_pct=$(       _num used_percentage)
ctx_kb=$(        _num context_window_size | awk '{printf "%d", $1/1000}')
cost=$(          _num total_cost_usd)
tok_fresh=$(     _num input_tokens)
tok_cr=$(        _num cache_read_input_tokens)
tok_cw=$(        _num cache_creation_input_tokens)
tok_out=$(       _num output_tokens)
session_id=$(    _str session_id)
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
' "${jsonl_files[@]}" > "${MODEL_BREAKDOWN}.tmp" 2>/dev/null && \
      mv "${MODEL_BREAKDOWN}.tmp" "$MODEL_BREAKDOWN") &
  fi
  [ -x "${HOME}/.claude/refresh-pricing.sh" ] && "${HOME}/.claude/refresh-pricing.sh" &
fi

# TTL countdown
elapsed=$((now - prev_ts))
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

# Session total from per-model Σ breakdown (written at end of each render)
session_cost_val=$(cat "$SESSION_COST" 2>/dev/null | tr -d '[:space:]')
if [ -n "$session_cost_val" ]; then
  cost_display="${YELLOW}$(fmt_c "$session_cost_val")${RESET}"
else
  cost_display="${DIM}\$0.00${RESET}"
fi

sep="${DIM} │ ${RESET}"

# Line 1: current turn
printf "%s%s%s%s" \
  "${BOLD}${CYAN}${model}${RESET}" "${sep}" \
  "ctx ${ctx_color}${ctx_pct}%${RESET}${DIM}/${ctx_kb}k${RESET}" "${sep}"
printf "%s%s" "$cost_display" "${sep}"
printf "↑${WHITE}%s${RESET} ${GREEN}+%sr${RESET} ${YELLOW}+%sw${RESET} ↓${BLUE}%s${RESET}" \
  "$(fmt_tok $tok_fresh)" "$(fmt_tok $tok_cr)" "$(fmt_tok $tok_cw)" "$(fmt_tok $tok_out)"
printf "%s hit ${hit_color}%s%%${RESET}" "${sep}" "$cache_pct"
printf "%s ~ttl ${cache_color}%s${RESET}\n" "${sep}" "$cache_timer"

# Lines 2+: per-model totals — read directly from flat-text breakdown (no jq needed)
total_cost=0
if [ -f "$MODEL_BREAKDOWN" ] && [ -s "$MODEL_BREAKDOWN" ]; then
  while IFS=' ' read -r m_id m_in m_cr m_cw5m m_cw1h m_out; do
    [ "$((m_in + m_cr + m_cw5m + m_cw1h + m_out))" -eq 0 ] && continue
    m_name=$(model_display "$m_id")
    read m_pin m_pout <<< "$(pricing_for "$m_id")"
    m_pcr=$(awk   -v b="$m_pin" 'BEGIN {printf "%.4f", b * 0.10}')
    m_pcw5m=$(awk -v b="$m_pin" 'BEGIN {printf "%.4f", b * 1.25}')
    m_pcw1h=$(awk -v b="$m_pin" 'BEGIN {printf "%.4f", b * 2.00}')
    m_cw_total=$((m_cw5m + m_cw1h))
    m_cost=$(echo "$m_in $m_pin $m_cr $m_pcr $m_cw5m $m_pcw5m $m_cw1h $m_pcw1h $m_out $m_pout" | awk '{
      printf "%.6f", ($1*$2 + $3*$4 + $5*$6 + $7*$8 + $9*$10) / 1000000
    }')
    total_cost=$(awk -v a="$total_cost" -v b="$m_cost" 'BEGIN {printf "%.6f", a+b}')
    printf "${DIM}Σ ${CYAN}%s${RESET}${DIM}: ↑%s +%sr +%sw ↓%s = ${YELLOW}%s${RESET}\n" \
      "$m_name" \
      "$(fmt_tok $m_in)" "$(fmt_tok $m_cr)" "$(fmt_tok $m_cw_total)" "$(fmt_tok $m_out)" \
      "$(fmt_c $m_cost)"
  done < "$MODEL_BREAKDOWN"
  echo "$total_cost" > "$SESSION_COST"
fi
