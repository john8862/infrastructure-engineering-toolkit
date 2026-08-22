#!/usr/bin/env python3
"""Small dependency-free contract checks for the public DNS role."""

from pathlib import Path
import re


ROOT = Path(__file__).resolve().parents[2]
ROLE = ROOT / "ansible" / "roles" / "dns_update"
EXAMPLE = ROOT / "examples" / "dns-update"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def check(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def main() -> None:
    required_role_files = (
        "README.md",
        "argument_specs.yml",
        "defaults/main.yml",
        "handlers/main.yml",
        "meta/main.yml",
        "tasks/main.yml",
        "tasks/reconcile_record.yml",
    )
    for relative in required_role_files:
        check((ROLE / relative).is_file(), f"missing role file: {relative}")

    check((EXAMPLE / "README.md").is_file(), "missing example README")
    check((EXAMPLE / "requirements.yml").is_file(), "missing pinned requirements")
    check((EXAMPLE / "site.yml").is_file(), "missing example playbook")

    defaults = read(ROLE / "defaults/main.yml")
    main_tasks = read(ROLE / "tasks/main.yml")
    record_tasks = read(ROLE / "tasks/reconcile_record.yml")
    example_playbook = read(EXAMPLE / "site.yml")
    requirements = read(EXAMPLE / "requirements.yml")

    check("dns_update_enabled: false" in defaults, "role must default to disabled")
    check("dns_update_manage: false" in defaults, "writes must default to disabled")
    check("dns_update_auth_mode: gss-tsig" in defaults, "GSS-TSIG must be default")
    check("dns_update_allow_insecure: false" in defaults, "insecure mode must be opt-in")
    check("dns_update_discover_zone" not in defaults + main_tasks + record_tasks,
          "zone discovery must not be present")
    check("dns_update_discover_server" not in defaults + main_tasks + record_tasks,
          "server discovery must not be present")

    check("dns_update_record.zone is defined" in record_tasks,
          "each record must declare a zone")
    check("community.general.nsupdate:" in record_tasks,
          "the official collection module must perform updates")
    check("no_log: true" in record_tasks, "record operations must protect sensitive data")
    check("dns_update_conflict_policy" in record_tasks,
          "PTR conflict policy must be explicit")
    module_start = record_tasks.index("community.general.nsupdate:")
    module_end = record_tasks.index("- name: Classify the DNS update module result")
    module_block = record_tasks[module_start:module_end]
    check("check_mode: false" not in module_block,
          "nsupdate must honour Ansible check mode")

    check("community.general" in requirements and "13.0.0" in requirements,
          "community.general must be pinned")
    check("example.invalid" in example_playbook, "examples must use documentation DNS names")
    check("198.51.100.20" in example_playbook,
          "examples must use an RFC 5737 documentation address")
    check("in-addr.arpa" in example_playbook,
          "examples must demonstrate an explicit reverse zone")
    check("dns_update_manage: false" in example_playbook,
          "example must remain read-only")

    all_text = "\n".join(
        path.read_text(encoding="utf-8")
        for base in (ROLE, EXAMPLE)
        for path in base.rglob("*")
        if path.is_file()
    )
    private_network = re.compile(
        r"\b(?:10\.(?:\d{1,3}\.){2}\d{1,3}|"
        r"192\.168\.(?:\d{1,3}\.)\d{1,3}|"
        r"172\.(?:1[6-9]|2\d|3[0-1])\.(?:\d{1,3}\.)\d{1,3})\b"
    )
    check(not private_network.search(all_text),
          "public role must not contain private network addresses")
    check((ROOT / "README.md").is_file(),
          "public repository scaffold must include its README")

    print("dns_update contract checks passed")


if __name__ == "__main__":
    main()
