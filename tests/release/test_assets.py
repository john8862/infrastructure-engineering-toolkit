#!/usr/bin/env python3
"""Smoke-test the independent release asset contract without uploading files."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
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


def _build(
    output_dir: Path,
    *,
    source_root: Path = ROOT,
    version: str = VERSION,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            sys.executable,
            str(BUILDER),
            "--version",
            f"v{version}",
            "--source-root",
            str(source_root),
            "--output-dir",
            str(output_dir),
        ],
        check=check,
        capture_output=not check,
        text=not check,
    )


def _clone_source(destination: Path) -> None:
    subprocess.run(
        ["git", "clone", "--quiet", "--no-local", str(ROOT), str(destination)],
        check=True,
    )


def _stage(source_root: Path) -> None:
    subprocess.run(["git", "-C", str(source_root), "add", "--all"], check=True)


def _assert_build_rejected(label: str, mutate, *, version: str = VERSION) -> None:
    with tempfile.TemporaryDirectory(prefix="ietk-negative-") as temporary_root:
        temporary_path = Path(temporary_root)
        source = temporary_path / "source"
        output = temporary_path / "output"
        _clone_source(source)
        mutate(source, temporary_path)
        _stage(source)
        result = _build(output, source_root=source, version=version, check=False)
        assert result.returncode != 0, f"{label} was accepted: {result.stderr}"


def _assert_build_accepted(label: str, mutate) -> None:
    with tempfile.TemporaryDirectory(prefix="ietk-positive-") as temporary_root:
        temporary_path = Path(temporary_root)
        source = temporary_path / "source"
        output = temporary_path / "output"
        _clone_source(source)
        mutate(source, temporary_path)
        _stage(source)
        result = _build(output, source_root=source, check=False)
        assert result.returncode == 0, f"{label} was rejected: {result.stderr}"


def _assert_verifier_rejected(label: str, output: Path, mutate) -> None:
    spec = importlib.util.spec_from_file_location("build_assets", BUILDER)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    mutate()
    try:
        module.verify_output(output, VERSION)
    except ValueError:
        return
    raise AssertionError(f"{label} was accepted by verify_output")


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


def _replace_root_license_with_symlink(source: Path, _temporary_path: Path) -> None:
    license_path = source / "LICENSE"
    license_path.unlink()
    os.symlink("components/freeipa-bootstrap/README.md", license_path)


def _replace_allowlisted_file_with_symlink(source: Path, _temporary_path: Path) -> None:
    allowlisted = source / "ansible/roles/mariadb/README.md"
    allowlisted.unlink()
    os.symlink(str(source / "LICENSE"), allowlisted)


def _add_freeipa_unreviewed_file(source: Path, _temporary_path: Path) -> None:
    (source / "components/freeipa-bootstrap/unreviewed.txt").write_text(
        "This file was not reviewed for publication.\n", encoding="utf-8"
    )


def _add_repository_test_file(source: Path, _temporary_path: Path) -> None:
    (source / "tests/freeipa-bootstrap/local-fixture.txt").write_text(
        "This fixture is intentionally outside the published component.\n", encoding="utf-8"
    )


def _inject_internal_marker(source: Path, _temporary_path: Path) -> None:
    (source / "components/freeipa-bootstrap/README.md").write_text(
        "BEGIN PRIVATE KEY\n", encoding="utf-8"
    )


def _prepare_non_empty_output(_source: Path, temporary_path: Path) -> None:
    output = temporary_path / "output"
    output.mkdir()
    (output / "leftover.txt").write_text("must be rejected\n", encoding="utf-8")


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

        _assert_build_rejected("root LICENSE symlink", _replace_root_license_with_symlink)
        _assert_build_rejected("allowlisted input symlink", _replace_allowlisted_file_with_symlink)
        _assert_build_rejected("unreviewed FreeIPA tracked file", _add_freeipa_unreviewed_file)
        _assert_build_accepted("repository test path", _add_repository_test_file)
        _assert_build_rejected("known internal or secret marker", _inject_internal_marker)
        _assert_build_rejected("non-empty output directory", _prepare_non_empty_output)
        _assert_build_rejected("malformed SemVer", lambda _source, _path: None, version="1.0")

        tampered_manifest = Path(temporary_root) / "tampered-manifest"
        _build(tampered_manifest)
        manifest_path = tampered_manifest / f"release-manifest-v{VERSION}.json"
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        manifest["assets"][0]["sha256"] = "0" * 64
        manifest_path.write_text(json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8")
        _assert_verifier_rejected("manifest tampering", tampered_manifest, lambda: None)

        tampered_checksums = Path(temporary_root) / "tampered-checksums"
        _build(tampered_checksums)
        checksum_path = tampered_checksums / f"SHA256SUMS-v{VERSION}.txt"
        lines = checksum_path.read_text(encoding="utf-8").splitlines()
        digest, name = lines[0].split(maxsplit=1)
        assert len(digest) == 64
        lines[0] = f"{'0' * 64}  {name}"
        checksum_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
        _assert_verifier_rejected("checksum tampering", tampered_checksums, lambda: None)
        print(
            "release asset contract passed: six independent archives, two deterministic builds, "
            "six build-rejection contracts, one excluded-test-path contract, "
            "two verifier-tamper contracts, and safe boundaries"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
