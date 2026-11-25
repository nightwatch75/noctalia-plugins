# nnotes

A [noctalia](https://github.com/noctalia-dev/noctalia) bar plugin: a one-click scratchpad.
Click the bar glyph to toggle a floating panel: a notes list on the left, an
editor on the right. Every note is one `.md` or `.txt` file in a folder, saved
automatically. The glyph lights up while the panel is open.

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
| Middle click | Copy the notes folder path to the clipboard   |

Middle click is freed in the manifest (`middle = "none"`); settings open from
the panel's ⚙ button.

| Key          | Action                                    |
|--------------|-------------------------------------------|
| `Ctrl+Enter` | Save now                                  |
| `Esc`        | Close the panel (noctalia default; saves) |

The editor header has the note name (Enter renames), save, delete, folder, ⚙
and close buttons. The ⚙ button opens this plugin's settings page, also
reachable from the command line:

```sh
noctalia msg settings-open-plugin nightwatch75/nnotes
```

## Features

- The list shows the notes folder. **+** starts a new note; it is created on
  the first text you type and lands at the top.
- The sort button under the search box cycles manual order, name A–Z,
  name Z–A and newest first. In manual order, drag the grip (≡) of a row to
  reorder. Sort mode and order are saved in `.nnotes.json` inside the notes
  folder. Pinned notes always stay on top.
- The pin button keeps a note at the top and disables its delete button until
  you unpin it.
- The save button writes the text now and applies a name you typed in the
  title field (Enter does the same for the name).
- The search box filters by file name and, when `grep` is installed, by file
  content.
- Delete asks for a second click before it removes the file.
- Switching note, closing the panel and `Ctrl+Enter` all save first.
- The panel footer shows a live word/character count and a saved/editing
  status.
- Panel placement (attached/floating), position and open-near-click are the
  standard per-panel settings noctalia exposes in *Settings → Plugins*.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `notes_folder` | `folder` | *(empty)* | Folder with one file per note. Empty = `~/Documents/Nnotes`. |
| `autosave_seconds` | `int` | `5` | Idle seconds before unsaved changes are written (0–300). `0` saves only on close, note switch and `Ctrl+Enter`. |
| `glyph` (widget) | `glyph` | `notes` | Icon shown on the bar. |

## Requirements

- noctalia with plugin API 24 or newer (noctalia v5.0.0-beta.9 or newer)
- `xdg-open` (`xdg-utils`) — opens the notes folder (right-click on the bar
  widget, folder button in the panel)
- `grep` — content search in the panel (optional; without it search matches
  file names only)

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
