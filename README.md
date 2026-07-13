# noctalia-plugins

Personal collection of [noctalia](https://github.com/noctalia-dev/noctalia) plugins.
Each plugin lives in its own subdirectory (`<plugin>/plugin.toml`), following
noctalia's git plugin-source convention.

Add this repo as a source in `~/.config/noctalia/config.toml`:

```toml
[[plugins.source]]
kind = "git"
name = "nightwatch75"
location = "https://github.com/nightwatch75/noctalia-plugins.git"
```

## Plugins

| Plugin | Id | Description |
|--------|----|-------------|
| [nnotes](nnotes/) | `nightwatch75/nnotes` | One-click scratchpad: a bar glyph toggles a floating editor panel on a single notes file, with autosave |
| [dns-switcher](dns-switcher/) | `nightwatch75/dns-switcher` | Switch the system DNS resolver from the bar |
| [file-search](file-search/) | `nightwatch75/file-search` | Fuzzy search files and folders as you type (fzf-powered), open results via MIME association |
| [todo](todo/) | `nightwatch75/todo` | Prioritised to-do list on the bar: editable tasks with low/medium/important colour chips, done toggle with strike-through, sorted by priority |

## License

MIT — see [LICENSE](LICENSE).
