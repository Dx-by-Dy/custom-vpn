# shellcheck shell=bash
# Users and their credentials (users.conf), links; sourced by vpn.sh

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
