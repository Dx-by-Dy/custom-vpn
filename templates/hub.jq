# sing-box config for ROLE=hub. `vpn.sh render` runs it as a jq program with
# the variables from .env in $ENV and:
#   $users      every valid credential: {name, uuid, hy2, route}; rotated-out
#               ones are named "name~expires", hy2 is "hysteria_user:hysteria_pass",
#               route is local, none or the name of one of $routes
#   $routes     routes through exits: {name: "EXIT/IPNAME", ip, uuid, server,
#               port, sni, public_key, short_id}
#   $rule_sets  RU lists in /rule-sets that are there: geosite-ru, geoip-ru
#   $host_ips   this host's own addresses (/32, /128)
#   $hy2        false until caddy has the certificate (VLESS works without it)
#   $sites      exceptions by name: {hub: [domains that count as RU],
#               route: [domains that don't, whatever the lists say]}
# RU leaves from the hub; everything else through the user's route, and nowhere
# if it has none. A key of a route "EXIT/IP+ru" sends everything through the
# exit, RU and the exceptions too.

# RU: by name, and by IP for connections made to an IP
def ru_lists: {domain_suffix: (["ru", "su", "xn--p1ai"] + $sites.hub)} + if $rule_sets == [] then {} else {rule_set: $rule_sets} end;
def ru: if $sites.route == [] then ru_lists else
  {type: "logical", mode: "and", rules: [{domain_suffix: $sites.route, invert: true}, ru_lists]} end;
# Addresses nobody may reach through this hub
def guard: [{ip_is_private: true, action: "reject"}]
  + if $host_ips == [] then [] else [{ip_cidr: $host_ips, action: "reject"}] end;
# Who uses route R: its users and the `check` user of the route
def members($r): [$users[] | select(.route == $r) | .name] + ["check@\($r)"];
{
  log: {level: "warn"},
  dns: {servers: [{type: "https", tag: "doh", server: "1.1.1.1"}]},
  # jq 1.7 (Ubuntu 24.04) needs an operator expression in parentheses as a value
  inbounds: (([
    {
      type: "vless",
      tag: "vless-in",
      listen: $ENV.VLESS_LISTEN_HOST,
      listen_port: ($ENV.VLESS_LISTEN_PORT | tonumber),
      users: [$users[] | {name, uuid, flow: "xtls-rprx-vision"}],
      tls: {
        enabled: true,
        server_name: $ENV.REALITY_SNI,
        reality: {
          enabled: true,
          handshake: {server: $ENV.REALITY_TARGET_HOST, server_port: ($ENV.REALITY_TARGET_PORT | tonumber)},
          private_key: $ENV.REALITY_PRIVATE_KEY,
          short_id: [$ENV.REALITY_SHORT_ID]
        }
      }
    }
  ] + if $hy2 then [
    {
      type: "hysteria2",
      tag: "hy2-in",
      listen: "::",
      listen_port: ($ENV.HYSTERIA_PORT | tonumber),
      # Clients send "user:password" (the format of the old hysteria server)
      users: [$users[] | {name, password: .hy2}],
      masquerade: {type: "proxy", url: $ENV.MASQUERADE_URL, rewrite_host: true},
      tls: {
        enabled: true,
        certificate_path: "\($ENV.CERT_DIR)/\($ENV.DOMAIN).crt",
        key_path: "\($ENV.CERT_DIR)/\($ENV.DOMAIN).key"
      }
    }
  ] else [] end) + [
    # `vpn.sh check` tries every route through here: user "check@ROUTE"
    {
      type: "socks",
      tag: "check-in",
      listen: "127.0.0.1",
      listen_port: ($ENV.CHECK_PORT | tonumber),
      users: [("local", "none", $routes[].name, ($routes[].name + "+ru")) | {username: "check@\(.)", password: $ENV.CHECK_TOKEN}]
    }
  ]),
  outbounds: ([{type: "direct", tag: "local"}] + [$routes[] | {
    type: "vless",
    tag: .name,
    server,
    server_port: .port,
    uuid,
    flow: "xtls-rprx-vision",
    packet_encoding: "xudp",
    tls: {
      enabled: true,
      server_name: .sni,
      utls: {enabled: true, fingerprint: "chrome"},
      reality: {enabled: true, public_key, short_id}
    }
  }]),
  route: {
    default_domain_resolver: "doh",
    rule_set: [$rule_sets[] | {type: "local", tag: ., format: "binary", path: "/rule-sets/\(.).srs"}],
    rules: ([
      {action: "sniff"},
      {protocol: "bittorrent", action: "reject"}
    ]
    + guard
    # Everything through the exit: before anything can count as RU
    + [$routes[].name as $r | {auth_user: members("\($r)+ru"), outbound: $r}]
    # What leaves from here is resolved here, so names that point at private
    # networks or at this host (localtest.me -> 127.0.0.1) are blocked too.
    # Traffic to exits keeps the name: after a resolve sing-box would send them
    # the IP, picked by DNS from here; they resolve it themselves.
    + [{type: "logical", mode: "or", rules: [ru, {auth_user: members("local")}], action: "resolve"}]
    + guard
    + [ru + {outbound: "local"}]
    + [("local", $routes[].name) as $r | {auth_user: members($r), outbound: $r}]
    # Route none, routes that don't exist: nothing leaves
    + [{action: "reject"}])
  }
}
