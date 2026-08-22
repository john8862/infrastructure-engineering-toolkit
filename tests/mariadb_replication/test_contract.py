"""Static contract tests for the public MariaDB replication role.

These tests intentionally do not connect to MariaDB. They protect the public
role boundary, examples, and safety defaults without requiring credentials,
inventory, or a live topology.
"""

from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
ROLE = ROOT / "ansible" / "roles" / "mariadb_replication"
EXAMPLE = ROOT / "examples" / "mariadb-replication"


class MariaDBReplicationContractTests(unittest.TestCase):
    def read(self, relative: str) -> str:
        return (ROLE / relative).read_text(encoding="utf-8")

    def test_role_layout_and_dependency_are_explicit(self) -> None:
        for relative in (
            "README.md",
            "defaults/main.yml",
            "meta/main.yml",
            "meta/requirements.yml",
            "tasks/main.yml",
            "tasks/controller_preflight.yml",
            "tasks/validate_primary.yml",
            "tasks/validate_replica.yml",
            "tasks/validate_server_ids.yml",
            "tasks/consistency_primary.yml",
            "tasks/consistency_replica.yml",
            "tasks/configure_primary.yml",
            "tasks/configure_replica.yml",
            "tasks/summary.yml",
        ):
            self.assertTrue((ROLE / relative).is_file(), relative)

        requirements = self.read("meta/requirements.yml")
        self.assertIn("ansible.mariadb", requirements)
        self.assertNotIn("vendor/", requirements)

    def test_safety_defaults_do_not_install_or_force_reconfigure(self) -> None:
        defaults = self.read("defaults/main.yml")
        self.assertRegex(defaults, r"(?m)^mariadb_replication_manage_packages:\s*false\s*$")
        self.assertRegex(defaults, r"(?m)^mariadb_replication_force_reconfigure:\s*false\s*$")
        self.assertRegex(defaults, r"(?m)^mariadb_replication_user_host:\s*[\"']{2}\s*$")
        self.assertRegex(defaults, r"(?m)^mariadb_replication_consistency_allow_null_checksum:\s*false\s*$")
        self.assertRegex(defaults, r"(?m)^mariadb_replication_validate_network:\s*true\s*$")
        self.assertRegex(defaults, r"(?m)^mariadb_replication_require_log_basename:\s*true\s*$")

    def test_replication_credentials_and_channel_changes_are_hidden(self) -> None:
        primary = self.read("tasks/configure_primary.yml")
        replica = self.read("tasks/configure_replica.yml")
        connectivity = self.read("tasks/validate_replica.yml")
        self.assertIn("ansible.mariadb.mariadb_user:", primary)
        self.assertIn("no_log: true", primary)
        self.assertIn("no_log: true", replica)
        self.assertIn("no_log: true", connectivity)
        self.assertIn("primary_password:", replica)
        self.assertIn("mariadb_replication_password", replica)

    def test_role_excludes_unsafe_adjacent_automation(self) -> None:
        executable = "\n".join(
            path.read_text(encoding="utf-8")
            for path in (ROLE / "tasks").glob("*.yml")
        ).lower()
        for forbidden in (
            "maxscale",
            "keepalived",
            "galera",
            "wsrep",
            "mariabackup",
            "xtrabackup",
            "mysqldump",
            "reset master",
            "skip_slave",
            "sql_slave_skip_counter",
        ):
            self.assertNotIn(forbidden, executable)

    def test_role_does_not_render_server_configuration_or_assets(self) -> None:
        task_text = "\n".join(
            path.read_text(encoding="utf-8")
            for path in (ROLE / "tasks").glob("*.yml")
        )
        self.assertNotRegex(task_text, r"\b(template|copy|assemble|blockinfile|lineinfile)\s*:")
        self.assertNotRegex(task_text, r"(?:\bwith_fileglob\b|lookup\(['\"]file)")
        for extension in (".pem", ".key", ".crt", ".p12", ".jks"):
            self.assertFalse(any(ROLE.rglob(f"*{extension}")), extension)

    def test_public_examples_use_placeholders_and_documentation_addresses(self) -> None:
        inventory = (EXAMPLE / "inventory.yml").read_text(encoding="utf-8")
        variables = (EXAMPLE / "group_vars/mariadb_replication.yml.example").read_text(
            encoding="utf-8"
        )
        docs = (EXAMPLE / "README.md").read_text(encoding="utf-8")
        self.assertIn("db-primary", inventory)
        self.assertIn("db-replica-a", inventory)
        self.assertIn("192.0.2.10", inventory)
        self.assertIn("192.0.2.11", inventory)
        self.assertIn("db-primary.example.invalid", variables)
        self.assertIn("vault_mariadb_replication_password", variables)
        self.assertIn("mariadb_replication_auto_start: false", variables)
        self.assertIn("example.invalid", docs)
        self.assertNotRegex(
            inventory + variables + docs,
            r"(?i)(BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY|password\s*:\s*['\"](?!\{\{)|token\s*:\s*['\"]\w+)",
        )

    def test_public_tree_contains_expected_component_roots(self) -> None:
        for relative in (
            "ansible/roles/mariadb_replication",
            "examples/mariadb-replication",
            "tests/mariadb_replication",
        ):
            self.assertTrue((ROOT / relative).is_dir(), relative)


if __name__ == "__main__":
    unittest.main()
