# claude-code-statusline

A feature-rich status line for [Claude Code](https://claude.ai/code) that shows real-time token usage, cache efficiency, cost breakdown per model (including sub-agents), and a TTL countdown for the prompt cache.

---

## What it looks like

**Line 1 — current turn:**
```
Opus 4.7 │ ctx 14%/200k │ $0.42 │ ↑1 +87kr +2kw ↓312 │ hit 97% │ ~ttl 4:12
```

**Line 2+ — per-model session totals (including sub-agents):**
```
Σ Opus 4.7:   ↑12 +1.4Mr +80kw ↓7k = $0.38
Σ Sonnet 4.6: ↑8  +210kr +30kw ↓3k = $0.04
```

| Field | Meaning |
|---|---|
| `ctx 14%/200k` | Context window usage (color: green < 50%, yellow < 80%, red ≥ 80%) |
| `$0.42` | Session cost — sum of Σ per-model rows |
| `↑N` | Fresh (uncached) input tokens this turn — almost always 1–6 |
| `+Xr` | Cache read tokens (billed at 10% of base price) |
| `+Xw` | Cache write tokens (billed at 125–200% of base price) |
| `↓N` | Output tokens generated |
| `hit X%` | `cache_read / (fresh + read + write)` for this turn |
| `~ttl X:XX` | Time until prompt cache *may* expire (~5-min floor, resets on each API call) |
| `Σ model: ...` | Cumulative token totals + cost per model, including all sub-agents |

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

**Σ per-model rows** are computed by parsing the session's JSONL transcript (plus any sub-agent JSONL files in the same directory) on each new API response. The breakdown is written to `/tmp/claude_session_<id>/model_breakdown.json` and read back on subsequent renders.

**Pricing** is fetched from LiteLLM's community-maintained `model_prices_and_context_window.json` at most once per 24 hours and cached in `/tmp/claude_pricing.json`. Cache read/write rates follow Anthropic's standard ratios (read = 10%, write_5m = 125%, write_1h = 200% of the base input price) derived at runtime — only the base input and output rates are stored.

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

## License

MIT — see [LICENSE](LICENSE).
