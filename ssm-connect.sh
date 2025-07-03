#!/bin/bash

set -euo pipefail

AWS_PROFILE="ssm-session-manager"
AWS_REGION="ap-south-1"
CONFIG_DIR="$HOME/.ssm-connect"
ALIAS_FILE="$CONFIG_DIR/aliases"

# === Ensure alias file exists ===
mkdir -p "$CONFIG_DIR"
touch "$ALIAS_FILE"
chmod 600 "$ALIAS_FILE"

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
  ssm-connect --help         -h      Show this help
  ssm-connect --uninstall --remove   Uninstall script and remove all aliases
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

    # validate and add
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

    --uninstall|--remove)
      echo "[⚠️] This will remove 'ssm-connect', all saved aliases, and AWS profile '$AWS_PROFILE'"
      read -p "Are you sure? (y/N): " confirm
      if [[ "$confirm" =~ ^[Yy]$ ]]; then
        echo "[🗑️] Removing script from /usr/local/bin/ssm-connect"
        sudo rm -f /usr/local/bin/ssm-connect

        echo "[🗑️] Deleting config directory $CONFIG_DIR"
        rm -rf "$CONFIG_DIR"

        echo "[🧹] Cleaning AWS profile '$AWS_PROFILE'"
        AWS_CONFIG="$HOME/.aws/config"
        AWS_CREDS="$HOME/.aws/credentials"

        if [[ -f "$AWS_CONFIG" ]]; then
          sed -i.bak "/^\[profile $AWS_PROFILE\]/,/^\[.*\]/ {/^\[.*\]/!d}" "$AWS_CONFIG"
          sed -i.bak "/^\[profile $AWS_PROFILE\]/d" "$AWS_CONFIG"
        fi

        if [[ -f "$AWS_CREDS" ]]; then
          sed -i.bak "/^\[$AWS_PROFILE\]/,/^\[.*\]/ {/^\[.*\]/!d}" "$AWS_CREDS"
          sed -i.bak "/^\[$AWS_PROFILE\]/d" "$AWS_CREDS"
        fi

        echo "[✅] Uninstalled successfully."
      else
        echo "[❎] Aborted."
      fi
      exit 0
      ;;

  --*|-*)
      echo "Unknown option: $1"
      show_help
      exit 1
      ;;
esac


# === Ensure AWS profile exists ===
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

# === Interactive selection ===
if [[ ! -s "$ALIAS_FILE" ]]; then
  echo "[📭] No aliases found. Please add an alias using: ssm-connect --add-alias <alias> <instance-id>"
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

echo "Session ended. You can reconnect using: ssm-connect $ALIAS_NAME"

