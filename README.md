# claude-code-statusline

A feature-rich status line for [Claude Code](https://claude.ai/code) that shows real-time token usage, cache efficiency, cost per model split between the main conversation and its sub-agents, and a TTL countdown for the prompt cache. Verified against Claude Code 2.1.290.

---

## What it looks like

**Line 1 — current turn:**
```
Opus 4.7 (xhigh) │ ctx 14%/200k │ $0.42 / $0.65 │ ↑1 +87kr +2kw ↓312 │ hit 97% │ ~ttl 0:59:01(89k)
```

**Line 2+ — per-model session totals, split main vs sub-agents, plus `/compact` cost:**
```
Σ Fable 5.1: ↑634 +2.5Mr +99kw ↓23k = $4.12 +3ws (main)
Σ Sonnet 5: ↑28 +314kr +68kw ↓14k = $0.312 (agents ×2)
Σ Opus 5.5: ↑16 +433kr +41kw ↓3.4k = $0.92 (main $0.60 · agents ×3 $0.32)
Σ /compact ×2: $0.42
```

| Field | Meaning |
|---|---|
| `(xhigh)` | Effort level of the session (`effort.level` on CC 2.1.29x: low / medium / high / xhigh / max). Omitted when the CLI doesn't send it |
| `ctx 14%/200k` | Context window usage (color: green < 50%, yellow < 80%, red ≥ 80%) |
| `$0.42 / $0.65` | Session cost: `$<harness>` (Claude Code's own counter, sub-agents included) `/` `$<local>` (sum of the Σ rows: whole transcript incl. sub-agents, LiteLLM rates) — see *Why the two cost figures differ* |
| `↑N` | Fresh (uncached) input tokens this turn — almost always 1–6 |
| `+Xr` | Cache read tokens (10% of base input for most models; 5% for Opus 5.5, 2.5% for Fable 5.1 / Mythos 5.1) |
| `+Xw` | Cache write tokens total this turn (125% of base for the 5m tier, 200% for the 1h tier) |
| `↓N` | Output tokens generated |
| `hit X%` | `cache_read / (fresh + read + write)` for this turn |
| `~ttl T(Xk)` | Countdown until the cached portion of your current context expires + how many tokens of the current context are cached (`cache_read + cache_write` of this call). Uses 1h-tier countdown when last cache write went to the 1h tier, 5m-tier otherwise. Timer is per-model — switching models shows the correct remaining TTL for that model's cache. |
| `Σ model: ...` | Cumulative token totals + cost per model, from transcript JSONLs including sub-agents |
| `+Nws` | On a Σ row: web-search requests made with that model, billed at $10 / 1k. Web fetches have no per-request fee (their content is billed as input tokens) |
| `(main)` / `(agents ×N)` / `(main $X · agents ×N $Y)` | Who spent it: only the main conversation, only `N` sub-agents, or both with each side's cost. `N` counts the sub-agent transcripts that used this model |
| `Σ /compact ×N: $X` | Cumulative cost of the `N` `/compact` summarizations run this session. Exact, not estimated — each is the `cost.total_cost_usd` step captured at the compact boundary |

---

## Features

- **Live per-model cost breakdown** — separate Σ rows for Opus, Sonnet, Haiku, and any future models
- **Sub-agent cost attribution** — Explore, Plan, inline Task agents *and* nested `ultracode`/Workflow fleets are folded into the Σ totals, and every row says how much of it the sub-agents spent. `/usage` can't show this: its ledger lumps everything together
- **`/compact` cost tracking** — a cumulative `Σ /compact ×N` row showing exactly what compaction has cost this session (`/clear` is free and shows nothing)
- **Auto-updating pricing** — fetches latest rates from [LiteLLM's database](https://github.com/BerriAI/litellm/blob/main/model_prices_and_context_window.json) once per day; covers all active and legacy Claude models with correct per-version rates
- **Cache hit % and TTL countdown** — tells you how efficiently the cache is being used and when it might expire
- **Hardcoded fallback rates** — works offline; if LiteLLM is unreachable the last-known rates stay in effect, and a built-in table covers every current family (including the per-model cache-read rates of Opus 5.5 and Fable / Mythos 5.1)
- **Zero token cost** — reads from local JSONL files and `/tmp`, makes no Anthropic API calls (the only network call is the daily pricing fetch from GitHub)

---

## Requirements

- [Claude Code](https://claude.ai/code) 2.x
- `bash` 3.2+ (default on macOS; bash 4+ recommended for best compatibility)
- `curl` (for the pricing fetch)
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
2. Back up any existing `~/.claude/statusline.sh`, and record your current `statusLine` **value** so it can be restored later
3. Copy scripts to `~/.claude/` and make them executable
4. Patch **only** the `statusLine` key in `~/.claude/settings.json` to activate the statusline
5. Fetch the initial pricing cache from LiteLLM

> **Your other settings are never touched.** Install and uninstall only ever read or write the single `statusLine` key — the rest of `settings.json` is left exactly as-is. The installer does **not** copy your whole `settings.json` to a backup, so uninstall can never restore a stale full file over settings you've changed since.

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

`install.sh` creates timestamped backups of the scripts it overwrites (`~/.claude/statusline.sh.bak.<ts>`, `~/.claude/refresh-pricing.sh.bak.<ts>`) and records your prior `statusLine` **value** (`~/.claude/settings.json.statusLine.bak.<ts>`). To go back:

```bash
./uninstall.sh
```

`uninstall.sh` restores the previous scripts and **the `statusLine` key only** — putting back exactly the value you had before (or removing the key entirely if you had no statusline before). Every other key in `settings.json` is left untouched. It **never** overwrites your whole `settings.json` from a backup, so it can't wipe settings you've added since installing. If you've run the installer more than once, it lists the available timestamps and lets you pick which generation to revert to.

To stop backups from piling up, `install.sh` keeps only the **3 most recent backup generations** (each install is one generation, grouping that run's `statusline.sh`/`refresh-pricing.sh` backups and the saved `statusLine` value under a shared timestamp) and prunes older ones automatically. Adjust the `MAX_BACKUPS` variable near the top of `install.sh` to change the limit.

---

## How it works

The statusline script is invoked by Claude Code every second via `refreshInterval: 1`. It receives a JSON blob on stdin with the current session state and prints the status lines.

**Top-line cost** shows two figures: `$<harness>` is read directly from Claude Code's `cost.total_cost_usd` field and matches `/usage`'s "Total cost". `$<local>` is the sum of the Σ per-model rows. Both include sub-agents; see *Why the two cost figures differ* for what still separates them. When only one is available, just that value is shown. Neither figure equals the authoritative Anthropic Console bill.

**TTL countdown** shows `T(Xk)` where `T` is the remaining TTL and `Xk` is how much of the current context is cached. Specifically, `Xk = cache_read + cache_write` from the active model's most recent API call — this matches `ctx N%` size closely, because those two fields together cover the cached portion of the conversation sent to the API. The timer uses the **1h-tier countdown** when the most recent cache write went to the 1h cache tier (common in Claude Code), otherwise the 5m-tier countdown. The countdown is **per-model**: it tracks the last API call to the active model, so when switching models (e.g., opusplan toggling between Opus and Sonnet), the timer immediately reflects how long ago that model was last called. After `/compact`, cache_log entries older than the compact boundary are excluded — `/compact` rewrites conversation history and invalidates the prompt cache.

**Context % per model:** When using a multi-model setting (e.g., `/model opusplan`), the `ctx N%` figure changes as the active model switches. Each model has its own cached state; Claude Code computes `used_percentage` relative to the active model's view of the conversation, so the percentage legitimately differs between models. This is expected.

**Σ per-model rows** are computed by parsing the session's JSONL transcript (plus every sub-agent JSONL found recursively under the session's `subagents/` directory — including nested `ultracode`/Workflow fleets in `subagents/workflows/wf_*/`) on each new API response, and at most every 45s while idle so background fleets keep updating. Each API call is counted once: Claude Code writes one line per content block and repeats the usage while streaming, so the scan keeps only the last line per `message.id`. The parent transcript's lines count as **main**, every `agent-*.jsonl` as a sub-agent, which is where the `(main …)` / `(agents ×N …)` suffix comes from. The breakdown is written to `/tmp/claude_session_<id>/model_breakdown.txt` and read back on subsequent renders.

**`/compact` cost** is tracked separately because the summarization call it triggers never appears as a usage-bearing assistant entry in the transcript — so the Σ per-model rows can't see it. Claude Code does, however, fold the compaction cost into `cost.total_cost_usd` (verified empirically: the harness total steps up by the exact compaction cost at the moment a new `compact_boundary` is written). The statusline records the harness total at each completed turn and, when a new compact boundary appears, attributes the cost rise since the last turn to that compaction — accumulating it into the `Σ /compact ×N` row. (Anchoring to the last turn rather than the immediately previous render matters for slow compactions: the harness can bump `total_cost_usd` a render or two *before* the boundary line lands in the transcript, so a render-to-render delta would collapse to zero.) State lives in `/tmp/claude_session_<id>/compact_cost.txt`. Because the figure is the real harness delta, it's exact, not estimated. Compactions that happened *before* the feature was active aren't priced retroactively (their deltas were never captured), and `/clear` — which starts a new session with a fresh state dir and costs nothing — never produces a row. Both manual and auto-compactions are counted. Because the value is the harness-total delta measured across the compaction render, any other cost that settles in that same instant can fold in too — an auto-compaction firing mid-turn, or a manual `/compact` issued before the previous turn's cost has posted.

**Pricing** is fetched from LiteLLM's community-maintained `model_prices_and_context_window.json` at most once per 24 hours and cached in `/tmp/claude_pricing.txt`: base input, output, cache read, cache write 5m and cache write 1h per model. Cache rates are stored per model because they are no longer fixed ratios: Opus 5.5 reads cost 5% of base input and Fable 5.1 / Mythos 5.1 reads 2.5%, while older models keep read = 10%, write_5m = 125%, write_1h = 200%. Those classic ratios are the fallback when a rate is missing.

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

The top-line shows `$<harness> / $<local>`. On Claude Code 2.1.29x the two should be close. Both include sub-agents: measured on 2.1.290, each sub-agent API call stepped the harness total by exactly its priced cost.

| Surface | Includes | Misses |
|---|---|---|
| `$<harness>` (= `/usage` "Total cost") | Main conversation and sub-agent calls as they land, plus internal calls that no transcript records (web search runs on Haiku; title generation, summarization). Since CC 2.1.246 it is saved at process exit and restored on resume | History before a reset: `/clear` starts over, and so does any run that fails to restore the saved counter (e.g. after a crash) |
| `$<local>` (= sum of Σ rows) | The whole transcript history: parent + every sub-agent JSONL on disk, incl. Workflow fleets, split per model into main vs sub-agents | Internal calls that never reach a transcript; `/compact` summarizations; fleet activity newer than the last Σ scan (idle renders re-scan at most every 45s) |

So what still separates them: internal calls and `/compact` (harness only), a reset counter (local keeps the older history), and pricing-table drift (local uses LiteLLM rates, the harness uses Claude Code's own table).

`/usage` itself shows the harness ledger: per process and **unattributed**, so it can't tell you what your sub-agents cost. That's why the Σ rows are rebuilt from the transcripts instead.

`/compact` cost sits on the `$<harness>` side of this split: it's folded into `cost.total_cost_usd` but never reaches the transcript, so it's absent from `$<local>`. The dedicated `Σ /compact ×N` row breaks out that component so you can see how much of the harness total is compaction.

Neither figure is the definitive Anthropic bill — for that, check the [Anthropic Console](https://console.anthropic.com/) dashboard.

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

Runs 186 assertions covering: harness JSON extraction (compact + pretty-printed), the `_snum` regression guard, multiple `display_name` ambiguity, install/uninstall settings safety (only the `statusLine` key is ever read or written; unrelated keys survive a full install→uninstall cycle; install aborts early with a clear recovery hint if a source file is missing), corrupt `cache_log` resilience (a poisoned entry from an older/garbled parser is ignored on read and purged on the next turn, so it can't wedge the ctx display), per-model TTL after a mid-session model switch (cache_log entries are tagged with the same stdin-derived family prefix the reader filters by, and the 5m/1h tier is read from the active model's own newest transcript line — a stale or foreign trailing line can't flip the tier or zero the cached amount), crash-safe turn commits (the turn marker lands only after cache_log, so a render killed mid-turn retries instead of freezing the ttl at `expired(0)`; Σ regeneration is throttled through unique per-render scratch files — skipped when already current or in flight, re-armed by subagent JSONL growth alone, orphaned scratch from killed renders purged), the Claude Code 2.1.187+ stdin schema (`current_usage` nested under `context_window`, and `rate_limits.*.used_percentage` disambiguation so a rate-limit % never leaks into the context display), JSONL aggregation (token summing, duplicate-uuid dedup, synthetic-entry filtering, `ephemeral_5m/1h` vs legacy `cache_creation_input_tokens`, cache-write double-count regression, web-search counter propagation), recursive sub-agent collection (inline subagents plus nested `ultracode`/Workflow fleets, both folded into Σ), unknown-family models (Fable 5 with a `[1m]` context-beta id: cache_log filter, ctx/ttl freshness, Σ display name, pricing fallback), dual-cost top-line display (harness + local, fallback cases), dual-TTL display with 5m/1h token-count annotations, compact_boundary cache_log floor (pre-compact entries excluded), `/compact` cost capture (per-boundary delta accumulation, no double-counting on normal turns, no retroactive pricing of pre-feature compactions, the long-compaction lead race where the harness bumps cost before the boundary lands, and back-to-back compactions with no turn between), an end-to-end render with Σ lines, and the CC 2.1.2xx regressions (NUL crash-padding in transcripts can't hide fresh lines from the ttl/compact greps; `usage.iterations[]` multi-pass turns are summed across iterations for both Σ and the ttl tier instead of first-matching the one-iteration top-level copy; idle renders probe at most every 45s and regenerate Σ while a background Workflow fleet burns without a main-loop turn; a `0/0` cache-write whiff inherits the previous same-family tier instead of flipping a live 1h cache to the 5m countdown — unless the previous entry predates the last `/compact`), and the CC 2.1.29x changes (`"iterations":[]` on every line reads the top-level usage instead of summing an empty array to zero; one count per `message.id`, so streaming checkpoints with growing output can't multiply sub-agent cache tokens; real 2.1.290 stdin samples, pretty and compact, including a fresh session's `null` usage; the effort level after the model name; the Mythos family; per-model cache rates checked against a harness-measured Opus 5.5 call; web fetches carry no request fee; and the main vs sub-agent split with its three suffix forms and legacy 8-column breakdown files). The Σ tests run the production awk, extracted from `statusline.sh` between the `SIGMA_AWK` markers, so the test copy can't drift from the real parser.

CI runs automatically on every push and pull request via GitHub Actions (no extra dependencies — `jq` is intentionally absent to verify the no-jq path).

---

## License

MIT — see [LICENSE](LICENSE).
