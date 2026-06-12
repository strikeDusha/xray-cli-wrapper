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
git clone <this> xray-cli && cd xray-cli
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
~/.config/systemd/user/xray-cli.service
```

## Notes

- Latency test uses a TCP-connect handshake to the server endpoint — fast and
  doesn't require the tunnel to be up.
- No external Python packages. Colors disable automatically when piped or with
  `NO_COLOR=1`.
