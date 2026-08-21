# To Do

A [noctalia](https://github.com/noctalia-dev/noctalia) v5 bar plugin: a
prioritised to-do list. Click the bar glyph to toggle a panel of task rows —
add tasks with **+**, tick them off (the text is struck through), and set each
task's priority. Right-click a task for a context menu with edit, done,
priority and delete. The list is kept sorted by priority and stored as a single
JSON file; no external commands are run.

## Plugin

| Field | Value |
| --- | --- |
| ID | `nightwatch75/todo` |
| Entries | Bar widget: `todo`; panel: `panel` |

## Usage

Add the `todo` widget from Noctalia's widget picker and click it to open the
task panel. You can also open the panel directly or bind it in your compositor:

```sh
noctalia msg panel-toggle nightwatch75/todo:panel
```

| Action                       | Effect                                              |
|-------------------------------|-----------------------------------------------------|
| Left click (bar glyph)        | Open/close the To Do panel                          |
| **+** (panel header)          | Add a new task and start typing it                  |
| Sort toggle (panel header)    | Switch ordering between **Priority** and **Manual** |
| Colour chip (row)             | Cycle the task's priority: important → medium → low |
| ☰ grip (row, manual only)     | Drag the row to a new position (reorder)            |
| Click the task's text          | Edit the task's text                                |
| **Right-click** the task's text | Open the row menu: edit, done, priority, delete    |
| **Enter**, or ✓ (row)         | Commit the edit — the row goes back to a static line |
| ☐ / ☑ button (row)            | Toggle done/to-do (done tasks are struck through)   |
| 🗑 button (panel header)       | Delete every done task (asks first)                 |
| ⚙ button (panel header)       | Open this plugin's page in *Settings → Plugins*     |

That settings page also opens from the command line, so it can be bound in your
compositor too:

```sh
noctalia msg settings-open-plugin nightwatch75/todo
```

## Priorities

Each task carries a priority, shown at the start of the row as a small coloured
square. Click the square to cycle it. A legend at the foot of the panel maps
each colour to its category:

| Priority  | Colour |
|-----------|--------|
| Important | red    |
| Medium    | amber  |
| Low       | green  |

## Ordering

The panel header carries a toggle that switches between two ordering modes; the
choice is remembered.

- **Priority** (default) — rows are sorted by priority: important first, then
  medium, then low. Changing a task's priority moves it into its new group but
  keeps its position relative to its peers; equal-priority rows are never
  reshuffled. No grips are shown.
- **Manual** — rows keep the order you give them. Each row grows a ☰ grip on the
  left; here changing a priority only recolours the chip and never moves the row.

Priority mode is only a view: the stored order is always the manual one, so
switching between the two modes (as often as you like) never loses your custom
ordering.

### Reordering in manual mode

Grab a row by its ☰ grip and drag it. Thin insertion zones open up between the
rows as you drag; drop the row on one to move it there. This uses noctalia's
declarative drag-and-drop, which needs plugin API ≥ 5.

## The row menu

Right-click a task's text to open a native context menu:

| Entry              | Effect                                        |
|--------------------|-----------------------------------------------|
| Edit task          | Put the row into edit mode                    |
| Mark as done/to do | Same as the row's ☐ / ☑ button                 |
| Priority           | Set the priority directly (● marks the current one) |
| Delete task        | Remove the task                                |

The menu is why a row carries only one button: everything that used to need a
pencil and a trash icon on every line lives here now, which leaves the task text
much more room. It needs plugin API ≥ 28.

## Editing

Rows are static lines by default. Click a task's text (or pick **Edit task**
from the row menu) to edit it; press **Enter** or the ✓ button to commit back to
a static line. A new task (**+**) opens straight into edit mode — committing it
while still empty simply discards it. Edits are also autosaved after a short
idle pause and on close.

Tick a task (☐ → ☑) to complete it — its text is struck through until you
un-tick it. The bar glyph's tooltip shows how many tasks are still to do.

A task longer than the row wraps onto further lines and the row grows to fit,
so the whole text stays readable and never runs under the button on the
right.

## Storage

Tasks live in one file, `todo.json`, inside the configured **To Do folder**
(default `~/Documents/Todo`). It is a small JSON object,
`{ "version": 2, "sort": "priority" | "manual", "tasks": [ … ] }`, where `tasks`
is the array of `{ id, text, priority, done }` objects (in manual order) — easy
to read, hand-edit, sync, or back up. An older plain-array file is still read
automatically. The plugin runs no external programs.

## Settings

| Setting      | What it does                                             |
|--------------|----------------------------------------------------------|
| To Do folder | Where `todo.json` is stored (default `~/Documents/Todo`).|
| Bar glyph    | The glyph shown for the widget on the bar.               |

## Install

Install **To Do** from Noctalia's plugin store (*Settings → Plugins*), then add
the widget to a bar from *Settings → Bar*. Plugin options live in
*Settings → Plugins*.

For local development, add your working copy as a path source instead
(`.luau` edits hot-reload):

```sh
noctalia msg plugins source add dev path /path/to/plugins
noctalia msg plugins enable nightwatch75/todo
```

## Requirements

- noctalia v5.0.0-beta.9 or newer — the first tagged release that accepts
  `plugin_api = 28` (`panel.openContextMenu`, for the row menu; keyboard
  shortcuts need 13, `noctalia.openSettings()` 15, `noctalia.readFileAsync` 23,
  so the bar widget re-reads the task count without blocking the bar; relative
  luau imports 22, declarative drag-and-drop 5)
- No external dependencies

## License

MIT.
