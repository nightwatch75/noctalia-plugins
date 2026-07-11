# nnotes

A [noctalia](https://github.com/noctalia-dev/noctalia) bar plugin: a one-click scratchpad.
Click the bar glyph to toggle a floating editor panel on a single notes file
(plain `.txt`), with autosave. The glyph lights up while the panel is open.

> **Note:** this plugin was created as a stopgap while waiting for an official
> notes plugin, which has since been released by the Noctalia developers and is
> available at <https://github.com/noctalia-dev/official-plugins>.

## Features

- Configurable glyph, notes folder, file name
- Left click: open/close the panel — Right click: open the notes folder —
  Middle click: copy the file path (same actions available as panel buttons)
- Autosave after N idle seconds (configurable, `0` disables the timer) plus
  save on `Ctrl+Enter` and on panel close, so toggling it shut never loses
  what you just typed
- Live word/char count and saved/editing status in the panel footer
- Panel placement (attached/floating), position and open-near-click are the
  standard per-panel settings noctalia exposes in Settings → Plugins

## Install

noctalia discovers plugins from configured sources. By convention the plugin
id `nightwatch75/nnotes` maps to the `nnotes/` subdirectory of the source repo.

Add the [noctalia-plugins](../) repo as a git source and enable the plugin in
`~/.config/noctalia/config.toml`:

```toml
[plugins]
enabled = ["nightwatch75/nnotes"]

[[plugins.source]]
kind = "git"
name = "nightwatch75"
location = "https://github.com/nightwatch75/noctalia-plugins.git"
```

For local development, point a path source at your working copy instead
(noctalia hot-reloads `.luau` changes):

```toml
[[plugins.source]]
kind = "path"
name = "dev"
location = "/path/to/noctalia-plugins"
```

Restart noctalia, then add the **nnotes** widget to a bar from
Settings → Bar. Plugin options live in Settings → Plugins.

## Keys

| Key          | Action                                   |
|--------------|------------------------------------------|
| `Ctrl+Enter` | Save now                                 |
| `Esc`        | Close the panel (noctalia default; saves) |

The panel can also be driven externally:

```sh
noctalia msg panel-toggle nightwatch75/nnotes:panel
```

## License

MIT — see [LICENSE](LICENSE).
