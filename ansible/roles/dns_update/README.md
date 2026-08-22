# `dns_update` role

This role independently inspects and, when explicitly enabled, reconciles
caller-supplied DNS `A` and `PTR` records. It is deliberately separate from
database, proxy, failover, certificate, and host-configuration roles. A DNS
failure is reported per record and does not block unrelated work unless the
caller opts into a hard failure policy.

The role delegates DDNS writes to the official
[`community.general.nsupdate`](https://docs.ansible.com/ansible/latest/collections/community/general/nsupdate_module.html)
module. It does not vendor a collection, reimplement DNS update messages, or
wrap update commands in a shell script.

## Safe defaults

The defaults are read-only:

```yaml
dns_update_enabled: false
dns_update_manage: false
dns_update_auth_mode: gss-tsig
dns_update_allow_insecure: false
dns_update_conflict_policy: report
dns_update_fail_on_error: false
```

Set both `dns_update_enabled` and `dns_update_manage` to `true` only after
the update server, ACL, zone ownership, and authentication path have been
approved. A server is required for every managed record, either through the
global `dns_update_server` default or an individual record override.

Every record must include a non-empty `zone`, including a reverse zone for a
PTR record. The role never infers a zone from the record name or address and
does not discover authoritative servers. This prevents an omitted reverse
zone from silently targeting an unintended update authority.

## Record interface

```yaml
dns_update_server: ns1.example.invalid
dns_update_records:
  - name: app.example.invalid.
    type: A
    value: 198.51.100.20
    zone: example.invalid.
    state: present
  - name: 20.100.51.198.in-addr.arpa.
    type: PTR
    value: app.example.invalid.
    zone: 100.51.198.in-addr.arpa.
    state: present
```

Supported record fields are `name`, `type` (`A` or `PTR`), `value`,
`zone`, and `state` (`present` or `absent`). A present PTR has exactly one
target. `server`, `port`, `protocol`, `timeout`, and `ttl` may be overridden
per record. Values are inspected first; a matching value set is a no-op.

The read-only inspection uses `dig` with an argument vector and never invokes
the update module. A failed lookup is retained in the per-record result so
that it cannot be mistaken for proof that an existing record is absent.

## Authentication

GSS-TSIG is the secure default. The role creates a private temporary
Kerberos credential cache, obtains a ticket using `kinit` with the password on
standard input, and passes the isolated cache to `nsupdate`. The cache is
removed after the record operation. Supply credentials only from an external
runtime secret mechanism:

```yaml
dns_update_auth_mode: gss-tsig
dns_update_kerberos_principal: "{{ runtime_kerberos_principal }}"
dns_update_kerberos_password: "{{ runtime_kerberos_password }}"
```

Standard TSIG is also supported. The key name, secret, and algorithm are
passed directly to `nsupdate`; the secret is protected with `no_log`:

```yaml
dns_update_auth_mode: tsig
dns_update_key_name: "{{ runtime_tsig_name }}"
dns_update_key_secret: "{{ runtime_tsig_secret }}"
dns_update_key_algorithm: hmac-sha256
```

Supported algorithms are `hmac-md5`, `hmac-sha1`, `hmac-sha224`,
`hmac-sha256`, `hmac-sha384`, `hmac-sha512`, and
`HMAC-MD5.SIG-ALG.REG.INT`. Prefer a modern HMAC algorithm and keep the
secret outside source control.

Unsigned mode is intentionally disabled by default. It can be selected only
as an explicitly labelled test-only path by setting both
`dns_update_auth_mode: insecure` and `dns_update_allow_insecure: true`; it
must not be used for a production update authority. `none` is accepted only
as a compatibility alias and is subject to the same opt-in guard.

## Failure and conflict policy

Each record is inspected and classified independently:

* a matching value set is reported as `unchanged` and is not sent to
  `nsupdate`;
* an existing, different PTR is reported as `conflict` and is left untouched
  when `dns_update_conflict_policy: report` (the default);
* `replace` permits a PTR replacement only when the caller has explicitly
  established ownership of the complete managed zone; and
* update, dependency, lookup, or authentication errors are reported and do
  not fail the play by default. Set `dns_update_fail_on_error: true` when a
  managed update is a hard prerequisite.

Ansible check mode performs read-only inspection and reports what would be
changed. It never obtains a Kerberos ticket or invokes `nsupdate`. The role
uses `no_log` for assertions, temporary credential handling, and module calls
that can contain authentication material.

## Dependency

The role requires the `community.general` collection and its target-side
`dnspython` dependency. GSS-TSIG additionally requires `gssapi` and a working
Kerberos client. The collection is not bundled here. Install the pinned
version from the example requirements file:

```bash
ansible-galaxy collection install \
  --requirements-file examples/dns-update/requirements.yml \
  --collections-path ./collections
```

Runtime package installation is disabled by default. If enabled, callers
must supply platform-specific package names in
`dns_update_runtime_packages`; the role does not guess them.
