# To Do

A [noctalia](https://github.com/noctalia-dev/noctalia) v5 bar plugin: a
prioritised to-do list. Click the bar glyph to toggle a panel of task rows —
add tasks with **+**, tick them off (the text is struck through), delete them,
and set each task's priority. The list is kept sorted by priority and stored as
a single JSON file; no external commands are run.

| Action                 | Effect                                              |
|------------------------|-----------------------------------------------------|
| Left click (bar glyph) | Open/close the To Do panel                          |
| **+** (panel header)   | Add a new task and start editing it                 |
| Colour chip (row)      | Cycle the task's priority: important → medium → low |
| ☐ / ☑ button (row)     | Toggle done/to-do (done tasks are struck through)   |
| 🗑 button (row)         | Delete the task                                     |

## Priorities

Each task carries a priority, shown as a small coloured square at the start of
the row. Click the square to cycle it:

| Priority  | Colour |
|-----------|--------|
| Important | red    |
| Medium    | amber  |
| Low       | green  |

Rows are always sorted by priority — important first, then medium, then low —
keeping, within each group, the order tasks were added.

## Editing

An active task is an editable text field: type into it and press **Enter** to
save immediately, or just keep working (edits are autosaved after a short idle
pause and on close). Tick a task to complete it — its row turns into a
struck-through, dimmed line until you un-tick it. The bar glyph's tooltip shows
how many tasks are still to do.

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
