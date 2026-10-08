# Claude Usage — a Tern plugin

**English** | [简体中文](README.zh-CN.md)

See your Claude Pro / Max and ChatGPT (Codex) subscription limits live, right inside the Tern terminal — no browser tab, no guessing when your 5-hour window resets.

![Claude Usage panel next to a terminal, with the status bar segment at bottom right](assets/usage-panel.png)

Per-window progress bars with an elapsed-time marker, pace vs. even usage, reset countdowns, per-model weekly limits and extra-usage credits — plus a `5h 48% (38m) · 7d 48%` segment in the status bar.

## Features

- **Every limit in one panel** — 5-hour window, 7-day window, per-model weekly limits (Opus / Sonnet / …), extra usage credits, and promo quotas.
- **Claude / GPT tabs** — switch with `Tab`, `1` / `2` or a click; the choice is saved and decides what the panel and the status bar show by default. ChatGPT shows its 5-hour / 7-day Codex windows, the code-review limit and credits.
- **Pace tracking** — shows whether you're ahead of or behind an even burn rate, and warns with an ETA when you'll run out before reset.
- **Status bar segment** — color-coded usage + countdown, click to toggle a floating panel.
- **Zero-config accounts** — automatically picks up your Claude Code login (macOS Keychain or `~/.claude/.credentials.json`), your Codex CLI ChatGPT login (`~/.codex/auth.json`) and omp logins; or sign in to Claude with OAuth directly from the panel.
- **Multiple accounts** — one card per account, deduplicated across sources.
- **Polite polling** — reuses Claude Code's own cached usage when fresher, honors `Retry-After`, exponential backoff on 429, stops polling when nothing is visible.
- **Responsive layout** — adapts from narrow splits to wide panes; 48-sample sparklines on wide layouts.

## Install

```sh
tern plugin install https://github.com/zerx-lab/tern-claude-usage
```

Enable it in **Preferences › Plugins**. Then use the command palette:

- **订阅用量（Claude / GPT）：显示 / 隐藏额度浮窗** — toggle the floating panel
- **Claude 用量：登录订阅账户** — sign in to Claude with OAuth (ChatGPT accounts come from `codex login` or omp)
- **New Claude Usage block** — open as a regular split

## Keys

| Key | Action |
| --- | --- |
| `Tab` / `1` / `2` | Switch Claude / GPT |
| `r` | Refresh now |
| `l` | Sign in (Claude) |
| `j` / `k` | Select account |
| `x` | Remove (plugin-login accounts only) |
| `+` / `-` | Refresh interval (30s – 10m) |
| `c` | Toggle the current tab's CLI source (Claude Code / Codex) |
| `o` | Toggle omp sources |
| `s` | Toggle status bar |
| `?` | Help |

## Privacy

Talks only to Anthropic's endpoints (`api.anthropic.com`, `claude.ai`, `platform.claude.com`) and OpenAI's (`chatgpt.com` for usage, `auth.openai.com` for token refresh). Tokens stay on your machine: plugin-login tokens are stored in the plugin data dir with `600` permissions; Claude Code and Codex tokens are refreshed in place only once expired, without breaking either CLI; omp tokens are read-only.

## Development

```sh
brew install luau
python3 tests/run.py
```

Detailed design notes (account sources, OAuth flow, refresh policy, file map) are in [README.zh-CN.md](README.zh-CN.md).

## License

MIT
