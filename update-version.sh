#!/usr/bin/env bash
set -euo pipefail

# === Config ===
readonly GIT_REPO_PATH="$(cd "$(dirname "$0")" && pwd)"
readonly GIT_VERSION_FILE="$GIT_REPO_PATH/version"

# === Output helpers ===
say()  { printf '%s\n' "$*"; }
warn() { printf '[⚠️] %s\n' "$*" >&2; }
die()  { printf '[⚠️] %s\n' "$*" >&2; exit 1; }

usage() {
  echo "Usage: $0 [patch|minor|major] [--dry-run]"
  exit 1
}

# === Argument parsing ===
(( $# >= 1 && $# <= 2 )) || usage
BUMP_TYPE="$1"
case "$BUMP_TYPE" in
  patch|minor|major) ;;
  *) usage ;;
esac

DRY_RUN=false
[[ "${2:-}" == "--dry-run" ]] && DRY_RUN=true

# === Ensure on master branch ===
CURRENT_BRANCH=$(git -C "$GIT_REPO_PATH" rev-parse --abbrev-ref HEAD)
[[ "$CURRENT_BRANCH" == "master" ]] \
  || die "You are not on the master branch. Current branch: $CURRENT_BRANCH"

# === Read current version from file ===
if [[ -f "$GIT_VERSION_FILE" ]]; then
  CURRENT_VERSION=$(<"$GIT_VERSION_FILE")
  CURRENT_VERSION="${CURRENT_VERSION//[[:space:]]/}"
else
  say "[ℹ️] No version file found. Assuming 0.0.0"
  CURRENT_VERSION="0.0.0"
fi

IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_VERSION"
MAJOR=${MAJOR:-0}; MINOR=${MINOR:-0}; PATCH=${PATCH:-0}

case "$BUMP_TYPE" in
  patch) PATCH=$((PATCH + 1)) ;;
  minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
  major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
esac

NEW_VERSION="${MAJOR}.${MINOR}.${PATCH}"
TAG_NAME="v$NEW_VERSION"

say "[🚧] Bumping version: $CURRENT_VERSION → $NEW_VERSION"

if $DRY_RUN; then
  say "[🔍] Dry-run mode is ON. No files will be written."
  say "[🧪] Would bump version file to $NEW_VERSION and create tag $TAG_NAME"
  exit 0
fi

# === File updates ===
echo "$NEW_VERSION" > "$GIT_VERSION_FILE"
say "[✅] Updated version file."

# === Git commit, tag & push ===
cd "$GIT_REPO_PATH"
git add version
git commit -m "chore: bump version to $NEW_VERSION"

if git rev-parse "$TAG_NAME" >/dev/null 2>&1; then
  warn "Tag $TAG_NAME already exists. Skipping tag creation."
else
  git tag -a "$TAG_NAME" -m "Release $TAG_NAME"
  say "[🏷️] Created git tag: $TAG_NAME"
fi

read -rp "[🔄] Do you want to push the changes to GitHub? (y/n): " push_choice
if [[ "$push_choice" == "y" ]]; then
  git push origin master
  git push origin "$TAG_NAME"
  say "[🚀] Version and tag $TAG_NAME pushed to GitHub."
else
  say "[ℹ️] Skipping push to GitHub."
fi
