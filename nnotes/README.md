# nnotes

A [noctalia](https://github.com/noctalia-dev/noctalia) bar plugin: a one-click scratchpad.
Click the bar glyph to toggle a floating editor panel on a single notes file
(plain `.txt`), with autosave. The glyph lights up while the panel is open.

> **Note:** this plugin was created as a stopgap while waiting for an official
> notes plugin, which has since been released by the Noctalia developers and is
> available at <https://github.com/noctalia-dev/official-plugins>.

## Plugin

| Field | Value |
| --- | --- |
| ID | `nightwatch75/nnotes` |
| Entries | Bar widget: `nnotes`; panel: `panel` |

## Usage

Add the `nnotes` widget from Noctalia's widget picker and click it to open the
notes panel. You can also open the panel directly or bind it in your
compositor:

```sh
noctalia msg panel-toggle nightwatch75/nnotes:panel
```

| Action       | Effect                                        |
|--------------|-----------------------------------------------|
| Left click   | Open/close the notes panel                    |
| Right click  | Open the notes folder in the file manager     |
| Middle click | Copy the notes file path to the clipboard     |

| Key          | Action                                    |
|--------------|-------------------------------------------|
| `Ctrl+Enter` | Save now                                  |
| `Esc`        | Close the panel (noctalia default; saves) |

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

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `notes_folder` | `folder` | *(empty)* | Where the notes file lives. Empty = `~/Notes`. |
| `file_name` | `string` | `notes.txt` | Single text file the panel edits. |
| `autosave_seconds` | `int` | `5` | Idle seconds before unsaved changes are written. `0` saves only on close / `Ctrl+Enter`. |
| `glyph` (widget) | `glyph` | `notes` | Icon shown on the bar. |

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

## License

MIT.
