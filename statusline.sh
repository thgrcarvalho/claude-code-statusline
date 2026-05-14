#!/bin/bash
# Claude Code status line — model · context % · cost · cache breakdown · per-model totals (incl. sub-agents)
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

model=$(echo "$input"        | jq -r '.model.display_name // "?"')
ctx_pct=$(echo "$input"      | jq -r '.context_window.used_percentage // 0')
ctx_kb=$(echo "$input"       | jq -r '.context_window.context_window_size // 0 | . / 1000 | floor')
cost=$(echo "$input"         | jq -r '.cost.total_cost_usd // 0')
tok_fresh=$(echo "$input"    | jq -r '.context_window.current_usage.input_tokens // 0')
tok_cr=$(echo "$input"       | jq -r '.context_window.current_usage.cache_read_input_tokens // 0')
tok_cw=$(echo "$input"       | jq -r '.context_window.current_usage.cache_creation_input_tokens // 0')
tok_out=$(echo "$input"      | jq -r '.context_window.current_usage.output_tokens // 0')
session_id=$(echo "$input"   | jq -r '.session_id // "default"')
transcript_path=$(echo "$input" | jq -r '.transcript_path // ""')

# Friendly display name from API model ID or display name
model_display() {
  case "$1" in
    *opus-4-7*|"Opus 4.7")        echo "Opus 4.7" ;;
    *opus-4-5*|"Opus 4.5")        echo "Opus 4.5" ;;
    *opus*|"Opus"*)               echo "Opus" ;;
    *sonnet-4-6*|"Sonnet 4.6")    echo "Sonnet 4.6" ;;
    *sonnet-4-5*|"Sonnet 4.5")    echo "Sonnet 4.5" ;;
    *sonnet*|"Sonnet"*)           echo "Sonnet" ;;
    *haiku-4-5*|"Haiku 4.5")      echo "Haiku 4.5" ;;
    *haiku*|"Haiku"*)             echo "Haiku" ;;
    *)                            echo "$1" ;;
  esac
}

# Pricing: base_input, output (USD per million tokens)
# Cache prices derived at use-time: read=0.10×, write_5m=1.25×, write_1h=2.00× of base
# Live rates read from /tmp/claude_pricing.json (refreshed daily by refresh-pricing.sh)
pricing_for() {
  local cache="/tmp/claude_pricing.json"
  local model_id="$1"
  local norm_id
  # Normalize: strip "anthropic/" prefix and trailing -YYYYMMDD date
  norm_id=$(echo "$model_id" | sed -E 's|^anthropic/||; s|-[0-9]{8}$||')

  if [ -f "$cache" ]; then
    local rates
    rates=$(jq -r --arg m "$norm_id" \
      '.[$m] | select(. != null) | "\(.input) \(.output)"' \
      "$cache" 2>/dev/null)
    if [ -n "$rates" ] && [ "$rates" != " " ]; then
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
LAST_STATE="${STATE_DIR}/last_api.ts"               # last API response timestamp
SESSION_COST="${STATE_DIR}/session_cost.txt"        # total cost from Σ breakdown
MODEL_BREAKDOWN="${STATE_DIR}/model_breakdown.json" # per-model totals from JSONL

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

    # Parse: deduplicate by uuid, group by model, sum usage
    # Split cache_creation into 5min and 1hr for accurate pricing
    (jq -rs '
      [.[] | select(.message.role == "assistant" and .message.usage != null
               and (.message.model | strings | startswith("claude-"))) |
        { uuid,
          model: .message.model,
          in:   (.message.usage.input_tokens // 0),
          cr:   (.message.usage.cache_read_input_tokens // 0),
          cw5m: (.message.usage.cache_creation.ephemeral_5m_input_tokens // 0),
          cw1h: (.message.usage.cache_creation.ephemeral_1h_input_tokens // .message.usage.cache_creation_input_tokens // 0),
          out:  (.message.usage.output_tokens // 0)
        }
      ] |
      unique_by(.uuid) |
      group_by(.model) |
      map({
        model: .[0].model,
        in:   (map(.in)   | add),
        cr:   (map(.cr)   | add),
        cw5m: (map(.cw5m) | add),
        cw1h: (map(.cw1h) | add),
        out:  (map(.out)  | add)
      })
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

# Lines 2+: per-model totals from JSONL (parent + sub-agents)
# Uses process substitution so total_cost accumulates in the main shell
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
  done < <(jq -r '.[] | "\(.model) \(.in) \(.cr) \(.cw5m) \(.cw1h) \(.out)"' "$MODEL_BREAKDOWN" 2>/dev/null)
  echo "$total_cost" > "$SESSION_COST"
fi
