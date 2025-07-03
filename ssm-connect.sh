#!/bin/bash
set -euo pipefail

AWS_PROFILE="ssm-session-manager"
AWS_REGION="ap-south-1"
CONFIG_DIR="$HOME/.ssm-connect"
ALIAS_FILE="$CONFIG_DIR/aliases"
VERSION_FILE="$CONFIG_DIR/version"
REMOTE_VERSION_URL="https://raw.githubusercontent.com/muhammadsemeer/ssm-connect/master/version"
SCRIPT_URL="https://raw.githubusercontent.com/muhammadsemeer/ssm-connect/master/ssm-connect.sh"
SCRIPT_PATH="/usr/local/bin/ssm-connect"

# === Ensure config dir and version ===
mkdir -p "$CONFIG_DIR"
touch "$ALIAS_FILE"
chmod 600 "$ALIAS_FILE"

# === Version Check (non-blocking) ===
check_for_update() {
  if [[ -f "$VERSION_FILE" ]]; then
    LOCAL_VERSION=$(cat "$VERSION_FILE")
  else
    LOCAL_VERSION="0.0.0"
  fi

  LATEST_VERSION=$(curl -fsSL "$REMOTE_VERSION_URL" || echo "$LOCAL_VERSION")

  if [[ "$LATEST_VERSION" != "$LOCAL_VERSION" ]]; then
    echo "[⬆️] New version available: $LATEST_VERSION (current: $LOCAL_VERSION)"
    echo "     Run: ssm-connect --update to upgrade."
  fi
}

# === Update Command ===
if [[ "${1:-}" == "--update" ]]; then
  echo "[⬇️] Updating ssm-connect from GitHub..."
  curl -fsSL "$SCRIPT_URL" -o "$SCRIPT_PATH"
  chmod +x "$SCRIPT_PATH"
  curl -fsSL "$REMOTE_VERSION_URL" -o "$VERSION_FILE"
  echo "[✅] ssm-connect updated successfully!"
  exit 0
fi

# === Run version check in background ===
check_for_update &

# === Check required tools ===
for cmd in aws fzf; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "[ERROR] Missing required tool: $cmd"
    exit 1
  fi
done

show_help() {
cat <<EOF
Usage:
  ssm-connect                     Launch interactive instance selector
  ssm-connect <alias>             Connect directly to instance using alias

  ssm-connect --add-alias -a a id    Add or update alias (alias, instance-id)
  ssm-connect --remove-alias -r a    Remove an alias
  ssm-connect --list-aliases -l      List all aliases
  ssm-connect --update               Update to latest version
  ssm-connect --help         -h      Show this help
EOF
}

case "${1:-}" in
  --help|-h)
    show_help
    exit 0
    ;;
  --add-alias|-a)
    if [[ $# -ne 3 ]]; then
      echo "[ERROR] Usage: ssm-connect -a <alias> <instance-id>"
      exit 1
    fi
    NEW_ALIAS="$2"
    NEW_ID="$3"

    sed -i.bak "/^$NEW_ALIAS /d" "$ALIAS_FILE"
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
      sed -i.bak "/^$TO_REMOVE /d" "$ALIAS_FILE"
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
    echo "[❌] Unknown option: $1"
    show_help
    exit 1
    ;;
esac

# === AWS Profile Config ===
if ! aws configure list-profiles | grep -q "^$AWS_PROFILE$"; then
  echo "[INFO] AWS profile '$AWS_PROFILE' not found. Configuring..."
  aws configure --profile "$AWS_PROFILE"
fi

# === Direct connect ===
if [[ $# -eq 1 ]]; then
  ALIAS_NAME="$1"
  INSTANCE_ID=$(grep "^$ALIAS_NAME " "$ALIAS_FILE" | awk '{print $2}')

  if [[ -z "$INSTANCE_ID" ]]; then
    echo "[ERROR] Alias '$ALIAS_NAME' not found in $ALIAS_FILE"
    exit 1
  fi

  echo "[🔌] Connecting to '$ALIAS_NAME' ($INSTANCE_ID)..."
  aws ssm start-session --target "$INSTANCE_ID" --region "$AWS_REGION" --profile "$AWS_PROFILE"
  exit 0
fi

# === Interactive connect ===
if [[ ! -s "$ALIAS_FILE" ]]; then
  echo "[📭] No aliases found. Use: ssm-connect --add-alias <alias> <id>"
  exit 0
fi

echo "[🔍] Selecting instance interactively..."
SELECTED_LINE=$(cat "$ALIAS_FILE" | fzf --prompt="Select instance: ")

if [[ -z "$SELECTED_LINE" ]]; then
  echo "[⚠️] No instance selected."
  exit 0
fi

ALIAS_NAME=$(echo "$SELECTED_LINE" | awk '{print $1}')
INSTANCE_ID=$(echo "$SELECTED_LINE" | awk '{print $2}')

echo "[🔌] Connecting to '$ALIAS_NAME' ($INSTANCE_ID)..."
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE"

echo "[✅] Session ended."
