# Identity and DNS boundaries

This document describes the public architecture of the FreeIPA bootstrap and its DNS provider boundary. It is a
composition guide, not a deployment topology. Names and addresses below are documentation placeholders only.

## Identity topology

The bootstrap has two FreeIPA roles:

- A **primary** is created with the supported `ipa-server-install` path.
- A **replica** is added with the supported `ipa-replica-install` path and an explicitly chosen source server.

The bootstrap validates the host, realm, source reachability, time prerequisites, and command options before invoking
the installer. It records the role after a successful new installation and refuses to guess when an existing server's
role cannot be established safely. A healthy existing installation is validated rather than reinstalled.

The identity layer includes the directory service, Kerberos, the FreeIPA web and command-line interfaces, and the
optional integrated Dogtag CA. KRA is a separate opt-in operation and is available only when the FreeIPA CA is enabled.
The bootstrap does not create users, groups, HBAC or sudo rules, host groups, application principals, trust
relationships, certificate profiles, password policy, or application configuration.

```text
  ipa-primary.example.invalid  <---- FreeIPA replication ---->  ipa-replica.example.invalid
          |                                                        |
          +---- identity and service records --------------------+
```

For a replica, `IPA_REPLICA_SOURCE`, `IPA_REPLICA_PRINCIPAL`, and `IPA_ADMIN_PASSWORD` are supplied by the caller.
The source is a DNS name or address that the caller controls; no source identity is inferred from a private inventory.
Use an address such as `192.0.2.10` or a name under `example.invalid` in documentation and fixtures.

## DNS selector and provider contract

The canonical selector is `DNS_BACKEND`:

| Backend | Authority model | Update or transfer security | Boundary |
| --- | --- | --- | --- |
| `integrated` | FreeIPA primary/replica replication; not a conventional AXFR secondary | FreeIPA CLI/Kerberos/GSS-TSIG path; insecure update mode is rejected | FreeIPA LDAP-integrated DNS |
| `bind9_webmin` | BIND master/slave with AXFR/IXFR and optional NOTIFY | TSIG `update-policy` or an explicit ACL according to the selected policy | Native BIND configuration and marked managed includes; Webmin is an administration surface |
| `technitium` | Technitium Primary/Secondary zones | API-configured AXFR/IXFR/NOTIFY with TSIG policy and source-network ACLs | Official Technitium API and installer |
| `existing` | An external DNS service is administered elsewhere | Controlled outside this component | Read-only prerequisite and result validation |

`IPA_DNS_MODE` and `DNS_PROVIDER` remain compatibility inputs, but the bootstrap normalises them to the canonical
backend. Use one selector in a new environment. `SERVER_FQDN` and `MANAGE_HOSTNAME` are the canonical hostname inputs;
the older hostname names remain compatibility aliases.

All providers expose the same conceptual operations: preflight, installation, configuration, forwarders, forward and
reverse zones, records, prerequisite validation, final validation, FreeIPA system-record synchronisation, and
uninstall handling. Provider-specific actions stay behind `dns/provider.sh`; the FreeIPA orchestration layer does not
embed BIND or Technitium implementation details.

## Integrated DNS

Integrated mode delegates DNS setup to the supported FreeIPA installer. Each configured forwarder is passed as its own
`--forwarder` option. Reverse auto-discovery is disabled and only the server IPv4 `/24` reverse zone and its PTR are
created after installation. An explicitly empty forwarder list remains empty; the bootstrap does not invent a resolver
list.

FreeIPA replication and DNS authority are related but not interchangeable. A FreeIPA replica is not automatically a
conventional BIND or Technitium secondary, and a DNS secondary does not imply a FreeIPA replica.

## Managed external DNS

With an external provider the bootstrap installs FreeIPA without integrated DNS. Before installation it validates only
the server A record and explicitly configured authoritative reverse-zone PTR prerequisites. After the installer has
provided its version-specific system-record set, the selected provider can reconcile those records. Delete directives
are not replayed against records outside the managed contract.

For BIND:

- A primary manages marked forward and reverse zones, restricted AXFR/IXFR, optional NOTIFY, and the configured TSIG
  or ACL update policy.
- A secondary declares `type slave` zones, uses the configured primary and `masters` key, stores transferred data in
  the configured slave directory, and does not edit transferred slave files.
- Webmin is installed or validated through its official repository path when that provider is selected. It does not
  replace native BIND configuration or initialise an undocumented cluster file.

For Technitium:

- Primary and Secondary zones are reconciled through the official HTTP API rather than by editing service files.
- API calls preserve unrelated settings and refuse an unsafe zone-type conversion or deletion.
- Transfer keys and source-network rules are explicit. TSIG policy is not the same as FreeIPA GSS-TSIG/Kerberos.

For `existing`, the bootstrap never creates, edits, or removes external records. It writes a prerequisite plan before
installation, preserves the installer-generated system-record output after success, and reports a pending DNS state
until an authorised operator publishes the records and reruns the read-only check.

## Address changes and DNS ownership

The FreeIPA component includes an address-update path for supported backends. The safe sequence is:

```text
read-only check -> dry-run with the new address -> authoritative update -> validation
```

The path edits only records in its managed contract, preserves the hostname and FreeIPA LDAP/Kerberos state, updates
the local configuration input, waits for configured secondary convergence where applicable, and attempts a backend-aware
rollback on failure. It refuses to run on a DNS secondary or on the read-only `existing` backend. An operating-system
interface migration is a separate change.

The separate `dns_update` Ansible role provides a provider-neutral A/PTR contract for callers that already know the
authoritative server and zone. Every record declares its own zone; the role never discovers a zone or nameserver. It
inspects with `dig` first and delegates writes to `community.general.nsupdate` when both `dns_update_enabled` and
`dns_update_manage` are enabled. GSS-TSIG is the secure default, standard TSIG is optional, and unsigned mode is
test-only and requires an explicit opt-in. A matching value is a no-op, while a conflicting PTR is reported and left
untouched by default.

The role is independent of FreeIPA, MariaDB, MaxScale, and VRRP. The pinned example uses `community.general` 13.0.0;
the role's contract, syntax, `yamllint`, and `ansible-lint` checks pass. Live target validation remains required: a
local run was blocked before DNS by a Python 3.14 controller RPC incompatibility, so no live DNS deployment outcome is
claimed.

## Boundary checklist

Before composing identity and DNS, confirm:

- the host operating system and architecture are allowlisted for the FreeIPA component;
- the primary/replica role and realm are deliberate and recorded;
- the DNS backend and zone authority are unambiguous;
- forwarders, authoritative reverse zones, transfer keys, and source ACLs come from an approved external policy;
- external DNS is published or explicitly marked pending before relying on the FreeIPA service records; and
- runtime checks such as `ipa server-show`, `ipa topologysegment-find`, `named-checkconf`, `named-checkzone`, `dig`, or
  the provider API are run on a disposable supported host before a real change.

The bootstrap provides infrastructure primitives and validation. It does not decide who may administer the realm,
which applications trust it, or which DNS service is authoritative for a caller's domain.
