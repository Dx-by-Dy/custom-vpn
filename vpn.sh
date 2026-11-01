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
# Settings and lists that are this server's state: backed up by `update repo`
CONF_FILES=(.env users.conf hubs.conf exits.conf groups.conf routing.conf)
# Files and directories that hold this server's state; never taken from the repo
STATE_PATHS=("${CONF_FILES[@]}" data generated)
# What `check` asks for the public IP a route leaves from: a foreign site and a .ru one
IP_ECHO_URL=https://api.ipify.org
IP_ECHO_RU_URL=https://ip.beget.ru
# What vpn.sh changed on the host outside this directory, for `uninstall`
HOST_STATE=/var/lib/custom-vpn
SYSCTL_CONF=/etc/sysctl.d/99-vpn.conf
SSH_HARDENING_CONF=/etc/ssh/sshd_config.d/00-vpn-hardening.conf
ASSUME_YES=false

# Commands of this ROLE only (all of them before there is a .env)
usage() {
  local role
  role=$(sed -n 's/^ROLE=//p' "$ENV_FILE" 2>/dev/null | tail -1)
  # show "ROLES" <<EOF: the text if this role is one of ROLES
  show() { if [[ -z $role || " $1 " == *" $role "* ]]; then cat; else cat >/dev/null; fi; }
  show "hub exit control" <<'EOF'
Usage: ./vpn.sh <command> [args]

EOF
  show "hub exit" <<'EOF'
Setup:
  deploy                  full setup: tune, init, up, maintenance timer, links
                          (ROLE=exit ./vpn.sh deploy sets up an exit)
  init                    create .env, generate missing keys, create the first user
  up                      render configs, check ports, start/restart containers
  down                    stop containers
  logs                    follow container logs
  tune                    enable BBR and bigger UDP buffers (sysctl)
  install-docker          install docker via get.docker.com
  uninstall               remove everything vpn.sh set up on this host (asks what to keep)
  firewall [--dry-run]    enable ufw for ssh, VPN ports and other listening
                          services, optionally disable SSH password login

EOF
  show "control" <<'EOF'
Control (ROLE=control, on a laptop): the scheme of all hubs; every change below
is published as a signed snapshot that hubs apply
  init                    create .env and the signing key (ROLE=control ./vpn.sh init)
  hub add NAME TOKEN      add (or update) a hub from the token `control join` printed on it,
                          print the token that hub needs
  hub del NAME            remove a hub: it can't read new snapshots
  hub list                list hubs
  publish                 build the snapshot again (generated/state.txt) and put it
                          into DNS (CONTROL_DOMAIN in .env)
  import FILE             take over the users of a stand-alone hub (`state export` there)

EOF
  show "hub control" <<'EOF'
Users (hub, control):
  user add NAME [--group G] [--route R]
                          add a user and print their links
  user del NAME           remove a user, their links stop working immediately
  user list               list users
  user route NAME ROUTE|- set the user's own route (- : the group's or ROUTE_DEFAULT)
  user group NAME GROUP|- put the user into a group (- : no group)
  links [NAME]            print subscription links (all users or one)
  rotate NAME|--all [--grace HOURS]
                          issue new credentials, the old ones keep working for
                          HOURS (default 24) so clients can refresh the subscription

Routes (hub, control): where traffic that isn't RU leaves; RU always leaves from the hub
  exit add NAME TOKEN     add (or update) an exit from the token `hub add` printed on it;
                          its egress IPs become routes NAME/IPNAME
  exit del NAME           remove an exit
  exit list               list exits and their routes
  group add NAME [ROUTE]  add a group of users with a common route
  group route NAME ROUTE|-
                          change the group's route (- : ROUTE_DEFAULT)
  group del NAME          remove an empty group
  group list              list groups
  route list              who leaves through which route
                          Routes: local (the hub), none (no internet but RU), EXIT/IPNAME

EOF
  show "hub" <<'EOF'
Under control (hub): users, groups and routes come from control's snapshots
  control join            print the token for `hub add` in control
  control set TOKEN       trust the control that printed TOKEN (`hub add` there),
                          read its snapshots from DNS (vpn-sync.timer, every 5 min)
  control unset           manage users here again
  sync                    read the snapshot from DNS now
  state apply [FILE]      apply a snapshot by hand (stdin by default):
                          ssh HUB './vpn.sh state apply' < state.txt
  state export            print this stand-alone hub's users for `import` in control

EOF
  show "exit" <<'EOF'
Hubs (ROLE=exit):
  hub add NAME            let hub NAME use this exit, print the token for it
  hub token NAME          print the token again (with egress IPs added since)
  hub del NAME            remove a hub, it can't connect anymore
  hub list                list hubs

EOF
  show "hub exit" <<'EOF'
Maintenance:
  update images           upgrade sing-box / caddy images to the latest releases
  update rules            download the RU lists again (hub; done daily by the timer)
  update repo             update this repo's code from GitHub (keeps .env, users, certificates)
  render                  render configs into generated/ and validate them
  check                   check containers, certificate, Let's Encrypt path, REALITY target,
                          routes (hub), egress IPs (exit)
  prune                   drop expired credentials, refresh the RU lists
                          (check and prune run hourly from vpn-maintenance.timer)
EOF
  show "control" <<'EOF'
Maintenance:
  prune                   drop expired credentials (and publish)
EOF
  show "hub exit control" <<'EOF'
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
. lib/exit.sh
. lib/routes.sh
. lib/control.sh
. lib/dns.sh

# --- main --------------------------------------------------------------------

args=()
for arg in "$@"; do
  [[ $arg == -y ]] && ASSUME_YES=true || args+=("$arg")
done
set -- "${args[@]+"${args[@]}"}"

cmd=${1:-help}
(($#)) && shift
case $cmd in
  deploy | init | up | render | user | rotate | prune | update | firewall | uninstall | hub | exit | group | route | control | state | sync | publish | import) lock ;;
esac
# Control is a laptop: nothing to run or check there
if [[ $(env_role) == control ]]; then
  case $cmd in
    init | user | links | rotate | prune | exit | group | route | hub | publish | import | up | help | -h | --help) ;;
    *) die "./vpn.sh $cmd isn't for ROLE=control (./vpn.sh help)" ;;
  esac
fi
case $cmd in
  deploy) cmd_deploy ;;
  init) cmd_init ;;
  up) cmd_up ;;
  down) load_env; "$DOCKER" compose down ;;
  logs) load_env; "$DOCKER" compose logs -f --tail=100 ;;
  tune) cmd_tune ;;
  install-docker) cmd_install_docker ;;
  uninstall) cmd_uninstall ;;
  firewall) cmd_firewall "$@" ;;
  user) cmd_user "$@" ;;
  hub) cmd_hub "$@" ;;
  exit) cmd_exit "$@" ;;
  group) cmd_group "$@" ;;
  route) cmd_route "$@" ;;
  control) cmd_control "$@" ;;
  state) cmd_state "$@" ;;
  sync) cmd_sync ;;
  publish) require_role control publish; cmd_publish ;;
  import) cmd_import "$@" ;;
  links) cmd_links "$@" ;;
  rotate) cmd_rotate "$@" ;;
  update) cmd_update "$@" ;;
  render) cmd_render ;;
  prune) cmd_prune ;;
  check) cmd_check ;;
  help | -h | --help) usage ;;
  *) echo "unknown command: $cmd" >&2; usage >&2; exit 1 ;;
esac
