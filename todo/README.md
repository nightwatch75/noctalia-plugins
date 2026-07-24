# To Do

A [noctalia](https://github.com/noctalia-dev/noctalia) v5 bar plugin: a
prioritised to-do list. Click the bar glyph to toggle a panel of task rows —
add tasks with **+**, tick them off (the text is struck through), delete them,
and set each task's priority. Order tasks by priority or by hand (drag-and-drop),
and store them as a single JSON file or as iCalendar files for CalDAV-compatible
sync; no external commands are run.

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
| ↻ refresh (panel header)      | Reload tasks from storage (pick up external changes) |
| Colour chip (row)             | Cycle the task's priority: important → medium → low |
| ☰ grip (row, manual only)     | Drag the row to a new position (reorder)            |
| Click the text, or ✎ (pencil) | Edit the task's text                                |
| **Enter**, or ✓ (row)         | Commit the edit — the row goes back to a static line |
| ☐ / ☑ button (row)            | Toggle done/to-do (done tasks are struck through)   |
| 🗑 button (row)                | Delete the task                                     |

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

## Editing

Rows are static lines by default. Click a task's text (or its ✎ pencil button)
to edit it; press **Enter** or the ✓ button to commit back to a static line. A
new task (**+**) opens straight into edit mode — committing it while still empty
simply discards it. Edits are also autosaved after a short idle pause and on
close.

Tick a task (☐ → ☑) to complete it — its text is struck through until you
un-tick it. The bar glyph's tooltip shows how many tasks are still to do.

## Storage

Tasks live inside the configured **To Do folder** (default `~/Documents/Todo`),
in one of two formats set by the **Storage format** option. The plugin runs no
external programs.

### JSON (default)

A single `todo.json`: `{ "version": 2, "sort": "priority" | "manual", "tasks":
[ … ] }`, where `tasks` is the array of `{ id, text, priority, done }` objects in
manual order — easy to read, hand-edit, or back up. An older plain-array file is
still read automatically.

### iCalendar (CalDAV-compatible)

One [iCalendar](https://www.rfc-editor.org/rfc/rfc5545) `VTODO` file per task,
`<uid>.ics` — the same on-disk layout ("vdir") that Radicale and vdirsyncer use.
`SUMMARY` is the text, `PRIORITY` is `1`/`5`/`9` for important/medium/low, and
`STATUS`/`PERCENT-COMPLETE` mark completion. Manual order and the sort mode live
in a small `.order.json` sidecar (VTODO has no ordering property), so ordering
is preserved between this plugin's own instances but does not travel over CalDAV.
Files are written atomically (temp + rename); `*.sync-conflict*` copies left by
sync tools are ignored, never read or deleted. Switching format does not migrate
existing tasks.

**Sync across devices.** Point the To Do folder at a directory shared by
**Syncthing** / Nextcloud / Dropbox: the per-file layout means edits to different
tasks on different devices merge cleanly, and only the *same* task edited at once
produces a conflict copy. For **CalDAV apps** (e.g. tasks.org via DAVx⁵ on
Android) the plain folder is not enough — run a CalDAV server such as
**Radicale** over the folder (its native storage is exactly this vdir), then sync
the mobile app against it; **vdirsyncer** can likewise bridge the folder to any
CalDAV server.

The panel footer shows the active mode (**iCal mode** / **JSON mode**). Use the
**↻** button in the header to reload from storage — it pulls in tasks that
arrived from another device while the panel is open (the plugin writes locally;
pushing to other devices is the CalDAV client's / file-sync tool's job, not the
plugin's).

## Settings

| Setting        | What it does                                                    |
|----------------|-----------------------------------------------------------------|
| To Do folder   | Where tasks are stored (default `~/Documents/Todo`).            |
| Storage format | `Single JSON file` (default) or `iCalendar files (VTODO)`.      |
| Bar glyph      | The glyph shown for the widget on the bar.                      |

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

- noctalia with plugin API ≥ 5 (declarative drag-and-drop)
- No external dependencies

## License

MIT.
