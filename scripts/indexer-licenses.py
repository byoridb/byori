#!/usr/bin/env python3
"""Collect crate-provided license texts for the native indexer distribution."""
import json
import pathlib
import sys


def main():
    metadata = json.load(sys.stdin)
    output = pathlib.Path(sys.argv[1])
    sections = ["Byori code indexer — dependency license notices\n"]
    for package in sorted(metadata["packages"], key=lambda item: (item["name"], item["version"])):
        if package.get("source") is None:
            continue
        root = pathlib.Path(package["manifest_path"]).parent
        files = sorted({
            path for pattern in ("LICENSE*", "LICENCE*", "COPYING*", "license*", "licence*")
            for path in root.rglob(pattern) if path.is_file()
        })
        license_file = package.get("license_file")
        if license_file:
            path = root / license_file
            if path.is_file() and path not in files:
                files.append(path)
        fallback = pathlib.Path(__file__).resolve().parents[1] / "indexer" / "licenses" / (package["name"] + "-LICENSE")
        if fallback.is_file():
            files.append(fallback)
        if package["name"] == "tree-sitter" and not fallback.is_file():
            raise SystemExit("tree-sitter's crate omits its MIT text; indexer/licenses/tree-sitter-LICENSE is required")
        if not files:
            raise SystemExit("crate has no packaged license text: " + package["name"])
        sections.append("\n" + "=" * 72 + "\n")
        sections.append("{} {} ({})\n{}\n".format(
            package["name"], package["version"], package.get("license") or "see text",
            package.get("repository") or package.get("homepage") or "",
        ))
        for path in files:
            sections.append("\n--- {} ---\n{}\n".format(path.name, path.read_text(encoding="utf-8")))
    output.write_text("".join(sections), encoding="utf-8")


if __name__ == "__main__":
    main()
