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
#
# The one way back: `control stable COMMIT` names a commit known to be good, the
# record carries it, and every server keeps it with a script of plain git
# commands (STABLE_SCRIPT), which works when the code at HEAD is what's broken.
# `control rollback` orders servers there ("back" in the order); `rollback` on a
# server runs the script. An order goes back only to a commit this server ran
# itself (its reflog), so control's key alone can't send it to any old commit.

UPDATES_FILE=$CONTROL_DIR/updates.conf
UPDATES_HEADER='# kind  name  commit  ordered-at   (control hub|exit update)'
UPDATE_FILE=$OUT/update.txt
UPDATE_KEY=$CONTROL_DIR/update.key
UPDATE_STATE=$CONTROL_DIR/update.json
UPDATE_NAMESPACE=cvpn-update
# The stable commit: control's, what a server was told, how the server gets there
STABLE_FILE=$CONTROL_DIR/stable
STABLE_SCRIPT=$CONTROL_DIR/rollback.sh
# A server sent back by hand: control's orders from before this time wait
UPDATE_HOLD=$CONTROL_DIR/update.hold
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

# Every hub or exit of KIND: its order, and what it says it runs (exits through the hubs)
update_list() {
  local kind=$1 hubs n commit at when status code result names reports=
  hubs=$(control_hubs_json)
  if [[ $kind == hub ]]; then
    names=$(jq -r '.[].name' <<<"$hubs")
  else
    names=$(conf_rows "$EXITS_FILE" | awk '{print $1}')
    reports=$(control_hub_statuses | exit_reports_of)
  fi
  printf '%-12s %-14s %-12s %-14s %-10s %s\n' "${kind^^}" ORDERED SINCE RUNS SING-BOX "LAST REPORT"
  for n in $names; do
    commit=- at= when=-
    read -r commit at < <(conf_rows "$UPDATES_FILE" | awk -v k="$kind" -v n="$n" '$1 == k && $2 == n {print $3, $4}') || true
    [[ -n $commit ]] || commit=-
    [[ -z ${at:-} ]] || when=$(date -d "@$at" '+%m-%d %H:%M')
    if [[ $kind == hub ]]; then
      status=$(jq -r --arg n "$n" '.[] | select(.name == $n) | "\(.domain) \(.sub_port) \(.recipient)"' <<<"$hubs" | {
        read -r d p r && hub_status_get "$d" "$p" "$r"
      } || true)
    else
      status=$(jq -c --arg n "$n" '.[$n] // empty' <<<"$reports")
    fi
    code=$(jq -r '.update.code // .code // "?" | .[:12]' <<<"$status" 2>/dev/null || echo "?")
    result=$(jq -r '.update.result // empty' <<<"$status" 2>/dev/null || true)
    [[ $kind == hub || -n $status ]] || result="no report yet (down, or its code or the hubs' is older)"
    [[ $kind == hub || -z $status ]] || result+=" (heard by $(jq -r .via <<<"$status") $(mins_since "$(jq -r .seen <<<"$status")") min ago)"
    printf '%-12s %-14s %-12s %-14s %-10s %s\n' "$n" "${commit:0:12}" "$when" "${code:-?}" \
      "$(jq -r '.sing_box // "?"' <<<"$status" 2>/dev/null || echo "?")" "$result"
  done
}

# control stable [COMMIT|-]: the commit to go back to
cmd_stable() {
  local c=${1:-} commit
  require_role control stable
  if [[ -z $c ]]; then
    commit=$(cat "$STABLE_FILE" 2>/dev/null || true)
    if [[ -z $commit ]]; then
      echo "No stable commit. Name one that works: $(vsh stable) COMMIT, then $(vsh publish)"
    else
      echo "Stable: $(git_here log -1 --format='%h %cs %s' "$commit" 2>/dev/null || echo "${commit:0:12}")"
      echo "Servers go back to it with: $(vsh rollback) NAME...|--all"
    fi
    return
  fi
  if [[ $c == - ]]; then
    mkdir -p "$CONTROL_DIR"
    rm -f "$STABLE_FILE"
    control_changed
    info "no stable commit any more"
    return
  fi
  commit=$(update_resolve "$c")
  git_here cat-file -e "$commit^{commit}" 2>/dev/null || die "${commit:0:12} isn't in this checkout: git pull, or check the commit"
  # Code from before this function would go forward again by itself, and has no way back
  git_here grep -q STABLE_SCRIPT "$commit" -- lib/remote.sh ||
    die "${commit:0:12} is older than rollbacks: a server on it couldn't follow them. Name a newer commit"
  mkdir -p "$CONTROL_DIR"
  echo "$commit" >"$STABLE_FILE"
  control_changed
  info "stable: $(git_here log -1 --format='%h %cs %s' "$commit"); publish to tell the servers"
}

# control rollback NAME...|--all: hubs and exits to the stable commit, published now
control_rollback() {
  local stable name n at found targets=() kinds
  lock
  stable=$(cat "$STABLE_FILE" 2>/dev/null || true)
  [[ -n $stable ]] || die "no stable commit: $(vsh stable) COMMIT. By hand on a server: ./vpn.sh hub update repo COMMIT"
  (($#)) || die "usage: $(vsh rollback) NAME...|--all (stable: ${stable:0:12})"
  conf_init "$UPDATES_FILE" "$UPDATES_HEADER"
  kinds=$(control_hubs_json | jq -r '.[].name | "hub \(.)"'; conf_rows "$EXITS_FILE" | awk '{print "exit", $1}')
  for name in "$@"; do
    found=false
    while read -r n; do
      [[ -n $n ]] || continue
      if [[ $name == --all || ${n#* } == "$name" ]]; then targets+=("$n"); found=true; fi
    done <<<"$kinds"
    $found || die "no hub or exit $name"
  done
  if control_pending; then
    echo "Publishing sends these too:"
    cmd_control_diff
    ask "Publish them with the rollback?" n || return 0
  fi
  at=$(date +%s)
  for n in "${targets[@]}"; do
    conf_rewrite "$UPDATES_FILE" -v k="${n% *}" -v n="${n#* }" '/^#/ || $1 != k || $2 != n'
    echo "$n $stable $at back" >>"$UPDATES_FILE"
  done
  info "back to ${stable:0:12}: $(printf '%s ' "${targets[@]#* }")"
  cmd_publish
  echo "Servers read it within 5 min + DNS TTL; at once, on a server: ./vpn.sh hub|exit control sync"
  echo "See it: $(vsh check). They stay there until the next $(vsh hub update) / $(vsh exit update)."
  echo "A server that can't (DNS, broken code), on it: sh $STABLE_SCRIPT"
}

# Build UPDATE_FILE for snapshot VERSION (control's publish)
update_build() {
  local version=$1 hubs=$2 kind name commit at back pub orders='{}' tmp
  control_update_key >/dev/null
  while read -r kind name commit at back; do
    if [[ $kind == hub ]]; then
      pub=$(jq -r --arg n "$name" '.[] | select(.name == $n) | .recipient' <<<"$hubs")
    else
      pub=$(exit_public_key "$name")
    fi
    if [[ -z $pub ]]; then
      warn "update order for $kind $name: there's no such $kind any more ($(vsh "$kind" update) $name -)"
      continue
    fi
    orders=$(jq -c --arg id "$(update_id "$pub")" --arg c "$commit" --argjson at "$at" --arg back "$back" \
      '. + {($id): ({commit: $c, at: $at} + (if $back == "back" then {back: true} else {} end))}' <<<"$orders")
  done < <(conf_rows "$UPDATES_FILE")
  tmp_dir tmp
  jq -n --argjson version "$version" --arg domains "$(control_domains_line)" --argjson orders "$orders" \
    --arg stable "$(cat "$STABLE_FILE" 2>/dev/null || true)" '
    {v: 1, version: $version, domains: $domains, orders: $orders} + (if $stable != "" then {stable: $stable} else {} end)' |
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
  stable_keep "$(jq -r '.stable // empty' <<<"$json")"
  update_run "$(jq -c --arg id "$(update_my_id)" '.orders[$id] // empty' <<<"$json")"
}

# rollback_script COMMIT: going back with nothing of the code at HEAD: the lock (a
# hung holder doesn't stop this), the state saved, the hold, git, then the deploy
# of the commit's own code
rollback_script() {
  cat <<EOF
#!/bin/sh
# Written by vpn.sh: back to ${1:0:12}, without the code at HEAD. By hand: sh $STABLE_SCRIPT
set -e
cd $(printf '%q' "$PWD")
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.directory GIT_CONFIG_VALUE_0="\$PWD"
exec 9>.vpn.lock
flock -w 120 9 || echo "warning: another vpn.sh holds the lock, going on" >&2
mkdir -p backups "$CONTROL_DIR"
chmod 700 backups
tar -czf "backups/state-\$(date +%Y%m%d-%H%M%S).tar.gz" \$(ls -d ${CONF_FILES[*]} 2>/dev/null)
date +%s >"$UPDATE_HOLD"
git reset -q --hard $1
exec 9>&-
echo ">> code at ${1:0:12}; control's older orders wait, a new one lifts this"
exec ./vpn.sh -y deploy
EOF
}

# The stable commit control names: keep it here, with its objects, for a day
# without GitHub, and the script to go back to it
stable_keep() {
  local c=$1
  if [[ -z $c ]]; then
    rm -f "$STABLE_FILE" "$STABLE_SCRIPT"
    return 0
  fi
  [[ $c =~ ^[0-9a-f]{40}$ ]] || { warn "control named a bad stable commit: $c"; return 0; }
  echo "$c" >"$STABLE_FILE"
  git_here cat-file -e "$c^{commit}" 2>/dev/null ||
    git_here fetch -q "${REPO_URL:-$DEFAULT_REPO_URL}" "${REPO_BRANCH:-$DEFAULT_REPO_BRANCH}" 2>/dev/null || true
  if git_here cat-file -e "$c^{commit}" 2>/dev/null; then
    rollback_script "$c" >"$STABLE_SCRIPT.tmp"
    chmod 700 "$STABLE_SCRIPT.tmp"
    mv "$STABLE_SCRIPT.tmp" "$STABLE_SCRIPT"
  else
    rm -f "$STABLE_SCRIPT"
  fi
}

# rollback [COMMIT] on a hub or an exit: the stable commit, or one of this checkout
cmd_rollback() {
  local c=${1:-} commit
  load_env
  if [[ $ROLE == control ]]; then
    control_rollback "$@"
    return
  fi
  [[ $ROLE == hub || $ROLE == exit ]] || die "./vpn.sh rollback is for hubs and exits"
  commit=${c:-$(cat "$STABLE_FILE" 2>/dev/null || true)}
  [[ -n $commit ]] || die "control hasn't named a stable commit here: $(vsh rollback) COMMIT, or ./vpn.sh control stable COMMIT there"
  commit=$(git_here rev-parse -q --verify "$commit^{commit}") ||
    die "${c:-the stable commit} isn't in this checkout (./vpn.sh $ROLE update repo COMMIT needs GitHub)"
  git_here grep -q STABLE_SCRIPT "$commit" -- lib/remote.sh ||
    warn "${commit:0:12} is older than rollbacks: if control has an order for this server, it goes forward again (./vpn.sh control $ROLE update NAME -)"
  echo "Back from $(git_here log -1 --format='%h %s' HEAD | cut -c1-70)"
  echo "       to $(git_here log -1 --format='%h %s' "$commit" | cut -c1-70)"
  echo "Containers whose config changes will be restarted: VPN connections drop for a few seconds."
  ask "Go back?" n || return 0
  exec sh -c "$(rollback_script "$commit")"
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
  server_status update "$(cat "$UPDATE_STATE")"
}

# Parts of check that fail now (but update itself)
update_fails() { ./vpn.sh check 2>&1 | awk '$1 != "update" && $2 ~ /^FAIL/ {print $1}' | sort -u || true; }

# update_run ORDER ({commit, at} or nothing): be at that commit
update_run() {
  local order=$1 want key at back head url=${REPO_URL:-$DEFAULT_REPO_URL} branch=${REPO_BRANCH:-$DEFAULT_REPO_BRANCH} before broke fetched=true
  head=$(git_here rev-parse -q --verify HEAD 2>/dev/null || echo none)
  if [[ -z $order ]]; then
    rm -f "$UPDATE_HOLD"
    update_state "" "$head" "no order"
    return 0
  fi
  want=$(jq -r .commit <<<"$order")
  at=$(jq -r .at <<<"$order")
  back=$(jq -r '.back // false' <<<"$order")
  key="$want $at"
  [[ $want =~ ^[0-9a-f]{40}$ ]] || { update_state "$want" "$head" "FAIL: control ordered a bad commit: $want"; return 0; }
  if [[ $want == "$head" ]]; then
    rm -f "$UPDATE_HOLD"
    update_state "$want" "$head" ok
    return 0
  fi
  # Sent back by hand: what control ordered before that isn't wanted any more
  if [[ -s $UPDATE_HOLD ]]; then
    if ((at <= $(<"$UPDATE_HOLD"))); then
      update_state "$want" "$head" "FAIL: rolled back by hand to ${head:0:12}; a new order from control lifts this"
      return 0
    fi
    rm -f "$UPDATE_HOLD"
  fi
  # Tried and went back: again only when control orders it again
  [[ $key != "$(jq -r '.failed // empty' "$UPDATE_STATE" 2>/dev/null)" ]] || return 0

  git_here fetch -q "$url" "$branch" 2>/dev/null || fetched=false
  # Going back doesn't need GitHub if the commit is here
  if ! $fetched && ! { [[ $back == true ]] && git_here cat-file -e "$want^{commit}" 2>/dev/null; }; then
    update_state "$want" "$head" "FAIL: can't fetch $branch from $url (tries again)"
    return 0
  fi
  if $fetched && { ! git_here cat-file -e "$want^{commit}" 2>/dev/null || ! git_here merge-base --is-ancestor "$want" FETCH_HEAD; }; then
    update_state "$want" "$head" "FAIL: ${want:0:12} isn't on $branch of $url" "$key"
    return 0
  fi
  if [[ $head != none ]] && ! git_here merge-base --is-ancestor "$head" "$want"; then
    if [[ $back != true ]]; then
      update_state "$want" "$head" "FAIL: ${want:0:12} is older than ${head:0:12} here (updates only go forward)" "$key"
      return 0
    fi
    # Control's key alone can't send this server to any old commit
    if ! git_here reflog --format=%H | grep -qx "$want"; then
      update_state "$want" "$head" "FAIL: ${want:0:12} never ran here, so no going back to it by order: ./vpn.sh $ROLE rollback $want" "$key"
      return 0
    fi
    info "control orders back to ${want:0:12}, this $ROLE runs ${head:0:12}"
    exec 9>&-
    ./vpn.sh -y update repo "$want" || warn "update repo $want failed"
    sleep "$UPDATE_SETTLE"
    broke=$(update_fails | paste -sd' ')
    if [[ $(git_here rev-parse HEAD) != "$want" ]]; then
      update_state "$want" "$(git_here rev-parse HEAD)" "FAIL: couldn't go back to ${want:0:12}: sh $STABLE_SCRIPT here" "$key"
    elif [[ -n $broke ]]; then
      # stays: it's where control said to be, and there's nowhere better
      update_state "$want" "$want" "FAIL: back at ${want:0:12} as ordered, but check fails at: $broke"
    else
      update_state "$want" "$want" ok
      info "back at ${want:0:12}, as control ordered"
    fi
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

# The code this server runs, for people and for the status control reads; uses report
check_code() {
  local c
  c=$(git_here rev-parse -q --verify HEAD 2>/dev/null || echo unknown)
  report code "ok (${c:0:12}, sing-box ${SINGBOX_IMAGE##*:})"
  server_status code "$(jq -cn --arg c "$c" '$c')"
  server_status sing_box "$(jq -cn --arg s "${SINGBOX_IMAGE##*:}" '$s')"
}

# Can this server go back to what control calls stable? uses report
check_stable() {
  local c
  [[ -s $STABLE_FILE ]] || return 0
  c=$(<"$STABLE_FILE")
  if [[ -s $STABLE_SCRIPT ]] && git_here cat-file -e "$c^{commit}" 2>/dev/null; then
    report stable "ok (${c:0:12} is here: ./vpn.sh $ROLE rollback)"
  else
    report stable "FAIL: control names ${c:0:12} as stable, it isn't here and can't be fetched: no going back to it"
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
