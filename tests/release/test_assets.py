#!/usr/bin/env python3
"""Smoke-test the independent release asset contract without uploading files."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path, PurePosixPath
import subprocess
import sys
import tarfile
import tempfile


ROOT = Path(__file__).resolve().parents[2]
BUILDER = ROOT / "scripts/release/build-assets.py"
VERSION = "0.1.0"
PACKAGES = (
    "ansible-role-dns-update",
    "ansible-role-keepalived",
    "ansible-role-mariadb",
    "ansible-role-mariadb-replication",
    "ansible-role-maxscale",
    "freeipa-bootstrap",
)
ROLE_ROOTS = {
    "ansible-role-dns-update": "dns_update",
    "ansible-role-keepalived": "keepalived",
    "ansible-role-mariadb": "mariadb",
    "ansible-role-mariadb-replication": "mariadb_replication",
    "ansible-role-maxscale": "maxscale",
}


def _build(output_dir: Path) -> None:
    subprocess.run(
        [
            sys.executable,
            str(BUILDER),
            "--version",
            f"v{VERSION}",
            "--source-root",
            str(ROOT),
            "--output-dir",
            str(output_dir),
        ],
        check=True,
    )


def _digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _assert_archive(path: Path, package: str) -> None:
    component_root = "freeipa-bootstrap" if package == "freeipa-bootstrap" else ROLE_ROOTS[package]
    prohibited_names = {
        "AGENTS" + ".md",
        "SECURITY" + ".md",
        "PUBLICATION_REVIEW" + ".md",
    }
    prohibited_tokens = (".git", ".github")
    prohibited_content = (
        b"PUBLICATION_REVIEW.md",
        b"SECURITY.md",
        b"AGENTS.md",
    )
    with tarfile.open(path, mode="r:gz") as archive:
        names = []
        for member in archive.getmembers():
            relative = PurePosixPath(member.name.rstrip("/"))
            assert not relative.is_absolute()
            assert ".." not in relative.parts
            assert relative.parts[0] == component_root
            assert not any(token in member.name for token in prohibited_tokens)
            assert relative.name not in prohibited_names
            if member.isdir():
                continue
            assert member.isreg(), f"non-regular archive entry: {member.name}"
            assert not member.mode & 0o022, f"unsafe archive mode: {member.name}"
            names.append(member.name)
            content = archive.extractfile(member).read()
            assert not any(marker in content for marker in prohibited_content)
            assert b"BEGIN PRIVATE KEY" not in content
            assert b"github_pat_" not in content
            assert b"ghp_" not in content
        assert f"{component_root}/README.md" in names
        assert f"{component_root}/LICENSE" in names
        if package == "freeipa-bootstrap":
            assert f"{component_root}/install.sh" in names
            assert any(name.startswith(f"{component_root}/examples/") for name in names)


def _assert_checksums(output_dir: Path) -> None:
    checksum_file = output_dir / f"SHA256SUMS-v{VERSION}.txt"
    for line in checksum_file.read_text(encoding="utf-8").splitlines():
        digest, name = line.split(maxsplit=1)
        assert digest == _digest(output_dir / name)


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="ietk-assets-") as temporary_root:
        first = Path(temporary_root) / "first"
        second = Path(temporary_root) / "second"
        _build(first)
        _build(second)
        first_files = sorted(path.name for path in first.iterdir())
        second_files = sorted(path.name for path in second.iterdir())
        assert first_files == second_files
        for name in first_files:
            assert _digest(first / name) == _digest(second / name), f"non-deterministic asset: {name}"

        manifest_path = first / f"release-manifest-v{VERSION}.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        assert manifest["repository"] == "infrastructure-engineering-toolkit"
        assert manifest["tag"] == f"v{VERSION}"
        assert sorted(asset["component"] for asset in manifest["assets"]) == sorted(
            [*ROLE_ROOTS.values(), "freeipa-bootstrap"]
        )
        for package in PACKAGES:
            archive = first / f"{package}-v{VERSION}.tar.gz"
            _assert_archive(archive, package)
        _assert_checksums(first)
    print("release asset contract passed: six independent archives, deterministic hashes, and safe boundaries")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
