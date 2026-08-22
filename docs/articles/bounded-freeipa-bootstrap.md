# Building a bounded FreeIPA bootstrap with an explicit DNS contract

> Article draft — Infrastructure Engineering Toolkit

Infrastructure bootstraps become difficult to operate when they hide foundational choices behind a single successful
command. A FreeIPA deployment has several of those choices: realm and hostname, primary or replica role, CA mode, DNS
authority, and the handling of an existing installation. A safer bootstrap makes each choice explicit, checks the host
before changing it, and keeps provider-specific DNS work behind a small interface.

## Start with the identity boundary

The bootstrap has one path for a primary and another for a replica. A primary uses the platform's supported
`ipa-server-install` flow. A replica uses `ipa-replica-install` with a caller-supplied source, principal, and
administrator credential. The implementation checks the target distribution, major release, architecture, hostname,
realm, reachability, time prerequisites, and installer option surface before invoking either command.

This distinction matters operationally. A healthy FreeIPA server should not be converted by a rerun that happens to use
a different role variable. When an existing server's role cannot be established safely, stopping is safer than guessing.
The bootstrap records the role after a successful new installation so later runs can validate the same decision.

The same boundary applies to the CA. Integrated Dogtag is the default for a new installation, while CA-less mode accepts
external LDAP and HTTP certificate files. An existing integrated CA is detected rather than installed again. Optional
KRA installation is separate and requires the integrated CA. Users, groups, policies, trusts, application principals,
and certificate profiles remain outside the infrastructure bootstrap.

## Treat DNS as a provider contract

DNS is not one implementation hidden in the FreeIPA installer. The public selector supports integrated FreeIPA DNS,
managed BIND with Webmin, Technitium, and an existing external service. Each provider implements the same conceptual
operations: preflight, installation, configuration, forwarders, zones, records, prerequisite validation, final
validation, and system-record synchronisation.

The provider boundary allows the FreeIPA orchestration code to remain about identity while the provider code handles its
own authority model. Integrated DNS uses FreeIPA replication and is not a conventional AXFR secondary. BIND and
Technitium can run primary/secondary zones with explicit transfer security. Existing DNS is read-only: the bootstrap
can produce a prerequisite plan and preserve the installer's system-record output, but it cannot publish records on a
service it does not own.

This model also clarifies what “success” means. A FreeIPA installer can complete while an external DNS publication is
still pending. Reporting that state explicitly gives an operator a safe next action: publish the preserved records
through the authorised DNS process and rerun the read-only check.

## Make the safe path the default path

The bootstrap exposes two non-mutating modes:

```bash
./install.sh --check
./install.sh --dry-run
```

The first performs read-only preflight and provider validation. The second validates and prints planned packages,
files, services, DNS zones and records, firewall behaviour, and the selected FreeIPA mode. Normal runs redact known
credential arguments and write structured state and logs, while preserving the boundary that the underlying installer
may briefly expose password arguments in a process list.

Existing healthy state is validated rather than reinstalled. A partial installation that predates the current run stops;
automatic uninstall and retry is limited to partial state created by the same run. This is a deliberately narrow recovery
rule because automatic cleanup cannot know which resources belong to an earlier administrator.

## Design for address changes as transactions

An address change is different from a realm change. The bootstrap's address-update path therefore checks first, renders a
dry-run, changes only managed A/PTR records on an authoritative provider, updates the shared configuration input, and
validates before activation. Where the backend supports it, the path waits for secondary convergence and attempts a
backend-aware rollback if a later step fails. It preserves the hostname and FreeIPA LDAP/Kerberos state and refuses to
operate on a DNS secondary or a read-only existing provider.

The path does not migrate an operating-system interface. That remains a separate, reviewable network change. Keeping
these actions separate prevents a DNS record update from silently becoming a host-network reconfiguration.

## Know what the bootstrap cannot prove

Shell tests and syntax checks can exercise argument construction, input validation, redaction, provider selection, and
record helpers. They cannot prove that a target's package repositories, SELinux policy, BIND daemon, Webmin listener,
Technitium API, chrony, or systemd state will behave as expected. Runtime checks must therefore run on a disposable
supported host with approved DNS and time prerequisites.

The result is a useful infrastructure primitive rather than an end-to-end identity platform. It establishes the
foundational service and gives the operator clear evidence about what remains outside the automation: identity policy,
application integration, backup and restore, and external DNS ownership.

## Conclusion

A trustworthy bootstrap is explicit about authority. It distinguishes primary from replica, integrated from external
DNS, new from existing state, and host address changes from identity changes. The implementation becomes easier to test
because each provider has a contract, and safer to operate because a pending or unsupported state is reported instead
of being silently repaired.
