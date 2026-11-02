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
  role=${ROLE:-$(sed -n 's/^ROLE=//p' "$ENV_FILE" 2>/dev/null | tail -1)}
  # show "ROLES" <<EOF: the text if this role is one of ROLES
  show() { if [[ -z $role || " $1 " == *" $role "* ]]; then cat; else cat >/dev/null; fi; }
  cat <<'EOF'
Usage: ./vpn.sh ROLE OBJECT ACTION [args]
  ROLE is this server's role (hub, exit, client, control); on a new server it
  picks the role: ./vpn.sh exit deploy. The older form without ROLE works too.

EOF
  show "control" <<'EOF'
Control (the laptop): the scheme of every hub. Changes are saved here; publish
sends them as a signed snapshot (DNS, CONTROL_DOMAIN in .env), hubs apply it
within minutes.
  ./vpn.sh control init                     .env and the signing key
  ./vpn.sh control user add NAME [--group G] [--route R]
  ./vpn.sh control user del NAME            the user's keys stop working on every hub
  ./vpn.sh control user list
  ./vpn.sh control user route NAME ROUTE[,ROUTE...]|-
                                            the user's own routes, picked in the app; the first is
                                            the main one (- : the group's or ROUTE_DEFAULT)
  ./vpn.sh control user group NAME GROUP|-  put the user into a group (- : no group)
  ./vpn.sh control user links [NAME]        subscription links on every hub (one per route)
  ./vpn.sh control user rotate NAME|--all [--grace HOURS]
                                            new keys; the old ones work HOURS more (24)
  ./vpn.sh control group add NAME [ROUTE[,ROUTE...]]
                                            a group of users with common routes
  ./vpn.sh control group route NAME ROUTE[,ROUTE...]|-   (- : ROUTE_DEFAULT)
  ./vpn.sh control group del NAME           (an empty one)
  ./vpn.sh control group list
  ./vpn.sh control exit add NAME TOKEN      an exit from `./vpn.sh exit hub add` there;
                                            its IPs become routes NAME/IPNAME
  ./vpn.sh control exit del NAME
  ./vpn.sh control exit list
  ./vpn.sh control route list               who leaves through which routes
                                            (local, none = RU only, EXIT/IPNAME)
  ./vpn.sh control hub add NAME TOKEN       a hub from `./vpn.sh hub control join` there;
                                            prints the token for `hub control set`
  ./vpn.sh control hub token NAME           print that token again
  ./vpn.sh control hub del NAME             the hub can't read new snapshots
  ./vpn.sh control hub list
  ./vpn.sh control check                    the whole system: DNS, every hub (snapshot, DNS,
                                            its own check, subscription), every route
  ./vpn.sh control dns                      the control domains: zones, what DNS gives
  ./vpn.sh control diff                     what isn't published yet
  ./vpn.sh control publish                  send the scheme to the hubs (a new snapshot)
  ./vpn.sh control import FILE              users of a stand-alone hub (`hub control export`)
  ./vpn.sh control prune                    drop expired credentials

EOF
  show "hub" <<'EOF'
Hub: people connect here.
  ./vpn.sh hub deploy                       full setup: tune, init, up, timer, links
  ./vpn.sh hub control join                 print the token for `control hub add`
  ./vpn.sh hub control set TOKEN            trust that control, take its snapshots from DNS
                                            (vpn-sync.timer, every 5 min)
  ./vpn.sh hub control sync                 take the snapshot from DNS now
  ./vpn.sh hub control apply [FILE]         apply a snapshot by hand (stdin by default):
                                            ssh HUB './vpn.sh hub control apply' < state.txt
  ./vpn.sh hub control export               this stand-alone hub's users, for `control import`
  ./vpn.sh hub control unset                manage users here again
 Stand-alone (not under control): the same objects as in control, here
  ./vpn.sh hub user add|del|list|route|group|links|rotate ...
  ./vpn.sh hub group add|route|del|list ...
  ./vpn.sh hub exit add|del|list ...
 Under control these only show: user list, user links, group list, exit list, route list
  ./vpn.sh hub route list                   who leaves through which route

EOF
  show "exit" <<'EOF'
Exit: hubs leave through it.
  ./vpn.sh exit deploy                      full setup: tune, init, up, timer
  ./vpn.sh exit hub add NAME                a token for hubs (one for all: main)
  ./vpn.sh exit hub token NAME              print it again (with IPs added since)
  ./vpn.sh exit hub del NAME                hubs with this token can't connect anymore
  ./vpn.sh exit hub list

EOF
  show "client" <<'EOF'
Client: a local proxy (socks5 + http on CLIENT_LISTEN) through the hubs of CLIENT_SUB.
  CLIENT_SUB=LINK ./vpn.sh client deploy    full setup (LINK: the user's subscription)
  ./vpn.sh client refresh                   take the subscription again (hourly by the timer)

EOF
  show "hub exit client" <<EOF
Every server (./vpn.sh ${role:-ROLE} ...):
  init                    create .env, generate missing keys
  up                      render configs, check ports, start/restart containers
  down | logs             stop containers | follow their logs
  check                   health of this server (hourly from vpn-maintenance.timer)
  prune                   hourly upkeep: expired credentials, RU lists, subscription
  render                  render configs into generated/ and validate them
  update images|repo|rules
                          sing-box / caddy images; this code from GitHub (keeps keys,
                          users, certificates); the RU lists (hub)
  firewall [--dry-run]    ufw for ssh, the VPN ports and other listening services,
                          optionally key-only SSH
  tune                    BBR and bigger UDP buffers (sysctl)
  install-docker          docker via get.docker.com
  uninstall               remove what vpn.sh set up on this host (asks what to keep)

EOF
  cat <<'EOF'
  help                    this help
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
. lib/client.sh

# --- main --------------------------------------------------------------------

args=()
for arg in "$@"; do
  [[ $arg == -y ]] && ASSUME_YES=true || args+=("$arg")
done
set -- "${args[@]+"${args[@]}"}"

cmd=${1:-help}
(($#)) && shift
# Tree form: ./vpn.sh ROLE OBJECT ACTION. The role word is this server's role; on
# a server without .env it picks the role (./vpn.sh exit deploy). A role word
# that is also an object here (exit / control on a hub, hub / exit in control,
# hub on an exit) keeps meaning the object: ./vpn.sh exit add on a hub.
if [[ " hub exit client control " == *" $cmd "* ]]; then
  own=$(env_role)
  if [[ ! -f $ENV_FILE ]]; then
    [[ -z ${ROLE:-} || $ROLE == "$cmd" ]] || die "ROLE=$ROLE, but the command says $cmd"
    export ROLE=$cmd
    cmd=${1:-help}
    (($#)) && shift
  elif [[ $cmd == "$own" ]]; then
    cmd=${1:-help}
    (($#)) && shift
  else
    # Actions of the object with that name here; anything else is the other role's tree
    case $own:$cmd in
      hub:exit | control:exit) actions="add del list" ;;
      hub:control) actions="join set unset sync apply export" ;;
      control:hub | exit:hub) actions="add token del list" ;;
      *) actions="" ;;
    esac
    [[ -n $actions && " $actions " == *" ${1:-add} "* ]] ||
      die "./vpn.sh $cmd ${1:-} ... is for ROLE=$cmd, this server is ROLE=$own (./vpn.sh help)"
  fi
fi
case $cmd in
  deploy | init | up | render | user | rotate | prune | refresh | update | firewall | uninstall | hub | exit | group | route | control | state | sync | publish | import) lock ;;
esac
# Control is a laptop: nothing to run or check there
case $(env_role) in
  control)
    case $cmd in
      init | user | links | rotate | prune | exit | group | route | hub | publish | diff | import | up | check | dns | help | -h | --help) ;;
      *) die "./vpn.sh $cmd isn't for ROLE=control (./vpn.sh help)" ;;
    esac
    ;;
  client)
    case $cmd in
      deploy | init | up | down | logs | tune | install-docker | uninstall | firewall | render | check | prune | refresh | update | help | -h | --help) ;;
      *) die "./vpn.sh $cmd isn't for ROLE=client (./vpn.sh help)" ;;
    esac
    ;;
esac
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
  dns) require_role control dns; cmd_control_dns ;;
  diff) require_role control diff; cmd_control_diff ;;
  publish) require_role control publish; cmd_publish ;;
  import) cmd_import "$@" ;;
  links) cmd_links "$@" ;;
  rotate) cmd_rotate "$@" ;;
  update) cmd_update "$@" ;;
  render) cmd_render ;;
  prune) cmd_prune ;;
  refresh) require_role client refresh; cmd_prune ;;
  check) cmd_check ;;
  help | -h | --help) usage ;;
  *) echo "unknown command: $cmd" >&2; usage >&2; exit 1 ;;
esac
# control: say once, at the end, that the change is only saved
! $CONTROL_CHANGED || control_saved
