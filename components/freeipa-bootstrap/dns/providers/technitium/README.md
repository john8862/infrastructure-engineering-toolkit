# Technitium DNS provider

The bootstrap manages Technitium through its documented HTTP API. It does not
edit the Technitium database or undocumented files.

Supported operations include:

- the official Linux installer with mandatory SHA-256 pinning;
- Primary and Secondary forward/reverse zones;
- native AXFR/IXFR/NOTIFY configuration through the API;
- TSIG transfer authentication and RFC 2136 update security policies;
- explicit insecure RFC 2136 updates restricted by `TECHNITIUM_UPDATE_NETWORKS`
  (normally inherited from `DNS_DYNAMIC_UPDATE_NETWORKS`);
- idempotent A/AAAA/CNAME/PTR/SRV/TXT/URI record reconciliation and validation.

Technitium secure DDNS is TSIG policy plus an explicit source-network ACL. It
is not FreeIPA GSS-TSIG/Kerberos, so `DNS_DYNAMIC_UPDATE_MODE=secure` on this
backend must not be described as equivalent to FreeIPA integrated DNS secure
updates. A secondary never edits transferred records locally.

The project version is maintained once in the repository root
[`VERSION`](../../../VERSION) and is shown by `../../../install.sh --version`.
It is not the Technitium DNS Server runtime version. Technitium is installed
from `TECHNITIUM_INSTALLER_URL` (the official installer by default), with
mandatory `TECHNITIUM_INSTALLER_SHA256` integrity pinning. The installer does
not hard-code a Technitium release number.

Use `TECHNITIUM_API_TOKEN` or a 0600 `TECHNITIUM_API_TOKEN_FILE` in production.
When a token is not supplied, the provider uses the documented login API and
prompts for `TECHNITIUM_API_PASSWORD` without writing it to logs. API
connections require HTTPS and TLS certificate verification; provide
`TECHNITIUM_API_CA_FILE` for a private CA. Plain HTTP and verification
disablement are rejected.

## Automatic host-firewall integration

Firewall convergence is automatic; there is no Technitium firewall enable/disable
switch. When `DNS_BACKEND=technitium` and a supported host firewall is already
active, the bootstrap configures only the missing rules. It supports active
firewalld and active UFW. An installed-but-inactive firewall is reported and is
left inactive. The bootstrap never enables, disables, resets, or changes the
default policy of a firewall.

The port plan is derived from the installed server's `/api/settings/get` response
and, when available on Linux, checked against non-loopback listeners reported by
`ss -lntup`. The documented defaults below are a reference only; configured
ports are used at runtime.

| Function | Default port | Open condition |
| --- | --- | --- |
| DNS | UDP 53 | Technitium DNS service; always required for the selected backend |
| DNS | TCP 53 | Technitium DNS service; required for TCP queries and AXFR/IXFR/NOTIFY |
| Web HTTP | TCP 5380 | Web Console HTTP is configured on a non-loopback address |
| Web HTTPS | TCP 53443 | Web Console TLS is enabled externally, or cluster mode requires the Web HTTPS endpoint |
| Web HTTP/3 | UDP 53443 | Web Console HTTP/3 is enabled externally |
| DoT | TCP 853 | DNS-over-TLS is enabled and externally listening |
| DoQ | UDP 853 | DNS-over-QUIC is enabled and externally listening |
| DoH | TCP 443 | DNS-over-HTTPS is enabled and not restricted to a Unix socket |
| DoH HTTP/3 | UDP 443 | DNS-over-HTTPS HTTP/3 is enabled and externally listening |
| DNS-over-HTTP | TCP 80 | DNS-over-HTTP is enabled and not restricted to a Unix socket |
| DHCP | UDP 67 | At least one Technitium DHCP scope is enabled; installation alone does not open it |

The API settings determine both the feature flags and configured ports. Enabled
DHCP scopes are read from the documented `/api/dhcp/scopes/list` response. A Web
Console bound only to `127.0.0.1`/`::1` is not opened. If the configured Web or
encrypted-DNS listener is not externally visible to `ss` on a Linux host, its
optional firewall rule is not added. The base DNS rules remain distinct from
the optional management and encrypted-DNS rules.

For a primary/secondary or three-node topology, TCP/UDP 53 is the DNS path used
for ordinary queries and conventional AXFR/IXFR/NOTIFY. No arbitrary transfer
port is invented. If `TECHNITIUM_ZONE_TRANSFER_PROTOCOL=Tls`, the configured
Technitium `dnsOverTlsPort` (normally TCP 853) is source-restricted to topology
peers; if it is `Quic`, the configured `dnsOverQuicPort` (normally UDP 853) is
source-restricted to topology peers. The Technitium zone/API ACL remains the
authoritative transfer restriction. Cluster
mode does not require a separate undocumented cluster port: the supported
cluster node URL uses the Web HTTPS endpoint, so the configured Web TLS port is
the port converged when `clusterInitialized=true`.

To restrict client-facing DNS, set `TECHNITIUM_DNS_CLIENT_NETWORKS` to a
whitespace- or comma-separated list of trusted IPv4 networks. In that mode, DNS
53 is represented by source rules for those networks and for every entry in the
topology array (`DNS_PRIMARY_*`, `DNS_SECONDARY_*`, and
`DNS_ADDITIONAL_NODES=fqdn=ipv4 ...`). This keeps the primary, secondary, and
additional node paths available without hard-coded peer variables. Leave the
variable empty to use the existing firewall zone/interface policy for DNS.

UFW rules created for these source restrictions carry the
`freeipa-bootstrap-technitium` comment. firewalld source rules are tracked in
`$IPA_STATE_DIR/technitium-firewall.rules`. On rerun, only source rules recorded
by this bootstrap are eligible for removal when a feature or peer disappears;
administrator-created equivalent rules are preserved. A successful
`update-server-ip.sh --new-ip ...` reruns this same reconciliation when the
local Technitium primary's address changes, so a changed topology IP removes
only the old installer-managed peer rule and adds the new one.

The API fields and cluster behavior used by this integration are maintained in
the
[official Technitium API documentation](https://raw.githubusercontent.com/TechnitiumSoftware/DnsServer/master/APIDOCS.md).
Protocol support and the native XFR/DHCP feature set are described in the
[official Technitium README](https://raw.githubusercontent.com/TechnitiumSoftware/DnsServer/master/README.md).
The default Linux installation paths and service contract come from the
[official installer](https://github.com/TechnitiumSoftware/DnsServer/blob/master/DnsServerApp/install.sh)
and
[official systemd unit](https://raw.githubusercontent.com/TechnitiumSoftware/DnsServer/master/DnsServerApp/systemd.service).
