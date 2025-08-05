#!/bin/bash
set -euo pipefail

# === Config ===
REPO_URL="https://raw.githubusercontent.com/muhammadsemeer/ssm-connect/master/version"
LOCAL_VERSION_FILE="$HOME/.ssm-connect/version"
GIT_REPO_PATH="$(dirname "$0")"  # Assumes script is in git repo
GIT_VERSION_FILE="$GIT_REPO_PATH/version"

usage() {
  echo "Usage: $0 [patch|minor|major]"
  exit 1
}

if [[ $# -ne 1 ]]; then
  usage
fi

BUMP_TYPE="$1"

# === Fetch latest remote version from GitHub ===
echo "[🌐] Fetching latest version from GitHub..."
LATEST_REMOTE_VERSION=$(curl -fsSL "$REPO_URL" || echo "0.0.0")
if [[ -z "$LATEST_REMOTE_VERSION" ]]; then
  echo "[❌] Failed to fetch latest version."
  exit 1
fi

IFS='.' read -r MAJOR MINOR PATCH <<< "$LATEST_REMOTE_VERSION"

case "$BUMP_TYPE" in
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

# === Update local and repo version file ===
echo "$NEW_VERSION" > "$LOCAL_VERSION_FILE"
echo "$NEW_VERSION" > "$GIT_VERSION_FILE"

echo "[✅] Version bumped: $LATEST_REMOTE_VERSION → $NEW_VERSION"

# === Commit and push if in Git repo ===
if git -C "$GIT_REPO_PATH" rev-parse 2>/dev/null; then
  cd "$GIT_REPO_PATH"
  git add version
  git commit -m "chore: bump version to $NEW_VERSION"
  # ask to push
  read -p "[🔄] Do you want to push the changes to GitHub? (y/n): " push_choice
  if [[ "$push_choice" != "y" ]]; then
    echo "[ℹ️] Skipping push to GitHub."
    exit 0
  fi
  git push origin master
  echo "[🚀] Version pushed to GitHub."
else
  echo "[ℹ️] Not in a git repo. Skipping push."
fi
