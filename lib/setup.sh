# shellcheck shell=bash
# Host setup: .env and keys, sysctl, maintenance timer, docker; sourced by vpn.sh


# .env from the xray + hysteria version: the same keys under new names
migrate_env() {
  local pair old new xver
  xver=$(sed -n 's/^REALITY_XVER=//p' "$ENV_FILE")
  [[ ${xver:-0} == 0 ]] ||
    die "REALITY_XVER=$xver: sing-box can't send the PROXY protocol to REALITY_TARGET; set REALITY_SNI to another site, REALITY_TARGET= and REALITY_XVER=0 (see the 443/tcp section of docs/hub.md)"
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
  # ROLE=client CLIENT_SUB=LINK [CLIENT_LISTEN=...] ./vpn.sh deploy
  local want=${ROLE:-} want_sub=${CLIENT_SUB:-} want_listen=${CLIENT_LISTEN:-}
  if [[ $(env_role) == control ]]; then
    control_init
    return
  fi
  if [[ ! -f $ENV_FILE ]]; then
    cp .env.example "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    # ROLE=exit ./vpn.sh deploy
    [[ -z $want ]] || sed -i "s/^ROLE=.*/ROLE=$want/" "$ENV_FILE"
  fi
  need_pkg jq "configs are built with it"
  migrate_env
  # Pick up keys added to .env.example after this .env was created
  local line
  while IFS= read -r line; do
    [[ $line =~ ^([A-Z0-9_]+)= ]] || continue
    grep -q "^${BASH_REMATCH[1]}=" "$ENV_FILE" || echo "$line" >>"$ENV_FILE"
  done <.env.example
  load_env
  [[ -z $want || $want == "$ROLE" ]] || die "ROLE=$want given, but $ENV_FILE has ROLE=$ROLE"
  if [[ $ROLE == client ]]; then
    [[ -z $want_sub || -n ${CLIENT_SUB:-} ]] || set_var CLIENT_SUB "$want_sub"
    if [[ -n $want_listen && $want_listen != "${CLIENT_LISTEN:-}" ]]; then
      set_var CLIENT_LISTEN "$want_listen"
      load_env
    fi
    [[ -n ${CLIENT_SUB:-} ]] || die "set CLIENT_SUB in $ENV_FILE: the subscription link of this client's user"
    info "client of $(client_subs | paste -sd' '), proxy on $CLIENT_LISTEN_HOST:$CLIENT_LISTEN_PORT"
    return
  fi
  if [[ $ROLE == hub ]]; then
    [[ $DOMAIN != vpn.example.com ]] || die "set DOMAIN in $ENV_FILE first"
    [[ ${ACME_EMAIL:-} != you@example.com ]] || die "set ACME_EMAIL in $ENV_FILE to your email or leave it empty"
    # caddy stores certificates under the lowercase name, hysteria reads them from there
    [[ $DOMAIN == "${DOMAIN,,}" ]] || set_var DOMAIN "${DOMAIN,,}"
  fi

  [[ -n $REALITY_SHORT_ID ]] || set_var REALITY_SHORT_ID "$(rand_hex 8)"
  [[ -n ${ACME_CHECK_TOKEN:-} ]] || set_var ACME_CHECK_TOKEN "$(rand_hex 16)"
  [[ -n ${CHECK_TOKEN:-} ]] || set_var CHECK_TOKEN "$(rand_hex 16)"
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
  if [[ $ROLE == exit ]]; then
    exit_init
    return
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
    warn "not root or no systemd: run $(vsh prune) and $(vsh check) yourself (e.g. from cron)"
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
  if under_control && [[ -n ${CONTROL_DOMAIN:-} ]]; then install_sync_timer; fi
}

cmd_install_docker() {
  command -v docker >/dev/null && { info "docker already installed"; return; }
  curl -fsSL https://get.docker.com | sh
  mkdir -p "$HOST_STATE"
  touch "$HOST_STATE/docker-installed"
}

cmd_deploy() {
  [[ $(env_role) != control ]] || die "control runs nothing: ./vpn.sh control init sets it up"
  command -v "$DOCKER" >/dev/null || die "$DOCKER not found, run: $(vsh install-docker)"
  if [[ $EUID -eq 0 ]]; then cmd_tune; else warn "not root, skipping sysctl tuning"; fi
  cmd_init
  cmd_up
  install_timer
  case $ROLE in
    exit) cmd_hub list ;;
    client) info "proxy: socks5 and http on $CLIENT_LISTEN_HOST:$CLIENT_LISTEN_PORT" ;;
    *) cmd_links ;;
  esac
}
