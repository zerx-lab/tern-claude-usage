# Claude Usage — a Tern plugin

**English** | [简体中文](README.zh-CN.md)

See your Claude Pro / Max and ChatGPT (Codex) subscription limits live — for as many accounts as you have — right inside the Tern terminal. No browser tab, no guessing when your 5-hour window resets or which account still has room.

![Claude Usage panel next to a terminal, with the status bar segment at bottom right](assets/usage-panel.png)

Per-window progress bars with an elapsed-time marker, pace vs. even usage, reset countdowns, per-model weekly limits and extra-usage credits, a cross-account summary — plus a `5h 48% (38m) · 7d 48%` segment in the status bar.

## Features

- **Every limit in one panel** — 5-hour window, 7-day window, per-model weekly limits (Opus / Sonnet / …), extra usage credits, and promo quotas.
- **Claude / GPT tabs** — switch with `Tab`, `1` / `2` or a click; the choice is saved and decides what the panel and the status bar show by default. ChatGPT shows its 5-hour / 7-day Codex windows, the code-review limit and credits.
- **Multiple accounts per provider** — sign in to any number of Claude and ChatGPT accounts with OAuth right from the panel; CLI and omp logins are picked up too and deduplicated across sources.
- **Cross-account summary** — average 5h / 7d use with a tick per account, spare capacity in whole windows, how many accounts are usable, the one with the most headroom, and when the first used-up account frees up.
- **Layouts** — cards, compact one-line rows with the selected account's card below, or automatic (cards up to two accounts); cards sit side by side on wide panes.
- **Customization** — per-account alias, hide, manual order or sorting by usage / reset / name, a status-bar pin; status bar shows the pinned account, the one with the most headroom, or every account, for the current tab or both providers; toggle pace, sparklines and per-model rows.
- **Pace tracking** — shows whether you're ahead of or behind an even burn rate, and warns with an ETA when you'll run out before reset.
- **Zero-config accounts** — automatically picks up your Claude Code login (macOS Keychain or `~/.claude/.credentials.json`), your Codex CLI ChatGPT login (`~/.codex/auth.json`) and omp logins.
- **Polite polling** — reuses Claude Code's own cached usage when fresher, honors `Retry-After`, exponential backoff on 429, skips hidden accounts, stops polling when nothing is visible.
- **Responsive layout** — adapts from narrow splits to wide panes; 48-sample sparklines on wide layouts.

## Install

```sh
tern plugin install https://github.com/zerx-lab/tern-claude-usage
```

Enable it in **Preferences › Plugins**. Then use the command palette:

- **订阅用量（Claude / GPT）：显示 / 隐藏额度浮窗** — toggle the floating panel
- **Claude 用量：登录订阅账户（可添加多个）** — add a Claude account with OAuth
- **GPT 用量：登录 ChatGPT 账户（可添加多个）** — add a ChatGPT account with OAuth
- **New Claude Usage block** — open as a regular split

## Keys

| Key | Action |
| --- | --- |
| `Tab` / `1` / `2` | Switch Claude / GPT |
| `r` | Refresh now |
| `l` | Sign in to another account of the current tab |
| `j` / `k` | Select account |
| `J` / `K` | Move account down / up (manual order) |
| `e` | Rename (alias) |
| `p` | Pin to the status bar |
| `h` | Hide / unhide |
| `a` | List hidden accounts |
| `v` | Cycle layout (auto / cards / compact) |
| `x` | Remove (plugin-login accounts only) |
| `+` / `-` | Refresh interval (30s – 10m) |
| `c` | Toggle the current tab's CLI source (Claude Code / Codex) |
| `o` | Toggle omp sources |
| `s` | Toggle status bar |
| `,` | Settings |
| `?` | Help |

## Privacy

Talks only to Anthropic's endpoints (`api.anthropic.com`, `claude.ai`, `platform.claude.com`) and OpenAI's (`chatgpt.com` for usage, `auth.openai.com` for sign-in and token refresh). Tokens stay on your machine: plugin-login tokens are stored in the plugin data dir with `600` permissions; Claude Code and Codex tokens are refreshed in place only once expired, without breaking either CLI; omp tokens are read-only.

## Development

```sh
brew install luau
python3 tests/run.py
```

Detailed design notes (account sources, OAuth flows, summary, settings, refresh policy, file map) are in [README.zh-CN.md](README.zh-CN.md).

## License

MIT
