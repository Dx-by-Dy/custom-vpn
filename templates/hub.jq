# sing-box config. `vpn.sh render` runs it as a jq program with the variables
# from .env in $ENV and:
#   $users     every valid credential: {name, uuid, hy2}; rotated-out ones are
#              named "name~expires", hy2 is "hysteria_user:hysteria_pass"
#   $host_ips  this host's own addresses (/32, /128)
#   $hy2       false until caddy has the certificate (VLESS works without it)
{
  log: {level: "warn"},
  dns: {servers: [{type: "https", tag: "doh", server: "1.1.1.1"}]},
  inbounds: ([
    {
      type: "vless",
      tag: "vless-in",
      listen: "::",
      listen_port: ($ENV.VLESS_PORT | tonumber),
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
  ] else [] end),
  outbounds: [{type: "direct", tag: "direct"}],
  route: {
    default_domain_resolver: "doh",
    rules: ([
      {action: "sniff"},
      {protocol: "bittorrent", action: "reject"},
      # Resolve before the IP rules, so names that point at private networks
      # or at this host (localtest.me -> 127.0.0.1) are blocked too
      {action: "resolve"},
      {ip_is_private: true, action: "reject"}
    ] + if $host_ips == [] then [] else [{ip_cidr: $host_ips, action: "reject"}] end),
    final: "direct"
  }
}
