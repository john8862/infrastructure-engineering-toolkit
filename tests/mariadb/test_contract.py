"""Focused, dependency-free contract checks for the public MariaDB role."""

from pathlib import Path
import re
import unittest


ROOT = Path(__file__).resolve().parents[2]
ROLE = ROOT / "ansible" / "roles" / "mariadb"
EXAMPLE = ROOT / "examples" / "mariadb"


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


class MariaDBRoleContractTests(unittest.TestCase):
    def test_public_metadata_and_official_repository_defaults(self) -> None:
        metadata = read(ROLE / "meta" / "main.yml")
        defaults = read(ROLE / "defaults" / "main.yml")

        self.assertIn("license: MIT", metadata)
        self.assertIn("https://deb.mariadb.org/", defaults)
        self.assertIn("https://supplychain.mariadb.com/mariadb-keyring-2019.gpg", defaults)
        self.assertNotRegex(defaults, r"(?i)mirror|internal|corp|customer")

    def test_destructive_bootstrap_switches_are_off_by_default(self) -> None:
        defaults = read(ROLE / "defaults" / "main.yml")
        assertions = read(ROLE / "tasks" / "assertions.yml")
        bootstrap = read(ROLE / "tasks" / "bootstrap.yml")

        self.assertRegex(defaults, r"(?m)^mariadb_bootstrap_new_server:\s*false\s*$")
        self.assertRegex(defaults, r"(?m)^mariadb_bootstrap_reset_master:\s*false\s*$")
        self.assertRegex(defaults, r"(?m)^mariadb_bootstrap_existing_host_mode:\s*fail\s*$")
        self.assertIn("not (mariadb_bootstrap_reset_master | bool) or mariadb_bootstrap_new_server | bool", assertions)
        self.assertIn("not (mariadb_bootstrap_reset_master | bool) or mariadb_bootstrap_existing_host_mode == 'fail'", assertions)
        self.assertIn("query: RESET MASTER", bootstrap)
        self.assertIn("mariadb_bootstrap_should_reset | bool", bootstrap)

    def test_baseline_does_not_copy_data_or_start_replication(self) -> None:
        task_text = "\n".join(
            read(path)
            for path in (ROLE / "tasks").glob("*.yml")
            if path.name in {"assertions.yml", "bootstrap.yml", "configure.yml", "preflight.yml", "verify.yml"}
        )
        self.assertNotRegex(task_text, r"(?i)mysqldump|mariabackup|CHANGE\s+(MASTER|REPLICATION SOURCE)\s+TO|START\s+(SLAVE|REPLICA)")

    def test_sensitive_database_and_tls_operations_are_no_log(self) -> None:
        bootstrap = read(ROLE / "tasks" / "bootstrap.yml")
        preflight = read(ROLE / "tasks" / "preflight.yml")
        security = read(ROLE / "tasks" / "security.yml")

        self.assertGreaterEqual(bootstrap.count("no_log: true"), 8)
        self.assertGreaterEqual(preflight.count("no_log: true"), 4)
        provider_acl = security.split("- name: Grant mysql traversal ACL on provider TLS directories", 1)[1]
        self.assertIn("no_log: true", provider_acl.split("when:", 1)[0])

    def test_generic_fixture_is_safe_and_uses_documentation_values(self) -> None:
        inventory = read(EXAMPLE / "inventory.example.yml")
        site = read(EXAMPLE / "site.yml")

        self.assertIn("db-primary", inventory)
        self.assertIn("db-replica-a", inventory)
        self.assertIn("192.0.2.10", inventory)
        self.assertIn("192.0.2.11", inventory)
        self.assertIn("example.invalid", site)
        self.assertIn("lookup('ansible.builtin.env', 'MARIADB_ROOT_PASSWORD')", site)
        self.assertIn("lookup('ansible.builtin.env', 'MARIADB_REPLICATION_PASSWORD')", site)
        self.assertIn("mariadb_fixture_apply: false", site)
        self.assertIn("mariadb_bootstrap_reset_master: false", site)
        self.assertIn("mariadb_tls_enabled: false", site)

if __name__ == "__main__":
    unittest.main()
