#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$(readlink -f "$0")")"

ENV_FILE=.env
USERS_FILE=users.conf
OUT=generated
DOCKER=${DOCKER:-docker}
DEFAULT_GRACE_HOURS=24
# `update repo` pulls from here; override with REPO_URL / REPO_BRANCH in .env
DEFAULT_REPO_URL=https://github.com/Dx-by-Dy/custom-vpn.git
DEFAULT_REPO_BRANCH=main
# Files and directories that hold this server's state; never taken from the repo
STATE_PATHS=(.env users.conf data generated)
# What vpn.sh changed on the host outside this directory, for `uninstall`
HOST_STATE=/var/lib/custom-vpn
SYSCTL_CONF=/etc/sysctl.d/99-vpn.conf
SSH_HARDENING_CONF=/etc/ssh/sshd_config.d/00-vpn-hardening.conf
ASSUME_YES=false

usage() {
  cat <<'EOF'
Usage: ./vpn.sh <command> [args]

Setup:
  deploy                  full setup: tune, init, up, maintenance timer, links
  init                    create .env, generate missing keys, create the first user
  up                      render configs, check ports, start/restart containers
  down                    stop containers
  logs                    follow container logs
  tune                    enable BBR and bigger UDP buffers (sysctl)
  install-docker          install docker via get.docker.com
  uninstall               remove everything vpn.sh set up on this host (asks what to keep)
  firewall [--dry-run]    enable ufw for ssh, VPN ports and other listening
                          services, optionally disable SSH password login

Users:
  user add NAME           add a user and print their links
  user del NAME           remove a user, their links stop working immediately
  user list               list users
  links [NAME]            print subscription links (all users or one)
  rotate NAME|--all [--grace HOURS]
                          issue new credentials, the old ones keep working for
                          HOURS (default 24) so clients can refresh the subscription

Maintenance:
  update images           upgrade sing-box / caddy images to the latest releases
  update repo             update this repo's code from GitHub (keeps .env, users, certificates)
  render                  render configs into generated/ and validate them
  check                   check containers, certificate, Let's Encrypt path, REALITY target
  prune                   drop expired credentials
                          (check and prune run hourly from vpn-maintenance.timer)
  help                    show this help

Options:
  -y                      answer yes to all questions
EOF
}

die() { echo "error: $*" >&2; exit 1; }
warn() { echo "warning: $*" >&2; }
info() { echo ">> $*"; }

# ask "Question" y|n: returns 0 on yes; an empty answer means the default.
ask() {
  local question=$1 default=$2 hint answer
  $ASSUME_YES && return 0
  [[ -t 0 ]] || die "$question: no terminal to ask, rerun with -y"
  [[ $default == y ]] && hint="[Y/n]" || hint="[y/N]"
  read -r -p "$question $hint " answer
  [[ ${answer:-$default} == [yY]* ]]
}

# Serialize commands that change state (manual runs vs. the prune timer)
lock() {
  exec 9>.vpn.lock
  flock 9
}

require_root() { [[ $EUID -eq 0 ]] || die "$1 needs root"; }

urlencode() {
  local LC_ALL=C s=$1 out='' c i
  for ((i = 0; i < ${#s}; i++)); do
    c=${s:i:1}
    case $c in
      [a-zA-Z0-9.~_-]) out+=$c ;;
      *) out+=$(printf '%%%02X' "'$c") ;;
    esac
  done
  printf '%s' "$out"
}

rand_hex() { od -An -tx1 -N"$1" /dev/urandom | tr -d ' \n'; }

load_env() {
  [[ -f $ENV_FILE ]] || die "no $ENV_FILE: cp .env.example .env, then set DOMAIN and ACME_EMAIL"
  grep -qE '^XRAY_(PORT|PRIVATE_KEY)=' "$ENV_FILE" && die "$ENV_FILE is from the xray version, run: ./vpn.sh init"
  set -a; . "./$ENV_FILE"; set +a
  REALITY_TARGET=${REALITY_TARGET:-$REALITY_SNI:443}
  local host=${REALITY_TARGET%:*}
  host=${host#[}
  export REALITY_TARGET_HOST=${host%]} REALITY_TARGET_PORT=${REALITY_TARGET##*:}
  # caddy's certificate for DOMAIN: on the host and in the sing-box container
  CERT=data/caddy/caddy/certificates/acme-v02.api.letsencrypt.org-directory/$DOMAIN/$DOMAIN.crt
  export CERT_DIR=/caddy-data/caddy/certificates/acme-v02.api.letsencrypt.org-directory/$DOMAIN
  SUB_NAME_ENC=$(urlencode "$SUB_NAME")
  SUB_TITLE_B64=$(printf '%s' "$SUB_NAME" | base64 -w0)
}

# Write KEY=VALUE into .env (replace or append) and set it in this shell.
set_var() {
  local key=$1 val=$2
  if grep -q "^$key=" "$ENV_FILE"; then
    sed -i "s|^$key=.*|$key=$val|" "$ENV_FILE"
  else
    echo "$key=$val" >>"$ENV_FILE"
  fi
  export "$key=$val"
}

singbox_cli() { "$DOCKER" run --rm "$SINGBOX_IMAGE" "$@"; }

# Install a missing command from the package of the same name, asking first
need_pkg() {
  local pkg=$1 why=$2
  command -v "$pkg" >/dev/null && return
  command -v apt-get >/dev/null || die "$pkg is not installed ($why)"
  ask "$pkg is not installed ($why). Install it?" y || die "$pkg is required"
  local out
  out=$(DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$pkg" 2>&1) || die "can't install $pkg: $out"
}

# --- users -------------------------------------------------------------------
#
# users.conf has one credential per line:
#   name  vless_uuid  hysteria_user  hysteria_pass  sub_token  expires
# Active credentials have expires "-". Rotated-out ones have sub_token "-" and
# an expiry time (unix epoch); they stay valid until then. The hysteria user
# ("name-xxxx") changes on rotation, so old and new passwords can be valid at
# the same time; clients send "hysteria_user:hysteria_pass" as the password.

USERS_HEADER='# name  vless_uuid  hysteria_user  hysteria_pass  sub_token  expires'

users_init() {
  [[ -f $USERS_FILE ]] || { echo "$USERS_HEADER" >"$USERS_FILE"; chmod 600 "$USERS_FILE"; }
}

# Credentials that are active or not expired yet
users_valid() {
  awk -v now="$(date +%s)" '!/^#/ && NF && ($6 == "-" || $6 > now)' "$USERS_FILE" 2>/dev/null || true
}

users_active() { awk '!/^#/ && NF && $6 == "-"' "$USERS_FILE" 2>/dev/null || true; }

user_exists() { users_active | awk -v n="$1" '$1 == n {f = 1} END {exit !f}'; }

check_name() {
  [[ $1 =~ ^[a-z0-9_-]{1,32}$ ]] || die "user name must be 1-32 chars of a-z, 0-9, _ and -"
}

# Prints "name uuid hysteria_user hysteria_pass" for a fresh credential
new_cred() { echo "$1 $(cat /proc/sys/kernel/random/uuid) $1-$(rand_hex 2) $(rand_hex 16)"; }

# Rewrite users.conf: awk program gets each non-comment line as fields
users_rewrite() {
  local tmp
  tmp=$(mktemp "$USERS_FILE.XXXX")
  awk "$@" "$USERS_FILE" >"$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$USERS_FILE"
}

# Sets per-user link variables used by templates and `links`
user_vars() {
  local uuid=$1 hy_user=$2 hy_pass=$3 token=$4
  SUB_URL="https://$DOMAIN:$SUB_PORT/$token/sub"
  SUB_PAGE="https://$DOMAIN:$SUB_PORT/$token/"
  SUB_URL_ENC=$(urlencode "$SUB_URL")
  VLESS_LINK="vless://$uuid@$DOMAIN:$VLESS_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$REALITY_SNI&fp=chrome&pbk=$REALITY_PUBLIC_KEY&sid=$REALITY_SHORT_ID&type=tcp#$SUB_NAME_ENC-reality"
  HY2_LINK="hysteria2://$hy_user:$hy_pass@$DOMAIN:$HYSTERIA_PORT/?sni=$DOMAIN#$SUB_NAME_ENC-hy2"
}

cmd_user() {
  local action=${1:-} name=${2:-}
  case $action in
    add)
      check_name "$name"
      load_env
      users_init
      user_exists "$name" && die "user $name already exists"
      echo "$(new_cred "$name") $(rand_hex 16) -" >>"$USERS_FILE"
      cmd_up
      cmd_links "$name"
      ;;
    del)
      check_name "$name"
      user_exists "$name" || die "no user $name"
      users_rewrite -v n="$name" '/^#/ || $1 != n'
      cmd_up
      info "user $name removed"
      ;;
    list)
      [[ -f $USERS_FILE ]] || die "no users yet, run: ./vpn.sh init"
      awk -v now="$(date +%s)" '
        !/^#/ && NF && $6 == "-" { order[++n] = $1; token[$1] = $5 }
        !/^#/ && NF && $6 != "-" && $6 > now { old[$1]++ }
        END {
          printf "%-20s %-34s %s\n", "NAME", "SUB TOKEN", "OLD CREDENTIALS"
          for (i = 1; i <= n; i++) printf "%-20s %-34s %s\n", order[i], token[order[i]], old[order[i]] + 0
        }' "$USERS_FILE"
      ;;
    *) die "usage: ./vpn.sh user add|del|list [NAME]" ;;
  esac
}

cmd_rotate() {
  local target=${1:-} grace=$DEFAULT_GRACE_HOURS names expires line
  [[ -n $target ]] || die "usage: ./vpn.sh rotate NAME|--all [--grace HOURS]"
  shift
  while (($#)); do
    case $1 in
      --grace) grace=${2:-}; shift 2 || die "--grace needs a value" ;;
      *) die "unknown option: $1" ;;
    esac
  done
  [[ $grace =~ ^[0-9]+$ ]] || die "--grace must be a number of hours"
  load_env
  if [[ $target == --all ]]; then
    names=$(users_active | awk '{print $1}')
    [[ -n $names ]] || die "no users"
  else
    check_name "$target"
    user_exists "$target" || die "no user $target"
    names=$target
  fi

  expires=$(($(date +%s) + grace * 3600))
  local tmp
  tmp=$(mktemp "$USERS_FILE.XXXX")
  while IFS= read -r line; do
    read -r name uuid hy_user hy_pass token exp <<<"$line"
    if [[ $line != \#* && ${exp:-} == - ]] && grep -qx "$name" <<<"$names"; then
      ((grace == 0)) || echo "$name $uuid $hy_user $hy_pass - $expires"
      echo "$(new_cred "$name") $token -"
    else
      echo "$line"
    fi
  done <"$USERS_FILE" >"$tmp"
  chmod 600 "$tmp"
  mv "$tmp" "$USERS_FILE"

  cmd_up
  if ((grace == 0)); then
    info "rotated: $(echo $names); old credentials no longer work"
  else
    info "rotated: $(echo $names); old credentials work until $(date -d "@$expires" '+%F %R %Z')"
  fi
  echo "Clients get the new credentials on the next subscription refresh (links didn't change)."
}

cmd_prune() {
  [[ -f $USERS_FILE ]] || return 0
  local now
  now=$(date +%s)
  awk -v now="$now" '!/^#/ && NF && $6 != "-" && $6 <= now {f = 1} END {exit !f}' "$USERS_FILE" || return 0
  users_rewrite -v now="$now" '/^#/ || !NF || $6 == "-" || $6 > now'
  info "expired credentials removed"
  cmd_up
}

# --- setup -------------------------------------------------------------------

# .env from the xray + hysteria version: the same keys under new names
migrate_env() {
  local pair old new xver
  xver=$(sed -n 's/^REALITY_XVER=//p' "$ENV_FILE")
  [[ ${xver:-0} == 0 ]] ||
    die "REALITY_XVER=$xver: sing-box can't send the PROXY protocol to REALITY_TARGET; set REALITY_SNI to another site, REALITY_TARGET= and REALITY_XVER=0 (see the README section on port 443)"
  for pair in XRAY_PORT:VLESS_PORT XRAY_PRIVATE_KEY:REALITY_PRIVATE_KEY \
    XRAY_PUBLIC_KEY:REALITY_PUBLIC_KEY XRAY_SHORT_ID:REALITY_SHORT_ID; do
    old=${pair%:*} new=${pair#*:}
    if grep -q "^$old=" "$ENV_FILE" && ! grep -q "^$new=" "$ENV_FILE"; then
      sed -i "s/^$old=/$new=/" "$ENV_FILE"
    fi
  done
  sed -i -E '/^(XRAY_IMAGE|HYSTERIA_IMAGE|REALITY_XVER)=/d' "$ENV_FILE"
}

cmd_init() {
  [[ -f $ENV_FILE ]] || { cp .env.example "$ENV_FILE"; chmod 600 "$ENV_FILE"; }
  need_pkg jq "configs are built with it"
  migrate_env
  # Pick up keys added to .env.example after this .env was created
  local line
  while IFS= read -r line; do
    [[ $line =~ ^([A-Z0-9_]+)= ]] || continue
    grep -q "^${BASH_REMATCH[1]}=" "$ENV_FILE" || echo "$line" >>"$ENV_FILE"
  done <.env.example
  load_env
  [[ $DOMAIN != vpn.example.com && $ACME_EMAIL != you@example.com ]] ||
    die "set DOMAIN and ACME_EMAIL in $ENV_FILE first"
  # caddy stores certificates under the lowercase name, hysteria reads them from there
  [[ $DOMAIN == "${DOMAIN,,}" ]] || set_var DOMAIN "${DOMAIN,,}"

  [[ -n $REALITY_SHORT_ID ]] || set_var REALITY_SHORT_ID "$(rand_hex 8)"
  [[ -n ${ACME_CHECK_TOKEN:-} ]] || set_var ACME_CHECK_TOKEN "$(rand_hex 16)"
  if [[ -n $REALITY_PRIVATE_KEY && -z $REALITY_PUBLIC_KEY ]]; then
    die "REALITY_PUBLIC_KEY is empty, but REALITY_PRIVATE_KEY is set: restore it from a backup (new keys would break every client)"
  fi
  if [[ -z $REALITY_PRIVATE_KEY ]]; then
    local keys
    keys=$(singbox_cli generate reality-keypair)
    # "PrivateKey: ..." / "PublicKey: ..."
    set_var REALITY_PRIVATE_KEY "$(awk '/^PrivateKey/ {print $NF}' <<<"$keys")"
    set_var REALITY_PUBLIC_KEY "$(awk '/^PublicKey/ {print $NF}' <<<"$keys")"
    [[ -n $REALITY_PRIVATE_KEY && -n $REALITY_PUBLIC_KEY ]] || die "can't parse sing-box reality-keypair output: $keys"
  fi

  # Single-user setups kept the credentials in .env: move them to the "default" user
  if [[ ! -f $USERS_FILE && -n ${XRAY_UUID:-} && -n ${HYSTERIA_PASSWORD:-} && -n ${SUB_TOKEN:-} ]]; then
    users_init
    echo "default $XRAY_UUID default-$(rand_hex 2) $HYSTERIA_PASSWORD $SUB_TOKEN -" >>"$USERS_FILE"
    info "moved credentials from $ENV_FILE to user \"default\" in $USERS_FILE"
  fi
  sed -i -E '/^(XRAY_UUID|HYSTERIA_PASSWORD|SUB_TOKEN)=/d' "$ENV_FILE"

  users_init
  if [[ -z $(users_active) ]]; then
    echo "$(new_cred default) $(rand_hex 16) -" >>"$USERS_FILE"
    info "created user \"default\""
  fi
  info "keys are in $ENV_FILE, users in $USERS_FILE"
}

# Services whose config changed during render (they need a restart)
CHANGED=()

# Write content to a file only if it differs (in place: bind mounts keep the same inode);
# with a service name, mark that service as changed.
write_file() {
  local out=$1 content=$2 service=${3:-}
  cmp -s "$out" <(printf '%s\n' "$content") && return
  printf '%s\n' "$content" >"$out"
  chmod 644 "$out"
  [[ -z $service ]] || CHANGED+=("$service")
}

# Substitute ${VAR} in a template; every referenced variable must be non-empty.
render_file() {
  local tpl=$1 out=$2 service=${3:-} content var
  content=$(<"$tpl")
  for var in $(grep -o '\${[A-Z0-9_]*}' "$tpl" | tr -d '${}' | sort -u); do
    [[ -n ${!var:-} ]] || die "$var is empty (used in $tpl)"
    content=${content//"\${$var}"/"${!var}"}
  done
  write_file "$out" "$content" "$service"
}

check() {
  local name=$1 out
  shift
  out=$("$DOCKER" run --rm "$@" 2>&1) || die "$name config test failed: $out"
}

# This host's own addresses as a JSON list of /32 and /128: clients must not reach
# services on it (they would bypass the firewall, traffic to itself goes over lo)
host_ips_json() {
  ip -o addr show scope global 2>/dev/null |
    awk '{split($4, a, "/"); print a[1] (index(a[1], ":") ? "/128" : "/32")}' | jq -Rn '[inputs]'
}

# Valid credentials as JSON for the sing-box template
users_json() {
  users_valid | jq -Rn '[inputs | [splits("[ \t]+")] | {
    name: (if .[5] == "-" then .[0] else .[0] + "~" + .[5] end),
    uuid: .[1],
    hy2: (.[2] + ":" + .[3])
  }]'
}

# Render a jq template (templates/*.jq); every $ENV.VAR it uses must be non-empty
render_jq() {
  local tpl=$1 out=$2 service=$3 var content
  shift 3
  for var in $(grep -o '\$ENV\.[A-Z0-9_]*' "$tpl" | cut -d. -f2 | sort -u); do
    [[ -n ${!var:-} ]] || die "$var is empty (used in $tpl)"
  done
  content=$(jq -n "$@" -f "$tpl") || die "can't render $tpl"
  write_file "$out" "$content" "$service"
}

# hysteria needs caddy's certificate; without it sing-box runs VLESS only
HY2=false

cmd_render() {
  load_env
  command -v jq >/dev/null || die "jq is not installed, run: ./vpn.sh init"
  [[ $(printf '%s\n' "$VLESS_PORT" "$SUB_PORT" "$ACME_HTTP_PORT" | sort -u | wc -l) == 3 ]] ||
    die "VLESS_PORT, SUB_PORT and ACME_HTTP_PORT must be different tcp ports"
  [[ -n $(users_active) ]] || die "no users, run: ./vpn.sh init"

  [[ -s $CERT ]] && HY2=true || HY2=false
  mkdir -p "$OUT/sub"
  chmod 700 "$OUT"
  render_jq templates/sing-box.jq "$OUT/sing-box.json" sing-box \
    --argjson users "$(users_json)" --argjson host_ips "$(host_ips_json)" --argjson hy2 "$HY2"
  render_file templates/Caddyfile "$OUT/Caddyfile" caddy

  # Per-user subscription and import page; drop pages of removed users
  local name uuid hy_user hy_pass token exp tokens=" "
  while read -r name uuid hy_user hy_pass token exp; do
    user_vars "$uuid" "$hy_user" "$hy_pass" "$token"
    mkdir -p "$OUT/sub/$token"
    render_file templates/sub.html "$OUT/sub/$token/index.html"
    write_file "$OUT/sub/$token/sub" "$(printf '%s\n' "$VLESS_LINK" "$HY2_LINK" | base64 -w0)"
    tokens+="$token "
  done < <(users_active)
  local dir
  for dir in "$OUT"/sub/*/; do
    dir=$(basename "$dir")
    [[ $tokens == *" $dir "* ]] || rm -rf "${OUT:?}/sub/$dir"
  done

  mkdir -p data/caddy
  check sing-box -v "$PWD/$OUT/sing-box.json:/c.json:ro,z" -v "$PWD/data/caddy:/caddy-data:ro,z" \
    "$SINGBOX_IMAGE" check -c /c.json
  check caddy -v "$PWD/$OUT/Caddyfile:/c:ro,z" "$CADDY_IMAGE" caddy validate --config /c --adapter caddyfile
  info "configs rendered to $OUT/"
}

# REALITY contacts its target on every handshake; sites sometimes block server IPs.
# Ask the target the way sing-box does: SNI REALITY_SNI at REALITY_TARGET.
reality_target_ok() {
  curl -s -o /dev/null -m 8 --connect-to "$REALITY_SNI:443:$REALITY_TARGET" "https://$REALITY_SNI/"
}

# --- ports -------------------------------------------------------------------

# Sockets on non-loopback addresses: "proto port pid process"
listeners() {
  ss -Hlntup 2>/dev/null | awk '{
    port = addr = $5
    sub(/.*:/, "", port)
    sub(/:[^:]*$/, "", addr)
    if (addr ~ /^127\.|^\[::1\]|%lo$/) next
    pid = proc = "?"
    if (match($0, /\("[^"]+",pid=[0-9]+/)) {
      split(substr($0, RSTART + 2, RLENGTH - 2), a, "\",pid=")
      proc = a[1]; pid = a[2]
    }
    print $1, port, pid, proc
  }' | sort -u
}

# Host PIDs of this stack's containers
our_pids() {
  local ids
  ids=$("$DOCKER" compose ps -q 2>/dev/null || true)
  [[ -z $ids ]] || "$DOCKER" inspect -f '{{.State.Pid}}' $ids
}

# Ports this stack listens on: "port/proto description"
vpn_ports() {
  echo "$VLESS_PORT/tcp sing-box (VLESS REALITY)"
  echo "$HYSTERIA_PORT/udp sing-box (hysteria)"
  echo "$SUB_PORT/tcp caddy (subscription)"
  echo "$SUB_PORT/udp caddy (subscription, HTTP/3)"
  echo "$ACME_HTTP_PORT/tcp caddy (Let's Encrypt HTTP-01)"
}

# nginx config that hands Let's Encrypt HTTP-01 requests to caddy on ACME_HTTP_PORT
acme_proxy_snippet() {
  local port=$ACME_HTTP_PORT
  [[ $port == 80 ]] && port=8880
  cat <<EOF
      server {
          listen 80;
          listen [::]:80;
          server_name $DOMAIN;
          location /.well-known/acme-challenge/ {
              proxy_pass http://127.0.0.1:$port;
              proxy_set_header Host \$host;
          }
      }
EOF
}

# What to do when a port is taken
port_hint() {
  case $1 in
    "$ACME_HTTP_PORT/tcp")
      if [[ $ACME_HTTP_PORT == 80 ]]; then
        echo "    Let's Encrypt only checks port 80. If a web server owns it, keep it there:"
        echo "    set ACME_HTTP_PORT=8880 in $ENV_FILE and make it pass the checks to caddy, e.g. nginx:"
        acme_proxy_snippet
        echo "    (or just the location block inside an existing server for $DOMAIN)"
      else
        echo "    set ACME_HTTP_PORT to another free local port and point the port-80 proxy at it"
      fi
      ;;
    "$VLESS_PORT/tcp")
      echo "    another HTTPS server? Move it or set VLESS_PORT to a free port"
      echo "    (REALITY off 443 looks less natural, see the README section on port 443)"
      ;;
    "$HYSTERIA_PORT/udp")
      echo "    set HYSTERIA_PORT to any free UDP port; clients get it on the next subscription refresh"
      ;;
    "$SUB_PORT/tcp")
      echo "    set SUB_PORT to a free port; the port is part of subscription links,"
      echo "    so every user has to import the subscription again"
      ;;
  esac
}

# Fail if a port we need is held by something other than our containers
check_ports() {
  local ours all need desc proto port lport pid proc busy=()
  ours=" $(our_pids | tr '\n' ' ') "
  all=$(listeners)
  while read -r need desc; do
    port=${need%/*} proto=${need#*/}
    [[ $need == "$SUB_PORT/udp" ]] && continue # optional, caddy works without HTTP/3
    while read -r p lport pid proc; do
      [[ $p == "$proto" && $lport == "$port" && $ours != *" $pid "* ]] || continue
      busy+=("$need is taken by $proc (pid $pid), needed for $desc")
      busy+=("$(port_hint "$need")")
      break
    done <<<"$all"
  done < <(vpn_ports)
  ((${#busy[@]} == 0)) && return
  printf '%s\n' "ports are busy:" "${busy[@]}" >&2
  if [[ $EUID -ne 0 ]]; then
    warn "not root, can't see which processes own the ports; continuing"
    return
  fi
  die "nothing started"
}

# Let's Encrypt validates via http://DOMAIN:80/.well-known/acme-challenge/...; caddy
# answers "ok" on a secret path there, so we can see that port 80 really reaches it
# (directly or through a proxy) long before a renewal would fail.
acme_path_ok() {
  local i
  for i in 1 2 3 4 5; do
    [[ $(curl -s -m 5 --resolve "$DOMAIN:80:127.0.0.1" \
      "http://$DOMAIN/.well-known/acme-challenge/$ACME_CHECK_TOKEN" 2>/dev/null) == ok ]] && return 0
    sleep 2
  done
  return 1
}

acme_path_warning() {
  warn "port 80 doesn't reach caddy: Let's Encrypt can't renew the certificate for $DOMAIN"
  if [[ $ACME_HTTP_PORT == 80 ]]; then
    echo "    caddy should own 80/tcp; see what holds it: ss -ltnp 'sport = :80'" >&2
  else
    echo "    the web server on port 80 must pass ACME checks to caddy on $ACME_HTTP_PORT, e.g. nginx:" >&2
    acme_proxy_snippet >&2
  fi
}

preflight() {
  local resolved public
  # Repeated ACME failures hit Let's Encrypt rate limits
  resolved=$(getent ahostsv4 "$DOMAIN" | awk 'NR==1 {print $1}' || true)
  public=$(curl -4 -fsS -m 5 https://ifconfig.me 2>/dev/null || true)
  if [[ -z $resolved ]]; then
    warn "$DOMAIN doesn't resolve, caddy won't get a certificate"
  elif [[ -n $public && $resolved != "$public" ]]; then
    warn "$DOMAIN -> $resolved, but this server is $public"
  fi
  reality_target_ok ||
    warn "this server can't reach $REALITY_TARGET as https://$REALITY_SNI/: VLESS won't work, check REALITY_SNI / REALITY_TARGET"
  check_ports
}

cmd_up() {
  local running restart=() svc
  running=$("$DOCKER" compose ps --services --status running 2>/dev/null || true)
  CHANGED=()
  cmd_render
  preflight
  "$DOCKER" compose up -d --remove-orphans
  # compose doesn't notice changed config files; restart what was already running
  for svc in $(printf '%s\n' "${CHANGED[@]}" | sort -u); do
    grep -qx "$svc" <<<"$running" && restart+=("$svc")
  done
  ((${#restart[@]} == 0)) || "$DOCKER" compose restart "${restart[@]}"
  $HY2 || hy2_wait_cert
  "$DOCKER" compose ps
  acme_path_ok || acme_path_warning
}

# First start: caddy gets the certificate in a minute or so, then hysteria can start
hy2_wait_cert() {
  local i
  info "waiting for caddy to get the certificate for $DOMAIN (hysteria starts after it, VLESS already works)"
  for ((i = 0; i < 36; i++)); do
    [[ -s $CERT ]] && break
    sleep 5
  done
  if [[ ! -s $CERT ]]; then
    warn "no certificate for $DOMAIN yet, hysteria is off; see ./vpn.sh logs, then run ./vpn.sh up"
    return
  fi
  CHANGED=()
  cmd_render
  "$DOCKER" compose restart sing-box
}

# Health check for people and for vpn-maintenance.timer (non-zero exit = problem)
cmd_check() {
  load_env
  local failed=0 svc running days
  report() { printf '%-12s %s\n' "$1" "$2"; [[ $2 == ok* ]] || failed=1; }

  running=$("$DOCKER" compose ps --services --status running 2>/dev/null || true)
  for svc in sing-box caddy; do
    grep -qx "$svc" <<<"$running" && continue
    report containers "FAIL: $svc is not running"
  done
  [[ $failed == 1 ]] || report containers "ok"

  if [[ ! -f $CERT ]]; then
    report certificate "FAIL: no certificate yet ($CERT)"
  elif command -v openssl >/dev/null; then
    days=$((($(date -d "$(openssl x509 -enddate -noout -in "$CERT" | cut -d= -f2)" +%s) - $(date +%s)) / 86400))
    # caddy renews 30 days ahead, so less than 14 means renewals have been failing
    ((days >= 14)) && report certificate "ok ($days days left)" || report certificate "FAIL: expires in $days days"
  fi

  # Configs rendered before the certificate came have no hysteria
  if [[ -f $CERT ]] && ! jq -e '.inbounds | any(.type == "hysteria2")' "$OUT/sing-box.json" >/dev/null 2>&1; then
    report hysteria "FAIL: off (no certificate when configs were rendered), run: ./vpn.sh up"
  fi

  if acme_path_ok; then
    report acme "ok (port 80 reaches caddy)"
  else
    report acme "FAIL: port 80 doesn't reach caddy, renewals will fail"
    acme_path_warning 2>&1 | tail -n +2
  fi

  if reality_target_ok; then
    report reality "ok ($REALITY_SNI via $REALITY_TARGET)"
  else
    report reality "FAIL: can't reach $REALITY_SNI via $REALITY_TARGET, VLESS is down"
  fi
  return $failed
}

cmd_links() {
  local only=${1:-} name uuid hy_user hy_pass token exp found=false
  load_env
  while read -r name uuid hy_user hy_pass token exp; do
    [[ -z $only || $name == "$only" ]] || continue
    found=true
    user_vars "$uuid" "$hy_user" "$hy_pass" "$token"
    echo
    echo "[$name]"
    echo "  import page:   $SUB_PAGE"
    echo "  subscription:  $SUB_URL"
    if [[ -n $only ]]; then
      echo "  vless:         $VLESS_LINK"
      echo "  hysteria2:     $HY2_LINK"
      if command -v qrencode >/dev/null; then
        qrencode -t ansiutf8 "$SUB_PAGE"
      else
        echo "  (apt install qrencode to get a QR code of the import page here)"
      fi
    fi
  done < <(users_active)
  $found || die "no user ${only:-found}"
  echo
}

cmd_tune() {
  require_root tune
  # Remember the values before the first tuning, so `uninstall` can put them back
  if [[ ! -f $SYSCTL_CONF && ! -f $HOST_STATE/sysctl.orig ]]; then
    mkdir -p "$HOST_STATE"
    sysctl net.core.default_qdisc net.ipv4.tcp_congestion_control net.core.rmem_max net.core.wmem_max |
      sed 's/ = /=/' >"$HOST_STATE/sysctl.orig"
  fi
  # BBR for VLESS (TCP), bigger UDP buffers for hysteria (QUIC)
  cat >"$SYSCTL_CONF" <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
EOF
  sysctl -q -p "$SYSCTL_CONF"
  info "sysctl tuned ($SYSCTL_CONF)"
}

install_timer() {
  if [[ $EUID -ne 0 ]] || ! command -v systemctl >/dev/null; then
    warn "not root or no systemd: run ./vpn.sh prune and ./vpn.sh check yourself (e.g. from cron)"
    return
  fi
  # Older versions installed vpn-prune.*
  if [[ -f /etc/systemd/system/vpn-prune.timer ]]; then
    systemctl disable -q --now vpn-prune.timer 2>/dev/null || true
    rm -f /etc/systemd/system/vpn-prune.{timer,service}
  fi
  cat >/etc/systemd/system/vpn-maintenance.service <<EOF
[Unit]
Description=VPN maintenance: expire rotated credentials, health check

[Service]
Type=oneshot
ExecStart=$PWD/vpn.sh prune
ExecStart=$PWD/vpn.sh check
EOF
  cat >/etc/systemd/system/vpn-maintenance.timer <<'EOF'
[Unit]
Description=Hourly VPN maintenance

[Timer]
OnCalendar=hourly
Persistent=true

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable -q --now vpn-maintenance.timer
  info "vpn-maintenance.timer enabled (failures show in: systemctl --failed)"
}

cmd_install_docker() {
  command -v docker >/dev/null && { info "docker already installed"; return; }
  curl -fsSL https://get.docker.com | sh
  mkdir -p "$HOST_STATE"
  touch "$HOST_STATE/docker-installed"
}

cmd_deploy() {
  command -v "$DOCKER" >/dev/null || die "$DOCKER not found, run: ./vpn.sh install-docker"
  if [[ $EUID -eq 0 ]]; then cmd_tune; else warn "not root, skipping sysctl tuning"; fi
  cmd_init
  cmd_up
  install_timer
  cmd_links
}

# --- update ------------------------------------------------------------------

latest_release() {
  local json tag
  json=$(curl -fsSL -m 15 "https://api.github.com/repos/$1/releases/latest") || return 1
  tag=$(grep -m1 '"tag_name"' <<<"$json" | cut -d'"' -f4)
  [[ -n $tag ]] && echo "$tag"
}

cmd_update() {
  case ${1:-} in
    images) cmd_update_images ;;
    repo) cmd_update_repo ;;
    *) die "usage: ./vpn.sh update images|repo" ;;
  esac
}

cmd_update_images() {
  load_env
  local sb c var new changes=()
  sb=$(latest_release SagerNet/sing-box) || die "can't reach GitHub"
  c=$(latest_release caddyserver/caddy) || die "can't reach GitHub"
  declare -A latest=(
    [SINGBOX_IMAGE]="${SINGBOX_IMAGE%:*}:$sb" # ghcr tags keep the "v"
    [CADDY_IMAGE]="${CADDY_IMAGE%:*}:${c#v}-alpine"
  )
  for var in SINGBOX_IMAGE CADDY_IMAGE; do
    new=${latest[$var]}
    [[ ${!var} == "$new" ]] && continue
    # Images often appear in registries some time after the GitHub release
    if "$DOCKER" pull -q "$new" >/dev/null 2>&1; then
      changes+=("$var")
      echo "  ${!var}  ->  $new"
    else
      echo "  ${!var}  (${new##*:} is released, but the image isn't published yet)"
    fi
  done
  ((${#changes[@]})) || { info "nothing to update"; return; }
  ask "Update?" n || return 0

  cp "$ENV_FILE" "$ENV_FILE.bak"
  for var in "${changes[@]}"; do set_var "$var" "${latest[$var]}"; done
  # On failure (e.g. a config the new version rejects) go back to the old images
  local rc
  set +e
  (set -e; cmd_up)
  rc=$?
  set -e
  if ((rc != 0)); then
    mv "$ENV_FILE.bak" "$ENV_FILE"
    warn "update failed, restoring previous versions"
    cmd_up
    exit 1
  fi
  rm -f "$ENV_FILE.bak"
  info "updated"
}

cmd_update_repo() {
  load_env
  local url=${REPO_URL:-$DEFAULT_REPO_URL} branch=${REPO_BRANCH:-$DEFAULT_REPO_BRANCH}
  local new old tracked index changes

  need_pkg git "updates are fetched with it"
  # Deployments copied without .git become a checkout on the first update
  [[ -d .git ]] || git init -q
  git fetch -q "$url" "$branch" || die "can't fetch $branch from $url"
  new=$(git rev-parse FETCH_HEAD)
  old=$(git rev-parse -q --verify HEAD || true)

  # A reset to a commit that tracks local state would overwrite it
  tracked=$(git ls-tree -r --name-only "$new" -- "${STATE_PATHS[@]}")
  [[ -z $tracked ]] || die "upstream tracks local state ($(echo $tracked)), refusing to update"

  # What the working tree would look like after the update
  index=$(mktemp -u)
  GIT_INDEX_FILE=$index git read-tree "$new"
  changes=$(GIT_INDEX_FILE=$index git diff -R --stat=72 || true)
  rm -f "$index"
  if [[ -n $old ]]; then
    changes+=$(git diff --stat=72 --diff-filter=D "$old" "$new" | sed '$d')
  fi

  if [[ -z $changes ]]; then
    git reset -q --hard "$new"
    info "up to date: $(git log -1 --format='%h %s' "$new")"
    return
  fi

  echo "Update from $url ($branch):"
  if [[ -n $old ]] && git merge-base --is-ancestor "$old" "$new" 2>/dev/null; then
    git log --format='  %h %s' "$old..$new"
  else
    echo "  -> $(git log -1 --format='%h %s' "$new")"
  fi
  echo "Files that will change:"
  echo "$changes" | sed 's/^/  /'
  if [[ -n $old && -n $(git status --porcelain --untracked-files=no) ]]; then
    warn "local edits to these files will be lost:"
    git status --porcelain --untracked-files=no | sed 's/^/  /' >&2
  fi
  echo "Kept as is: ${STATE_PATHS[*]} (keys, users, certificates)."
  echo "Containers whose config changes will be restarted: VPN connections drop for a few seconds."
  ask "Update?" n || return 0

  # Belt and braces: back up the state and check it survived the reset
  local backup sums
  mkdir -p backups
  chmod 700 backups
  backup=backups/state-$(date +%Y%m%d-%H%M%S).tar.gz
  local files=() f
  for f in .env users.conf; do [[ -f $f ]] && files+=("$f"); done
  tar -czf "$backup" "${files[@]}"
  ls -1t backups/state-*.tar.gz | tail -n +11 | xargs -r rm -f
  sums=$(sha256sum .env users.conf 2>/dev/null || true)

  git reset -q --hard "$new"

  if [[ -n $sums ]] && ! sha256sum --quiet -c <<<"$sums" >/dev/null 2>&1; then
    tar -xzf "$backup"
    die "local state changed during the update; restored it from $backup"
  fi
  info "code updated to $(git log -1 --format='%h %s' "$new") (state backup: $backup)"

  # Continue with the new vpn.sh: new .env keys, configs, restarts of what changed, timer
  exec 9>&-
  exec ./vpn.sh deploy
}

# --- firewall ----------------------------------------------------------------

cmd_firewall() {
  local dry=false
  [[ ${1:-} == --dry-run ]] && dry=true
  require_root firewall
  load_env

  local ours all rules=() others=() p port pid proc rule desc
  ours=" $(our_pids | tr '\n' ' ') "
  all=$(listeners)

  # SSH first, so the current session survives
  local ssh_ports
  ssh_ports=$(awk '$4 == "sshd" && $1 == "tcp" {print $2}' <<<"$all" | sort -u)
  [[ -n $ssh_ports ]] || { warn "no sshd listener found, assuming 22/tcp"; ssh_ports=22; }
  for port in $ssh_ports; do rules+=("$port/tcp ssh"); done
  while read -r rule desc; do
    # behind a proxy on port 80 the ACME port is local only
    [[ $rule == "$ACME_HTTP_PORT/tcp" && $ACME_HTTP_PORT != 80 ]] && continue
    rules+=("$rule $desc")
  done < <(vpn_ports)

  # Anything else listening publicly (another site, a game server...)
  local known
  known=" $(printf '%s\n' "${rules[@]}" | awk '{print $1}' | tr '\n' ' ') "
  while read -r p port pid proc; do
    [[ -n $p && $ours != *" $pid "* && $known != *" $port/$p "* ]] || continue
    others+=("$port/$p $proc")
    known+="$port/$p "
  done <<<"$all"

  echo "Allow incoming:"
  for rule in "${rules[@]}"; do printf '  %-12s %s\n' "${rule%% *}" "${rule#* }"; done
  if ((${#others[@]})); then
    echo "Other services listening on public addresses:"
    for rule in "${others[@]}"; do printf '  %-12s %s\n' "${rule%% *}" "${rule#* }"; done
  fi
  echo "Everything else incoming will be dropped."
  $dry && return

  if ((${#others[@]})) && ask "Keep the other services reachable?" y; then
    rules+=("${others[@]}")
  fi
  ask "Enable the firewall?" n || return 0

  if ! command -v ufw >/dev/null; then
    command -v apt-get >/dev/null || die "ufw is not installed"
    apt-get install -y -qq ufw >/dev/null
  fi
  # Record what we change, for `uninstall`
  mkdir -p "$HOST_STATE"
  if [[ ! -f $HOST_STATE/firewall ]]; then
    local status
    status=$(ufw status)
    [[ $status == *"Status: active"* ]] && echo "was_active=1" >"$HOST_STATE/firewall" ||
      echo "was_active=0" >"$HOST_STATE/firewall"
  fi
  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  for rule in "${rules[@]}"; do
    # ufw rejects some characters in comments (e.g. the apostrophe in "Let's")
    ufw allow "${rule%% *}" comment "$(tr -cd 'A-Za-z0-9 ()/._-' <<<"${rule#* }")" >/dev/null
    echo "rule ${rule%% *} ${rule#* }" >>"$HOST_STATE/firewall"
  done
  ufw --force enable >/dev/null
  ufw status verbose

  harden_ssh
}

# Optional: key-only SSH login, only when some key is installed
harden_ssh() {
  local conf=$SSH_HARDENING_CONF keys
  keys=$(cat /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys 2>/dev/null | grep -cE '^(ssh-|ecdsa-|sk-)' || true)
  if ((keys == 0)); then
    warn "no SSH keys in authorized_keys, keeping password login"
    return
  fi
  grep -qE '^Include /etc/ssh/sshd_config.d/' /etc/ssh/sshd_config || {
    warn "sshd_config doesn't include sshd_config.d, skipping SSH hardening"
    return
  }
  [[ -f $conf ]] && { info "SSH password login is already disabled ($conf)"; return; }
  ask "Disable SSH password login ($keys keys found in authorized_keys)?" n || return 0
  # First value wins in sshd, hence 00- to override cloud-init's 50-*.conf
  cat >"$conf" <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF
  if ! sshd -t; then
    rm -f "$conf"
    die "sshd rejected the config, nothing changed"
  fi
  if systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null; then
    info "SSH password login disabled ($conf)"
  else
    warn "couldn't reload sshd; $conf applies after sshd restarts"
  fi
}

# --- uninstall ---------------------------------------------------------------

cmd_uninstall() {
  require_root uninstall
  echo "This stops the VPN for everyone and removes what vpn.sh set up on this host:"
  echo "containers, the maintenance timer and sysctl tuning. It asks about the rest"
  echo "(images, firewall, SSH, keys and users, docker)."
  ask "Uninstall?" n || return 0

  # Containers by compose label: works even without a usable .env
  local ids images=""
  ids=$("$DOCKER" ps -aq --filter label=com.docker.compose.project=vpn 2>/dev/null || true)
  if [[ -n $ids ]]; then
    images=$("$DOCKER" inspect -f '{{.Config.Image}}' $ids | sort -u)
    "$DOCKER" rm -f $ids >/dev/null
    info "containers removed"
  fi

  local unit
  for unit in vpn-maintenance vpn-prune; do
    [[ -f /etc/systemd/system/$unit.timer ]] || continue
    systemctl disable -q --now "$unit.timer" 2>/dev/null || true
    rm -f /etc/systemd/system/"$unit".{timer,service}
    systemctl daemon-reload
    info "$unit.timer removed"
  done

  if [[ -f $SYSCTL_CONF ]]; then
    rm -f "$SYSCTL_CONF"
    if [[ -f $HOST_STATE/sysctl.orig ]]; then
      local values
      mapfile -t values <"$HOST_STATE/sysctl.orig"
      sysctl -q -w "${values[@]}"
      rm -f "$HOST_STATE/sysctl.orig"
      info "sysctl restored"
    else
      sysctl -q --system >/dev/null 2>&1 || true
      warn "values from before tuning are unknown (tuned by an older vpn.sh); BBR and buffer sizes stay until reboot"
    fi
  fi

  if [[ -n $images ]] && ask "Remove the images ($(echo $images))?" y; then
    # shellcheck disable=SC2086
    "$DOCKER" rmi $images >/dev/null 2>&1 || true
    info "images removed"
  fi

  if [[ -f $HOST_STATE/firewall ]] && command -v ufw >/dev/null; then
    local was_active port desc kind
    was_active=$(sed -n 's/^was_active=//p' "$HOST_STATE/firewall" | head -1)
    # Unknown means: assume it was on and keep it on
    [[ $was_active == 0 ]] || was_active=1
    if [[ $was_active == 0 ]] && ask "Turn ufw off again and drop the rules vpn.sh added (it was off before)?" y; then
      ufw --force disable >/dev/null
      while read -r kind port desc; do
        [[ $kind == rule ]] && ufw delete allow "$port" >/dev/null 2>&1 || true
      done <"$HOST_STATE/firewall"
      rm -f "$HOST_STATE/firewall"
      info "ufw disabled, rules removed"
    elif [[ $was_active == 1 ]] && ask "Delete the ufw rules vpn.sh added (ssh stays open)?" y; then
      while read -r kind port desc; do
        [[ $kind == rule && $desc != ssh ]] && ufw delete allow "$port" >/dev/null 2>&1 || true
      done <"$HOST_STATE/firewall"
      rm -f "$HOST_STATE/firewall"
      info "ufw rules removed"
    fi
  fi

  if [[ -f $SSH_HARDENING_CONF ]] && ask "Allow SSH password login again (remove $SSH_HARDENING_CONF)?" n; then
    rm -f "$SSH_HARDENING_CONF"
    systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
    info "SSH password login allowed again"
  fi

  if ask "Delete keys, users and certificates (${STATE_PATHS[*]} backups/)? Everyone's links stop working for good" n; then
    rm -rf "${STATE_PATHS[@]}" backups .env.bak
    info "keys, users and certificates deleted"
  else
    info "kept ${STATE_PATHS[*]}: ./vpn.sh deploy brings the same VPN back"
  fi

  if [[ -f $HOST_STATE/docker-installed ]] && ask "Remove docker (installed by ./vpn.sh install-docker)?" n; then
    # Only what is installed: apt refuses the whole list if one package is unknown
    local pkgs
    pkgs=$(dpkg-query -W -f='${Status} ${Package}\n' docker-ce docker-ce-cli containerd.io \
      docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras docker-model-plugin 2>/dev/null |
      awk '/ installed / {print $NF}' || true)
    if [[ -n $pkgs ]]; then
      # shellcheck disable=SC2086
      apt-get purge -y -qq $pkgs >/dev/null
    fi
    rm -rf /var/lib/docker /var/lib/containerd
    rm -f "$HOST_STATE/docker-installed"
    info "docker removed"
  fi

  rmdir "$HOST_STATE" 2>/dev/null || true
  info "done; this directory stays, remove it with: rm -rf $PWD"
}

# --- main --------------------------------------------------------------------

args=()
for arg in "$@"; do
  [[ $arg == -y ]] && ASSUME_YES=true || args+=("$arg")
done
set -- "${args[@]+"${args[@]}"}"

cmd=${1:-help}
(($#)) && shift
case $cmd in
  deploy | init | up | render | user | rotate | prune | update | firewall | uninstall) lock ;;
esac
case $cmd in
  deploy) cmd_deploy ;;
  init) cmd_init ;;
  up) cmd_up ;;
  down) "$DOCKER" compose down ;;
  logs) "$DOCKER" compose logs -f --tail=100 ;;
  tune) cmd_tune ;;
  install-docker) cmd_install_docker ;;
  uninstall) cmd_uninstall ;;
  firewall) cmd_firewall "$@" ;;
  user) cmd_user "$@" ;;
  links) cmd_links "$@" ;;
  rotate) cmd_rotate "$@" ;;
  update) cmd_update "$@" ;;
  render) cmd_render ;;
  prune) cmd_prune ;;
  check) cmd_check ;;
  help | -h | --help) usage ;;
  *) echo "unknown command: $cmd" >&2; usage >&2; exit 1 ;;
esac
