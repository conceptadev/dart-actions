"""Build an isolated legacy/modern Melos workspace without global activation.

This is a bootstrap/CI compatibility smoke test, not proof that a consumer's
complete release workflow or version preparation works with that Melos version.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile

SUPPORTED = ("6.3.3", "7.3.0", "8.5.0", "8.7.0")


def populate(root: Path, version: str) -> None:
    if version not in SUPPORTED:
        raise ValueError("Unsupported compatibility-matrix version.")
    legacy = version.startswith("6.")
    package = root / "packages/example"
    (package / "bin").mkdir(parents=True)
    (package / "pubspec.yaml").write_text(
        "name: foundation_example\npublish_to: none\n"
        "environment:\n  sdk: '>=3.11.0 <4.0.0'\n"
        + ("" if legacy else "resolution: workspace\n")
    )
    (package / "bin/main.dart").write_text("void main() {\n  print('Melos fixture passed');\n}\n")
    configuration = (
        "scripts:\n  ci:\n    run: dart run melos exec -- dart run bin/main.dart\n"
    )
    pubspec = ("name: foundation_workspace\npublish_to: none\n"
               "environment:\n  sdk: '>=3.11.0 <4.0.0'\n"
               f"dev_dependencies:\n  melos: {version}\n")
    if legacy:
        (root / "melos.yaml").write_text(
            "name: foundation_workspace\npackages:\n  - packages/*\n" + configuration)
    else:
        pubspec += "workspace:\n  - packages/example\nmelos:\n"
        pubspec += "\n".join("  " + line for line in configuration.splitlines()) + "\n"
    (root / "pubspec.yaml").write_text(pubspec)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("version", choices=SUPPORTED)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="dart-actions-melos-") as directory:
        root = Path(directory)
        populate(root, args.version)
        for command in (
            ["dart", "pub", "get"],
            ["dart", "run", "melos", "--version"],
            ["dart", "run", "melos", "bootstrap"],
            ["dart", "run", "melos", "run", "ci", "--no-select"],
        ):
            subprocess.run(command, cwd=root, check=True, timeout=300)


if __name__ == "__main__":
    main()
