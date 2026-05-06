#!/bin/bash
set -euo pipefail

# === Config ===
GIT_REPO_PATH="$(dirname "$0")"
GIT_VERSION_FILE="$GIT_REPO_PATH/version"

usage() {
  echo "Usage: $0 [patch|minor|major] [--dry-run]"
  exit 1
}

# === Argument parsing ===
DRY_RUN=false
if [[ $# -lt 1 || $# -gt 2 ]]; then
  usage
fi

BUMP_TYPE="$1"
if [[ "${2:-}" == "--dry-run" ]]; then
  DRY_RUN=true
fi

# === Ensure on master branch ===
CURRENT_BRANCH=$(git -C "$GIT_REPO_PATH" rev-parse --abbrev-ref HEAD)
if [[ "$CURRENT_BRANCH" != "master" ]]; then
  echo "[⚠️] You are not on the master branch. Current branch: $CURRENT_BRANCH"
  exit 1
fi

# === Read current version from file ===
if [[ -f "$GIT_VERSION_FILE" ]]; then
  CURRENT_VERSION=$(<"$GIT_VERSION_FILE")
else
  echo "[ℹ️] No version file found. Assuming 0.0.0"
  CURRENT_VERSION="0.0.0"
fi

IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_VERSION"

case "$BUMP_TYPE" in
  patch) PATCH=$((PATCH + 1)) ;;
  minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
  major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
  *) usage ;;
esac

NEW_VERSION="${MAJOR}.${MINOR}.${PATCH}"

echo "[🚧] Bumping version: $CURRENT_VERSION → $NEW_VERSION"

if $DRY_RUN; then
  echo "[🔍] Dry-run mode is ON. No files will be written."
  echo "[🧪] Would bump version file to $NEW_VERSION and create tag v$NEW_VERSION"
  exit 0
fi

# === File updates ===
echo "$NEW_VERSION" > "$GIT_VERSION_FILE"
echo "[✅] Updated version file."

# === Git commit, tag & push ===
cd "$GIT_REPO_PATH"
git add version
git commit -m "chore: bump version to $NEW_VERSION"

TAG_NAME="v$NEW_VERSION"
if git rev-parse "$TAG_NAME" >/dev/null 2>&1; then
  echo "[⚠️] Tag $TAG_NAME already exists. Skipping tag creation."
else
  git tag -a "$TAG_NAME" -m "Release $TAG_NAME"
  echo "[🏷️] Created git tag: $TAG_NAME"
fi

read -rp "[🔄] Do you want to push the changes to GitHub? (y/n): " push_choice
if [[ "$push_choice" == "y" ]]; then
  git push origin master
  git push origin "$TAG_NAME"
  echo "[🚀] Version and tag $TAG_NAME pushed to GitHub."
else
  echo "[ℹ️] Skipping push to GitHub."
fi
