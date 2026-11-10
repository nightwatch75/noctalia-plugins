# kuma-status

Uptime Kuma on the bar. A glyph shows the overall state with the number of
monitors up and down; a panel lists every monitor with its last 40 heartbeats
and the status pages you choose. Read-only: it never pauses, edits or restarts
a monitor.

## Plugin

| Field | Value |
| --- | --- |
| ID | `nightwatch75/kuma-status` |
| Entries | Bar widget: `kuma-status`; panel: `panel`; service: `service` |

## Requirements

- noctalia with `plugin_api = 32` (tooltips on panel containers).
- A reachable Uptime Kuma, version 2.5 or newer. Kuma 3 (beta) adds the real
  group hierarchy.
- An API key, created in Kuma under **Settings → API Keys**. On Kuma 2 the
  key works on `/metrics`. On Kuma 3 also open **Settings → General** and
  enable the **Prometheus API** (`/metrics`) and the API section
  (`/api/monitors`); both are off by default.
- `xdg-open` on `PATH`, to open a monitor or a status page in the browser.

## Usage

Add **kuma-status** to a bar from the Add-widget picker, set the Kuma URL and
the API key in the plugin settings, and click the glyph. Or:

```sh
noctalia msg panel-toggle nightwatch75/kuma-status:panel
```

- **Bar:** a text (default `Kuma`), the heart glyph and, in `counts` mode, the
  number of monitors up (green arrow) and down (red arrow). The glyph color is
  the worst state (green all up, yellow pending, red down, grey not reachable
  or nothing monitored). The tooltip lists the monitors that are down.
- **Header:** the title, a settings button (opens the plugin settings: URL,
  key, proxy user...) and a close button. Under it, the tabs, the configured
  Kuma URL and the refresh button.
- **Dashboard tab:** groups and monitors with the newest state, ping and a bar
  of the last 40 heartbeats. Under a check, in small, the certificate expiry
  when Kuma reports it (colored glyph: green over 30 days, yellow over 7, red
  below). Click a group to collapse it, a monitor name to open its page in
  Kuma. Right click a monitor for **Open monitor in Kuma**,
  **Open monitored URL** and **Copy monitored URL** (the URL the monitor
  tests); hovering a row shows that URL. A line of buttons above the list
  has the view choice (see below) and **expand all** / **collapse all**.
- **Status pages tab:** type a status page URL in the field and press `+` to
  add it here; the trash button removes pages added this way. Pages from the
  `Status pages` setting are listed too (remove them in the settings). The
  open button next to a title opens the page.
- The refresh button asks the service for new data now.

How groups are built:

| Server | Groups |
| --- | --- |
| Kuma 3 with **Kuma 3 support** on | The real groups, nested ones as `Parent / Child`; paused monitors are grey |
| Kuma 2 | One group per tag. By default a monitor appears once, under its first tag (tags sorted alphabetically). The view button switches to **All tags (duplicates)** (the choice is remembered): a monitor with two tags then appears twice; the bar counts it once either way. Paused monitors are not listed: Kuma exports nothing for them |

The history bar uses the status page data for monitors that are on one of your
listed pages. The others fill from the plugin's own polls (one cell per
refresh, in memory only), so right after a start their bar is mostly empty.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `kuma_url` | `string` | empty | Base URL, `http://` or `https://`. Over `http://` the panel shows a warning: the key and password travel in clear text |
| `api_key` | `string` | empty | Kuma API key. Sent only to `kuma_url`: as Basic password on `/metrics`, as Bearer on `/api/monitors` |
| `proxy_user`, `proxy_password` | `string` | empty | One Basic auth pair for status pages behind a reverse proxy. Sent only to the hosts of the listed status pages |
| `status_pages` | `string_list` | empty | One URL per page, `https://host/status/<slug>`. Pages added from the panel are kept in the plugin data folder and merged with this list |
| `kuma3_support` | `bool` | `false` | Call `/api/monitors` (Kuma 3). Off means no call at all. A 404 turns it off until the settings change |
| `groups_on_open` | `select` | `expanded` | Dashboard groups when the panel opens: `expanded`, `collapsed` or `last` (the groups you closed stay closed; a new group starts open) |
| `start_tab` | `select` | `dashboard` | Tab the panel opens on: `dashboard`, `pages` or `last` (the one you used last) |
| `bar_display` | `select` | `counts` | `counts`: glyph, up and down numbers. `color`: glyph color only |
| `refresh_seconds` | `int` | `60` | Seconds between updates, 20 to 3600. Kuma caches status pages for a minute |
| `glyph` | `glyph` | `heartbeat` | Bar icon (per widget) |
| `bar_label` | `string` | `Kuma` | Text to the left of the glyph (per widget). Empty hides it |

## Notes

- The API key and the proxy password are stored in clear text in the noctalia
  settings file, because settings have no secret type. Create a key just for
  this plugin and a read-only proxy user.
- A 401 or 403 on a source stops calls to it until you change the settings.
- Monitor names come from the server: control characters are removed and the
  text is cut to 80 characters. Names never reach a command.
- Commands spawned: `xdg-open <url>` on click or from the right-click menu,
  with a URL the plugin builds or validates (`http://` or `https://` only).
- Kuma exposes the certificate expiry in `/metrics` but not the domain
  expiry: the plugin cannot show the latter.
