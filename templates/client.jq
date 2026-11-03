# sing-box config of ROLE=client: a local proxy through the hubs of the subscription.
# Inputs: $sub[0] = {outbounds: [vless / hysteria2 of every hub]}, $test_url (RU: answered by the hub),
#   $protocol = auto (the fastest of all), reality or hy2 (the fastest hub on it)
def chosen: $sub[0].outbounds | map(select($protocol == "auto"
  or (.type == "vless" and $protocol == "reality") or (.type == "hysteria2" and $protocol == "hy2")));
{
  log: {level: "warn"},
  dns: {servers: [{type: "local", tag: "local"}]},
  inbounds: [{
    type: "mixed",
    tag: "proxy",
    listen: $ENV.CLIENT_LISTEN_HOST,
    listen_port: ($ENV.CLIENT_LISTEN_PORT | tonumber)
  }],
  outbounds: ([{
    type: "urltest",
    tag: "auto",
    outbounds: [chosen[].tag],
    url: $test_url,
    interval: "3m"
  }] + chosen + [{type: "direct", tag: "direct"}]),
  route: {
    default_domain_resolver: "local",
    rules: [{ip_is_private: true, outbound: "direct"}],
    final: "auto"
  }
}
