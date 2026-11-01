# shellcheck shell=bash
# Removing everything vpn.sh set up; sourced by vpn.sh


cmd_uninstall() {
  require_root uninstall
  echo "This stops the VPN for everyone and removes what vpn.sh set up on this host:"
  echo "containers, the maintenance timer and sysctl tuning. It asks about the rest"
  echo "(images, firewall, SSH, keys and users, docker)."
  ask "Uninstall?" n || return 0

  # Containers by compose label: works even without a usable .env
  local ids images=""
  ids=$("$DOCKER" ps -aq --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME:-vpn}" 2>/dev/null || true)
  if [[ -n $ids ]]; then
    images=$("$DOCKER" inspect -f '{{.Config.Image}}' $ids | sort -u)
    "$DOCKER" rm -f $ids >/dev/null
    info "containers removed"
  fi

  local unit
  for unit in vpn-maintenance vpn-prune vpn-sync; do
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
    info "kept ${STATE_PATHS[*]}: $(vsh deploy) brings the same VPN back"
  fi

  if [[ -f $HOST_STATE/docker-installed ]] && ask "Remove docker (installed by vpn.sh install-docker)?" n; then
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
