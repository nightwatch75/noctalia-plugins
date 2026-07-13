# To Do

A [noctalia](https://github.com/noctalia-dev/noctalia) v5 bar plugin: a
prioritised to-do list. Click the bar glyph to toggle a panel of task rows —
add tasks with **+**, tick them off (the text is struck through), delete them,
and set each task's priority. The list is kept sorted by priority and stored as
a single JSON file; no external commands are run.

| Action                       | Effect                                              |
|-------------------------------|-----------------------------------------------------|
| Left click (bar glyph)        | Open/close the To Do panel                          |
| **+** (panel header)          | Add a new task and start typing it                  |
| Colour chip (row)             | Cycle the task's priority: important → medium → low |
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

Rows are sorted by priority — important first, then medium, then low. Changing
a task's priority moves it into its new group but keeps its position relative to
its peers; equal-priority rows are never reshuffled.

## Editing

Rows are static lines by default. Click a task's text (or its ✎ pencil button)
to edit it; press **Enter** or the ✓ button to commit back to a static line. A
new task (**+**) opens straight into edit mode — committing it while still empty
simply discards it. Edits are also autosaved after a short idle pause and on
close.

Tick a task (☐ → ☑) to complete it — its text is struck through until you
un-tick it. The bar glyph's tooltip shows how many tasks are still to do.

## Storage

Tasks live in one file, `todo.json`, inside the configured **To Do folder**
(default `~/Documents/Todo`). It is a plain JSON array of
`{ id, text, priority, done }` objects — easy to read, hand-edit, sync, or back
up. The plugin runs no external programs.

## Settings

| Setting      | What it does                                             |
|--------------|----------------------------------------------------------|
| To Do folder | Where `todo.json` is stored (default `~/Documents/Todo`).|
| Bar glyph    | The glyph shown for the widget on the bar.               |

## Install

noctalia discovers plugins from configured sources. By convention the plugin
id `nightwatch75/todo` maps to the `todo/` subdirectory of the source repo.

Add the [noctalia-plugins](../) repo as a git source and enable the plugin in
`~/.config/noctalia/config.toml`:

```toml
[plugins]
enabled = ["nightwatch75/todo"]

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

Restart noctalia, then add the **To Do** widget to a bar from Settings → Bar.
Plugin options live in Settings → Plugins.

## Requirements

- noctalia ≥ 5.0.0
- No external dependencies

## License

MIT — see [LICENSE](../LICENSE).
