# File Search

A [noctalia](https://github.com/noctalia-dev/noctalia) v5 bar plugin: fuzzy
search files and folders as you type, with [fzf](https://github.com/junegunn/fzf)
as the matching subsystem. Click the bar glyph to open a search panel; picking
a result opens it with the system MIME association (`xdg-open`) — directories
open in your file manager.

| Action       | Effect                                          |
|--------------|-------------------------------------------------|
| Left click   | Open/close the search panel                     |
| Right click  | Open the search folder in the file manager      |
| Middle click | Copy the search folder path to the clipboard    |

## Features

- Live results while you type: the search folder is walked once with `find`
  into a cache, then every keystroke is fuzzy-matched through
  `fzf --filter`, so typing stays responsive even on large trees
- Configurable bar glyph, search folder (defaults to `~`), excluded folder
  names (`.git, node_modules, .cache, .venv` by default, matched anywhere in
  the tree), hidden entries on/off, max results
- `Enter` opens the top match; every result row opens on click via the
  system MIME association — files in their default app, folders in the file
  manager
- Launcher provider for a keyboard-first flow: type `/fs <text>` in the
  noctalia launcher and navigate the results with the native arrow keys +
  `Enter` (plugin panels cannot receive arrow keys in the current Luau API,
  so the launcher is the keyboard way to browse results)
- Folder results are marked with a trailing `/` and a folder glyph
- Index rebuilds automatically when the relevant settings change, and on
  demand via the panel's refresh button (external file changes are picked up
  on rebuild)
- Panel placement (attached/floating), position and open-near-click are the
  standard per-panel settings noctalia exposes in Settings → Plugins

## Requirements

- noctalia ≥ 5.0.0
- [fzf](https://github.com/junegunn/fzf)
- GNU findutils and `xdg-open` (`xdg-utils`) — standard on Linux desktops

## Install

Install **File Search** from Noctalia's plugin store (*Settings → Plugins*),
then add the widget to a bar from *Settings → Bar*. Plugin options live in
*Settings → Plugins*.

For local development, add your working copy as a path source instead
(`.luau` edits hot-reload):

```sh
noctalia msg plugins source add dev path /path/to/plugins
noctalia msg plugins enable nightwatch75/file-search
```

Restart noctalia, then add the **File Search** widget to a bar from
Settings → Bar. Plugin options live in Settings → Plugins.

## Keys

In the panel:

| Key     | Action                              |
|---------|-------------------------------------|
| `Enter` | Open the top match                  |
| `Esc`   | Close the panel (noctalia default)  |

In the noctalia launcher (keyboard-first flow, native navigation):

| Key         | Action                                    |
|-------------|-------------------------------------------|
| `/fs <text>`| Fuzzy search files and folders            |
| `↑` / `↓`   | Move through the results                  |
| `Enter`     | Open the selected result (MIME/xdg-open)  |

With an empty `/fs` query the list also offers *Rebuild search index*; the
index is shared with the panel and built on demand when missing.

The panel can also be driven externally:

```sh
noctalia msg panel-toggle nightwatch75/file-search:panel
```

## Notes

- The index lives in `${XDG_CACHE_HOME:-~/.cache}/noctalia/file-search.list`
  and is a plain list of paths relative to the search folder.
- Excluded entries match by folder/file *name* (`find -name`), not by path;
  entries containing `/` are skipped and logged.
- With hidden entries off, anything starting with a dot is pruned — both
  hidden folders (not descended into) and hidden files.
- Unreadable subtrees are silently skipped (permission errors don't fail the
  index).

## License

MIT.
