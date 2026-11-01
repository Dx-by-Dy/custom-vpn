# shellcheck shell=bash
# ufw and SSH hardening; sourced by vpn.sh


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
