# Changelog

All notable changes to the FreeIPA Server Bootstrap project are documented in
this file. The repository has no earlier version history, so no historical
releases are inferred here.

## [0.1.0] - Unreleased

This is the initial pre-1.0 project baseline.

### Added

- FreeIPA primary and replica installation with role-aware validation.
- FreeIPA integrated DNS with generated reverse-zone records.
- External BIND9 and Webmin integration with native and managed-include layouts.
- Technitium DNS integration through the documented installer and HTTP API.
- Independent DNS primary/secondary roles and multi-node topology support.
- DNS redundancy with AXFR/IXFR, TSIG, NOTIFY, and `also-notify` controls.
- Secure DDNS for BIND and Technitium, plus explicitly restricted insecure DDNS
  where the selected backend supports it.
- DNS ACLs, transfer controls, source-network restrictions, and record
  reconciliation for FreeIPA system records.
- Automatic feature-aware firewall convergence for active UFW or firewalld
  installations.
- Managed hostname handling and transactional server-IP update functionality.
- Primary and secondary environment templates for repeatable deployment.

### Documentation

- Standalone installation, DNS, topology, validation, recovery, and security
  documentation suitable for the project Wiki/Confluence workflow.
- A canonical project version, version policy, and a single documentation lint
  entry point.
