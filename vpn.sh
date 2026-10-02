#!/usr/bin/env bash
# Usage: ./vpn.sh [deploy|init|render|up|down|logs|links|tune|install-docker]
set -euo pipefail
cd "$(dirname "$0")"

ENV_FILE=.env
OUT=generated
DOCKER=${DOCKER:-docker}

die() { echo "error: $*" >&2; exit 1; }
info() { echo ">> $*"; }

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

load_env() {
  [[ -f $ENV_FILE ]] || die "no $ENV_FILE: cp .env.example .env, then set DOMAIN and ACME_EMAIL"
  set -a; . "./$ENV_FILE"; set +a

  # Derived values used by templates and `links`
  export SUB_URL="https://$DOMAIN:$SUB_PORT/$SUB_TOKEN/sub"
  export SUB_PAGE="https://$DOMAIN:$SUB_PORT/$SUB_TOKEN/"
  export SUB_URL_ENC=$(urlencode "$SUB_URL")
  export SUB_NAME_ENC=$(urlencode "$SUB_NAME")
  export SUB_TITLE_B64=$(printf '%s' "$SUB_NAME" | base64 -w0)
  VLESS_LINK="vless://$XRAY_UUID@$DOMAIN:$XRAY_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$REALITY_SNI&fp=chrome&pbk=$XRAY_PUBLIC_KEY&sid=$XRAY_SHORT_ID&type=tcp#$SUB_NAME_ENC-reality"
  HY2_LINK="hysteria2://$HYSTERIA_PASSWORD@$DOMAIN:$HYSTERIA_PORT/?sni=$DOMAIN#$SUB_NAME_ENC-hy2"
}

# Write KEY=VALUE into .env (replace or append) and export it.
set_var() {
  local key=$1 val=$2
  if grep -q "^$key=" "$ENV_FILE"; then
    sed -i "s|^$key=.*|$key=$val|" "$ENV_FILE"
  else
    echo "$key=$val" >>"$ENV_FILE"
  fi
  export "$key=$val"
}

rand_hex() { od -An -tx1 -N"$1" /dev/urandom | tr -d ' \n'; }

xray_cli() { "$DOCKER" run --rm "$XRAY_IMAGE" "$@"; }

cmd_init() {
  [[ -f $ENV_FILE ]] || { cp .env.example "$ENV_FILE"; chmod 600 "$ENV_FILE"; }
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

  [[ -n $XRAY_UUID ]] || set_var XRAY_UUID "$(cat /proc/sys/kernel/random/uuid)"
  [[ -n $XRAY_SHORT_ID ]] || set_var XRAY_SHORT_ID "$(rand_hex 8)"
  [[ -n $HYSTERIA_PASSWORD ]] || set_var HYSTERIA_PASSWORD "$(rand_hex 16)"
  [[ -n $SUB_TOKEN ]] || set_var SUB_TOKEN "$(rand_hex 16)"

  if [[ -z $XRAY_PRIVATE_KEY || -z $XRAY_PUBLIC_KEY ]]; then
    local keys
    if [[ -n $XRAY_PRIVATE_KEY ]]; then
      keys=$(xray_cli x25519 -i "$XRAY_PRIVATE_KEY")
    else
      keys=$(xray_cli x25519)
    fi
    # "PrivateKey: ..." / "Password (PublicKey): ..." (older xray: "Public key: ...")
    set_var XRAY_PRIVATE_KEY "$(awk '/^Private/ {print $NF}' <<<"$keys")"
    set_var XRAY_PUBLIC_KEY "$(awk '/Public/ {print $NF}' <<<"$keys")"
    [[ -n $XRAY_PRIVATE_KEY && -n $XRAY_PUBLIC_KEY ]] || die "can't parse xray x25519 output: $keys"
  fi
  info "secrets are in $ENV_FILE"
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

cmd_render() {
  load_env
  [[ $SUB_PORT != "$XRAY_PORT" ]] || die "SUB_PORT and XRAY_PORT are both tcp/$XRAY_PORT"
  mkdir -p "$OUT/sub/$SUB_TOKEN"
  chmod 700 "$OUT"
  # drop pages left from a previous SUB_TOKEN
  find "$OUT/sub" -mindepth 1 -maxdepth 1 ! -name "$SUB_TOKEN" -exec rm -rf {} +

  render_file templates/xray.json "$OUT/xray.json" xray
  render_file templates/hysteria.yaml "$OUT/hysteria.yaml" hysteria
  render_file templates/Caddyfile "$OUT/Caddyfile" caddy
  render_file templates/sub.html "$OUT/sub/$SUB_TOKEN/index.html"
  write_file "$OUT/sub/$SUB_TOKEN/sub" "$(printf '%s\n' "$VLESS_LINK" "$HY2_LINK" | base64 -w0)"

  check xray -v "$PWD/$OUT/xray.json:/c.json:ro,z" "$XRAY_IMAGE" run -test -c /c.json
  check caddy -v "$PWD/$OUT/Caddyfile:/c:ro,z" "$CADDY_IMAGE" caddy validate --config /c --adapter caddyfile
  info "configs rendered to $OUT/"
}

preflight() {
  local unit resolved public
  # Repeated ACME failures hit Let's Encrypt rate limits
  resolved=$(getent ahostsv4 "$DOMAIN" | awk 'NR==1 {print $1}' || true)
  public=$(curl -4 -fsS -m 5 https://ifconfig.me 2>/dev/null || true)
  if [[ -z $resolved ]]; then
    echo "warning: $DOMAIN doesn't resolve, caddy won't get a certificate" >&2
  elif [[ -n $public && $resolved != "$public" ]]; then
    echo "warning: $DOMAIN -> $resolved, but this server is $public" >&2
  fi

  for unit in xray hysteria-server; do
    if systemctl is-active -q "$unit" 2>/dev/null; then
      echo "warning: $unit.service is running on the host and holds the ports;" \
        "stop it: systemctl disable --now $unit" >&2
    fi
  done
}

cmd_up() {
  local running restart=() svc
  running=$("$DOCKER" compose ps --services --status running 2>/dev/null || true)
  cmd_render
  preflight
  "$DOCKER" compose up -d --remove-orphans
  # compose doesn't notice changed config files; restart what was already running
  for svc in $(printf '%s\n' "${CHANGED[@]}" | sort -u); do
    grep -qx "$svc" <<<"$running" && restart+=("$svc")
  done
  ((${#restart[@]} == 0)) || "$DOCKER" compose restart "${restart[@]}"
  "$DOCKER" compose ps
}

cmd_links() {
  load_env
  echo
  echo "VLESS REALITY:  $VLESS_LINK"
  echo "Hysteria 2:     $HY2_LINK"
  echo
  echo "Subscription:   $SUB_URL"
  echo "Import page:    $SUB_PAGE"
  if command -v qrencode >/dev/null; then
    qrencode -t ansiutf8 "$SUB_PAGE"
  else
    echo "(apt install qrencode to get a QR code of the import page here)"
  fi
  echo
}

cmd_tune() {
  [[ $EUID -eq 0 ]] || die "tune needs root"
  # BBR for xray (TCP), bigger UDP buffers for hysteria (QUIC)
  cat >/etc/sysctl.d/99-vpn.conf <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
EOF
  sysctl -q -p /etc/sysctl.d/99-vpn.conf
  info "sysctl tuned (/etc/sysctl.d/99-vpn.conf)"
}

cmd_install_docker() {
  command -v docker >/dev/null && { info "docker already installed"; return; }
  curl -fsSL https://get.docker.com | sh
}

cmd_deploy() {
  command -v "$DOCKER" >/dev/null || die "$DOCKER not found, run: ./vpn.sh install-docker"
  if [[ $EUID -eq 0 ]]; then cmd_tune; else echo "not root, skipping sysctl tuning" >&2; fi
  cmd_init
  cmd_up
  cmd_links
}

case ${1:-deploy} in
  deploy) cmd_deploy ;;
  init) cmd_init ;;
  render) cmd_render ;;
  up) cmd_up ;;
  down) "$DOCKER" compose down ;;
  logs) "$DOCKER" compose logs -f --tail=100 ;;
  links) cmd_links ;;
  tune) cmd_tune ;;
  install-docker) cmd_install_docker ;;
  *) sed -n '2p' "$0"; exit 1 ;;
esac
