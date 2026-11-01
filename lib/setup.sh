# shellcheck shell=bash
# Host setup: .env and keys, sysctl, maintenance timer, docker; sourced by vpn.sh


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
