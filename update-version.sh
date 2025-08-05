#!/bin/bash
set -euo pipefail

# === Config ===
GIT_REPO_PATH="$(dirname "$0")"
GIT_VERSION_FILE="$GIT_REPO_PATH/version"
CHANGELOG_FILE="$GIT_REPO_PATH/CHANGELOG.md"
VALID_CATEGORIES=("Added" "Changed" "Fixed" "Removed")

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
$DRY_RUN && echo "[🔍] Dry-run mode is ON. No files will be written."

# === Changelog collection with fzf ===
TODAY_DATE=$(date +%F)
echo
echo "[📝] Add changelog entries for version $NEW_VERSION using fzf."
echo "Enter one entry at a time. Leave message blank to finish."
echo

declare -A SECTIONS

while true; do
  CATEGORY=$(printf "%s\n" "${VALID_CATEGORIES[@]}" | fzf --prompt="Select category: " --height=10 --reverse) || break
  read -rp "Message for $CATEGORY (leave blank to finish): " MESSAGE
  [[ -z "$MESSAGE" ]] && break
  SECTIONS["$CATEGORY"]+="- $MESSAGE"$'\n'
done

# === Show preview of changelog ===
if (( ${#SECTIONS[@]} )); then
  echo
  echo "[🧾] Preview of new changelog section:"
  echo "## [$NEW_VERSION] - $TODAY_DATE"
  for CATEGORY in "${VALID_CATEGORIES[@]}"; do
    if [[ -n "${SECTIONS[$CATEGORY]:-}" ]]; then
      echo "### $CATEGORY"
      echo "${SECTIONS[$CATEGORY]}"
    fi
  done
  echo
else
  echo "[⚠️] No changelog entries provided. Skipping changelog update."
fi

# === File updates (if not dry-run) ===
if ! $DRY_RUN; then
  echo "$NEW_VERSION" > "$GIT_VERSION_FILE"
  echo "[✅] Updated version file."

  if (( ${#SECTIONS[@]} )); then
    TEMP_CHANGELOG=$(mktemp)
    {
      cat "$CHANGELOG_FILE"
      echo "## [$NEW_VERSION] - $TODAY_DATE"
      for CATEGORY in "${VALID_CATEGORIES[@]}"; do
        if [[ -n "${SECTIONS[$CATEGORY]:-}" ]]; then
          echo "### $CATEGORY"
          echo "${SECTIONS[$CATEGORY]}"
        fi
      done
    } > "$TEMP_CHANGELOG"
    mv "$TEMP_CHANGELOG" "$CHANGELOG_FILE"
    echo "[✅] CHANGELOG.md updated."
    git add "$CHANGELOG_FILE"
  fi

  # === Git commit & push ===
  cd "$GIT_REPO_PATH"
  git add version
  git commit -m "chore: bump version to $NEW_VERSION"

  read -rp "[🔄] Do you want to push the changes to GitHub? (y/n): " push_choice
  if [[ "$push_choice" == "y" ]]; then
    git push origin master
    echo "[🚀] Version pushed to GitHub."
  else
    echo "[ℹ️] Skipping push to GitHub."
  fi
else
  echo "[🧪] Dry-run complete. No files were changed."
fi
