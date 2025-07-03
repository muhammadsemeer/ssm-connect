#!/bin/bash
set -euo pipefail

VERSION_FILE="$HOME/.ssm-connect/version"

if [[ ! -f "$VERSION_FILE" ]]; then
  echo "0.0.0" > "$VERSION_FILE"
fi

CURRENT_VERSION=$(cat "$VERSION_FILE")

IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_VERSION"

usage() {
  echo "Usage: $0 [patch|minor|major]"
  exit 1
}

if [[ $# -ne 1 ]]; then
  usage
fi

INCREMENT_TYPE="$1"

case "$INCREMENT_TYPE" in
  patch)
    PATCH=$((PATCH + 1))
    ;;
  minor)
    MINOR=$((MINOR + 1))
    PATCH=0
    ;;
  major)
    MAJOR=$((MAJOR + 1))
    MINOR=0
    PATCH=0
    ;;
  *)
    usage
    ;;
esac

NEW_VERSION="${MAJOR}.${MINOR}.${PATCH}"
echo "$NEW_VERSION" > "$VERSION_FILE"

echo "[✅] Version updated: $CURRENT_VERSION → $NEW_VERSION"
