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
- `stat` (coreutils), to warn when a credentials file is readable by others.

## Usage

Put the API key in a file only you can read, add **kuma-status** to a bar from
the Add-widget picker, set the Kuma URL and the key file in the plugin
settings, and click the glyph:

```sh
umask 077
mkdir -p ~/.config/kuma-status
printf '%s' 'uk1_xxxxxxxx' > ~/.config/kuma-status/api-key
```

Or open the panel from a terminal:

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
  when Kuma reports it (colored glyph, same fixed limits as the Certificates tab: red up to 7 days, yellow up to 30, green beyond; Kuma does not expose its own notification days). Click a group to collapse it, a monitor name to open its page in
  Kuma. Right click a monitor for **Open monitor in Kuma**,
  **Open monitored URL** and **Copy monitored URL** (the URL the monitor
  tests); hovering a row shows that URL. A line of buttons above the list
  has the view choice (see below) and **expand all** / **collapse all**.
- **Status pages tab:** type a status page URL in the field and press `+` to
  add it; the trash button removes it. The open button next to a title opens
  the page; the URL under the title copies it on click; the page description
  shows at the right of the title.
- **Certificates tab:** every monitor for which Kuma reports a certificate
  expiry, shortest first, grouped by how close the expiry is: **Expired**,
  **Expiring now** (up to 7 days), **Expiring soon** (8 to 30 days) and
  **Healthy** (over 30 days). Each row has a certificate glyph in red, yellow
  or green, the monitored URL (the monitor name when it has none) and the days
  left. The sort button reverses the order and the line next to it says which way. Group titles are large and colored; click one to collapse it, or use expand all / collapse all. The choice follows `groups_on_open` and is remembered the same way as on the Dashboard. Click a row to open the monitor in
  Kuma, right click for the same menu as the Dashboard. The data is the one
  already fetched for the Dashboard: no extra request.
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
| `api_key_file` | `file` | empty | Path of a file holding the Kuma API key (see Credentials below). Sent only to `kuma_url`: as Basic password on `/metrics`, as Bearer on `/api/monitors` |
| `proxy_user` | `string` | empty | Basic auth user for status pages behind a reverse proxy. Not a secret |
| `proxy_password_file` | `file` | empty | Path of a file holding that user's password. Sent, with the user, only to the Kuma URL host and to `proxy_hosts` |
| `proxy_hosts` | `string_list` | empty | Hosts (`host` or `host:port`) of status pages behind the same proxy login, e.g. `status.example.com`. A status page on any other host gets no password and shows a 401 hint |
| `insecure_tls` | `bool` | `false` | Accept untrusted HTTPS certificates (self-signed, expired) on every request. The panel shows a warning while it is on |
| `kuma3_support` | `bool` | `false` | Call `/api/monitors` (Kuma 3). Off means no call at all. A 404 turns it off until the settings change |
| `groups_on_open` | `select` | `expanded` | Dashboard groups when the panel opens: `expanded`, `collapsed` or `last` (the groups you closed stay closed; a new group starts open) |
| `start_tab` | `select` | `dashboard` | Tab the panel opens on: `dashboard`, `pages`, `certs` or `last` (the one you used last) |
| `group_tags` | `string_list` | empty | Kuma 2 only. Tags that make the Dashboard groups, in priority order and spelling (matched ignoring case). A monitor goes to the first listed tag it has, or under every one it has in the **All tags** view. Other tags are ignored; a monitor with none is listed last without a group name. Empty: every tag is a group |
| `notify_changes` | `select` | `toast_blink` | Toast when a monitor has been down for 2 cycles in a row and when it recovers; `toast_blink` also blinks the bar for 10 s or until you open the panel. No alert on the first cycle after start; the same monitor alerts at most every 10 minutes |
| `bar_display` | `select` | `counts` | `counts`: glyph, up and down numbers. `color`: glyph color only |
| `refresh_seconds` | `int` | `60` | Seconds between updates, 20 to 3600. Kuma caches status pages for a minute |
| `glyph` | `glyph` | `heartbeat` | Bar icon (per widget) |
| `bar_label` | `string` | `Kuma` | Text to the left of the glyph (per widget). Empty hides it |

## Credentials

The settings never hold a secret, only the **path** of a file that does. The
plugin reads the file the way noctalia reads its own `credential_source =
"file"`: an absolute path to a regular file, 1 byte to 64 KiB, no NUL bytes, one
trailing newline (LF or CRLF) ignored, and the file is never written or deleted
by the plugin. It is read again on every refresh, so a secret manager (agenix,
sops-nix, systemd credentials) can rotate it: a source refused with 401 is
tried again as soon as the file holds a different secret.

If the file is readable by group or other, the panel shows a warning: run
`chmod 600` on it. The plugin does not stop, it only warns.

Why files and not the keyring: noctalia stores its own secrets in the desktop
Secret Service, but gives plugins no API for it and no secret setting type.
A file path keeps the secret out of `settings.toml`.

## Notes

- Create a key just for this plugin and a read-only proxy user. A secret in a
  file protects it from `settings.toml` backups and screenshots, not from
  other programs running as you.
- A 401 or 403 on a source stops calls to it until the settings change or the
  secret in its file changes.
- Monitor names come from the server: control characters and bidi marks are
  removed and the text is cut to 80 characters. Names never reach a command.
- Monitored URLs are shown without `user:password@`, query and fragment;
  "Copy monitored URL" copies the real one.
- Answers over 1 MiB (4 MiB for status pages) are refused, and a status page
  shows at most 500 monitors.
- Commands spawned: `xdg-open <url>` on click or from the right-click menu,
  with a URL the plugin builds or validates (`http://` or `https://`, no spaces), and
  `stat -c %a <file>` to check a credentials file.
- Kuma exposes the certificate expiry in `/metrics` but not the domain
  expiry: the plugin cannot show the latter.
