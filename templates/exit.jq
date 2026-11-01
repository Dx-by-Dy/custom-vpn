# sing-box config for ROLE=exit. `vpn.sh render` runs it as a jq program with
# the variables from .env in $ENV and:
#   $hubs      one credential per hub and egress IP: {name: "hub@ip", uuid, ip}
#   $ips       egress IPs (EXIT_IPS)
#   $host_ips  this host's own addresses (/32, /128)
# Traffic leaves only through the egress IP of the credential it came with;
# there is no default route.
{
  log: {level: "warn"},
  dns: {servers: [{type: "https", tag: "doh", server: "1.1.1.1"}]},
  inbounds: [
    {
      type: "vless",
      tag: "vless-in",
      listen: "::",
      listen_port: ($ENV.VLESS_PORT | tonumber),
      users: [$hubs[] | {name, uuid, flow: "xtls-rprx-vision"}],
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
    },
    # `vpn.sh check` fetches its public IP through each egress IP: user "check@ip"
    {
      type: "socks",
      tag: "check-in",
      listen: "127.0.0.1",
      listen_port: ($ENV.CHECK_PORT | tonumber),
      users: [$ips[] | {username: "check@\(.)", password: $ENV.CHECK_TOKEN}]
    }
  ],
  outbounds: [$ips[] | {type: "direct", tag: "ip-\(.)", inet4_bind_address: .}],
  route: {
    default_domain_resolver: "doh",
    rules: ([
      {action: "sniff"},
      {protocol: "bittorrent", action: "reject"},
      # Egress IPs are IPv4: names resolve to IPv4 only and IPv6 destinations are
      # dropped, otherwise they would leave from another address of the host
      {action: "resolve", strategy: "ipv4_only"},
      {ip_cidr: ["::/0"], action: "reject"},
      {ip_is_private: true, action: "reject"}
    ]
    + if $host_ips == [] then [] else [{ip_cidr: $host_ips, action: "reject"}] end
    + [$ips[] as $ip | {
        auth_user: ([$hubs[] | select(.ip == $ip) | .name] + ["check@\($ip)"]),
        outbound: "ip-\($ip)"
      }]
    + [{action: "reject"}])
  }
}
