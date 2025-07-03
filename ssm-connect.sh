#!/bin/bash
set -euo pipefail

AWS_PROFILE="ssm-session-manager"
AWS_REGION="ap-south-1"
CONFIG_DIR="$HOME/.ssm-connect"
ALIAS_FILE="$CONFIG_DIR/aliases"
VERSION_FILE="$CONFIG_DIR/version"
UPDATE_FLAG="$CONFIG_DIR/update_available"
SCRIPT_PATH="/usr/local/bin/ssm-connect"
GITHUB_RAW_URL="https://raw.githubusercontent.com/muhammadsemeer/ssm-connect/refs/heads/master/ssm-connect.sh"

# === Ensure config dir exists ===
mkdir -p "$CONFIG_DIR"
touch "$ALIAS_FILE"
chmod 600 "$ALIAS_FILE"

# === Version management ===
if [[ ! -f "$VERSION_FILE" ]]; then
  echo "0.0.0" > "$VERSION_FILE"
fi
SCRIPT_VERSION=$(cat "$VERSION_FILE")

# === Check required tools ===
for cmd in aws fzf curl; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "[ERROR] Missing required tool: $cmd"
    exit 1
  fi
done

# === Background update checker ===
(
  LATEST_VERSION=$(curl -fsSL "$GITHUB_RAW_URL" | grep '^SCRIPT_VERSION=' | cut -d'"' -f2 || echo "")
  CURRENT_VERSION=$(cat "$VERSION_FILE" 2>/dev/null || echo "0.0.0")

  if [[ -n "$LATEST_VERSION" && "$LATEST_VERSION" != "$CURRENT_VERSION" ]]; then
    echo "[⬆️] New version available: $LATEST_VERSION (current: $CURRENT_VERSION)" > "$UPDATE_FLAG"
  else
    rm -f "$UPDATE_FLAG"
  fi
) &

# === Notify update if available ===
if [[ -f "$UPDATE_FLAG" ]]; then
  cat "$UPDATE_FLAG"
  echo "[ℹ️] Run: ssm-connect --update to upgrade."
fi

show_help() {
cat <<EOF
Usage:
  ssm-connect                      Launch interactive instance selector
  ssm-connect <alias>              Connect directly to instance using alias

  ssm-connect --add-alias -a a id  Add or update alias (alias, instance-id)
  ssm-connect --remove-alias -r a  Remove an alias
  ssm-connect --list-aliases -l    List all aliases
  ssm-connect --update             Update the CLI tool
  ssm-connect --version            Show current version
  ssm-connect --help         -h    Show this help
EOF
}

case "${1:-}" in
  --help|-h)
    show_help
    exit 0
    ;;

  --version)
    echo "ssm-connect version $SCRIPT_VERSION"
    exit 0
    ;;

  --update)
    echo "[⬇️] Updating ssm-connect from GitHub..."
    sudo curl -fsSL "$GITHUB_RAW_URL" -o "$SCRIPT_PATH"
    sudo chmod +x "$SCRIPT_PATH"

    NEW_VERSION=$(curl -fsSL "$GITHUB_RAW_URL" | grep '^SCRIPT_VERSION=' | cut -d'"' -f2 || echo "")
    echo "$NEW_VERSION" > "$VERSION_FILE"
    rm -f "$UPDATE_FLAG"

    echo "[✅] Updated to version $NEW_VERSION"
    exit 0
    ;;

  --add-alias|-a)
    if [[ $# -ne 3 ]]; then
      echo "[ERROR] Usage: ssm-connect -a <alias> <instance-id>"
      exit 1
    fi
    NEW_ALIAS="$2"
    NEW_ID="$3"
    sed -i "/^$NEW_ALIAS /d" "$ALIAS_FILE"
    echo "$NEW_ALIAS $NEW_ID" >> "$ALIAS_FILE"
    echo "[✅] Alias '$NEW_ALIAS' → '$NEW_ID' added."
    exit 0
    ;;

  --remove-alias|-r)
    if [[ $# -ne 2 ]]; then
      echo "[ERROR] Usage: ssm-connect -r <alias>"
      exit 1
    fi
    TO_REMOVE="$2"
    if grep -q "^$TO_REMOVE " "$ALIAS_FILE"; then
      sed -i "/^$TO_REMOVE /d" "$ALIAS_FILE"
      echo "[🗑️] Alias '$TO_REMOVE' removed."
    else
      echo "[WARN] Alias '$TO_REMOVE' not found."
    fi
    exit 0
    ;;

  --list-aliases|-l)
    if [[ ! -s "$ALIAS_FILE" ]]; then
      echo "[📭] No aliases found."
      exit 0
    fi
    echo "[📋] Current aliases:"
    column -t "$ALIAS_FILE"
    exit 0
    ;;

  --*|-*)
    echo "[ERROR] Unknown option: $1"
    show_help
    exit 1
    ;;
esac

# === AWS profile check ===
if ! aws configure list-profiles | grep -q "^$AWS_PROFILE$"; then
  echo "[INFO] AWS profile '$AWS_PROFILE' not found. Configuring..."
  aws configure --profile "$AWS_PROFILE"
fi

# === Direct connect ===
if [[ $# -eq 1 ]]; then
  ALIAS_NAME="$1"
  INSTANCE_ID=$(grep "^$ALIAS_NAME " "$ALIAS_FILE" | awk '{print $2}')

  if [[ -z "$INSTANCE_ID" ]]; then
    echo "[ERROR] Alias '$ALIAS_NAME' not found."
    exit 1
  fi

  echo "[🔌] Connecting to '$ALIAS_NAME' ($INSTANCE_ID)..."
  aws ssm start-session --target "$INSTANCE_ID" --region "$AWS_REGION" --profile "$AWS_PROFILE"
  exit 0
fi

# === Interactive connect ===
if [[ ! -s "$ALIAS_FILE" ]]; then
  echo "[📭] No aliases found. Add one using: ssm-connect --add-alias <alias> <instance-id>"
  exit 0
fi

echo "[🔍] Selecting instance interactively..."
SELECTED_LINE=$(cat "$ALIAS_FILE" | fzf --prompt="Select instance: ")

if [[ -z "$SELECTED_LINE" ]]; then
  echo "[WARN] No selection made."
  exit 0
fi

ALIAS_NAME=$(echo "$SELECTED_LINE" | awk '{print $1}')
INSTANCE_ID=$(echo "$SELECTED_LINE" | awk '{print $2}')

echo "[🔌] Connecting to '$ALIAS_NAME' ($INSTANCE_ID)..."
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE"

echo "[💨] Session ended. Reconnect anytime using: ssm-connect $ALIAS_NAME"
