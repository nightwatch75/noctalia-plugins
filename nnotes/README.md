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

## Requirements

- noctalia ≥ 5.0.0
- `xdg-open` (`xdg-utils`) — used to open the notes folder in your file
  manager (right-click on the bar widget, folder button in the panel)

## Install

Install **nnotes** from Noctalia's plugin store (*Settings → Plugins*), then
add the widget to a bar from *Settings → Bar*. Plugin options live in
*Settings → Plugins*.

For local development, add your working copy as a path source instead
(`.luau` edits hot-reload):

```sh
noctalia msg plugins source add dev path /path/to/plugins
noctalia msg plugins enable nightwatch75/nnotes
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

MIT.
