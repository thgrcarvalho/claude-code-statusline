# claude-code-statusline

A feature-rich status line for [Claude Code](https://claude.ai/code) that shows real-time token usage, cache efficiency, cost breakdown per model (including sub-agents), and a TTL countdown for the prompt cache.

---

## What it looks like

**Line 1 — current turn:**
```
Opus 4.7 │ ctx 14%/200k │ $0.42 / $0.65 │ ↑1 +87kr +2kw ↓312 │ hit 97% │ ~ttl 4:12(1.0k) / 0:59:01(80kw)
```

**Line 2+ — per-model session totals (including sub-agents):**
```
Σ Opus 4.7:   ↑12 +1.4Mr +80kw ↓7k = $0.38
Σ Sonnet 4.6: ↑8  +210kr +30kw ↓3k = $0.27
```

| Field | Meaning |
|---|---|
| `ctx 14%/200k` | Context window usage (color: green < 50%, yellow < 80%, red ≥ 80%) |
| `$0.42 / $0.65` | Session cost: `$<harness>` (matches `/usage`, excludes sub-agents) `/` `$<local>` (includes sub-agents, uses LiteLLM rates) — see *Why the two cost figures differ* |
| `↑N` | Fresh (uncached) input tokens this turn — almost always 1–6 |
| `+Xr` | Cache read tokens (billed at 10% of base price) |
| `+Xw` | Cache write tokens total this turn (billed at 125–200% of base price) |
| `↓N` | Output tokens generated |
| `hit X%` | `cache_read / (fresh + read + write)` for this turn |
| `~ttl M:SS(Xkw)` | 5m-tier countdown + total still-alive 5m cache writes across recent turns — if this hits 0 those tokens will be re-written (expensive) on the next call |
| `/ H:MM:SS(Ykw)` | 1h-tier countdown + total still-alive 1h cache writes — same stakes, longer window |
| `+Nws` | Web-search requests this model made, billed at $10 / 1k |
| `Σ model: ...` | Cumulative token totals + cost per model, from transcript JSONLs including sub-agents |

---

## Features

- **Live per-model cost breakdown** — separate Σ rows for Opus, Sonnet, Haiku, and any future models
- **Sub-agent token tracking** — Explore, Plan, and other agents are included in the Σ totals
- **Auto-updating pricing** — fetches latest rates from [LiteLLM's database](https://github.com/BerriAI/litellm/blob/main/model_prices_and_context_window.json) once per day; covers all active and legacy Claude models with correct per-version rates
- **Cache hit % and TTL countdown** — tells you how efficiently the cache is being used and when it might expire
- **Hardcoded fallback rates** — works offline; if LiteLLM is unreachable the last-known rates stay in effect
- **Zero token cost** — reads from local JSONL files and `/tmp`, makes no API calls

---

## Requirements

- [Claude Code](https://claude.ai/code) 2.x
- `bash` 3.2+ (default on macOS; bash 4+ recommended for best compatibility)
- `curl`
- `jq` *(optional)* — enables auto-updating pricing from LiteLLM; the statusline works fully without it

---

## Quick install

```bash
git clone https://github.com/thgrcarvalho/claude-code-statusline.git
cd claude-code-statusline
./install.sh
```

The installer will:
1. Check for `jq` and `curl`
2. Back up any existing `~/.claude/statusline.sh` and `~/.claude/settings.json`
3. Copy scripts to `~/.claude/` and make them executable
4. Patch `~/.claude/settings.json` to activate the statusline
5. Fetch the initial pricing cache from LiteLLM

Then **restart Claude Code**. The new statusline appears immediately.

### macOS note

Default macOS bash (3.2) is supported. For bash 4+:
```bash
brew install bash
```

To enable auto-updating pricing from LiteLLM (optional):
```bash
brew install jq
```

---

## Manual install

If you prefer to install by hand:

1. Copy `statusline.sh` and `refresh-pricing.sh` to `~/.claude/` and make them executable:
   ```bash
   cp statusline.sh refresh-pricing.sh ~/.claude/
   chmod +x ~/.claude/statusline.sh ~/.claude/refresh-pricing.sh
   ```

2. Add this block to `~/.claude/settings.json` (create the file if it doesn't exist):
   ```json
   {
     "statusLine": {
       "type": "command",
       "command": "/Users/YOUR_USERNAME/.claude/statusline.sh",
       "refreshInterval": 1
     }
   }
   ```
   Replace `/Users/YOUR_USERNAME` with your actual home directory path.

3. Restart Claude Code.

---

## Uninstall / Revert

`install.sh` creates timestamped backups of anything it overwrites (`~/.claude/statusline.sh.bak.<ts>`, `~/.claude/settings.json.bak.<ts>`, etc.). To go back:

```bash
./uninstall.sh
```

If you've run the installer more than once, `uninstall.sh` lists all available backup timestamps and lets you choose which one to restore. It also handles the case where no prior statusline existed — removing the installed files and cleaning the `statusLine` key from `settings.json`.

---

## How it works

The statusline script is invoked by Claude Code every second via `refreshInterval: 1`. It receives a JSON blob on stdin with the current session state and prints the status lines.

**Top-line cost** shows two figures: `$<harness>` is read directly from Claude Code's `cost.total_cost_usd` field and matches `/usage`'s "Total cost" exactly. `$<local>` is the sum of the Σ per-model rows and includes sub-agent activity that `/usage` omits. When only one is available, just that value is shown. Neither figure equals the authoritative Anthropic Console bill.

**TTL countdown** shows `M:SS(Xkw) / H:MM:SS(Ykw)` where `Xkw` / `Ykw` are the total tokens still alive in each cache tier across all turns in the session — not just the last turn. The script maintains a per-turn log (`cache_log.txt`) and sums only entries that haven't expired yet. When cache expires, those tokens get re-written at the expensive rate on the next API call; the timer tells you how long you have before that happens. The countdown is **per-model**: it tracks time since the active model's last API call, so when switching models (e.g., opusplan toggling between Opus and Sonnet) the timer immediately reflects the elapsed time for that model's cache — if Sonnet hasn't been called in 10 minutes, its 1h timer shows ~50 min remaining. After `/compact`, entries that predate the compact boundary are dropped from the sum — `/compact` rewrites conversation history, which invalidates Anthropic's prompt cache for those tokens.

**Context % per model:** When using a multi-model setting (e.g., `/model opusplan`), the `ctx N%` figure changes as the active model switches. Each model has its own cached state; Claude Code computes `used_percentage` relative to the active model's view of the conversation, so the percentage legitimately differs between models. This is expected.

**Σ per-model rows** are computed by parsing the session's JSONL transcript (plus any sub-agent JSONL files in the same directory) on each new API response. The breakdown is written to `/tmp/claude_session_<id>/model_breakdown.txt` and read back on subsequent renders.

**Pricing** is fetched from LiteLLM's community-maintained `model_prices_and_context_window.json` at most once per 24 hours and cached in `/tmp/claude_pricing.txt`. Cache read/write rates follow Anthropic's standard ratios (read = 10%, write_5m = 125%, write_1h = 200% of the base input price) derived at runtime — only the base input and output rates are stored.

---

## FAQ

**Why does Sonnet appear during plan mode with `/model opusplan`?**
opusplan should route to Opus during plan mode (Shift+Tab) and to Sonnet for execution. When Sonnet appears during plan mode, it indicates a known routing bug ([#16982](https://github.com/anthropics/claude-code/issues/16982), [#35927](https://github.com/anthropics/claude-code/issues/35927)) where opusplan intermittently fails to switch back to Opus. **The statusline is correctly reporting the actual model used** — it's your canary that the bug has triggered.

Workarounds:
- Persist the setting in `~/.claude/settings.json` with `"model": "opusplan"` (setting it only in-session via `/model opusplan` can cause the routing to break mid-session)
- Manually run `/model opus` when entering plan mode if Sonnet is shown
- Use `/advisor` as an alternative that keeps Opus available on-demand

Note: even when opusplan works correctly, plan-mode Opus turns use the **200K** context window — not 1M — regardless of your context setting.

---

## Why the two cost figures differ

The top-line shows `$<harness> / $<local>`:

| Surface | Includes | Misses |
|---|---|---|
| `$<harness>` (= `/usage` "Total cost") | Parent conversation API calls, internal Haiku usage (title generation, summarization, plan-mode classifier) | **Sub-agent activity** ([#22625](https://github.com/anthropics/claude-code/issues/22625), [#10388](https://github.com/anthropics/claude-code/issues/10388)) |
| `$<local>` (= sum of Σ rows) | Parent conversation + every sub-agent JSONL on disk | Internal Haiku calls that bypass transcript files |

If `$<local>` is much higher than `$<harness>`, that gap is your sub-agents' cost.

Neither figure is the definitive Anthropic bill — for that, check the [Anthropic Console](https://console.anthropic.com/) dashboard. This divergence is a known gap in Claude Code's `/usage` tracking, tracked upstream in the issues linked above.

---

## Configuration

All configuration is in `statusline.sh`. Common knobs:

| What | Where | Default |
|---|---|---|
| Cache TTL countdown (seconds) | Line `remaining=$((300 - elapsed))` | 300 (5 min) |
| Context warning thresholds | Lines `ctx_color` conditionals | 50% / 80% |
| Hit % color thresholds | Lines `hit_color` conditionals | 80% / 40% |
| Pricing fetch interval | `MAX_AGE` in `refresh-pricing.sh` | 86400 (24h) |

---

## Testing

```bash
./tests/test.sh
```

Runs 59 assertions covering: harness JSON extraction (compact + pretty-printed), the `_snum` regression guard, multiple `display_name` ambiguity, JSONL aggregation (token summing, duplicate-uuid dedup, synthetic-entry filtering, `ephemeral_5m/1h` vs legacy `cache_creation_input_tokens`, cache-write double-count regression, web-search counter propagation), dual-cost top-line display (harness + local, fallback cases), dual-TTL display with 5m/1h token-count annotations, compact_boundary cache_log floor (pre-compact entries excluded), and an end-to-end render with Σ lines.

CI runs automatically on every push and pull request via GitHub Actions (no extra dependencies — `jq` is intentionally absent to verify the no-jq path).

---

## License

MIT — see [LICENSE](LICENSE).
