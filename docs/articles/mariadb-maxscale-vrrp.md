# Composing MariaDB replication, MaxScale, and VRRP without hidden coupling

> Article draft — Infrastructure Engineering Toolkit

High availability is not a single role. It is a sequence of independently verifiable decisions: how data is replicated,
how clients find a service, how a proxy selects a backend, and how an address moves between nodes. Treating each concern
as a separate contract makes failures easier to isolate and reduces the temptation to automate an unsafe assumption.

## Begin with a known database topology

The MariaDB baseline prepares each host but does not configure a relationship. The replication role then defines one
writable primary and one or more replicas. GTID with the replica-position model is the default; file/position mode is
available for a caller that has recorded coordinates from a consistent data copy.

The replication role checks server identity, binary logging, network reachability, account transport policy, data
inventory, storage engines, and checksums. It does not copy data, enable binary logging, change `server_id`, generate
certificates, or invent a safe position. A replica that fails its own checks is reported and isolated, while a primary
safety failure remains a failed run.

This boundary keeps the data-copy method and its restore record visible instead of burying them in a playbook that also
changes the replication channel.

## Place MaxScale above the channel

MaxScale consumes a data-only model of backend servers, monitor modules, services, routers, and listeners. Its public
role defaults to rendering and review. Repository, package, service, firewall, and health checks are explicit switches.
A managed reload follows candidate configuration validation, and an optional REST check can confirm service health after
the reload.

Credentials and TLS files come from external workflows. MaxScale does not create database or proxy accounts, manage
Binlog Router or Config Sync, change MariaDB state, claim a VIP, or infer DNS. A caller can review the database topology
first, render the proxy configuration second, and decide separately whether a listener should be exposed.

MaxScale software is not part of the repository. The automation is MIT-licensed, while MaxScale packages, repository
metadata, and legal terms remain subject to MariaDB's current terms. This distinction matters when a playbook enables
official-repository integration: it is an installation choice made by the caller, not redistribution by the role.

## Use VRRP only for address ownership

Keepalived describes independent VRRP instances and optional references to externally managed health programs. It does
not know whether a virtual IP fronts MaxScale, MariaDB, or another service. Existing running deployments are protected by
default: reconciliation requires an explicit maintenance switch, the rendered file is validated, and the role does not
claim the VIP merely to test a run.

If a caller wants the VIP to follow a MaxScale health decision, the caller must provide and review a separately managed
health program and reference its path. That program's exit contract, privileges, and failure policy are not inferred from
MaxScale variables. Generic VRRP firewall rules are opt-in and do not replace the environment's firewall policy.

## Let DNS name the selected edge

DNS is a naming and authority layer. A service name such as `db-writer.example.invalid` may point to a Keepalived VIP,
an address serving a MaxScale listener, or a controlled diagnostic endpoint. The DNS provider does not decide which node
is healthy and does not claim a VIP.

This separation makes an address change observable. An operator can validate VIP ownership, the MaxScale listener, backend
health, and the DNS record independently. A failed DNS update does not require changing replication state, and a failed
replication check does not justify publishing a new DNS address.

## A reviewable composition sequence

Use the following sequence as a starting point:

1. Prepare every database host with the MariaDB baseline and external TLS assets.
2. Record and verify the data copy, then configure replication with explicit GTID or file/position inputs.
3. Render MaxScale definitions with repository, package, service, firewall, and health changes disabled.
4. Validate the candidate configuration and, on an approved host, perform the smallest service change.
5. Render Keepalived with explicit peers, priority, interface, VIP, and health-script references.
6. Schedule serial VRRP maintenance for an existing deployment and verify the peer path without forcing failover.
7. Publish the DNS name only after the selected edge address and health checks are passing.

The sequence is not a bundled workflow. Each role remains independently runnable, and each stage has its own rollback
boundary.

## What the composition does not promise

The combined layers do not provide automatic data promotion, conflict-free multi-primary operation, application account
management, PKI enrolment, backup/restore, DNS policy, or a guarantee that a health script correctly models an
application. Those are separate operational decisions. The value of the composition is that each decision has a visible
owner and a validation point.

## Conclusion

High availability is easier to reason about when the data plane, proxy, address owner, and naming service do not pretend
to be one system. MariaDB establishes service state, replication establishes the data path, MaxScale establishes the
client path, Keepalived establishes address ownership, and DNS names the chosen edge. The caller decides how those pieces
fit together and can stop safely when any one contract is not satisfied.
