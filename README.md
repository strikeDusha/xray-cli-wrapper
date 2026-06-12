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

`xr proxy` only redirects apps that honour the SOCKS/HTTP proxy. **TUN mode**
captures *all* traffic at the kernel level — same approach as v2rayN, NekoBox
and sing-box on Linux:

1. A TUN device (`tun0`, `198.18.0.1/15`) becomes the system's route.
2. [`tun2socks`](https://github.com/xjasonlyu/tun2socks) forwards that traffic
   into xray's local SOCKS inbound.
3. A `/32` **bypass route** sends xray's own connection to your proxy server out
   the real interface, so it doesn't loop back into the tunnel.
4. `0.0.0.0/1` + `128.0.0.0/1` "split-default" routes win over your real default
   without deleting it, and DNS is pointed through the tunnel — so teardown
   (`xr tun off`) restores everything cleanly.

```bash
yay -S tun2socks      # one-time: the AUR helper binary
xr tun on             # asks for sudo once (needs root for ip/route/tun2socks)
xr tun status
xr tun off
```

tun2socks runs as a transient root service (`xray-cli-tun`), so logs are in
`sudo systemctl status xray-cli-tun` / `journalctl -u xray-cli-tun`.

> Requires `tun2socks`, `iproute2`, and systemd — all standard on Arch. The
> single `sudo` prompt covers device creation, routing, and DNS in one batch.

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
