# DNS update example

This example runs the role in inspection mode. It uses only documentation
names and RFC 5737 documentation addresses; it does not contact a production
DNS service or contain credentials. `dns_update_manage` must remain `false`
until the caller has independently approved the authoritative server, zone,
ACL, record ownership, and authentication material.

Every record declares its own zone. In particular, the reverse zone is
written explicitly for the PTR record; the role never guesses a reverse zone
from an address and never discovers a zone through DNS.

The secure GSS-TSIG interface is the role default. A real Kerberos principal
and password must be supplied out-of-band only when an approved deployment
enables management. The alternative standard TSIG interface uses
`dns_update_key_name`, `dns_update_key_secret`, and
`dns_update_key_algorithm`; keep those values outside this repository. An
unsigned mode is test-only, disabled by default, and requires the explicit
`dns_update_allow_insecure: true` opt-in.

## Run the read-only example

Install the pinned collection into an isolated collections path, then run:

```bash
ansible-galaxy collection install \
  --requirements-file requirements.yml \
  --collections-path ./collections
ansible-playbook -i localhost, -c local site.yml
```

The command performs read-only `dig` queries. It does not install packages,
obtain Kerberos tickets, or call `community.general.nsupdate` because
`dns_update_manage` is false.

## Enabling a controlled update

Set `dns_update_manage: true` only in an external, access-controlled runtime
configuration. Keep `dns_update_server` and every record's `zone` explicit.
For GSS-TSIG, provide the principal and password through the runtime secret
mechanism used by the deployment platform. For standard TSIG, provide the
key name and secret through the same mechanism. Do not place either in this
example or commit them to source control.

The default failure policy reports update and authentication failures while
allowing unrelated roles to continue. Set `dns_update_fail_on_error: true`
only when DNS reconciliation is a hard prerequisite for that deployment.
The default PTR conflict policy is `report`, which leaves an existing,
different PTR untouched. `replace` is appropriate only when complete
ownership of the managed record has been established.
