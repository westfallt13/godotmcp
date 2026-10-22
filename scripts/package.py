#!/usr/bin/env python3
"""Build an installable addon ZIP with no connection secrets or project cache."""
import argparse
from pathlib import Path
from zipfile import ZipFile, ZIP_DEFLATED


def main():
    root = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=root / "dist/hermes-godot-mcp-1.0.1.zip")
    args = parser.parse_args()
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with ZipFile(args.output, "w", ZIP_DEFLATED) as archive:
        for path in sorted((root / "addons/hermes_mcp").rglob("*")):
            if path.is_file() and not path.is_symlink() and path.suffix in {".gd", ".uid", ".cfg", ".md", ".txt"}:
                archive.write(path, path.relative_to(root))
        for name in ("README.md", "CHANGELOG.md", "LICENSE", "docs/architecture.md", "scripts/hermes_config.py"):
            archive.write(root / name, name)
    print(args.output)


if __name__ == "__main__":
    main()
