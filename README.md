# claude-code-statusline

A feature-rich status line for [Claude Code](https://claude.ai/code) that shows real-time token usage, cache efficiency, cost breakdown per model (including sub-agents), and a TTL countdown for the prompt cache.

---

## What it looks like

**Line 1 — current turn:**
```
Opus 4.7 │ ctx 14%/200k │ $0.42 / $0.65 │ ↑1 +87kr +2kw ↓312 │ hit 97% │ ~ttl 0:59:01(89k)
```

**Line 2+ — per-model session totals (including sub-agents), plus `/compact` cost:**
```
Σ Opus 4.7:   ↑12 +1.4Mr +80kw ↓7k = $0.38
Σ Sonnet 4.6: ↑8  +210kr +30kw ↓3k = $0.27
Σ /compact ×2: $0.42
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
| `~ttl T(Xk)` | Countdown until the cached portion of your current context expires + how many tokens of the current context are cached (`cache_read + cache_write` of this call). Uses 1h-tier countdown when last cache write went to the 1h tier, 5m-tier otherwise. Timer is per-model — switching models shows the correct remaining TTL for that model's cache. |
| `+Nws` | Web-search requests this model made, billed at $10 / 1k |
| `Σ model: ...` | Cumulative token totals + cost per model, from transcript JSONLs including sub-agents |
| `Σ /compact ×N: $X` | Cumulative cost of the `N` `/compact` summarizations run this session. Exact, not estimated — each is the `cost.total_cost_usd` step captured at the compact boundary |

---

## Features

- **Live per-model cost breakdown** — separate Σ rows for Opus, Sonnet, Haiku, and any future models
- **Sub-agent token tracking** — Explore, Plan, inline Task agents *and* nested `ultracode`/Workflow fleets are all folded into the Σ totals
- **`/compact` cost tracking** — a cumulative `Σ /compact ×N` row showing exactly what compaction has cost this session (`/clear` is free and shows nothing)
- **Auto-updating pricing** — fetches latest rates from [LiteLLM's database](https://github.com/BerriAI/litellm/blob/main/model_prices_and_context_window.json) once per day; covers all active and legacy Claude models with correct per-version rates
- **Cache hit % and TTL countdown** — tells you how efficiently the cache is being used and when it might expire
- **Hardcoded fallback rates** — works offline; if LiteLLM is unreachable the last-known rates stay in effect. Models LiteLLM doesn't list yet (e.g. Fable 5 at $10/$50 per Mtok) are covered by built-in family fallbacks
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

To stop backups from piling up, `install.sh` keeps only the **3 most recent backup generations** (each install is one generation, grouping that run's `statusline.sh`/`refresh-pricing.sh`/`settings.json` backups under a shared timestamp) and prunes older ones automatically. Adjust the `MAX_BACKUPS` variable near the top of `install.sh` to change the limit.

---

## How it works

The statusline script is invoked by Claude Code every second via `refreshInterval: 1`. It receives a JSON blob on stdin with the current session state and prints the status lines.

**Top-line cost** shows two figures: `$<harness>` is read directly from Claude Code's `cost.total_cost_usd` field and matches `/usage`'s "Total cost" exactly. `$<local>` is the sum of the Σ per-model rows and includes sub-agent activity that `/usage` omits. When only one is available, just that value is shown. Neither figure equals the authoritative Anthropic Console bill.

**TTL countdown** shows `T(Xk)` where `T` is the remaining TTL and `Xk` is how much of the current context is cached. Specifically, `Xk = cache_read + cache_write` from the active model's most recent API call — this matches `ctx N%` size closely, because those two fields together cover the cached portion of the conversation sent to the API. The timer uses the **1h-tier countdown** when the most recent cache write went to the 1h cache tier (common in Claude Code), otherwise the 5m-tier countdown. The countdown is **per-model**: it tracks the last API call to the active model, so when switching models (e.g., opusplan toggling between Opus and Sonnet), the timer immediately reflects how long ago that model was last called. After `/compact`, cache_log entries older than the compact boundary are excluded — `/compact` rewrites conversation history and invalidates the prompt cache.

**Context % per model:** When using a multi-model setting (e.g., `/model opusplan`), the `ctx N%` figure changes as the active model switches. Each model has its own cached state; Claude Code computes `used_percentage` relative to the active model's view of the conversation, so the percentage legitimately differs between models. This is expected.

**Σ per-model rows** are computed by parsing the session's JSONL transcript (plus every sub-agent JSONL found recursively under the session's `subagents/` directory — including nested `ultracode`/Workflow fleets in `subagents/workflows/wf_*/`) on each new API response. The breakdown is written to `/tmp/claude_session_<id>/model_breakdown.txt` and read back on subsequent renders.

**`/compact` cost** is tracked separately because the summarization call it triggers never appears as a usage-bearing assistant entry in the transcript — so the Σ per-model rows can't see it. Claude Code does, however, fold the compaction cost into `cost.total_cost_usd` (verified empirically: the harness total steps up by the exact compaction cost at the moment a new `compact_boundary` is written). The statusline records the harness total at each completed turn and, when a new compact boundary appears, attributes the cost rise since the last turn to that compaction — accumulating it into the `Σ /compact ×N` row. (Anchoring to the last turn rather than the immediately previous render matters for slow compactions: the harness can bump `total_cost_usd` a render or two *before* the boundary line lands in the transcript, so a render-to-render delta would collapse to zero.) State lives in `/tmp/claude_session_<id>/compact_cost.txt`. Because the figure is the real harness delta, it's exact, not estimated. Compactions that happened *before* the feature was active aren't priced retroactively (their deltas were never captured), and `/clear` — which starts a new session with a fresh state dir and costs nothing — never produces a row. Both manual and auto-compactions are counted. Because the value is the harness-total delta measured across the compaction render, any other cost that settles in that same instant can fold in too — an auto-compaction firing mid-turn, or a manual `/compact` issued before the previous turn's cost has posted.

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

`/compact` cost sits on the `$<harness>` side of this split: it's folded into `cost.total_cost_usd` but never reaches the transcript, so it's absent from `$<local>`. The dedicated `Σ /compact ×N` row breaks out that component so you can see how much of the harness total is compaction.

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

Runs 88 assertions covering: harness JSON extraction (compact + pretty-printed), the `_snum` regression guard, multiple `display_name` ambiguity, JSONL aggregation (token summing, duplicate-uuid dedup, synthetic-entry filtering, `ephemeral_5m/1h` vs legacy `cache_creation_input_tokens`, cache-write double-count regression, web-search counter propagation), recursive sub-agent collection (inline subagents plus nested `ultracode`/Workflow fleets, both folded into Σ), unknown-family models (Fable 5 with a `[1m]` context-beta id: cache_log filter, ctx/ttl freshness, Σ display name, pricing fallback), dual-cost top-line display (harness + local, fallback cases), dual-TTL display with 5m/1h token-count annotations, compact_boundary cache_log floor (pre-compact entries excluded), `/compact` cost capture (per-boundary delta accumulation, no double-counting on normal turns, no retroactive pricing of pre-feature compactions, the long-compaction lead race where the harness bumps cost before the boundary lands, and back-to-back compactions with no turn between), and an end-to-end render with Σ lines.

CI runs automatically on every push and pull request via GitHub Actions (no extra dependencies — `jq` is intentionally absent to verify the no-jq path).

---

## License

MIT — see [LICENSE](LICENSE).
