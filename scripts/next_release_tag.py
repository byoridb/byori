#!/usr/bin/env python3
"""Choose the next stable patch tag from newline-delimited release tags."""

import argparse
import re
import sys


STABLE_TAG = re.compile(r"^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")


def parse_stable_tag(value):
    match = STABLE_TAG.fullmatch(value.strip())
    if match is None:
        return None
    return tuple(int(component) for component in match.groups())


def next_patch_tag(tags, baseline):
    baseline_version = parse_stable_tag(baseline)
    if baseline_version is None:
        raise ValueError("baseline must look like v1.2.3")
    versions = [baseline_version]
    versions.extend(
        version
        for version in (parse_stable_tag(tag) for tag in tags)
        if version is not None
    )
    major, minor, patch = max(versions)
    return f"v{major}.{minor}.{patch + 1}"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--baseline", required=True)
    args = parser.parse_args()
    try:
        print(next_patch_tag(sys.stdin, args.baseline))
    except ValueError as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
