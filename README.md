# xr — a friendly Xray-core CLI/TUI for Arch

A single-file, **stdlib-only** Python wrapper around [Xray-core](https://github.com/XTLS/Xray-core).
It manages saved servers, subscriptions, a `systemd --user` service, the system
proxy, and latency tests — with a Claude-Code-style interactive shell.

```
╭─ xray-cli  interactive shell ─────────────────────╮
│  core: Xray 1.8.x ...                             │
│  type /help for commands, or paste a share link   │
╰───────────────────────────────────────────────────╯

  ● tokyo-reality · connected
  ❯ /fastest
```

## Install

```bash
git clone https://github.com/strikeDusha/xray-cli-wrapper xray-cli && cd xray-cli
./install.sh            # copies `xr` to ~/.local/bin and writes the systemd unit
```

You also need Xray-core itself:

```bash
sudo pacman -S xray     # community repo
# or
yay -S xray-bin         # AUR
```

## Usage

Run `xr` with no arguments for the **interactive shell**, or use subcommands.

| Shell command | CLI equivalent | What it does |
|---|---|---|
| `/add <link>` | `xr add <link…>` | Add `vless://`, `vmess://`, `trojan://`, `ss://` links |
| `/list` | `xr list` | List saved servers (● = active) |
| `/use <name\|#>` | `xr use <ref>` | Set the active server (restarts if running) |
| `/start` `/stop` `/restart` | `xr start` … | Control the `systemd --user` service |
| `/status` | `xr status` | Connection state, ports, xray version |
| `/test` | `xr test` | TCP latency-probe every server, sorted |
| `/fastest` | `xr fastest` | Probe and switch to the lowest-latency server |
| `/sub <url>` | `xr sub <url>` | Import a base64 subscription URL |
| `/proxy on\|off` | `xr proxy on` | Toggle GNOME + shell env proxy |
| `/tun on\|off\|status` | `xr tun on` | **Whole-system TUN tunnel** (all apps, no per-app proxy) |
| `/remove <name\|#>` | `xr remove <ref>` | Delete a server |
| `/logs` | `xr logs [-f]` | journald logs for the service |
| `/config` | `xr config` | Print the generated `config.json` |

In the shell you can also just **paste a share link** with no command.

## How it works

- Inbound: SOCKS5 on `127.0.0.1:10808` + HTTP on `127.0.0.1:10809`.
- Each server is parsed into a normalized record and compiled into a real
  Xray outbound (handles tcp/ws/grpc/http, and tls/reality/none security,
  including VLESS-Reality + `xtls-rprx-vision` flow).
- The active config is written to `~/.config/xray-cli/config.json` and run by
  a generated `~/.config/systemd/user/xray-cli.service`.

## TUN mode (transparent whole-system tunnel)

`xr proxy` only redirects apps that honour the SOCKS/HTTP proxy. **TUN mode** is
a real, leak-free VPN: it captures *all* traffic at the kernel level — same
approach as v2rayN, NekoBox and sing-box on Linux.

```bash
yay -S tun2socks      # one-time: the AUR helper binary
xr tun on             # asks for sudo once (needs root for ip/route/tun2socks)
xr tun status
xr tun off
```

How it works, and why it's solid:

1. A TUN device (`tun0`, `198.18.0.1/15`) becomes the system's route, and
   [`tun2socks`](https://github.com/xjasonlyu/tun2socks) forwards that traffic
   into xray's local SOCKS inbound.
2. **No routing loop.** xray is *pinned* to the server's resolved IP (resolved
   before routes change), and that IP gets a `/32` bypass route out the real
   interface — so xray's own connection can never fold back into the tunnel,
   even with CDN/multi-IP servers. TLS SNI is preserved when pinning.
3. **Fail-closed kill-switch.** `0.0.0.0/1` + `128.0.0.0/1` split-default routes
   win over your real default without deleting it. If tun2socks dies, packets
   hit a downed device and are *dropped, not leaked* (it also auto-restarts).
4. **No IPv6 leaks.** IPv6 is blackholed for the session so traffic can't slip
   around the v4 tunnel.
5. **No DNS leaks.** DNS is pointed at `1.1.1.1`/`8.8.8.8` through the tunnel; a
   symlinked `/etc/resolv.conf` (systemd-resolved) is preserved and restored.
6. **Verified.** After setup, `xr` fetches your exit IP through xray's SOCKS
   *and* over the plain OS path; if they agree, the tunnel is confirmed
   leak-free. `xr tun off` cleanly restores routing, DNS and IPv6.

LAN/loopback stay direct automatically (more-specific link routes + explicit
private-CIDR routing rules — no `geoip.dat` required).

tun2socks runs as a transient root service (`xray-cli-tun`); logs via
`journalctl -u xray-cli-tun`. Everything privileged happens in one batched
`sudo` call. Requires `tun2socks`, `iproute2` and systemd — all standard on Arch.

## System proxy

`xr proxy on` sets GNOME proxy via `gsettings` and writes
`~/.config/xray-cli/proxy.env`. For your current shell:

```bash
source ~/.config/xray-cli/proxy.env   # on
unset http_proxy https_proxy all_proxy ALL_PROXY  # off
```

## Files

```
~/.config/xray-cli/servers.json     saved servers
~/.config/xray-cli/state.json       active server + settings
~/.config/xray-cli/config.json      generated xray config (live)
~/.config/xray-cli/tun.json         active TUN state (device + bypass routes)
~/.config/systemd/user/xray-cli.service
```

## Notes

- Latency test uses a TCP-connect handshake to the server endpoint — fast and
  doesn't require the tunnel to be up.
- No external Python packages. Colors disable automatically when piped or with
  `NO_COLOR=1`.
