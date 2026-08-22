#!/usr/bin/env python3
"""Build deterministic, independently installable release archives.

The release workflow calls this script after Release Please has created the
root GitHub Release.  The script intentionally uses an explicit file manifest
instead of archiving a directory wholesale: a new tracked file must be
reviewed and added to a package allowlist before it can become an asset.
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import subprocess
import tarfile
from typing import Iterable


SEMVER_RE = re.compile(
    r"^(?:v)?(0|[1-9][0-9]*)\."
    r"(0|[1-9][0-9]*)\."
    r"(0|[1-9][0-9]*)"
    r"(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?"
    r"(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?$"
)

REPOSITORY_NAME = "infrastructure-engineering-toolkit"
ROOT_LICENSE = "LICENSE"


ROLE_SPECS = (
    ("dns-update", "dns_update"),
    ("keepalived", "keepalived"),
    ("mariadb", "mariadb"),
    ("mariadb-replication", "mariadb_replication"),
    ("maxscale", "maxscale"),
)


# Keep package membership explicit.  A newly added role file is deliberately
# rejected by the packaging contract until it is reviewed and listed here.
ROLE_FILES = {
    "dns_update": (
        "ansible/roles/dns_update/README.md",
        "ansible/roles/dns_update/argument_specs.yml",
        "ansible/roles/dns_update/defaults/main.yml",
        "ansible/roles/dns_update/handlers/main.yml",
        "ansible/roles/dns_update/meta/main.yml",
        "ansible/roles/dns_update/tasks/main.yml",
        "ansible/roles/dns_update/tasks/reconcile_record.yml",
    ),
    "keepalived": (
        "ansible/roles/keepalived/README.md",
        "ansible/roles/keepalived/argument_specs.yml",
        "ansible/roles/keepalived/defaults/main.yml",
        "ansible/roles/keepalived/handlers/main.yml",
        "ansible/roles/keepalived/meta/main.yml",
        "ansible/roles/keepalived/tasks/main.yml",
        "ansible/roles/keepalived/templates/keepalived-systemd-override.conf.j2",
        "ansible/roles/keepalived/templates/keepalived.conf.j2",
        "ansible/roles/keepalived/templates/keepalived.logrotate.j2",
    ),
    "mariadb": (
        "ansible/roles/mariadb/README.md",
        "ansible/roles/mariadb/defaults/main.yml",
        "ansible/roles/mariadb/handlers/main.yml",
        "ansible/roles/mariadb/meta/argument_specs.yml",
        "ansible/roles/mariadb/meta/main.yml",
        "ansible/roles/mariadb/meta/requirements.yml",
        "ansible/roles/mariadb/tasks/assertions.yml",
        "ansible/roles/mariadb/tasks/bootstrap.yml",
        "ansible/roles/mariadb/tasks/configure.yml",
        "ansible/roles/mariadb/tasks/install.yml",
        "ansible/roles/mariadb/tasks/main.yml",
        "ansible/roles/mariadb/tasks/preflight.yml",
        "ansible/roles/mariadb/tasks/repository.yml",
        "ansible/roles/mariadb/tasks/security.yml",
        "ansible/roles/mariadb/tasks/service.yml",
        "ansible/roles/mariadb/tasks/verify.yml",
        "ansible/roles/mariadb/templates/50-server.cnf.j2",
        "ansible/roles/mariadb/templates/60-replication.cnf.j2",
        "ansible/roles/mariadb/templates/70-security.cnf.j2",
        "ansible/roles/mariadb/templates/80-logging.cnf.j2",
        "ansible/roles/mariadb/templates/90-performance.cnf.j2",
        "ansible/roles/mariadb/templates/99-node.cnf.j2",
    ),
    "mariadb_replication": (
        "ansible/roles/mariadb_replication/README.md",
        "ansible/roles/mariadb_replication/defaults/main.yml",
        "ansible/roles/mariadb_replication/handlers/main.yml",
        "ansible/roles/mariadb_replication/meta/main.yml",
        "ansible/roles/mariadb_replication/meta/requirements.yml",
        "ansible/roles/mariadb_replication/tasks/configure_primary.yml",
        "ansible/roles/mariadb_replication/tasks/configure_replica.yml",
        "ansible/roles/mariadb_replication/tasks/consistency_primary.yml",
        "ansible/roles/mariadb_replication/tasks/consistency_replica.yml",
        "ansible/roles/mariadb_replication/tasks/controller_preflight.yml",
        "ansible/roles/mariadb_replication/tasks/healthcheck.yml",
        "ansible/roles/mariadb_replication/tasks/install.yml",
        "ansible/roles/mariadb_replication/tasks/main.yml",
        "ansible/roles/mariadb_replication/tasks/summary.yml",
        "ansible/roles/mariadb_replication/tasks/validate_inputs.yml",
        "ansible/roles/mariadb_replication/tasks/validate_primary.yml",
        "ansible/roles/mariadb_replication/tasks/validate_replica.yml",
        "ansible/roles/mariadb_replication/tasks/validate_server_ids.yml",
    ),
    "maxscale": (
        "ansible/roles/maxscale/README.md",
        "ansible/roles/maxscale/argument_specs.yml",
        "ansible/roles/maxscale/defaults/main.yml",
        "ansible/roles/maxscale/handlers/main.yml",
        "ansible/roles/maxscale/meta/main.yml",
        "ansible/roles/maxscale/tasks/assertions.yml",
        "ansible/roles/maxscale/tasks/configure.yml",
        "ansible/roles/maxscale/tasks/directories.yml",
        "ansible/roles/maxscale/tasks/firewall.yml",
        "ansible/roles/maxscale/tasks/firewall_rule.yml",
        "ansible/roles/maxscale/tasks/install.yml",
        "ansible/roles/maxscale/tasks/logging.yml",
        "ansible/roles/maxscale/tasks/main.yml",
        "ansible/roles/maxscale/tasks/repository.yml",
        "ansible/roles/maxscale/tasks/systemd.yml",
        "ansible/roles/maxscale/tasks/tls_asset.yml",
        "ansible/roles/maxscale/tasks/validation.yml",
        "ansible/roles/maxscale/templates/listeners.cnf.j2",
        "ansible/roles/maxscale/templates/maxscale-systemd-override.conf.j2",
        "ansible/roles/maxscale/templates/maxscale.cnf.j2",
        "ansible/roles/maxscale/templates/maxscale.logrotate.j2",
        "ansible/roles/maxscale/templates/maxscale_macros.j2",
        "ansible/roles/maxscale/templates/monitors.cnf.j2",
        "ansible/roles/maxscale/templates/servers.cnf.j2",
        "ansible/roles/maxscale/templates/services.cnf.j2",
    ),
}


FREEIPA_FILES = (
    "components/freeipa-bootstrap/CHANGELOG.md",
    "components/freeipa-bootstrap/README.md",
    "components/freeipa-bootstrap/VERSION",
    "components/freeipa-bootstrap/dns/provider.sh",
    "components/freeipa-bootstrap/dns/providers/bind9-webmin/provider.sh",
    "components/freeipa-bootstrap/dns/providers/existing/provider.sh",
    "components/freeipa-bootstrap/dns/providers/technitium/README.md",
    "components/freeipa-bootstrap/dns/providers/technitium/provider.sh",
    "components/freeipa-bootstrap/docs/FreeIPA_Server_Bootstrap.md",
    "components/freeipa-bootstrap/install.sh",
    "components/freeipa-bootstrap/lib/common.sh",
    "components/freeipa-bootstrap/lib/env.sh",
    "components/freeipa-bootstrap/lib/firewall.sh",
    "components/freeipa-bootstrap/lib/freeipa.sh",
    "components/freeipa-bootstrap/lib/hostname.sh",
    "components/freeipa-bootstrap/lib/logging.sh",
    "components/freeipa-bootstrap/lib/ntp.sh",
    "components/freeipa-bootstrap/lib/packages.sh",
    "components/freeipa-bootstrap/lib/preflight.sh",
    "components/freeipa-bootstrap/lib/state.sh",
    "components/freeipa-bootstrap/lib/topology.sh",
    "components/freeipa-bootstrap/lib/validation.sh",
    "components/freeipa-bootstrap/scripts/lint-docs.sh",
    "components/freeipa-bootstrap/update-server-ip.sh",
    "examples/freeipa/freeipa.env.example",
    "examples/freeipa/primary.env.example",
    "examples/freeipa/secondary.env.example",
)


def _all_allowlisted_files() -> dict[str, tuple[str, ...]]:
    """Return package names and their exact repository-relative file paths."""

    packages = {
        f"ansible-role-{archive_name}": ROLE_FILES[role_name]
        for archive_name, role_name in ROLE_SPECS
    }
    packages["freeipa-bootstrap"] = FREEIPA_FILES
    return packages


def _normalise_version(value: str) -> str:
    match = SEMVER_RE.fullmatch(value.strip())
    if match is None:
        raise ValueError(
            "version must be strict SemVer in MAJOR.MINOR.PATCH form "
            "(an optional leading v and prerelease/build metadata are accepted)"
        )
    return ".".join(match.group(index) for index in range(1, 4)) + "".join(
        part
        for part in (
            f"-{match.group(4)}" if match.group(4) else "",
            f"+{match.group(5)}" if match.group(5) else "",
        )
    )


def _git_tracked_files(source_root: Path) -> set[str]:
    result = subprocess.run(
        ["git", "-C", str(source_root), "ls-files", "-z"],
        check=True,
        capture_output=True,
    )
    return {path for path in result.stdout.decode().split("\0") if path}


def _validate_allowlist(source_root: Path, tracked: set[str]) -> dict[str, tuple[str, ...]]:
    packages = _all_allowlisted_files()
    missing: list[str] = []
    untracked: list[str] = []
    for package, files in packages.items():
        for relative in files:
            path = source_root / relative
            if relative not in tracked:
                untracked.append(f"{package}: {relative}")
            if not path.is_file() or path.is_symlink():
                missing.append(f"{package}: {relative}")
    for role_name, expected_files in ROLE_FILES.items():
        prefix = f"ansible/roles/{role_name}/"
        unexpected = sorted(
            path
            for path in tracked
            if path.startswith(prefix) and path not in expected_files
        )
        untracked.extend(f"ansible-role-{role_name}: unreviewed file {path}" for path in unexpected)
    if ROOT_LICENSE not in tracked or not (source_root / ROOT_LICENSE).is_file():
        missing.append(ROOT_LICENSE)
    if missing or untracked:
        details = []
        if missing:
            details.append("missing or symlinked files: " + ", ".join(sorted(missing)))
        if untracked:
            details.append("allowlist contains untracked files: " + ", ".join(sorted(untracked)))
        raise ValueError("; ".join(details))
    return packages


def _safe_archive_path(value: str) -> PurePosixPath:
    path = PurePosixPath(value)
    if path.is_absolute() or ".." in path.parts or not path.parts:
        raise ValueError(f"unsafe archive path: {value!r}")
    return path


def _role_directory(package: str) -> str:
    archive_name = package.removeprefix("ansible-role-")
    for archive_role_name, role_directory in ROLE_SPECS:
        if archive_role_name == archive_name:
            return role_directory
    raise ValueError(f"unknown Ansible role package: {package}")


def _package_relative(package: str, source_path: str) -> str:
    if package.startswith("ansible-role-"):
        role_dir = _role_directory(package)
        prefix = f"ansible/roles/{role_dir}/"
        if not source_path.startswith(prefix):
            raise ValueError(f"role allowlist path is outside its role: {source_path}")
        return f"{role_dir}/{source_path.removeprefix(prefix)}"
    if package == "freeipa-bootstrap":
        if source_path.startswith("components/freeipa-bootstrap/"):
            return f"freeipa-bootstrap/{source_path.removeprefix('components/freeipa-bootstrap/')}"
        if source_path.startswith("examples/freeipa/"):
            return f"freeipa-bootstrap/examples/freeipa/{source_path.removeprefix('examples/freeipa/')}"
    raise ValueError(f"unknown package path: {package}: {source_path}")


def _freeipa_text(package_path: str, content: bytes) -> bytes:
    """Adjust repository-relative links for the self-contained archive."""

    if not package_path.endswith(".md"):
        return content
    text = content.decode("utf-8")
    if package_path == "freeipa-bootstrap/README.md":
        text = text.replace("../../examples/freeipa", "examples/freeipa")
    elif package_path == "freeipa-bootstrap/docs/FreeIPA_Server_Bootstrap.md":
        text = text.replace("../../examples/freeipa", "../examples/freeipa")
    repository_tests_url = (
        "https://github.com/john8862/infrastructure-engineering-toolkit/tree/main/"
        "tests/freeipa-bootstrap"
    )
    text = text.replace("../../tests/freeipa-bootstrap", repository_tests_url)
    return text.encode("utf-8")


def _file_mode(source_path: Path) -> int:
    mode = source_path.stat().st_mode
    return 0o755 if mode & 0o111 else 0o644


def _iter_archive_entries(
    source_root: Path,
    package: str,
    relative_files: Iterable[str],
) -> list[tuple[str, bytes, int]]:
    entries: dict[str, tuple[bytes, int]] = {}
    for source_path_text in relative_files:
        source_path = source_root / source_path_text
        archive_path = _safe_archive_path(_package_relative(package, source_path_text))
        if source_path.is_symlink() or not source_path.is_file():
            raise ValueError(f"archive input is not a regular file: {source_path_text}")
        content = _freeipa_text(archive_path.as_posix(), source_path.read_bytes())
        entries[archive_path.as_posix()] = (content, _file_mode(source_path))
    archive_root = "freeipa-bootstrap" if package == "freeipa-bootstrap" else _role_directory(package)
    license_path = _safe_archive_path(f"{archive_root}/{ROOT_LICENSE}")
    entries[license_path.as_posix()] = ((source_root / ROOT_LICENSE).read_bytes(), 0o644)

    output: list[tuple[str, bytes, int]] = []
    directories: set[str] = set()
    for path_text in sorted(entries):
        path = PurePosixPath(path_text)
        for index in range(1, len(path.parts)):
            directories.add("/".join(path.parts[:index]) + "/")
        content, mode = entries[path_text]
        output.append((path_text, content, mode))
    directory_entries = [(path, b"", 0o755) for path in sorted(directories)]
    return directory_entries + output


def _tar_bytes(entries: Iterable[tuple[str, bytes, int]]) -> bytes:
    raw = io.BytesIO()
    with tarfile.open(fileobj=raw, mode="w") as archive:
        for name, content, mode in entries:
            info = tarfile.TarInfo(name=name)
            info.mtime = 0
            info.uid = 0
            info.gid = 0
            info.uname = ""
            info.gname = ""
            info.mode = mode
            if name.endswith("/"):
                info.type = tarfile.DIRTYPE
                info.size = 0
            else:
                info.type = tarfile.REGTYPE
                info.size = len(content)
            archive.addfile(info, io.BytesIO(content) if info.isreg() else None)
    raw.seek(0)
    compressed = io.BytesIO()
    with gzip.GzipFile(fileobj=compressed, mode="wb", filename="", compresslevel=9, mtime=0) as gzip_file:
        gzip_file.write(raw.read())
    raw.close()
    return compressed.getvalue()


def _sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def _write(path: Path, content: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content)
    os.chmod(path, 0o644)


def _build_archives(source_root: Path, output_dir: Path, version: str) -> list[dict[str, object]]:
    tracked = _git_tracked_files(source_root)
    packages = _validate_allowlist(source_root, tracked)
    assets: list[dict[str, object]] = []
    for package, files in packages.items():
        archive_name = f"{package}-v{version}.tar.gz"
        archive_bytes = _tar_bytes(_iter_archive_entries(source_root, package, files))
        _write(output_dir / archive_name, archive_bytes)
        assets.append(
            {
                "name": archive_name,
                "kind": "freeipa-bootstrap" if package == "freeipa-bootstrap" else "ansible-role",
                "component": (
                    "freeipa-bootstrap"
                    if package == "freeipa-bootstrap"
                    else _role_directory(package)
                ),
                "sha256": _sha256_bytes(archive_bytes),
                "size": len(archive_bytes),
            }
        )
    return assets


def _manifest_bytes(version: str, assets: list[dict[str, object]]) -> bytes:
    manifest = {
        "schema_version": 1,
        "repository": REPOSITORY_NAME,
        "version": version,
        "tag": f"v{version}",
        "assets": assets,
        "checksum_file": f"SHA256SUMS-v{version}.txt",
        "build_policy": {
            "source": "git tracked files from explicit package allowlists",
            "archive_format": "gzip-compressed POSIX tar",
            "normalised_metadata": True,
            "symlinks": "rejected",
        },
    }
    return (json.dumps(manifest, indent=2, sort_keys=True) + "\n").encode("utf-8")


def _checksum_bytes(output_dir: Path, names: Iterable[str]) -> bytes:
    lines = []
    for name in sorted(names):
        lines.append(f"{hashlib.sha256((output_dir / name).read_bytes()).hexdigest()}  {name}")
    return ("\n".join(lines) + "\n").encode("utf-8")


def _validate_archive(path: Path, package: str) -> None:
    expected_root = "freeipa-bootstrap" if package == "freeipa-bootstrap" else _role_directory(package)
    forbidden_fragments = (
        ".git",
        ".github",
        "PUBLICATION_REVIEW",
        "SECURITY.md",
        "AGENTS.md",
    )
    forbidden_content = (
        b"PUBLICATION_REVIEW.md",
        b"SECURITY.md",
        b"AGENTS.md",
    )
    with tarfile.open(path, mode="r:gz") as archive:
        members = archive.getmembers()
        if not members:
            raise ValueError(f"empty archive: {path.name}")
        regular_files = []
        for member in members:
            safe = _safe_archive_path(member.name.rstrip("/"))
            if safe.parts[0] != expected_root:
                raise ValueError(f"archive path escapes component root: {path.name}: {member.name}")
            if member.isdir():
                continue
            if member.name.endswith("/"):
                raise ValueError(f"non-directory has directory suffix: {path.name}: {member.name}")
            if not member.isreg():
                raise ValueError(f"archive contains non-regular entry: {path.name}: {member.name}")
            if member.mode & 0o022:
                raise ValueError(f"archive entry is group/world writable: {path.name}: {member.name}")
            if any(fragment in member.name for fragment in forbidden_fragments):
                raise ValueError(f"forbidden archive path: {path.name}: {member.name}")
            content = archive.extractfile(member).read()
            if any(marker in content for marker in forbidden_content):
                raise ValueError(f"forbidden archive content: {path.name}: {member.name}")
            regular_files.append(member.name)
        if f"{expected_root}/README.md" not in regular_files:
            raise ValueError(f"archive has no component README: {path.name}")
        if f"{expected_root}/LICENSE" not in regular_files:
            raise ValueError(f"archive has no component licence: {path.name}")
        if package == "freeipa-bootstrap" and f"{expected_root}/install.sh" not in regular_files:
            raise ValueError(f"FreeIPA archive has no install entrypoint: {path.name}")


def verify_output(output_dir: Path, version: str) -> None:
    expected_packages = [f"ansible-role-{name}" for name, _ in ROLE_SPECS] + ["freeipa-bootstrap"]
    expected_archives = [f"{package}-v{version}.tar.gz" for package in expected_packages]
    manifest_path = output_dir / f"release-manifest-v{version}.json"
    checksum_path = output_dir / f"SHA256SUMS-v{version}.txt"
    if not manifest_path.is_file() or not checksum_path.is_file():
        raise ValueError("manifest and checksum files must be present")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("version") != version or manifest.get("tag") != f"v{version}":
        raise ValueError("manifest version/tag mismatch")
    assets_by_name = {asset["name"]: asset for asset in manifest.get("assets", [])}
    if sorted(assets_by_name) != sorted(expected_archives):
        raise ValueError("manifest archive list does not match the package allowlist")
    for package, archive_name in zip(expected_packages, expected_archives):
        archive_path = output_dir / archive_name
        _validate_archive(archive_path, package)
        digest = _sha256_bytes(archive_path.read_bytes())
        if assets_by_name[archive_name].get("sha256") != digest:
            raise ValueError(f"manifest checksum mismatch: {archive_name}")
    expected_sum_names = sorted(expected_archives + [manifest_path.name])
    expected_lines = _checksum_bytes(output_dir, expected_sum_names).decode("utf-8")
    if checksum_path.read_text(encoding="utf-8") != expected_lines:
        raise ValueError("SHA256SUMS does not match generated assets")


def build(source_root: Path, output_dir: Path, version: str) -> None:
    if output_dir.exists():
        if not output_dir.is_dir():
            raise ValueError(f"output path is not a directory: {output_dir}")
        if any(output_dir.iterdir()):
            raise ValueError(f"output directory must be empty: {output_dir}")
    else:
        output_dir.mkdir(parents=True)
    assets = _build_archives(source_root, output_dir, version)
    manifest_name = f"release-manifest-v{version}.json"
    _write(output_dir / manifest_name, _manifest_bytes(version, assets))
    checksum_names = [asset["name"] for asset in assets] + [manifest_name]
    _write(output_dir / f"SHA256SUMS-v{version}.txt", _checksum_bytes(output_dir, checksum_names))
    verify_output(output_dir, version)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--version", required=True, help="strict SemVer or v-prefixed release tag")
    parser.add_argument(
        "--output-dir",
        required=True,
        type=Path,
        help="empty or disposable directory for release assets",
    )
    parser.add_argument(
        "--source-root",
        type=Path,
        default=Path(__file__).resolve().parents[2],
        help="repository root (defaults to the current checkout)",
    )
    args = parser.parse_args()
    try:
        version = _normalise_version(args.version)
        source_root = args.source_root.resolve()
        output_dir = args.output_dir.resolve()
        if not (source_root / ".git").exists():
            raise ValueError(f"source root is not a Git checkout: {source_root}")
        if output_dir == source_root or output_dir.is_relative_to(source_root):
            raise ValueError("output directory must be outside the source checkout")
        build(source_root, output_dir, version)
    except (OSError, ValueError, subprocess.CalledProcessError, json.JSONDecodeError) as exc:
        parser.error(str(exc))
    print(f"built and verified release assets for v{version} in {output_dir}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
