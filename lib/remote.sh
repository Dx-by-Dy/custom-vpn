# shellcheck shell=bash
# Code updates ordered by control; sourced by vpn.sh
#
# `control hub update` / `control exit update` say which commit of the repo a
# hub or an exit should run; `control publish` puts the orders into DNS next to
# the snapshot (head upd.DOMAIN, pieces uVERSION-i), and the server's vpn-sync
# timer carries them out. The record:
#   JSON -> gzip -> age (control's update key: hubs get it in their snapshot,
#   exits in their control token) -> signed (namespace cvpn-update)
# written as "cvpn-upd1.<signature>.<data>". An order is for the hash of the
# server's key (a hub's age recipient, an exit's REALITY public key), not for
# its name. A server only moves forward along REPO_BRANCH of its own REPO_URL,
# runs check before and after, and goes back if the update broke something.

UPDATES_FILE=$CONTROL_DIR/updates.conf
UPDATES_HEADER='# kind  name  commit  ordered-at   (control hub|exit update)'
UPDATE_FILE=$OUT/update.txt
UPDATE_KEY=$CONTROL_DIR/update.key
UPDATE_STATE=$CONTROL_DIR/update.json
UPDATE_NAMESPACE=cvpn-update
# Seconds for restarted containers to come up before the check after an update
UPDATE_SETTLE=${UPDATE_SETTLE:-10}

# A hub or an exit that follows control (an exit only for code updates)
under_control() { [[ ($ROLE == hub || $ROLE == exit) && -n ${CONTROL_KEY:-} ]]; }

# Who an order is for: the hash of the server's key
update_id() { printf 'cvpn-update\n%s' "$1" | sha256sum | cut -c1-16; }

update_my_id() {
  if [[ $ROLE == hub ]]; then
    update_id "$(age-keygen -y "$CONTROL_DIR/age.key")"
  else
    update_id "$REALITY_PUBLIC_KEY"
  fi
}

# git on a copy owned by another user (scp, rsync): "dubious ownership" otherwise
git_here() { GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0=$PWD git "$@"; }

# --- control -----------------------------------------------------------------

# Control's update key (an age identity), made on first use
control_update_key() {
  if [[ ! -s $UPDATE_KEY ]]; then
    age-keygen -o "$UPDATE_KEY" 2>/dev/null
    chmod 600 "$UPDATE_KEY"
  fi
  grep -m1 '^AGE-SECRET-KEY-' "$UPDATE_KEY"
}

# The token an exit follows control with (it has the update key: keep it private)
control_exit_token() {
  jq -n --arg exit "$1" --arg key "$(cat "$CONTROL_DIR/sign.pub")" --arg domain "$(control_domains_line)" \
    --arg update_key "$(control_update_key)" '
    {v: 1, exit: $exit, key: $key, update_key: $update_key} + (if $domain != "" then {domain: $domain} else {} end)' |
    token_encode cvpn-ctl
}

# The REALITY public key of exit NAME, from its token
exit_public_key() {
  exit_routes_json | jq -r --arg e "$1/" 'first(.[] | select(.name | startswith($e)) | .public_key) // empty'
}

# COMMIT as a full hash; without one, the last commit of the repo's branch
update_resolve() {
  local c=${1:-} url=${REPO_URL:-$DEFAULT_REPO_URL} branch=${REPO_BRANCH:-$DEFAULT_REPO_BRANCH} found
  if [[ -z $c ]]; then
    found=$(git ls-remote "$url" "refs/heads/$branch" 2>/dev/null | awk '{print $1; exit}')
    [[ $found =~ ^[0-9a-f]{40}$ ]] || die "can't get the last commit of $branch from $url; name one: ... COMMIT"
    echo "$found"
    return
  fi
  [[ $c =~ ^[0-9a-f]{7,40}$ ]] || die "not a commit: $c"
  if ((${#c} == 40)); then
    echo "$c"
  else
    git_here rev-parse -q --verify "$c^{commit}" 2>/dev/null || die "$c isn't in this checkout: give the full commit (40 hex)"
  fi
}

# control hub|exit update [NAME|--all [COMMIT|-]]: order NAME (every hub or
# exit) to run COMMIT (the last one of the branch); - cancels; none: the orders
control_update() {
  local kind=$1 name=${2:-} commit=${3:-} names n at
  conf_init "$UPDATES_FILE" "$UPDATES_HEADER"
  if [[ -z $name ]]; then
    update_list "$kind"
    return
  fi
  if [[ $kind == hub ]]; then names=$(control_hubs_json | jq -r '.[].name'); else names=$(conf_rows "$EXITS_FILE" | awk '{print $1}'); fi
  if [[ $name == --all ]]; then
    [[ -n $names ]] || die "no ${kind}s yet"
  else
    [[ $'\n'$names$'\n' == *$'\n'"$name"$'\n'* ]] || die "no $kind $name ($(vsh "$kind" list))"
    names=$name
  fi
  if [[ $commit == - ]]; then
    for n in $names; do conf_rewrite "$UPDATES_FILE" -v k="$kind" -v n="$n" '/^#/ || $1 != k || $2 != n'; done
    info "no update order for $kind $(paste -sd' ' <<<"$names") any more (it stays on the code it has)"
    control_changed
    return
  fi
  commit=$(update_resolve "$commit")
  at=$(date +%s)
  for n in $names; do
    conf_rewrite "$UPDATES_FILE" -v k="$kind" -v n="$n" '/^#/ || $1 != k || $2 != n'
    echo "$kind $n $commit $at" >>"$UPDATES_FILE"
  done
  info "$kind $(paste -sd' ' <<<"$names") to run ${commit:0:12} once published (forward only; back if its check gets worse)"
  control_changed
}

# The orders of KIND, and what the hubs say they run
update_list() {
  local kind=$1 hubs n commit at status code result
  hubs=$(control_hubs_json)
  printf '%-12s %-14s %-12s %s\n' "${kind^^}" ORDERED SINCE "RUNS (last report)"
  while read -r n commit at; do
    code="?" result=
    if [[ $kind == hub ]]; then
      status=$(jq -r --arg n "$n" '.[] | select(.name == $n) | "\(.domain) \(.sub_port) \(.recipient)"' <<<"$hubs" | {
        read -r d p r && hub_status_get "$d" "$p" "$r"
      } || true)
      code=$(jq -r '.update.code // "?" | .[:12]' <<<"$status" 2>/dev/null || echo "?")
      result=$(jq -r '.update.result // empty' <<<"$status" 2>/dev/null || true)
    else
      result="(exits don't report: ./vpn.sh exit check there)"
    fi
    printf '%-12s %-14s %-12s %s\n' "$n" "${commit:0:12}" "$(date -d "@$at" '+%m-%d %H:%M')" "$code ${result:+$result}"
  done < <(conf_rows "$UPDATES_FILE" | awk -v k="$kind" '$1 == k {print $2, $3, $4}')
}

# Build UPDATE_FILE for snapshot VERSION (control's publish)
update_build() {
  local version=$1 hubs=$2 kind name commit at pub orders='{}' tmp
  control_update_key >/dev/null
  while read -r kind name commit at; do
    if [[ $kind == hub ]]; then
      pub=$(jq -r --arg n "$name" '.[] | select(.name == $n) | .recipient' <<<"$hubs")
    else
      pub=$(exit_public_key "$name")
    fi
    if [[ -z $pub ]]; then
      warn "update order for $kind $name: there's no such $kind any more ($(vsh "$kind" update) $name -)"
      continue
    fi
    orders=$(jq -c --arg id "$(update_id "$pub")" --arg c "$commit" --argjson at "$at" '. + {($id): {commit: $c, at: $at}}' <<<"$orders")
  done < <(conf_rows "$UPDATES_FILE")
  tmp_dir tmp
  jq -n --argjson version "$version" --arg domains "$(control_domains_line)" --argjson orders "$orders" '
    {v: 1, version: $version, domains: $domains, orders: $orders}' |
    gzip -9 | age -r "$(age-keygen -y "$UPDATE_KEY")" -o "$tmp/data"
  ssh-keygen -Y sign -q -f "$CONTROL_DIR/sign" -n "$UPDATE_NAMESPACE" "$tmp/data"
  printf 'cvpn-upd1.%s.%s\n' "$(base64 -w0 "$tmp/data.sig")" "$(base64 -w0 "$tmp/data")" >"$UPDATE_FILE.tmp"
  chmod 600 "$UPDATE_FILE.tmp"
  mv "$UPDATE_FILE.tmp" "$UPDATE_FILE"
}

# --- hub / exit --------------------------------------------------------------

# update_read LINE DIR: the record's JSON if this server's control signed it and
# it decrypts with the update key (DIR: a temporary directory for the work)
update_read() {
  local line=$1 dir=$2
  [[ $line =~ ^cvpn-upd1\.([A-Za-z0-9+/=]+)\.([A-Za-z0-9+/=]+)$ ]] || return 1
  base64 -d <<<"${BASH_REMATCH[1]}" >"$dir/data.sig" 2>/dev/null || return 1
  base64 -d <<<"${BASH_REMATCH[2]}" >"$dir/data" 2>/dev/null || return 1
  echo "$SIG_PRINCIPAL $CONTROL_KEY" >"$dir/signers"
  ssh-keygen -Y verify -f "$dir/signers" -I "$SIG_PRINCIPAL" -n "$UPDATE_NAMESPACE" -s "$dir/data.sig" \
    <"$dir/data" >/dev/null 2>&1 || return 1
  age -d -i "$UPDATE_KEY" "$dir/data" 2>/dev/null | gunzip 2>/dev/null |
    jq -ce 'select(.v == 1 and (.version | type) == "number" and (.orders | type) == "object")' 2>/dev/null
}

# Read control's update record from DNS and carry out this server's order;
# part of sync. Never fails sync: problems go into the update state
update_sync() {
  local d r v n sha line json= tmp
  [[ -s $UPDATE_KEY ]] || return 0
  tmp_dir tmp
  for d in $(control_domains); do
    for r in ${CONTROL_RESOLVERS:-$DNS_RESOLVERS_DEFAULT}; do
      read -r v n sha < <(dns_head "$d" "$r" upd) || continue
      line=$(dns_line "$d" "$r" u "$v" "$n" "$sha") || continue
      if json=$(update_read "$line" "$tmp"); then break 2; fi
      warn "upd.$d through $r: not signed by this server's control, or not for its update key"
    done
  done
  [[ -n $json ]] || return 0
  touch "$SYNCED_FILE"
  # Exits learn the control domains here (hubs from their snapshots)
  if [[ $ROLE == exit ]]; then
    d=$(jq -r '.domains // empty' <<<"$json")
    if [[ -n $d && $d != "$(control_domains_line)" ]]; then
      set_var CONTROL_DOMAIN "$d"
      info "control domains now: $d"
    fi
  fi
  update_run "$(jq -c --arg id "$(update_my_id)" '.orders[$id] // empty' <<<"$json")"
}

# update_state ORDER CODE RESULT [FAILED]: what came of the order, for check
# (and a hub's status.json); FAILED: the order not to try again
update_state() {
  mkdir -p "$CONTROL_DIR"
  jq -n --arg order "$1" --arg code "$2" --arg result "$3" --arg failed "${4:-}" --arg at "$(date -u +%FT%TZ)" '
    {order: $order, code: $code, result: $result, at: $at} + (if $failed != "" then {failed: $failed} else {} end)' \
    >"$UPDATE_STATE.tmp"
  chmod 600 "$UPDATE_STATE.tmp"
  mv "$UPDATE_STATE.tmp" "$UPDATE_STATE"
  hub_status update "$(cat "$UPDATE_STATE")"
}

# Parts of check that fail now (but update itself)
update_fails() { ./vpn.sh check 2>&1 | awk '$1 != "update" && $2 ~ /^FAIL/ {print $1}' | sort -u || true; }

# update_run ORDER ({commit, at} or nothing): be at that commit
update_run() {
  local order=$1 want key head url=${REPO_URL:-$DEFAULT_REPO_URL} branch=${REPO_BRANCH:-$DEFAULT_REPO_BRANCH} before broke
  head=$(git_here rev-parse -q --verify HEAD 2>/dev/null || echo none)
  if [[ -z $order ]]; then
    update_state "" "$head" "no order"
    return 0
  fi
  want=$(jq -r .commit <<<"$order")
  key="$want $(jq -r .at <<<"$order")"
  [[ $want =~ ^[0-9a-f]{40}$ ]] || { update_state "$want" "$head" "FAIL: control ordered a bad commit: $want"; return 0; }
  if [[ $want == "$head" ]]; then
    update_state "$want" "$head" ok
    return 0
  fi
  # Tried and went back: again only when control orders it again
  [[ $key != "$(jq -r '.failed // empty' "$UPDATE_STATE" 2>/dev/null)" ]] || return 0

  if ! git_here fetch -q "$url" "$branch" 2>/dev/null; then
    update_state "$want" "$head" "FAIL: can't fetch $branch from $url (tries again)"
    return 0
  fi
  if ! git_here cat-file -e "$want^{commit}" 2>/dev/null || ! git_here merge-base --is-ancestor "$want" FETCH_HEAD; then
    update_state "$want" "$head" "FAIL: ${want:0:12} isn't on $branch of $url" "$key"
    return 0
  fi
  if [[ $head != none ]] && ! git_here merge-base --is-ancestor "$head" "$want"; then
    update_state "$want" "$head" "FAIL: ${want:0:12} is older than ${head:0:12} here (updates only go forward)" "$key"
    return 0
  fi

  info "control orders ${want:0:12}, this $ROLE runs ${head:0:12}: updating"
  before=$(update_fails)
  # update repo and the deploy after it take the lock themselves
  exec 9>&-
  ./vpn.sh -y update repo "$want" || warn "update repo $want failed"
  sleep "$UPDATE_SETTLE"
  broke=$(comm -13 <(echo "$before") <(update_fails) | paste -sd' ')
  if [[ $(git_here rev-parse HEAD) != "$want" ]]; then
    update_state "$want" "$(git_here rev-parse HEAD)" "FAIL: update repo didn't get to ${want:0:12}" "$key"
  elif [[ -n $broke ]]; then
    warn "after the update check fails at: $broke; going back to ${head:0:12}"
    ./vpn.sh -y update repo "$head" || warn "couldn't go back to $head"
    update_state "$want" "$(git_here rev-parse HEAD)" "FAIL: ${want:0:12} broke $broke, went back to ${head:0:12}" "$key"
  else
    update_state "$want" "$want" ok
    info "now at ${want:0:12}, as control ordered"
  fi
}

# check on a hub or an exit under control; uses report from cmd_check
check_update() {
  local order result
  under_control && [[ -s $UPDATE_STATE ]] || return 0
  order=$(jq -r .order "$UPDATE_STATE")
  result=$(jq -r .result "$UPDATE_STATE")
  [[ -n $order ]] || return 0
  if [[ $result == ok ]]; then
    report update "ok (at ${order:0:12}, as control ordered)"
  else
    report update "$result (control ordered ${order:0:12})"
  fi
}

# exit control set TOKEN | unset | sync: the exit follows control's update orders
cmd_exit_control() {
  local action=${1:-} json
  case $action in
    set)
      json=$(token_decode cvpn-ctl "${2:-}") && jq -e '.exit and .key and .update_key' >/dev/null <<<"$json" ||
        die "that's not an exit's control token: ./vpn.sh control exit token NAME prints it"
      [[ -n $(jq -r '.domain // empty' <<<"$json") ]] || die "control has no CONTROL_DOMAIN: orders come only through DNS"
      need_pkg age "control's orders are encrypted with it"
      mkdir -p "$CONTROL_DIR"
      chmod 700 "$CONTROL_DIR"
      (umask 077 && jq -r .update_key <<<"$json" >"$UPDATE_KEY")
      set_var EXIT_NAME "$(jq -r .exit <<<"$json")"
      set_var CONTROL_KEY "$(jq -r .key <<<"$json")"
      set_var CONTROL_DOMAIN "$(jq -r .domain <<<"$json")"
      info "exit $EXIT_NAME follows control's code updates now (./vpn.sh control exit update $EXIT_NAME there)"
      install_sync_timer
      cmd_sync
      ;;
    unset)
      under_control || die "this exit doesn't follow control"
      sed -i -E '/^(CONTROL_KEY|EXIT_NAME|CONTROL_DOMAIN)=/d' "$ENV_FILE"
      rm -f "$UPDATE_KEY" "$UPDATE_STATE"
      remove_sync_timer
      info "this exit doesn't follow control any more"
      ;;
    sync) cmd_sync ;;
    *) die "usage: $(vsh control) set TOKEN | unset | sync" ;;
  esac
}
