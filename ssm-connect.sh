#!/bin/bash
set -euo pipefail

AWS_PROFILE="ssm-session-manager"
AWS_REGION="ap-south-1"
CONFIG_DIR="$HOME/.ssm-connect"
ALIAS_FILE="$CONFIG_DIR/aliases"
VERSION_FILE="$CONFIG_DIR/version"
REMOTE_VERSION_URL="https://raw.githubusercontent.com/muhammadsemeer/ssm-connect/master/version"
SCRIPT_URL="https://raw.githubusercontent.com/muhammadsemeer/ssm-connect/master/ssm-connect.sh"
REMOTE_CHANGELOG_FILE="https://raw.githubusercontent.com/muhammadsemeer/ssm-connect/master/CHANGELOG.md"
SCRIPT_PATH="/usr/local/bin/ssm-connect"
CHANGELOG_PATH="$CONFIG_DIR/CHANGELOG.md"
S3_BUCKET="ssm-scp"

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

  LATEST_VERSION=$(curl -fsSL "$REMOTE_VERSION_URL" 2>/dev/null || echo "$LOCAL_VERSION")

  if [[ "$LATEST_VERSION" != "$LOCAL_VERSION" ]]; then
    echo "[⬆️] New version available: $LATEST_VERSION (current: $LOCAL_VERSION)"
    echo "[ℹ️] Run: ssm-connect --update to upgrade."
  fi
}

# === Run version check in background, only for main usage ===
if [[ "${1:-}" != "--version" && "${1:-}" != "--help" && "${1:-}" != "-h" && "${1:-}" != "--update" && "${1:-}" != "--uninstall" ]]; then
  check_for_update &
else
  # If version or help command, run immediately
  check_for_update
fi

# === Check required tools ===
for cmd in aws fzf; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "[ERROR] Missing required tool: $cmd"
    exit 1
  fi
done

check_ssm_command() {
  local COMMAND_ID="$1"
  echo "[⏳] Waiting for SSM command ($COMMAND_ID) to complete..."

  while true; do
    STATUS=$(aws ssm list-command-invocations \
      --region "$AWS_REGION" \
      --profile "$AWS_PROFILE" \
      --command-id "$COMMAND_ID" \
      --details \
      --query "CommandInvocations[0].Status" \
      --output text)

    if [[ "$STATUS" == "Success" ]]; then
      break
    elif [[ "$STATUS" == "Failed" || "$STATUS" == "Cancelled" || "$STATUS" == "TimedOut" ]]; then
      echo "[❌] SSM command failed with status: $STATUS"
      echo "[ℹ️] Ensure the instance has AWS CLI installed in the home directory of the user 'ubuntu'"
      echo "[ℹ️] No need to configure AWS CLI on the instance, it will use the IAM role attached to the instance."
      echo "[ℹ️] If you encounter issues, please check the instance's IAM role permissions. It should have permissions to access S3 $S3_BUCKET bucket."
      exit 1
    fi

    sleep 2
  done
}


show_help() {
cat <<EOF
Usage:
  ssm-connect                     Launch interactive instance selector
  ssm-connect <alias>             Connect directly to instance using alias

  ssm-connect --add-alias -a a id    Add or update alias (alias, instance-id)
  ssm-connect --remove-alias -r a    Remove an alias
  ssm-connect --list-aliases -l      List all aliases
  ssm-connect --scp <alias> <source> <destination>
                                   Copy files using SCP (alias, source, destination)
  ssm-connect --update               Update to latest version
  ssm-connect --help         -h      Show this help
  ssm-connect --version
  ssm-connect --uninstall            Uninstall ssm-connect
  ssm-connect --whats-new            Show what's new in the latest version
EOF
}

print_changelog() {
  local version="$1"

  if [[ ! -f "$CHANGELOG_PATH" ]]; then
    echo "[ERROR] $CHANGELOG_PATH not found"
    return 1
  fi

  echo "[ℹ️] What's new in version $VERSION:"
  local block
  block=$(sed -n "/^## \[$version\]/,/^## \[/p" "$CHANGELOG_PATH")

  # Remove the last line if it’s another version header
  if [[ $(tail -n 1 <<< "$block") =~ ^##\ \[ ]]; then
    block=$(head -n -1 <<< "$block")
  fi

  echo "$block"
}

get_instance_id() {
  local ALIAS_NAME="$1"
  grep "^$ALIAS_NAME " "$ALIAS_FILE" | awk '{print $2}' || echo ""
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
  --version)
    if [[ -f "$VERSION_FILE" ]]; then
      echo "[ℹ️] Current version: $(cat "$VERSION_FILE")"
    else
      echo "[⚠️] Version file not found. Please run: ssm-connect --update"
    fi
    exit 0
    ;;
  --uninstall)
    if [[ "${1:-}" == "--uninstall" ]]; then
      echo "[🗑️] Uninstalling ssm-connect..."

      # Remove CLI
      if [[ -f "$SCRIPT_PATH" ]]; then
        sudo rm -f "$SCRIPT_PATH"
        echo "[✅] Removed CLI: $SCRIPT_PATH"
      else
        echo "[ℹ️] CLI script not found at $SCRIPT_PATH"
      fi

      # Remove config
      if [[ -d "$CONFIG_DIR" ]]; then
        rm -rf "$CONFIG_DIR"
        echo "[✅] Removed config dir: $CONFIG_DIR"
      else
        echo "[ℹ️] Config directory not found: $CONFIG_DIR"
      fi

      # Remove AWS profile credentials
      AWS_CRED_FILE="$HOME/.aws/credentials"
      AWS_CONFIG_FILE="$HOME/.aws/config"

      if [[ -f "$AWS_CRED_FILE" ]] && grep -q "^\[$AWS_PROFILE\]" "$AWS_CRED_FILE"; then
        sed -i.bak "/^\[$AWS_PROFILE\]/,/^\[/d" "$AWS_CRED_FILE"
        echo "[✅] Removed credentials for profile: $AWS_PROFILE"
      fi

      if [[ -f "$AWS_CONFIG_FILE" ]] && grep -q "^\[profile $AWS_PROFILE\]" "$AWS_CONFIG_FILE"; then
        sed -i.bak "/^\[profile $AWS_PROFILE\]/,/^\[/d" "$AWS_CONFIG_FILE"
        echo "[✅] Removed config for profile: $AWS_PROFILE"
      fi

      # Optional cleanup of .bak files
      rm -f "$AWS_CRED_FILE.bak" "$AWS_CONFIG_FILE.bak" 2>/dev/null || true

      echo "[🧹] Uninstall complete."
      exit 0
    fi
    ;;
  --scp)
    if [[ $# -ne 4 ]]; then
      echo "[ERROR] Usage: ssm-connect --scp <alias> <source> <destination>"
      exit 1
    fi

    SCP_ALIAS="$2"
    SOURCE="$3"
    DESTINATION="$4"

    INSTANCE_ID=$(get_instance_id "$SCP_ALIAS")
    if [[ -z "$INSTANCE_ID" ]]; then
      echo "[ERROR] Alias '$SCP_ALIAS' not found."
      exit 1
    fi

    TMP_NAME="ssm-tmp-$(date +%s)-$RANDOM"
    TMP_S3="s3://$S3_BUCKET/$TMP_NAME"

    if [[ -f "$SOURCE" ]]; then
      echo "[📤] Uploading local file to S3..."
      aws s3 cp "$SOURCE" "$TMP_S3" --region "$AWS_REGION" --profile "$AWS_PROFILE"

      echo "[📦] Triggering SSM command to copy from S3 to instance..."
      COMMAND_ID=$(aws ssm send-command \
        --region "$AWS_REGION" \
        --profile "$AWS_PROFILE" \
        --instance-ids "$INSTANCE_ID" \
        --document-name "AWS-RunShellScript" \
        --comment "ssm-connect scp upload" \
        --parameters "commands=[
          \"sudo -u ubuntu bash -c 'cd ~ && aws s3 cp $TMP_S3 $DESTINATION'\",
          \"sudo -u ubuntu bash -c 'aws s3 rm $TMP_S3'\"
        ]" \
        --query "Command.CommandId" --output text)

      check_ssm_command "$COMMAND_ID"

      echo "[✅] Upload complete."

    else
      echo "[📦] Triggering SSM command to upload from instance to S3..."
      COMMAND_ID=$(aws ssm send-command \
        --region "$AWS_REGION" \
        --profile "$AWS_PROFILE" \
        --instance-ids "$INSTANCE_ID" \
        --document-name "AWS-RunShellScript" \
        --comment "ssm-connect scp download" \
        --parameters "commands=[
          \"sudo -u ubuntu bash -c 'cd ~ && aws s3 cp $SOURCE $TMP_S3'\"
        ]" \
        --query "Command.CommandId" --output text)

      check_ssm_command "$COMMAND_ID"

      echo "[📥] Downloading file from S3..."
      aws s3 cp "$TMP_S3" "$DESTINATION" --region "$AWS_REGION" --profile "$AWS_PROFILE"

      echo "[🧹] Cleaning up S3..."
      aws s3 rm "$TMP_S3" --region "$AWS_REGION" --profile "$AWS_PROFILE"

      echo "[✅] Download complete."
    fi

    echo "[✅] SCP operation completed successfully!"
    exit 0
    ;;
  --whats-new)
    # read from changelog show new features
    VERSION=$(cat "$VERSION_FILE")
    print_changelog "$VERSION"
    exit 0
    ;;
  --update)
      echo "[⬇️] Updating ssm-connect..."
      sudo curl -fsSL "$SCRIPT_URL" -o "$SCRIPT_PATH"
      sudo chmod +x "$SCRIPT_PATH"
      curl -fsSL "$REMOTE_VERSION_URL" -o "$VERSION_FILE"
      curl -fsSL "$REMOTE_CHANGELOG_FILE" -o "$CHANGELOG_PATH"
      echo "[✅] ssm-connect updated successfully!"
      # read from changelog show new features
      VERSION=$(cat "$VERSION_FILE")
      print_changelog "$VERSION"
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
  INSTANCE_ID=$(get_instance_id "$ALIAS_NAME")

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
INSTANCE_ID=$(get_instance_id "$ALIAS_NAME")

echo "[🔌] Connecting to '$ALIAS_NAME' ($INSTANCE_ID)..."
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE"

echo "[✅] Session ended."
