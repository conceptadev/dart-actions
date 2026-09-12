"""Install a reviewed Linux x64 Flutter archive before exposing its SDKs.

The release manifest is trusted, reviewed caller configuration. Downloads and
cache hits must match its digest. No SDK command runs before verification.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile

VERSION = re.compile(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\Z")
DIGEST = re.compile(r"[0-9a-f]{64}\Z")
BASE_URL = "https://storage.googleapis.com/flutter_infra_release/releases/stable/linux"


def exact_version(value: object) -> str:
    if not isinstance(value, str) or not VERSION.fullmatch(value):
        raise ValueError("Use an exact stable SDK version, such as 3.44.0.")
    return value


def checked_file(workspace: Path, name: str) -> Path:
    relative = Path(name)
    root = workspace.resolve(strict=True)
    if relative.is_absolute() or ".." in relative.parts:
        raise ValueError("Configuration paths must stay inside the caller workspace.")
    path = (root / relative).resolve(strict=True)
    if not path.is_relative_to(root) or not path.is_file():
        raise ValueError("Configuration must be a file inside the caller workspace.")
    return path


def resolve_release(workspace: Path, version_file: str, releases_file: str) -> dict[str, str]:
    config = json.loads(checked_file(workspace, version_file).read_text())
    version = exact_version(config.get("flutter"))
    manifest = json.loads(checked_file(workspace, releases_file).read_text())
    release = manifest.get("releases", {}).get(version)
    if not isinstance(release, dict):
        raise ValueError(f"Flutter {version} has no reviewed release entry.")
    dart = exact_version(release.get("dart"))
    digest = release.get("sha256")
    if not isinstance(digest, str) or not DIGEST.fullmatch(digest):
        raise ValueError("The release must have a lowercase SHA-256 digest.")
    return {"flutter-version": version, "dart-version": dart, "sha256": digest}


def emit(path: str, values: dict[str, str]) -> None:
    # GitHub command files are line-oriented. Never allow output injection.
    for key, value in values.items():
        if any(c in key + value for c in "\r\n\x00"):
            raise ValueError("Multiline command-file values are not allowed.")
    with open(path, "a", encoding="utf-8") as stream:
        for key, value in values.items():
            stream.write(f"{key}={value}\n")


def verify_archive(archive: Path, expected: str) -> None:
    if not DIGEST.fullmatch(expected):
        raise ValueError("Invalid expected SHA-256 digest.")
    with archive.open("rb") as stream:
        actual = hashlib.file_digest(stream, "sha256").hexdigest()
    if actual != expected:
        raise ValueError("SDK archive checksum mismatch; remove the corrupt cache entry.")


def download_archive(version: str, archive: Path) -> None:
    version = exact_version(version)
    archive.parent.mkdir(parents=True, exist_ok=True)
    # Download to a unique temporary path, never reuse a partial download.
    fd, partial = tempfile.mkstemp(prefix="download-", dir=archive.parent)
    os.close(fd)
    try:
        subprocess.run(
            ["curl", "--fail", "--location", "--silent", "--show-error",
             "--proto", "=https", "--proto-redir", "=https", "--tlsv1.2",
             "--connect-timeout", "20", "--max-time", "600", "--retry", "2",
             "--output", partial, f"{BASE_URL}/flutter_linux_{version}-stable.tar.xz"],
            check=True, timeout=1900,
        )
        os.replace(partial, archive)
    finally:
        Path(partial).unlink(missing_ok=True)


def install_archive(archive: Path, release: dict[str, str], temp: Path) -> Path:
    version = exact_version(release["flutter-version"])
    dart_version = exact_version(release["dart-version"])
    verify_archive(archive, release["sha256"])
    temp.mkdir(parents=True, exist_ok=True)
    destination = Path(tempfile.mkdtemp(prefix="dart-actions-flutter-", dir=temp))
    try:
        with tarfile.open(archive, "r:xz") as bundle:
            # Reject traversal, external links, devices, and unexpected roots.
            def sdk_filter(member: tarfile.TarInfo, target: str) -> tarfile.TarInfo:
                if Path(member.name).parts[:1] != ("flutter",):
                    raise ValueError("SDK archive contains an unexpected root.")
                return tarfile.data_filter(member, target)
            bundle.extractall(destination, filter=sdk_filter)
        root = destination / "flutter"
        env = {**os.environ, "CI": "true", "FLUTTER_SUPPRESS_ANALYTICS": "true"}
        for executable, expected in (
            (root / "bin/cache/dart-sdk/bin/dart", f"Dart SDK version: {dart_version}"),
            (root / "bin/flutter", f"Flutter {version}"),
        ):
            result = subprocess.run([str(executable), "--version"], check=True,
                                    capture_output=True, text=True, env=env, timeout=180)
            output = result.stdout + result.stderr
            if re.search(re.escape(expected) + r"(?:\s|$)", output) is None:
                raise ValueError(f"Installed SDK version does not match {expected}.")
        return root
    except BaseException:
        shutil.rmtree(destination)
        raise


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("resolve", "install"))
    parser.add_argument("--version-file", default=".fvmrc")
    parser.add_argument("--releases-file", default=".github/flutter-releases.json")
    args = parser.parse_args()
    try:
        if platform.system() != "Linux" or platform.machine() not in ("x86_64", "amd64"):
            raise ValueError("This action currently supports Linux x64 only.")
        release = resolve_release(Path(os.environ["GITHUB_WORKSPACE"]),
                                  args.version_file, args.releases_file)
        if args.command == "resolve":
            emit(os.environ["GITHUB_OUTPUT"], release)
            return 0
        temp = Path(os.environ["RUNNER_TEMP"])
        archive = temp / "dart-actions-archives" / release["sha256"] / "flutter.tar.xz"
        if not archive.exists():
            download_archive(release["flutter-version"], archive)
        root = install_archive(archive, release, temp)
        emit(os.environ["GITHUB_OUTPUT"], {**release, "sdk-path": str(root)})
        emit(os.environ["GITHUB_ENV"], {"FLUTTER_ROOT": str(root)})
        bin_path = str(root / "bin")
        if any(c in bin_path for c in "\r\n\x00"):
            raise ValueError("Invalid SDK path.")
        with open(os.environ["GITHUB_PATH"], "a", encoding="utf-8") as stream:
            stream.write(bin_path + "\n")
        return 0
    except (OSError, ValueError, KeyError, TypeError, AttributeError,
            subprocess.SubprocessError, tarfile.TarError) as error:
        print(f"SDK setup failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
