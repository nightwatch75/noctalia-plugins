# DNS Switcher

A [noctalia](https://github.com/noctalia-dev/noctalia) v5 bar plugin: switch the system DNS
between popular providers, your own servers, or the ISP default, from a panel
on the bar. Based on [Ronin-CK's v4 DNS Switcher](https://github.com/noctalia-dev/legacy-v4-plugins)
(QML), rebuilt on the v5 Luau plugin API.

The bar widget shows the active provider (name + glyph); clicking it opens a
panel listing the configured providers — pick one and it is applied
immediately: one `nmcli` profile change pushed onto the live connection with
`nmcli device reapply`, so the network never drops or reconnects.

| Action       | Effect                                        |
|--------------|-----------------------------------------------|
| Left click   | Open/close the provider panel                 |
| Right click  | Reset to the connection default (ISP)         |
| Middle click | Copy the active DNS servers to the clipboard  |

## Features

- Pre-configured providers: Google, Cloudflare, OpenDNS, AdGuard, Quad9
  (pick which ones appear via the *Built-in providers* setting; clear it to
  use only your custom servers)
- Custom servers via the *Custom servers* setting, separated by `;` or `,`:
  `Pi-hole = 192.168.1.5; NextDNS = 45.90.28.0 45.90.30.0`
- Detection reads the connection profile (`ipv4.dns` + `ipv4.ignore-auto-dns`),
  so a manually configured resolver — LAN ones included — shows as its
  provider (or *Custom (ip)*), and DHCP-assigned DNS shows as *Default (ISP)*
- Live footer in the panel: connection name and active resolver IPs, with a
  copy button
- Glyph-only mode (*Show provider name* off) for compact bars
- Scriptable via IPC:
  `noctalia msg plugin nightwatch75/dns-switcher:service all apply cloudflare`
  (provider id, `default`, or `custom:<name>`); `… all poll` forces a re-check
- Singleton service entry: with multiple bars/monitors the engine runs once —
  widgets and panel are pure renderers over its shared state

## Requirements

- noctalia ≥ 5.0.0
- NetworkManager (`nmcli`) with an active connection
- Permission to modify system connections (see *Privileges* below)

## Install

Add the [noctalia-plugins](../) repo as a git source and enable the plugin in
`~/.config/noctalia/config.toml`:

```toml
[plugins]
enabled = ["nightwatch75/dns-switcher"]

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

Restart noctalia, then add the **DNS Switcher** widget to a bar from
Settings → Bar. Plugin options live in Settings → Plugins.

## How it changes the DNS

It modifies the profile of the active wifi/ethernet connection and reapplies
it to the device in place — no reactivation, no captive-portal re-runs, no
dropped packets:

```sh
nmcli con mod <uuid> ipv4.dns "<servers>" ipv4.ignore-auto-dns yes
nmcli device reapply <device>
```

Resetting to the ISP default clears `ipv4.dns` and sets
`ipv4.ignore-auto-dns no`, restoring the DHCP-provided resolvers.

## Privileges

The *Privilege command* setting is **empty by default**: NetworkManager's
polkit policy (`org.freedesktop.NetworkManager.settings.modify.system`)
allows active local sessions — typically `wheel`/`sudo` group members — to
modify system connections without a password on most desktop distros, so
plain `nmcli` just works.

If your distro is stricter you'll get a "not authorized" error; then either
set *Privilege command* to `pkexec` (noctalia's polkit agent shows the
password prompt) or `sudo -n` with a matching sudoers rule:

```
# /etc/sudoers.d/nmcli-dns
youruser ALL=(root) NOPASSWD: /usr/bin/nmcli
```

Or grant it via a polkit rule and keep the setting empty:

```js
// /etc/polkit-1/rules.d/50-nmcli-dns.rules
polkit.addRule(function(action, subject) {
    if ((action.id == "org.freedesktop.NetworkManager.settings.modify.system" ||
         action.id == "org.freedesktop.NetworkManager.network-control") &&
        subject.isInGroup("wheel")) {
        return polkit.Result.YES;
    }
});
```

All of these widen what the account can do to NetworkManager system-wide —
apply your usual judgement on shared machines.

## Notes

- Only IPv4 DNS is managed, like the v4 plugin.
- The plugin targets the first active wifi/ethernet connection (falling back
  to the first active non-loopback one); with VPNs up, the VPN's own DNS is
  not touched.
- Custom server entries accept one or two space-separated IPv4 addresses;
  invalid entries are skipped and logged.

## License

MIT — see [LICENSE](../LICENSE).
