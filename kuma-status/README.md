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

- **Bar:** the glyph color is the worst state (green all up, yellow pending,
  red down, grey not reachable or nothing monitored). The tooltip lists the
  monitors that are down.
- **Dashboard tab:** groups and monitors with the newest state, ping and a bar
  of the last 40 heartbeats. Click a group to collapse it, a monitor to open
  its page in Kuma. A line under the tabs says how groups are built.
- **Status pages tab:** one block per URL in the `Status pages` setting, with
  the same rows. The open button next to the title opens the page.
- The refresh button asks the service for new data now.

How groups are built:

| Server | Groups |
| --- | --- |
| Kuma 3 with **Kuma 3 support** on | The real groups, nested ones as `Parent / Child`; paused monitors are grey |
| Kuma 2 | One group per tag (a monitor with two tags appears twice; the bar counts it once). Paused monitors are not listed: Kuma exports nothing for them |

The history bar uses the status page data for monitors that are on one of your
listed pages. The others fill from the plugin's own polls (one cell per
refresh, in memory only), so right after a start their bar is mostly empty.

## Settings

| Setting | Type | Default | Description |
| --- | --- | --- | --- |
| `kuma_url` | `string` | empty | Base URL, `http://` or `https://`. Over `http://` the panel shows a warning: the key and password travel in clear text |
| `api_key` | `string` | empty | Kuma API key. Sent only to `kuma_url`: as Basic password on `/metrics`, as Bearer on `/api/monitors` |
| `proxy_user`, `proxy_password` | `string` | empty | One Basic auth pair for status pages behind a reverse proxy. Sent only to the hosts of the listed status pages |
| `status_pages` | `string_list` | empty | One URL per page, `https://host/status/<slug>` |
| `kuma3_support` | `bool` | `false` | Call `/api/monitors` (Kuma 3). Off means no call at all. A 404 turns it off until the settings change |
| `bar_display` | `select` | `counts` | `counts`: glyph, up and down numbers. `color`: glyph color only |
| `refresh_seconds` | `int` | `60` | Seconds between updates, 20 to 3600. Kuma caches status pages for a minute |
| `glyph` | `glyph` | `heartbeat` | Bar icon (per widget) |

## Notes

- The API key and the proxy password are stored in clear text in the noctalia
  settings file, because settings have no secret type. Create a key just for
  this plugin and a read-only proxy user.
- A 401 or 403 on a source stops calls to it until you change the settings.
- Monitor names come from the server: control characters are removed and the
  text is cut to 80 characters. Names never reach a command.
- Commands spawned: `xdg-open <url>` on click, with a URL the plugin builds.
