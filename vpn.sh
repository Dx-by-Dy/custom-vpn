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

# shellcheck source-path=SCRIPTDIR
. lib/common.sh
. lib/users.sh
. lib/setup.sh
. lib/render.sh
. lib/service.sh
. lib/update.sh
. lib/firewall.sh
. lib/uninstall.sh

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
