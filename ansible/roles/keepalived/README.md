# Generic Keepalived role

This role reconciles a Keepalived installation and one or more independent
VRRP instances. It is deliberately unaware of databases, proxies, DNS, and
application-specific health semantics. Callers provide VRRP instances and,
when required, paths to externally managed health-check programs through
`keepalived_vrrp_instances`.

## Public interface

The following values are illustrative only. The addresses belong to the
documentation range `192.0.2.0/24` and must be replaced with values approved
for the caller's network. Authentication is disabled by default; if it is
enabled, provide the secret from an external secret store rather than storing
it in this repository.

```yaml
keepalived_enabled: true
keepalived_script_user: ha-health
keepalived_script_group: ha-health
keepalived_peer_inventory_group: ha_nodes
keepalived_vrrp_instances:
  - name: virtual_router_a
    state: BACKUP
    interface: ens3
    virtual_router_id: 42
    priority: 100
    advert_int: 1
    mode: unicast
    unicast_src_ip: 192.0.2.10
    unicast_peers:
      - 192.0.2.11
    auth_type: NONE
    virtual_ip_addresses:
      - address: 192.0.2.20
        prefix: 24
```

`virtual_router_id` values must be unique within the configured Keepalived
file. `keepalived_sync_groups` is empty by default, so independent instances
remain independent unless a caller explicitly supplies a sync group.

The role can derive unicast peers from `keepalived_peer_inventory_group` or
accept explicit per-instance `unicast_peers`. A caller may set
`keepalived_script_user_manage: false` to reuse an existing service account.
The role does not create health-check programs or credentials; it only
references paths supplied in an instance definition.

For an existing host, `keepalived_existing_deployment_mode: auto` detects an
already configured and running service and makes the role validation-only by
default. Set `keepalived_existing_deployment_reconcile_enabled: true` only
for a planned, serial maintenance reconciliation. This guard prevents a
normal playbook run from rewriting a healthy Keepalived configuration or
reloading the daemon merely because this role is present.

## Existing deployments and idempotency

The role installs packages only when requested, validates the rendered file
with the installed Keepalived binary, and reloads the daemon only when the
configuration changes. It does not claim a virtual IP to test a run and does
not force failover. Running it with unchanged inputs is intended to produce no
configuration changes.

Firewall changes are opt-in (`keepalived_firewall_enabled: false` by default)
and require an inspectable UFW installation. The role only manages generic
VRRP protocol rules; it does not infer network policy.

## Scope and security

The role intentionally does not manage DNS, certificates, database state,
proxy users, or application health logic. Health-check programs run under the
configured least-privilege account when their paths are supplied by the
caller. Authentication secrets and any supplied script material should be
provided through an external secret-management workflow.
