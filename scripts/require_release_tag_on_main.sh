#!/usr/bin/env bash
set -euo pipefail

TAG="${1:-}"
SEMVER_PATTERN='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?(\+[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$'
if [[ ! "$TAG" =~ $SEMVER_PATTERN ]]; then
  echo "release tag must look like v1.2.3 or a SemVer prerelease (got: ${TAG:-empty})" >&2
  exit 2
fi

git rev-parse --verify --quiet "refs/tags/$TAG" >/dev/null \
  || { echo "release tag does not exist: $TAG" >&2; exit 3; }
git fetch --no-tags origin "+refs/heads/main:refs/remotes/origin/main"

TAG_COMMIT="$(git rev-list -n 1 "$TAG")"
if ! git merge-base --is-ancestor "$TAG_COMMIT" refs/remotes/origin/main; then
  echo "$TAG points to $TAG_COMMIT, which is not contained in origin/main" >&2
  echo "Merge the change into main and create a new release tag there." >&2
  exit 4
fi

echo "$TAG is on origin/main at $TAG_COMMIT"
