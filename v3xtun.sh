#!/usr/bin/env bash
# v3xtun — a friendly Xray-core CLI/VPN wrapper for Arch, in pure Bash.
#
# Pure shell + jq. No Python. Manages saved servers (vless/vmess/trojan/ss),
# subscriptions, a systemd --user service, the system proxy, and a hardened,
# leak-free TUN VPN mode (tun2proxy — same engine as the v3xtun GUI).
#
#   ./v3xtun.sh                 interactive shell
#   ./v3xtun.sh add <link>      add a share link
#   ./v3xtun.sh tun on          whole-system VPN
#   ./v3xtun.sh --help
#
set -u

# --------------------------------------------------------------------------- #
# Paths
# --------------------------------------------------------------------------- #
APP="v3xtun"
XDG_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}"
CONFIG_DIR="$XDG_CONFIG/$APP"
SERVERS_FILE="$CONFIG_DIR/servers.json"
STATE_FILE="$CONFIG_DIR/state.json"
GEN_CONFIG="$CONFIG_DIR/config.json"
TUN_STATE_FILE="$CONFIG_DIR/tun.json"
ENV_PROXY_FILE="$CONFIG_DIR/proxy.env"
SYSTEMD_USER_DIR="$XDG_CONFIG/systemd/user"
UNIT_NAME="v3xtun.service"
UNIT_PATH="$SYSTEMD_USER_DIR/$UNIT_NAME"
TUN_DEV="tun0"
TUN_ADDR="198.18.0.1/15"
TUN_UNIT="v3xtun-tun"
IP_ECHO="http://api.ipify.org"

# defaults (overridden by state.json)
SOCKS_PORT=10808
HTTP_PORT=10809
LISTEN="127.0.0.1"
LOGLEVEL="warning"
ACTIVE=""

# --------------------------------------------------------------------------- #
# Colors / UI
# --------------------------------------------------------------------------- #
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  RESET=$'\033[0m'; BOLD=$'\033[1m'; DIM=$'\033[2m'
  ORANGE=$'\033[38;5;209m'; PURPLE=$'\033[38;5;141m'; GREEN=$'\033[38;5;114m'
  RED=$'\033[38;5;203m'; YELLOW=$'\033[38;5;221m'; BLUE=$'\033[38;5;110m'
  GRAY=$'\033[38;5;245m'; CYAN=$'\033[38;5;116m'
else
  RESET=""; BOLD=""; DIM=""; ORANGE=""; PURPLE=""; GREEN=""
  RED=""; YELLOW=""; BLUE=""; GRAY=""; CYAN=""
fi

info() { printf '  %s•%s %s\n' "$BLUE" "$RESET" "$*"; }
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$*"; }
err()  { printf '  %s✗%s %s\n' "$RED" "$RESET" "$*"; }

_vislen() { # visible width of a string (strip ANSI)
  local s; s=$(printf '%s' "$1" | sed $'s/\033\\[[0-9;]*m//g')
  printf '%s' "${#s}"
}

box() { # box <color> <title> -- line line ...
  local color="$1" title="$2"; shift 2; shift  # drop the "--"
  local pad=1 inner=0 l vl
  vl=$(_vislen "$title"); [ "$vl" -gt "$inner" ] && inner=$vl
  for l in "$@"; do vl=$(_vislen "$l"); [ "$vl" -gt "$inner" ] && inner=$vl; done
  inner=$((inner + pad * 2))
  local tlen; tlen=$(_vislen "$title")
  local dashes=$((inner - tlen - 3))
  local line; line=$(printf '─%.0s' $(seq 1 "$dashes"))
  printf '%s╭─ %s%s%s %s%s╮%s\n' "$color" "$BOLD" "$title" "$RESET$color" "$line" "" "$RESET"
  for l in "$@"; do
    vl=$(_vislen "$l"); local gap=$((inner - vl - pad * 2))
    local sp; sp=$(printf ' %.0s' $(seq 1 $((gap + pad)) 2>/dev/null) 2>/dev/null)
    printf '%s│%s %s%s %s│%s\n' "$color" "$RESET" "$l" "$sp" "$color" "$RESET"
  done
  local bot; bot=$(printf '─%.0s' $(seq 1 "$inner"))
  printf '%s╰%s╯%s\n' "$color" "$bot" "$RESET"
}

SPIN_PID=""
spin_start() {
  [ -t 1 ] || { printf '  %s…\n' "$1"; return; }
  local text="$1"
  ( local f='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏' i=0
    while :; do
      printf '\r  %s%s%s %s…   ' "$ORANGE" "${f:i%10:1}" "$RESET" "$text"
      i=$((i+1)); sleep 0.08
    done ) &
  SPIN_PID=$!
}
spin_stop() {
  [ -n "$SPIN_PID" ] && { kill "$SPIN_PID" 2>/dev/null; wait "$SPIN_PID" 2>/dev/null; SPIN_PID=""; printf '\r%*s\r' 60 ''; }
}

# --------------------------------------------------------------------------- #
# Helpers
# --------------------------------------------------------------------------- #
ensure_dirs() { mkdir -p "$CONFIG_DIR"; }
have() { command -v "$1" >/dev/null 2>&1; }

b64d() { # url-safe-tolerant base64 decode
  local s="$1"; s="${s//-/+}"; s="${s//_//}"
  case $(( ${#s} % 4 )) in 2) s="${s}==";; 3) s="${s}=";; esac
  printf '%s' "$s" | base64 --decode 2>/dev/null
}

urldecode() { local d="${1//+/ }"; printf '%b' "${d//%/\\x}"; }

qget() { # qget <querystring> <key>   -> urldecoded value
  local q="$1" key="$2" kv oldIFS="$IFS"
  IFS='&'
  for kv in $q; do
    case "$kv" in "$key="*) IFS="$oldIFS"; urldecode "${kv#*=}"; return;; esac
  done
  IFS="$oldIFS"
}

is_ip() {
  case "$1" in
    *[!0-9.]*) [ "${1#*:}" != "$1" ] && return 0 || return 1 ;;  # has ':' -> v6
    *.*.*.*) return 0 ;;
    *) return 1 ;;
  esac
}

servers_json() { [ -f "$SERVERS_FILE" ] && cat "$SERVERS_FILE" || printf '[]'; }
write_servers() { local tmp; tmp=$(mktemp); cat > "$tmp"; mv "$tmp" "$SERVERS_FILE"; }  # atomic; avoids read-while-truncating

load_state() {
  if [ -f "$STATE_FILE" ]; then
    SOCKS_PORT=$(jq -r '.socks_port // 10808' "$STATE_FILE")
    HTTP_PORT=$(jq -r '.http_port // 10809' "$STATE_FILE")
    LISTEN=$(jq -r '.listen // "127.0.0.1"' "$STATE_FILE")
    LOGLEVEL=$(jq -r '.log_level // "warning"' "$STATE_FILE")
    ACTIVE=$(jq -r '.active // ""' "$STATE_FILE")
  fi
}

save_active() {
  ensure_dirs
  local cur='{}'; [ -f "$STATE_FILE" ] && cur=$(cat "$STATE_FILE")
  printf '%s' "$cur" | jq \
    --argjson sp "$SOCKS_PORT" --argjson hp "$HTTP_PORT" \
    --arg ls "$LISTEN" --arg lg "$LOGLEVEL" --arg ac "$1" \
    '. + {socks_port:$sp, http_port:$hp, listen:$ls, log_level:$lg, active:$ac}' \
    > "$STATE_FILE"
  ACTIVE="$1"
}

unique_tag() {
  local base="$1" arr n; arr=$(servers_json)
  [ -z "$base" ] && base="server"
  if ! printf '%s' "$arr" | jq -e --arg t "$base" 'any(.[]; .tag==$t)' >/dev/null; then
    printf '%s' "$base"; return
  fi
  n=2
  while printf '%s' "$arr" | jq -e --arg t "$base-$n" 'any(.[]; .tag==$t)' >/dev/null; do
    n=$((n+1))
  done
  printf '%s-%s' "$base" "$n"
}

# find a server object by tag / index / substring; prints object or empty
find_server() {
  local ref="$1" arr; arr=$(servers_json)
  local exact; exact=$(printf '%s' "$arr" | jq -c --arg r "$ref" '.[] | select(.tag==$r)' | head -1)
  [ -n "$exact" ] && { printf '%s' "$exact"; return; }
  case "$ref" in
    ''|*[!0-9]*) ;;
    *) printf '%s' "$arr" | jq -c --argjson i "$((ref-1))" '.[$i] // empty'; return;;
  esac
  printf '%s' "$arr" | jq -c --arg r "$ref" '[.[] | select(.tag|ascii_downcase|contains($r|ascii_downcase))] | if length==1 then .[0] else empty end'
}

# --------------------------------------------------------------------------- #
# Share-link parsing  ->  normalized server JSON (same schema as the Python xr)
# --------------------------------------------------------------------------- #
# Globals filled by parse_* then assembled by emit_server.
reset_fields() {
  P_proto=""; P_tag=""; P_addr=""; P_port="443"; P_id=""; P_flow=""
  P_enc="none"; P_pass=""; P_method=""; P_aid="0"; P_scy="auto"; P_raw=""
  S_net="tcp"; S_sec="none"; S_sni=""; S_fp=""; S_pbk=""; S_sid=""; S_spx=""
  S_path=""; S_host=""; S_alpn=""; S_svc=""; S_mode=""
}

emit_server() {
  local stream
  stream=$(jq -n \
    --arg net "$S_net" --arg sec "$S_sec" --arg sni "$S_sni" --arg fp "$S_fp" \
    --arg pbk "$S_pbk" --arg sid "$S_sid" --arg spx "$S_spx" --arg path "$S_path" \
    --arg host "$S_host" --arg alpn "$S_alpn" --arg svc "$S_svc" --arg mode "$S_mode" '
    {network:$net, security:$sec}
    + (if $sec=="tls" then
         {tls: {sni:$sni, fp:$fp, alpn: (if $alpn=="" then [] else ($alpn|split(",")) end)}}
       elif $sec=="reality" then
         {reality: {sni:$sni, fp:(if $fp=="" then "chrome" else $fp end), pbk:$pbk, sid:$sid, spx:$spx}}
       else {} end)
    + (if $net=="ws" then
         {ws: {path:(if $path=="" then "/" else $path end), host:$host}}
       elif $net=="grpc" then
         {grpc: {serviceName:$svc, multiMode:($mode=="multi")}}
       elif $net=="http" then
         {http: {path:(if $path=="" then "/" else $path end), host:(if $host=="" then [] else [$host] end)}}
       else {} end)')
  jq -n \
    --arg protocol "$P_proto" --arg tag "$P_tag" --arg address "$P_addr" \
    --argjson port "${P_port:-443}" --arg id "$P_id" --arg flow "$P_flow" \
    --arg encryption "$P_enc" --arg password "$P_pass" --arg method "$P_method" \
    --argjson alterId "${P_aid:-0}" --arg security "$P_scy" --arg raw "$P_raw" \
    --argjson stream "$stream" '
    {protocol:$protocol, tag:$tag, address:$address, port:$port, stream:$stream, raw:$raw}
    + (if $protocol=="vless" then {id:$id, flow:$flow, encryption:$encryption}
       elif $protocol=="vmess" then {id:$id, alterId:$alterId, security:$security}
       elif $protocol=="trojan" then {password:$password}
       elif $protocol=="shadowsocks" then {method:$method, password:$password}
       else {} end)'
}

parse_link() { # parse_link <link> -> server JSON on stdout, or return 1
  reset_fields
  P_raw="$1"
  case "$1" in
    vless://*)   _parse_vless "$1" ;;
    vmess://*)   _parse_vmess "$1" ;;
    trojan://*)  _parse_trojan "$1" ;;
    ss://*)      _parse_ss "$1" ;;
    *) return 1 ;;
  esac
}

_split_userhostq() { # sets U (userinfo) H (host) PО (port) Q (query) F (fragment)
  local rest="${1#*://}"
  F=""; case "$rest" in *#*) F="${rest#*#}"; rest="${rest%%#*}";; esac
  U="${rest%%@*}"
  local hpq="${rest#*@}"
  Q=""; case "$hpq" in *\?*) Q="${hpq#*\?}"; hpq="${hpq%%\?*}";; esac
  H="${hpq%%:*}"; PO="${hpq##*:}"
}

_parse_vless() {
  local U H PO Q F; _split_userhostq "$1"
  P_proto="vless"; P_id=$(urldecode "$U"); P_addr="$H"; P_port="$PO"
  P_flow=$(qget "$Q" flow); P_enc=$(qget "$Q" encryption); [ -z "$P_enc" ] && P_enc="none"
  _stream_from_query "$Q"
  P_tag=$(urldecode "$F"); [ -z "$P_tag" ] && P_tag="$H:$PO"
  emit_server
}

_parse_trojan() {
  local U H PO Q F; _split_userhostq "$1"
  P_proto="trojan"; P_pass=$(urldecode "$U"); P_addr="$H"; P_port="$PO"
  _stream_from_query "$Q"; [ -z "$S_sec" ] && S_sec="tls"
  [ "$S_sec" = "none" ] && S_sec="tls"
  P_tag=$(urldecode "$F"); [ -z "$P_tag" ] && P_tag="$H:$PO"
  emit_server
}

_parse_vmess() {
  local j; j=$(b64d "${1#vmess://}"); [ -z "$j" ] && return 1
  printf '%s' "$j" | jq -e . >/dev/null 2>&1 || return 1
  P_proto="vmess"
  P_addr=$(printf '%s' "$j" | jq -r '.add // ""')
  P_port=$(printf '%s' "$j" | jq -r '(.port // 443) | tonumber? // 443')
  P_id=$(printf '%s' "$j" | jq -r '.id // ""')
  P_aid=$(printf '%s' "$j" | jq -r '(.aid // 0) | tonumber? // 0')
  P_scy=$(printf '%s' "$j" | jq -r '.scy // "auto"')
  P_tag=$(printf '%s' "$j" | jq -r '.ps // (.add+":"+( .port|tostring))')
  local net tls; net=$(printf '%s' "$j" | jq -r '.net // "tcp"'); [ "$net" = "h2" ] && net="http"
  tls=$(printf '%s' "$j" | jq -r '.tls // ""')
  S_net="$net"
  case "$tls" in tls|1|true) S_sec="tls";; *) S_sec="none";; esac
  S_sni=$(printf '%s' "$j" | jq -r '.sni // .host // ""')
  S_host=$(printf '%s' "$j" | jq -r '.host // ""')
  S_path=$(printf '%s' "$j" | jq -r '.path // ""')
  S_fp=$(printf '%s' "$j" | jq -r '.fp // ""')
  S_alpn=$(printf '%s' "$j" | jq -r '.alpn // ""')
  [ "$net" = "grpc" ] && S_svc=$(printf '%s' "$j" | jq -r '.path // ""')
  emit_server
}

_parse_ss() {
  local rest="${1#ss://}" F="" host port method pass
  case "$rest" in *#*) F="${rest#*#}"; rest="${rest%%#*}";; esac
  if printf '%s' "$rest" | grep -q '@'; then
    local userinfo="${rest%@*}" hp="${rest##*@}"
    local dec; dec=$(b64d "$userinfo")
    case "$dec" in *:*) method="${dec%%:*}"; pass="${dec#*:}";;
                   *) local ud; ud=$(urldecode "$userinfo"); method="${ud%%:*}"; pass="${ud#*:}";; esac
    hp="${hp%%\?*}"; hp="${hp%%/*}"
    host="${hp%%:*}"; port="${hp##*:}"
  else
    local dec; dec=$(b64d "${rest%%\?*}")
    local creds="${dec%@*}" hp="${dec##*@}"
    method="${creds%%:*}"; pass="${creds#*:}"
    host="${hp%%:*}"; port="${hp##*:}"
  fi
  [ -z "$host" ] && return 1
  P_proto="shadowsocks"; P_addr="$host"; P_port="${port:-8388}"
  P_method="$method"; P_pass="$pass"; S_net="tcp"; S_sec="none"
  P_tag=$(urldecode "$F"); [ -z "$P_tag" ] && P_tag="$host:$port"
  emit_server
}

_stream_from_query() {
  local q="$1" net sec
  net=$(qget "$q" type); [ -z "$net" ] && net="tcp"; [ "$net" = "h2" ] && net="http"
  sec=$(qget "$q" security); [ -z "$sec" ] && sec="none"
  S_net="$net"; S_sec="$sec"
  S_sni=$(qget "$q" sni); [ -z "$S_sni" ] && S_sni=$(qget "$q" host)
  S_fp=$(qget "$q" fp); S_alpn=$(qget "$q" alpn)
  S_pbk=$(qget "$q" pbk); S_sid=$(qget "$q" sid); S_spx=$(qget "$q" spx)
  S_path=$(qget "$q" path); S_host=$(qget "$q" host)
  S_svc=$(qget "$q" serviceName); [ -z "$S_svc" ] && S_svc=$(qget "$q" path)
  S_mode=$(qget "$q" mode)
}

# --------------------------------------------------------------------------- #
# Xray config generation (jq does the heavy lifting)
# --------------------------------------------------------------------------- #
JQ_PRIVATE='["0.0.0.0/8","10.0.0.0/8","100.64.0.0/10","127.0.0.0/8","169.254.0.0/16","172.16.0.0/12","192.168.0.0/16","::1/128","fc00::/7","fe80::/10"]'

read -r -d '' JQ_BUILD <<'JQEOF' || true
def stream($s; $pin):
  ($s.stream.network // "tcp") as $net |
  ($s.stream.security // "none") as $sec |
  {network:$net, security:$sec}
  + (if $sec=="tls" then
       {tlsSettings:
         ( (if ($s.stream.tls.sni // "") != "" then {serverName:$s.stream.tls.sni}
            elif ($pin != null) and (($s.address|test("^[0-9.]+$"))|not) then {serverName:$s.address}
            else {} end)
         + (if ($s.stream.tls.fp // "") != "" then {fingerprint:$s.stream.tls.fp} else {} end)
         + (if (($s.stream.tls.alpn // [])|length) > 0 then {alpn:$s.stream.tls.alpn} else {} end)
         + {allowInsecure:false} )}
     elif $sec=="reality" then
       {realitySettings:
         ({serverName:$s.stream.reality.sni, fingerprint:($s.stream.reality.fp // "chrome"),
           publicKey:$s.stream.reality.pbk, shortId:$s.stream.reality.sid}
          + (if ($s.stream.reality.spx // "") != "" then {spiderX:$s.stream.reality.spx} else {} end))}
     else {} end)
  + (if $net=="ws" then
       {wsSettings: ({path:($s.stream.ws.path // "/")}
                     + (if ($s.stream.ws.host // "") != "" then {headers:{Host:$s.stream.ws.host}} else {} end))}
     elif $net=="grpc" then
       {grpcSettings:{serviceName:($s.stream.grpc.serviceName // ""), multiMode:($s.stream.grpc.multiMode // false)}}
     elif $net=="http" then
       {httpSettings:{path:($s.stream.http.path // "/"), host:($s.stream.http.host // [])}}
     else {} end);

def outbound($s; $pin):
  ($pin // $s.address) as $addr |
  {tag:"proxy", protocol:$s.protocol, streamSettings: stream($s; $pin)}
  + (if $s.protocol=="vless" then
       {settings:{vnext:[{address:$addr, port:$s.port,
         users:[ ({id:$s.id, encryption:($s.encryption // "none")}
                  + (if ($s.flow // "") != "" then {flow:$s.flow} else {} end)) ]}]}}
     elif $s.protocol=="vmess" then
       {settings:{vnext:[{address:$addr, port:$s.port,
         users:[{id:$s.id, alterId:($s.alterId // 0), security:($s.security // "auto")}]}]}}
     elif $s.protocol=="trojan" then
       {settings:{servers:[{address:$addr, port:$s.port, password:$s.password}]}}
     elif $s.protocol=="shadowsocks" then
       {settings:{servers:[{address:$addr, port:$s.port, method:$s.method, password:$s.password}]}}
     else {} end);

{
  log: {loglevel: $loglevel},
  inbounds: [
    {tag:"socks", listen:$listen, port:$socks, protocol:"socks",
     settings:{udp:true, auth:"noauth"},
     sniffing:{enabled:true, destOverride:["http","tls","quic"]}},
    {tag:"http", listen:$listen, port:$http, protocol:"http", settings:{}}
  ],
  outbounds: [
    outbound(.; $pin),
    {tag:"direct", protocol:"freedom", settings:{domainStrategy:"UseIP"}},
    {tag:"block", protocol:"blackhole", settings:{}}
  ],
  routing: {domainStrategy:"IPIfNonMatch",
            rules:[{type:"field", ip:$private, outboundTag:"direct"}]}
}
JQEOF

build_config() { # build_config <server_obj> [pin_ip]
  local obj="$1" pin="${2:-}" pinarg="null"
  [ -n "$pin" ] && pinarg="\"$pin\""
  printf '%s' "$obj" | jq \
    --argjson socks "$SOCKS_PORT" --argjson http "$HTTP_PORT" \
    --arg listen "$LISTEN" --arg loglevel "$LOGLEVEL" \
    --argjson pin "$pinarg" --argjson private "$JQ_PRIVATE" \
    "$JQ_BUILD"
}

write_active_config() { # [pin_ip] -> 0 ok, prints server obj
  local pin="${1:-}"
  [ -z "$ACTIVE" ] && return 1
  local obj; obj=$(servers_json | jq -c --arg t "$ACTIVE" '.[] | select(.tag==$t)' | head -1)
  [ -z "$obj" ] && return 1
  ensure_dirs
  build_config "$obj" "$pin" > "$GEN_CONFIG"
  printf '%s' "$obj"
}

# --------------------------------------------------------------------------- #
# xray binary / systemd
# --------------------------------------------------------------------------- #
xray_version() { have xray && xray version 2>/dev/null | head -1; }

require_xray() {
  have xray && return 0
  err "xray binary not found."
  box "$YELLOW" "xray not installed" -- \
    "Install on Arch with one of:" \
    "  ${CYAN}sudo pacman -S xray${RESET}        ${DIM}(community repo)${RESET}" \
    "  ${CYAN}yay -S xray-bin${RESET}            ${DIM}(AUR)${RESET}"
  return 1
}

have_systemd() { have systemctl; }
uctl() { systemctl --user "$@"; }
service_active() { have_systemd && [ "$(uctl is-active "$UNIT_NAME" 2>/dev/null)" = "active" ]; }
tun_active() {  # the tun2proxy unit may live in the system or the --user manager
  have_systemd || return 1
  [ "$(systemctl is-active "$TUN_UNIT" 2>/dev/null)" = "active" ] && return 0
  [ "$(systemctl --user is-active "$TUN_UNIT" 2>/dev/null)" = "active" ] && return 0
  return 1
}

write_unit() {
  mkdir -p "$SYSTEMD_USER_DIR"
  local bin; bin=$(command -v xray || echo /usr/bin/xray)
  cat > "$UNIT_PATH" <<EOF
[Unit]
Description=v3xtun managed Xray-core instance
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$bin run -config $GEN_CONFIG
Restart=on-failure
RestartSec=3
LimitNOFILE=51200

[Install]
WantedBy=default.target
EOF
  have_systemd && uctl daemon-reload
}

# --------------------------------------------------------------------------- #
# TUN helpers
# --------------------------------------------------------------------------- #
default_route() { # echoes "iface gw"
  have ip || return 1
  ip route show default 2>/dev/null | sed -n '1p' | \
    awk '{for(i=1;i<=NF;i++){if($i=="dev")d=$(i+1); if($i=="via")g=$(i+1)} print d, g}'
}

resolve_ips() { # resolve_ips <host> -> ipv4 lines
  if is_ip "$1"; then printf '%s\n' "$1"; return; fi
  if have getent; then getent ahostsv4 "$1" 2>/dev/null | awk '{print $1}' | sort -u; fi
}

run_root() { printf '  %s(requesting root via sudo for network setup…)%s\n' "$DIM" "$RESET"; sudo sh -c "$1"; }

tun2proxy_bin() { command -v tun2proxy-bin 2>/dev/null || command -v tun2proxy 2>/dev/null; }
tun_scope() { [ -f "$TUN_STATE_FILE" ] && jq -r '.scope // "system"' "$TUN_STATE_FILE" 2>/dev/null || printf 'system'; }
# true if tun2proxy has CAP_NET_ADMIN file-cap → can run rootless (like the GUI's "grant rights")
tun_has_cap() { have getcap && getcap "$1" 2>/dev/null | grep -qi 'cap_net_admin'; }

egress_socks() { have curl && curl -s --max-time 8 --socks5-hostname "$LISTEN:$SOCKS_PORT" "$IP_ECHO" 2>/dev/null; }
egress_os()    { have curl && curl -s --max-time 8 "$IP_ECHO" 2>/dev/null; }

# --------------------------------------------------------------------------- #
# Commands
# --------------------------------------------------------------------------- #
cmd_add() {
  ensure_dirs
  local added=0 link obj tag
  for link in "$@"; do
    obj=$(parse_link "$link") || { err "could not parse: ${link:0:48}…"; continue; }
    tag=$(printf '%s' "$obj" | jq -r '.tag')
    tag=$(unique_tag "$tag")
    obj=$(printf '%s' "$obj" | jq --arg t "$tag" '.tag=$t')
    servers_json | jq --argjson o "$obj" '. + [$o]' | write_servers
    local proto addr port
    proto=$(printf '%s' "$obj" | jq -r '.protocol'); addr=$(printf '%s' "$obj" | jq -r '.address'); port=$(printf '%s' "$obj" | jq -r '.port')
    ok "added ${BOLD}${tag}${RESET} ${DIM}(${proto} → ${addr}:${port})${RESET}"
    added=$((added+1))
  done
  load_state
  if [ "$added" -ge 1 ] && [ -z "$ACTIVE" ]; then
    local first; first=$(servers_json | jq -r '.[0].tag // ""')
    [ -n "$first" ] && { save_active "$first"; info "set active server to ${BOLD}${first}${RESET}"; }
  fi
  return 0
}

cmd_list() {
  load_state
  local n; n=$(servers_json | jq 'length')
  if [ "$n" -eq 0 ]; then warn "no servers yet — add one with ${CYAN}v3xtun add <link>${RESET}"; return; fi
  local lines=() i=1 line
  while IFS=$'\t' read -r tag proto addr port net sec; do
    local mark="${DIM}○${RESET}" name="$tag"
    [ "$tag" = "$ACTIVE" ] && { mark="${GREEN}●${RESET}"; name="${BOLD}${tag}${RESET}"; }
    lines+=("$mark ${GRAY}$(printf '%2d' "$i")${RESET}  ${PURPLE}$(printf '%-11s' "$proto")${RESET} $name")
    lines+=("      ${DIM}${addr}:${port}  ·  ${net}/${sec}${RESET}")
    i=$((i+1))
  done < <(servers_json | jq -r '.[] | [.tag,.protocol,.address,(.port|tostring),(.stream.network//"tcp"),(.stream.security//"none")] | @tsv')
  box "$GRAY" "servers ($n)" -- "${lines[@]}"
}

cmd_use() {
  local obj; obj=$(find_server "$1")
  [ -z "$obj" ] && { err "no server matching '$1'"; return 1; }
  local tag; tag=$(printf '%s' "$obj" | jq -r '.tag')
  load_state; save_active "$tag"
  ok "active server → ${BOLD}${tag}${RESET}"
  if tun_active; then info "TUN mode is on — reconfiguring tunnel…"; tun_on
  elif service_active; then info "restarting service to apply…"; cmd_restart; fi
}

cmd_remove() {
  local obj; obj=$(find_server "$1")
  [ -z "$obj" ] && { err "no server matching '$1'"; return 1; }
  local tag; tag=$(printf '%s' "$obj" | jq -r '.tag')
  servers_json | jq --arg t "$tag" 'map(select(.tag != $t))' | write_servers
  load_state
  if [ "$ACTIVE" = "$tag" ]; then
    local first; first=$(servers_json | jq -r '.[0].tag // ""'); save_active "$first"
  fi
  ok "removed ${BOLD}${tag}${RESET}"
}

cmd_start() {
  require_xray || return 1
  load_state
  if [ -z "$ACTIVE" ]; then
    local first; first=$(servers_json | jq -r '.[0].tag // ""')
    [ -z "$first" ] && { warn "no servers to start — add one first"; return 1; }
    save_active "$first"
  fi
  write_active_config >/dev/null || { err "active server missing; pick one with 'v3xtun use <name>'"; return 1; }
  write_unit
  if ! have_systemd; then warn "systemd not available — run manually:"; printf '    %sxray run -config %s%s\n' "$CYAN" "$GEN_CONFIG" "$RESET"; return; fi
  spin_start "starting xray → $ACTIVE"; uctl enable --now "$UNIT_NAME" >/dev/null 2>&1; sleep 0.6; spin_stop
  if service_active; then
    ok "connected via ${BOLD}${ACTIVE}${RESET} ${DIM}(socks ${SOCKS_PORT} · http ${HTTP_PORT})${RESET}"
  else err "service failed to start — check 'v3xtun logs'"; fi
}

cmd_stop() {
  have_systemd || { warn "systemd not available"; return; }
  if tun_active; then info "TUN mode is on — tearing it down first…"; tun_off; fi
  spin_start "stopping xray"; uctl disable --now "$UNIT_NAME" >/dev/null 2>&1; sleep 0.4; spin_stop
  ok "stopped"
}

cmd_restart() {
  load_state; write_active_config >/dev/null; write_unit
  have_systemd || { warn "systemd not available"; return; }
  spin_start "restarting xray"; uctl restart "$UNIT_NAME" >/dev/null 2>&1; sleep 0.6; spin_stop
  if service_active; then ok "restarted"; else err "restart failed — check 'v3xtun logs'"; fi
}

cmd_status() {
  load_state
  local running="${DIM}○ stopped${RESET}" tun="${DIM}○ off${RESET}"
  service_active && running="${GREEN}● connected${RESET}"
  tun_active && tun="${GREEN}● on${RESET}"
  local ver; ver=$(xray_version); [ -z "$ver" ] && ver="${RED}not installed${RESET}"
  local n; n=$(servers_json | jq 'length')
  local srv="${DIM}none${RESET}"; [ -n "$ACTIVE" ] && srv="${BOLD}${ACTIVE}${RESET}"
  box "$ORANGE" "v3xtun" -- \
    "${GRAY}status   ${RESET}$running" \
    "${GRAY}server   ${RESET}$srv" \
    "${GRAY}tun mode ${RESET}$tun" \
    "${GRAY}inbound  ${RESET}socks5 ${CYAN}${LISTEN}:${SOCKS_PORT}${RESET}  ·  http ${CYAN}${LISTEN}:${HTTP_PORT}${RESET}" \
    "${GRAY}xray     ${RESET}$ver" \
    "${GRAY}saved    ${RESET}${n} server(s)"
}

cmd_test() {
  local switch="${1:-}"
  local n; n=$(servers_json | jq 'length')
  [ "$n" -eq 0 ] && { warn "no servers to test"; return; }
  load_state
  spin_start "probing servers"
  local results=""
  while IFS=$'\t' read -r tag addr port; do
    local ms; ms=$(_tcp_ms "$addr" "$port")
    results="${results}${ms}\t${tag}\n"
  done < <(servers_json | jq -r '.[] | [.tag,.address,(.port|tostring)] | @tsv')
  spin_stop
  local lines=() best=""
  while IFS=$'\t' read -r ms tag; do
    [ -z "$tag" ] && continue
    local badge
    if [ "$ms" = "9999999" ]; then badge="${RED}timeout${RESET}"
    elif [ "$ms" -lt 150 ]; then badge="${GREEN}$(printf '%6d' "$ms") ms${RESET}"
    elif [ "$ms" -lt 400 ]; then badge="${YELLOW}$(printf '%6d' "$ms") ms${RESET}"
    else badge="${RED}$(printf '%6d' "$ms") ms${RESET}"; fi
    [ -z "$best" ] && [ "$ms" != "9999999" ] && best="$tag"
    local cur=""; [ "$tag" = "$ACTIVE" ] && cur=" ${GREEN}(active)${RESET}"
    lines+=("$badge  ${tag}${cur}")
  done < <(printf "$results" | sort -n)
  box "$GRAY" "latency" -- "${lines[@]}"
  if [ "$switch" = "switch" ] && [ -n "$best" ]; then
    if [ "$best" != "$ACTIVE" ]; then cmd_use "$best"; else info "already on the fastest server ($best)"; fi
  fi
}

_tcp_ms() { # tcp connect time in ms (timeout 3s), or 9999999
  local host="$1" port="$2"
  if have python3; then
    python3 - "$host" "$port" <<'PY' 2>/dev/null || echo 9999999
import socket,sys,time
h,p=sys.argv[1],int(sys.argv[2])
try:
    t=time.time(); socket.create_connection((h,p),3).close(); print(int((time.time()-t)*1000))
except Exception: print(9999999)
PY
  else
    local t0 t1
    t0=$(date +%s%N 2>/dev/null)
    if timeout 3 bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null; then
      t1=$(date +%s%N 2>/dev/null); echo $(( (t1 - t0) / 1000000 ))
    else echo 9999999; fi
  fi
}

cmd_sub() {
  have curl || { err "curl is required for subscriptions"; return 1; }
  spin_start "fetching subscription"
  local body; body=$(curl -s --max-time 15 -A "v3xtun/1.0" "$1"); spin_stop
  [ -z "$body" ] && { err "subscription fetch failed or empty"; return 1; }
  local decoded; decoded=$(printf '%s' "$body" | tr -d '\n' | base64 --decode 2>/dev/null)
  case "$decoded" in *://*) body="$decoded";; esac
  local links=() ln
  while IFS= read -r ln; do case "$ln" in *://*) links+=("$ln");; esac; done <<EOF
$body
EOF
  [ "${#links[@]}" -eq 0 ] && { warn "subscription returned no servers"; return; }
  info "got ${#links[@]} server(s)"
  cmd_add "${links[@]}"
  ok "imported from subscription"
}

cmd_proxy() {
  load_state
  case "$1" in
    on)
      ensure_dirs
      cat > "$ENV_PROXY_FILE" <<EOF
export http_proxy=http://$LISTEN:$HTTP_PORT
export https_proxy=http://$LISTEN:$HTTP_PORT
export all_proxy=socks5://$LISTEN:$SOCKS_PORT
export HTTP_PROXY=http://$LISTEN:$HTTP_PORT
export HTTPS_PROXY=http://$LISTEN:$HTTP_PORT
export ALL_PROXY=socks5://$LISTEN:$SOCKS_PORT
EOF
      if have gsettings; then
        gsettings set org.gnome.system.proxy mode 'manual' 2>/dev/null
        gsettings set org.gnome.system.proxy.http host "$LISTEN" 2>/dev/null
        gsettings set org.gnome.system.proxy.http port "$HTTP_PORT" 2>/dev/null
        gsettings set org.gnome.system.proxy.https host "$LISTEN" 2>/dev/null
        gsettings set org.gnome.system.proxy.https port "$HTTP_PORT" 2>/dev/null
        gsettings set org.gnome.system.proxy.socks host "$LISTEN" 2>/dev/null
        gsettings set org.gnome.system.proxy.socks port "$SOCKS_PORT" 2>/dev/null
        info "GNOME proxy set via gsettings"
      fi
      ok "system proxy ${GREEN}${BOLD}ON${RESET}"
      info "for shells, run: ${CYAN}source $ENV_PROXY_FILE${RESET}"
      ;;
    off)
      have gsettings && gsettings set org.gnome.system.proxy mode 'none' 2>/dev/null
      rm -f "$ENV_PROXY_FILE"
      ok "system proxy ${RED}${BOLD}OFF${RESET}"
      info "in current shell: ${CYAN}unset http_proxy https_proxy all_proxy${RESET}"
      ;;
    *) err "usage: proxy on|off";;
  esac
}

cmd_logs() {
  have_systemd || { warn "systemd not available; no journald logs"; return; }
  local follow=""; [ "${1:-}" = "-f" ] && follow="-f"
  journalctl --user -u "$UNIT_NAME" -n 40 --no-pager $follow
}

cmd_config() {
  load_state
  write_active_config >/dev/null || { warn "no active server"; return; }
  cat "$GEN_CONFIG"
}

# --------------------------------------------------------------------------- #
# TUN VPN mode — hardened, leak-free, fail-closed
# --------------------------------------------------------------------------- #
cmd_tun() {
  case "${1:-status}" in
    on) tun_on ;;
    off) tun_off ;;
    status|"") tun_status ;;
    *) err "usage: tun on|off|status" ;;
  esac
}

tun_status() {
  load_state
  local on=false; tun_active && on=true
  local dot="${DIM}○ off${RESET}"; $on && dot="${GREEN}● on${RESET}"
  local st='{}'; [ -f "$TUN_STATE_FILE" ] && st=$(cat "$TUN_STATE_FILE")
  local server pin bypass scope ifgw
  server=$(printf '%s' "$st" | jq -r '.server // "—"')
  pin=$(printf '%s' "$st" | jq -r '.pin_ip // "—"')
  scope=$(printf '%s' "$st" | jq -r '.scope // "—"')
  bypass=$(printf '%s' "$st" | jq -r '(.bypass // []) | join(", ")'); [ -z "$bypass" ] && bypass="${DIM}none${RESET}"
  ifgw=$(default_route); local iface="${ifgw%% *}" gw="${ifgw##* }"
  local lines=()
  lines+=("${GRAY}tun mode ${RESET}$dot")
  if $on; then
    spin_start "checking exit IP"; local eip; eip=$(egress_os); [ -z "$eip" ] && eip=$(egress_socks); spin_stop
    [ -z "$eip" ] && eip="${DIM}unknown${RESET}" || eip="${BOLD}${GREEN}${eip}${RESET}"
    lines+=("${GRAY}exit ip  ${RESET}$eip")
  fi
  lines+=("${GRAY}engine   ${RESET}tun2proxy ${DIM}(${scope})${RESET}")
  lines+=("${GRAY}device   ${RESET}${TUN_DEV}  ${DIM}virtual DNS (leak-free)${RESET}")
  lines+=("${GRAY}server   ${RESET}${server} ${DIM}pinned ${pin}${RESET}")
  lines+=("${GRAY}bypass   ${RESET}${bypass}")
  lines+=("${GRAY}uplink   ${RESET}${iface:-?} ${DIM}gw ${gw:-?}${RESET}")
  box "$PURPLE" "tun" -- "${lines[@]}"
}

# Drive tun2proxy --setup: it creates the TUN, rewrites the routing table, does
# leak-free virtual DNS, and *restores everything itself* on SIGTERM. We pin
# xray to the server's literal IP and pass that IP as --bypass so xray's own
# uplink to the server doesn't loop back into the tunnel.
tun_on() {
  require_xray || return 1
  local t2p; t2p=$(tun2proxy_bin)
  if [ -z "$t2p" ]; then
    err "tun2proxy binary not found."
    box "$YELLOW" "tun2proxy not installed" -- \
      "TUN mode needs tun2proxy (same engine as the v3xtun GUI). Install on Arch:" \
      "  ${CYAN}yay -S tun2proxy${RESET}            ${DIM}(provides tun2proxy-bin)${RESET}"
    return 1
  fi
  have_systemd || { err "TUN mode requires systemd."; return 1; }
  load_state
  [ -z "$ACTIVE" ] && { err "no active server — pick one with 'v3xtun use <name>'"; return 1; }
  local obj; obj=$(servers_json | jq -c --arg t "$ACTIVE" '.[] | select(.tag==$t)' | head -1)
  [ -z "$obj" ] && { err "active server missing"; return 1; }
  local addr; addr=$(printf '%s' "$obj" | jq -r '.address')

  spin_start "resolving $addr"; local bypass; bypass=$(resolve_ips "$addr"); spin_stop
  [ -z "$bypass" ] && { err "could not resolve $addr to IPv4 — cannot build a leak-free tunnel. Aborting."; return 1; }
  local pin_ip; pin_ip=$(printf '%s\n' "$bypass" | head -1)

  local prev=""; tun_active && [ -f "$TUN_STATE_FILE" ] && prev=$(jq -r '(.bypass // [])[]' "$TUN_STATE_FILE" 2>/dev/null)
  local all_bypass; all_bypass=$(printf '%s\n%s\n' "$bypass" "$prev" | sed '/^$/d' | sort -u)

  # pin xray to the literal server IP and (re)start it
  write_active_config "$pin_ip" >/dev/null; write_unit
  spin_start "starting xray (pinned to $pin_ip)"; uctl restart "$UNIT_NAME" >/dev/null 2>&1; sleep 0.7; spin_stop
  if ! service_active; then
    err "xray failed to start with pinned config — check 'v3xtun logs'"
    write_active_config >/dev/null; uctl restart "$UNIT_NAME" >/dev/null 2>&1; return 1
  fi

  # assemble tun2proxy args (--setup handles routing + DNS; --bypass per server IP)
  local args="--tun $TUN_DEV --proxy socks5://127.0.0.1:$SOCKS_PORT --setup --dns virtual"
  local ip; while IFS= read -r ip; do [ -n "$ip" ] && args="$args --bypass $ip"; done <<EOF
$all_bypass
EOF

  # rootless if tun2proxy carries CAP_NET_ADMIN (GUI "grant rights"), else via sudo
  local scope
  if tun_has_cap "$t2p"; then
    scope="user"
    spin_start "starting tun2proxy (rootless, cap_net_admin)"
    systemctl --user reset-failed "$TUN_UNIT" 2>/dev/null
    systemctl --user stop "$TUN_UNIT" 2>/dev/null
    systemd-run --user --unit="$TUN_UNIT" --collect \
      --property=Restart=on-failure --property=RestartSec=2 \
      "$t2p" $args >/dev/null 2>&1
    spin_stop
  else
    scope="system"
    spin_start "starting tun2proxy (sudo)"
    run_root "systemctl reset-failed $TUN_UNIT 2>/dev/null; systemctl stop $TUN_UNIT 2>/dev/null; systemd-run --unit=$TUN_UNIT --collect --property=Restart=on-failure --property=RestartSec=2 $t2p $args" >/dev/null
    spin_stop
  fi

  ensure_dirs
  printf '%s\n' "$all_bypass" | jq -R . | jq -s \
    --arg pin "$pin_ip" --arg server "$ACTIVE" --arg scope "$scope" --arg dev "$TUN_DEV" \
    '{dev:$dev, pin_ip:$pin, server:$server, scope:$scope, engine:"tun2proxy", bypass: map(select(length>0))}' \
    > "$TUN_STATE_FILE"

  sleep 1.0
  if ! tun_active; then
    err "tun2proxy did not come up — rolling back. Check 'journalctl -u $TUN_UNIT'"
    tun_off_silent; return 1
  fi

  spin_start "verifying tunnel (exit IP)"
  local via_socks via_os; via_socks=$(egress_socks); via_os=$(egress_os); spin_stop

  ok "TUN mode ${GREEN}${BOLD}ON${RESET} — whole system routed via ${BOLD}${ACTIVE}${RESET} ${DIM}(pinned ${pin_ip}, ${scope})${RESET}"
  if [ -n "$via_os" ] && [ "$via_os" = "$via_socks" ]; then
    ok "verified: exit IP ${BOLD}${GREEN}${via_os}${RESET} via tunnel ${DIM}(socks & OS path agree — no leak)${RESET}"
  elif [ -n "$via_os" ]; then
    warn "OS path exits via ${BOLD}${via_os}${RESET} ${DIM}(socks reported ${via_socks:-—})${RESET}"
  elif [ -n "$via_socks" ]; then
    warn "proxy core works (exit $via_socks) but OS-path check failed — echo host may be blocked"
  else
    warn "could not confirm exit IP yet; check 'v3xtun tun status' / 'journalctl -u $TUN_UNIT'"
  fi
  info "DNS is leak-free (virtual). tun2proxy restores routing on stop. Off with 'v3xtun tun off'"
}

tun_off_silent() {
  local scope; scope=$(tun_scope)
  if [ "$scope" = "user" ]; then
    spin_start "stopping tun2proxy"
    systemctl --user stop "$TUN_UNIT" 2>/dev/null
    systemctl --user reset-failed "$TUN_UNIT" 2>/dev/null
    spin_stop
  else
    spin_start "stopping tun2proxy (sudo)"
    run_root "systemctl stop $TUN_UNIT 2>/dev/null; systemctl reset-failed $TUN_UNIT 2>/dev/null; true" >/dev/null
    spin_stop
  fi
  sleep 0.5  # let tun2proxy restore routes/DNS on SIGTERM
  rm -f "$TUN_STATE_FILE"
  load_state
  if [ -n "$ACTIVE" ]; then write_active_config >/dev/null; service_active && uctl restart "$UNIT_NAME" >/dev/null 2>&1; fi
}

tun_off() {
  tun_off_silent
  ok "TUN mode ${RED}${BOLD}OFF${RESET} — tun2proxy stopped, routing & DNS restored"
}

# --------------------------------------------------------------------------- #
# Interactive shell
# --------------------------------------------------------------------------- #
banner() {
  local ver; ver=$(xray_version); local vline="${GREEN}${ver}${RESET}"; [ -z "$ver" ] && vline="${RED}xray not installed${RESET}"
  printf '\n'
  box "$ORANGE" "v3xtun · interactive shell" -- \
    "${GRAY}core:${RESET} $vline" \
    "${DIM}type ${RESET}${CYAN}help${RESET}${DIM} for commands, or paste a share link${RESET}"
  printf '\n'
}

status_line() {
  load_state
  local dot="${DIM}○${RESET}" conn="${DIM}stopped${RESET}"
  service_active && { dot="${GREEN}●${RESET}"; conn="${GREEN}connected${RESET}"; }
  tun_active && conn="${GREEN}connected ${DIM}+tun${RESET}"
  local name="${DIM}no server${RESET}"; [ -n "$ACTIVE" ] && name="$ACTIVE"
  printf '  %s %s %s·%s %s\n' "$dot" "$name" "$DIM" "$RESET" "$conn"
}

print_help() {
  box "$PURPLE" "commands" -- \
    "${CYAN}add <link>${RESET}   ${DIM}add a vless/vmess/trojan/ss link${RESET}" \
    "${CYAN}list${RESET}         ${DIM}list saved servers${RESET}" \
    "${CYAN}use <name|#>${RESET} ${DIM}set active server${RESET}" \
    "${CYAN}start/stop${RESET}   ${DIM}control the proxy service${RESET}" \
    "${CYAN}restart${RESET}      ${DIM}restart the service${RESET}" \
    "${CYAN}status${RESET}       ${DIM}connection status${RESET}" \
    "${CYAN}test${RESET}         ${DIM}latency-test all servers${RESET}" \
    "${CYAN}fastest${RESET}      ${DIM}switch to the fastest server${RESET}" \
    "${CYAN}sub <url>${RESET}    ${DIM}import a subscription${RESET}" \
    "${CYAN}proxy on|off${RESET} ${DIM}system proxy toggle${RESET}" \
    "${CYAN}tun on|off${RESET}   ${DIM}whole-system VPN (TUN)${RESET}" \
    "${CYAN}remove <ref>${RESET} ${DIM}delete a server${RESET}" \
    "${CYAN}logs${RESET}         ${DIM}service logs${RESET}" \
    "${CYAN}config${RESET}       ${DIM}print generated xray config${RESET}" \
    "${CYAN}quit${RESET}         ${DIM}exit${RESET}"
}

repl() {
  banner
  while :; do
    printf '\n'; status_line
    printf '  %s❯%s ' "$ORANGE" "$RESET"
    IFS= read -r line || { printf '\n%s  bye%s\n\n' "$DIM" "$RESET"; break; }
    line="${line# }"; [ -z "$line" ] && continue
    case "$line" in *://*) cmd_add $line; continue;; esac
    set -- $line; local c="$1"; shift || true
    case "$c" in
      quit|exit|q) printf '%s  bye%s\n\n' "$DIM" "$RESET"; break ;;
      help|h|'?') print_help ;;
      clear) clear; banner ;;
      add) [ $# -ge 1 ] && cmd_add "$@" || warn "usage: add <link>" ;;
      list|ls) cmd_list ;;
      use) [ $# -ge 1 ] && cmd_use "$1" || warn "usage: use <name|#>" ;;
      remove|rm) [ $# -ge 1 ] && cmd_remove "$1" || warn "usage: remove <name|#>" ;;
      start) cmd_start ;;
      stop) cmd_stop ;;
      restart) cmd_restart ;;
      status) cmd_status ;;
      test) cmd_test ;;
      fastest) cmd_test switch ;;
      sub) [ $# -ge 1 ] && cmd_sub "$1" || warn "usage: sub <url>" ;;
      proxy) [ $# -ge 1 ] && cmd_proxy "$1" || warn "usage: proxy on|off" ;;
      tun) cmd_tun "${1:-status}" ;;
      logs) cmd_logs ;;
      config) cmd_config ;;
      *) warn "unknown command '$c' — try 'help'" ;;
    esac
  done
}

# --------------------------------------------------------------------------- #
# Dependency check + dispatch
# --------------------------------------------------------------------------- #
check_core_deps() {
  have jq || { printf 'v3xtun requires jq. Install: sudo pacman -S jq\n' >&2; exit 1; }
}

usage() {
  cat <<EOF
${BOLD}v3xtun${RESET} — Xray-core CLI/VPN wrapper (pure Bash)

usage: v3xtun [command] [args]

  add <link...>     add vless/vmess/trojan/ss share link(s)
  list              list saved servers
  use <name|#>      set active server
  remove <name|#>   delete a server
  start|stop        control the proxy service
  restart           restart the service
  status            show connection status
  test              latency-test all servers
  fastest           switch to the fastest server
  sub <url>         import a subscription URL
  proxy on|off      toggle system proxy
  tun on|off|status whole-system TUN VPN (leak-free, kill-switch)
  logs [-f]         service logs
  config            print generated xray config
  install-unit      (re)write the systemd user unit

Run with no command for the interactive shell.
EOF
}

main() {
  check_core_deps
  [ $# -eq 0 ] && { repl; return; }
  local cmd="$1"; shift || true
  load_state
  case "$cmd" in
    add) cmd_add "$@" ;;
    list|ls) cmd_list ;;
    use) cmd_use "${1:-}" ;;
    remove|rm) cmd_remove "${1:-}" ;;
    start) cmd_start ;;
    stop) cmd_stop ;;
    restart) cmd_restart ;;
    status) cmd_status ;;
    test) cmd_test ;;
    fastest) cmd_test switch ;;
    sub) cmd_sub "${1:-}" ;;
    proxy) cmd_proxy "${1:-}" ;;
    tun) cmd_tun "${1:-status}" ;;
    logs) cmd_logs "${1:-}" ;;
    config) cmd_config ;;
    install-unit) write_unit && ok "wrote $UNIT_PATH" ;;
    -h|--help|help) usage ;;
    *) err "unknown command '$cmd'"; usage; return 1 ;;
  esac
}

# run only when executed directly (sourcing exposes functions for testing)
if [ "${BASH_SOURCE[0]:-$0}" = "$0" ]; then
  main "$@"
fi
