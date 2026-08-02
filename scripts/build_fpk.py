#!/usr/bin/env python3
"""Build fn-docker-desk fnOS package from the GitHub source tree.

The script creates a fnpack-compatible .fpk file under dist/:

    dist/fn-docker-desk_<version>_all.fpk

It uses only Python standard library modules so it can run on a clean machine.
"""

from __future__ import annotations

import argparse
import tarfile
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PKG = ROOT / "pkg"
FNOS = PKG / "fnos"
FILES = PKG / "files"
DIST = ROOT / "dist"


def read_manifest_version() -> str:
    manifest = FNOS / "manifest"
    for line in manifest.read_text(encoding="utf-8").splitlines():
        if line.strip().startswith("version"):
            return line.split("=", 1)[1].strip()
    raise RuntimeError("version not found in pkg/fnos/manifest")


def add_file(tar: tarfile.TarFile, source: Path, arcname: str) -> None:
    info = tar.gettarinfo(str(source), arcname)
    if source.name in {
        "main",
        "install_init",
        "install_callback",
        "upgrade_init",
        "upgrade_callback",
        "uninstall_init",
        "uninstall_callback",
        "config_init",
        "config_callback",
        "fn-docker-desk.sh",
    }:
        info.mode = 0o755
    with source.open("rb") as fh:
        tar.addfile(info, fh)


def add_tree(tar: tarfile.TarFile, base: Path, arcbase: str) -> None:
    for path in sorted(base.rglob("*")):
        if path.is_dir() or "__pycache__" in path.parts:
            continue
        add_file(tar, path, f"{arcbase}/{path.relative_to(base).as_posix()}")


def build_app_tgz(output: Path) -> None:
    with tarfile.open(output, "w:gz") as tar:
        add_file(tar, FILES / "fn-docker-desk.sh", "fn-docker-desk.sh")
        add_file(tar, FILES / "web.py", "web.py")
        add_tree(tar, FNOS / "ui", "ui")


def build_fpk(version: str) -> Path:
    DIST.mkdir(exist_ok=True)
    output = DIST / f"fn-docker-desk_{version}_all.fpk"

    with tempfile.TemporaryDirectory() as tmp:
        tmpdir = Path(tmp)
        app_tgz = tmpdir / "app.tgz"
        build_app_tgz(app_tgz)

        with tarfile.open(output, "w:gz") as tar:
            add_file(tar, FNOS / "manifest", "manifest")
            add_file(tar, FNOS / "ICON.PNG", "ICON.PNG")
            add_file(tar, FNOS / "ICON_256.PNG", "ICON_256.PNG")
            add_file(tar, app_tgz, "app.tgz")
            add_tree(tar, FNOS / "cmd", "cmd")
            add_tree(tar, FNOS / "config", "config")

    return output


def main() -> None:
    parser = argparse.ArgumentParser(description="Build fn-docker-desk .fpk package")
    parser.add_argument("--version", default=read_manifest_version(), help="package version")
    args = parser.parse_args()

    package = build_fpk(args.version)
    print(package)


if __name__ == "__main__":
    main()
