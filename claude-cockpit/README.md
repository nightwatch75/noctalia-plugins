# Claude Cockpit

Keep an eye on your Claude Code sessions and subscription from the bar:
every running session and whether it needs you, rate-limit windows and
token cost, every session on the
machine grouped by project with one click to resume it in a terminal, and
quick access to edit CLAUDE.md files (global and per project) in your own
editor, plus install, update and uninstall for Claude Code skills and mods.

## Plugin

| Field | Value |
| --- | --- |
| ID | `nightwatch75/claude-cockpit` |
| Entries | Bar widget: `widget`; panel: `panel`; service: `service` |

The `service` entry is headless and owns the usage fetch loop and the live
session poll; `widget` and the panel's Live and Usage tabs are thin clients
of its published state, and the panel fetches the data for its other three
tabs itself, on demand.

## Requirements

- `jq` and `curl` on `PATH` — required for the Usage tab (the service checks
  for both and reports a status instead of running when either is missing).
- `bash`, plus the base userland `get-claude-usage` and
  `list-claude-sessions` call: `find`, `stat`, `grep`, `tac`, `awk`, `head`,
  `tail`, `rm`. These ship with coreutils, findutils, gawk, grep and bash on
  every supported distribution.
- An authenticated Claude Code install for the Usage tab, i.e.
  `~/.claude/.credentials.json` exists. Sessions and CLAUDE.md work
  regardless.
- `claude` on `PATH` for the Skills/Mods tab, and `xdg-open` to open a
  plugin's repository from it.
- `mkdir` and `mv` for the Live tab's transcript-stats cache.
- Optional: `niri` or `umbriel` to focus a live session's terminal window
  from the Live tab. On other compositors everything else still works.
- `code` or `zed` on `PATH` to open a CLAUDE.md from the panel (or set
  `editor_command` to something else).

## Usage

Add the **Claude Cockpit** widget to a bar from the Add-widget picker. Its
`display_mode` setting picks what it shows:

- **Activity** (default) — the glyph (a red bell while a session waits
  for you), one dot per running Claude Code
  session (red: needs you, accent: working, grey: idle; up to 8, then
  `+N`), and fill rings for the 5-hour session and 7-day weekly windows,
  each followed by `sNN%` / `wNN%` (which ones: `usage_percent_display`). Ring and text turn amber or
  red when usage runs ahead of the clock. The tooltip lists the live
  sessions, then the usage figures.
- **Classic** — the glyph plus the same percentages, without rings.

Click it to open the panel:

```sh
noctalia msg panel-toggle nightwatch75/claude-cockpit:panel
```

The panel has five tabs, each with a glyph; it opens on Live:

- **Live** — every running Claude Code session, grouped into *Needs you*,
  *Working* and *Idle*, with a total cost and per-group counters on top.
  Each card shows the session title, how long it has been in its state,
  project path and git branch, what it is waiting for (e.g.
  `permission: Bash`), the last prompt, and chips for model, permission
  mode, context size (with a gauge) and estimated cost in the configured
  currency. Click a card (or the terminal glyph) to focus the session's
  terminal window (niri and Umbriel); the globe glyph opens the session on
  claude.ai while Remote Control is on. Cost is estimated from the
  transcript's token usage and the Usage tab's price table, so it can
  differ slightly from `/cost`.

- **Usage** — rate-limit windows (5-hour session, 7-day plan-wide week, and a
  model-scoped week when the plan has one), token consumption for today,
  this week and this month with estimated cost, a Monday-to-Sunday activity
  chart (hover a bar for that day's detail), a per-model breakdown and
  all-time session/message stats.
- **Sessions** — every local Claude Code session, grouped by the project
  (working directory) it ran in, most recent first. Click a session to
  resume it (`claude --resume <id>`) in a terminal, opened in that project's
  directory. The brain glyph opens that project's `CLAUDE.md` in the editor
  (offering to create it if missing); the eye glyph expands a preview (the
  session's opening prompt); the trash glyph deletes the session's transcript
  after an inline confirm. The
  search box filters by title, opening prompt or project path. Fetched when the
  tab is first opened and on the header refresh button — never polled in the
  background.
- **CLAUDE.md** — the global file, every CLAUDE.md `find-claude-md` finds
  under `$HOME` (symlinks to e.g. `AGENTS.md` included, noise dirs — `.git`,
  `node_modules`, `.cache`, `.venv` — and remote/network mounts excluded),
  plus one row per session-linked project that has none yet so it can still
  be created. Each row has a badge and a button that opens it in your editor.
- **Skills/Mods** — every installed Claude Code plugin (skills and mods ship
  as plugins), grouped by marketplace, plus bare skill folders under
  `~/.claude/skills`. Per plugin: enable/disable (toggle glyph), update
  (download glyph) and uninstall (trash glyph, inline confirm). Per marketplace: refresh and remove (inline
  confirm; removing a marketplace also uninstalls its plugins). A GitHub
  glyph (or a link glyph for any other site) opens the project page: the
  plugin's own `repository`/`homepage`, else its folder in the marketplace
  repository; for a local skill, the source recorded by the `skills` CLI. Local skill folders can only be removed: nothing tracks where
  they came from. The install box at the bottom takes `plugin@marketplace`
  (or a bare plugin name) to install a plugin, or `owner/repo`, a git URL or
  a path to add a marketplace. Restart Claude Code to apply plugin changes.
  **Check updates** re-fetches every marketplace (`claude plugin marketplace
  update`, nothing is installed) and compares versions: a plugin with a newer
  version shows `old → new` and an up-arrow update glyph. Only on that click,
  never in the background. A plugin that lives in another repository than
  its marketplace, with no `version` in the catalog, cannot be checked; its
  update button still works.

Rename is deliberately not offered: Claude Code has no command to rename a
session after it is created, so there is nothing this panel could persist
that Claude's own `/resume` picker would also show. A session's label is its
AI-generated title, or its last prompt cut short when no title exists yet.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `usage_refresh_interval` | `int` | `2` | Minutes between background usage fetches (2–15). |
| `currency` | `select` | `auto` | Cost display: `auto` follows the locale, or force one of `usd`, `eur`, `gbp`, `jpy`, `cny`, `chf`, `aud`, `cad`, `inr`. |
| `currency_api_url` | `string` | `https://api.frankfurter.dev/v1/latest` | Exchange-rate API `get-claude-usage` fetches non-USD rates from (ECB rates via Frankfurter by default). |
| `terminal` | `string` | `""` | Command to open a terminal for resuming a session. Empty uses the system's own terminal discovery ($TERMINAL, then the usual emulators). |
| `editor_command` | `string` | `""` | Command to open a CLAUDE.md file. Empty tries `code`, then `zed`. |
| `display_mode` | `select` | `activity` | Bar widget mode: `activity` (live-session dots + session/weekly rings with percentages) or `classic` (glyph + usage percentages). |
| `glyph` | `glyph` | `robot` | Bar widget glyph. |
| `usage_percent_display` | `select` | `both` | Usage windows the widget shows, in both modes: `session` (`sNN%`, the 5-hour window), `weekly` (`wMM%`, the 7-day window), `both`, or `none`. Activity mode draws a ring before each percentage. |

## Notes

What this plugin touches, so nothing is a surprise:

- **Reads** `~/.claude/sessions/*.json` (the per-process state files Claude
  Code keeps for every running session; a file whose process is gone or
  whose pid was reused is ignored), and the transcript of each running
  session for its model, context size, cost, title, branch and last prompt
  — re-parsed only when the transcript changes. Every 2 seconds, but only
  while the widget is in activity mode or the panel is open on the Live
  tab; with neither, nothing is polled.
- **Reads** `~/.claude/.credentials.json` for the OAuth token that
  authorizes the usage query, `~/.claude/stats-cache.json` for all-time
  session/message stats (Usage tab only), and every
  `~/.claude/projects/**/*.jsonl` session transcript — never a whole file,
  only small `grep`/`tac`+`awk` slices, since a single line in one of these
  files can itself be hundreds of KB.
- **Writes** `~/.claude/pricing-cache.json` (LiteLLM model prices + currency
  rates, refreshed daily) and `~/.claude/usage-cache.json` (the rate-window
  API response, cached 120s) — both Usage tab only, both disposable caches
  safe to delete. In the plugin's data dir: `live/` (per-session transcript
  stats, deleted when the session ends) and `rings/` (the widget's small
  ring SVGs, one per percentage and theme color).
- **Network**: the Anthropic usage API for your account's rate windows;
  LiteLLM's public model-price table to cost the tokens; the `currency_api_url`
  exchange-rate API (Frankfurter/ECB by default) for USD to the configured
  currency. All over HTTPS, on the usage refresh interval — the Sessions and
  CLAUDE.md tabs make no network calls.
- **Spawns** `get-claude-usage`, `list-claude-sessions`, `find-claude-md`,
  `live-claude-sessions` and `focus-claude-session` through `bash`
  (`focus-claude-session` calls `niri msg` or `umbriel msg` to focus a
  window, reading only window ids and pids, never titles); `claude --version` (Usage tab, to set the API's
  `User-Agent`); a configured or auto-discovered terminal to resume a
  session; `code`/`zed` (or `editor_command`) to open a CLAUDE.md;
  `claude plugin` (list, install, update, enable, disable, uninstall, marketplace
  add/update/remove) for the Skills/Mods tab, only on a click or a tab open;
  `xdg-open` for a project link.
  `find-claude-md` walks `$HOME` on the CLAUDE.md tab's first open and its
  refresh button only, never on a timer — remote/network mounts (NFS, SMB,
  sshfs, and similar) under `$HOME` are detected via `/proc/mounts` and
  excluded, so a stalled share cannot stall it.
- **Deletes** files: the trash glyph on a session removes its
  `<uuid>.jsonl` transcript and, if present, its `<uuid>/` subagent sidecar
  directory — after an inline confirm, never without one. On the
  Skills/Mods tab, uninstall and marketplace remove go through
  `claude plugin`; removing a local skill deletes its folder under
  `~/.claude/skills` (a symlinked one loses the link only). Both after an
  inline confirm.

The Usage tab's data engine, `get-claude-usage`, is copied (MIT) from
[jrohland/claudecode](https://github.com/jrohland/noctalia-v5-claudecode)
with the Frankfurter exchange-rate API URL updated (`frankfurter.app` moved
to `frankfurter.dev`) and its Claude Code Switch (`~/.ccs/instances`)
multi-account scan removed — this plugin only ever reads the default
`~/.claude` account; see its own header comment and this plugin's `LICENSE`
for attribution. This plugin's own `shared.luau` is a trimmed port of its
formatters, same account scope.

Localized in English. Translations for other locales are welcome through
[Noctalia Translate](https://i18n.noctalia.dev).

## License

[MIT](LICENSE)
