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
COMPLETION_URL="https://raw.githubusercontent.com/muhammadsemeer/ssm-connect/master/completions/ssm-connect.bash"
SCRIPT_PATH="/usr/local/bin/ssm-connect"
CHANGELOG_PATH="$CONFIG_DIR/CHANGELOG.md"
S3_BUCKET="ssm-scp"
USAGE_FILE="$HOME/.cache/ssm-connect/usage"

# === Ensure config dir and version ===
mkdir -p "$CONFIG_DIR"
touch "$ALIAS_FILE"
chmod 600 "$ALIAS_FILE"

UPDATE_INFO_FILE="${TMPDIR:-/tmp}/ssm-connect-update-info"
LAST_CHECK_FILE="${TMPDIR:-/tmp}/ssm-connect-last-check"

# === ANSI colors (only when stdout is a TTY) ===
if [[ -t 1 ]]; then
  C_GRP=$'\033[36m'    # cyan — group name
  C_DIM=$'\033[90m'    # dim gray — ungrouped marker
  C_HDR=$'\033[1m'     # bold — header row
  C_RESET=$'\033[0m'
else
  C_GRP=""; C_DIM=""; C_HDR=""; C_RESET=""
fi

# Strip surrounding whitespace/newlines and a leading 'v' from a version string.
_normalize_version() {
  local v="$1"
  v="${v//[$'\t\r\n ']/}"
  echo "${v#v}"
}

# Compare two versions. Echoes 1 if $1 > $2, -1 if $1 < $2, 0 if equal.
_version_cmp() {
  local a b
  a=$(_normalize_version "$1")
  b=$(_normalize_version "$2")
  [[ "$a" == "$b" ]] && { echo 0; return; }

  local IFS=.
  local -a av bv
  av=($a); bv=($b)

  local i max=${#av[@]} x y
  (( ${#bv[@]} > max )) && max=${#bv[@]}
  for ((i = 0; i < max; i++)); do
    x=${av[i]:-0}; x=${x//[^0-9]/}; x=${x:-0}
    y=${bv[i]:-0}; y=${y//[^0-9]/}; y=${y:-0}
    (( 10#$x > 10#$y )) && { echo 1; return; }
    (( 10#$x < 10#$y )) && { echo -1; return; }
  done
  echo 0
}

# Current installed version (normalized), or 0.0.0 if unknown.
_read_local_version() {
  if [[ -f "$VERSION_FILE" ]]; then
    _normalize_version "$(cat "$VERSION_FILE")"
  else
    echo "0.0.0"
  fi
}

# Print the remote version on success (exit 0); print nothing and exit 1 on
# any network/server failure or empty response.
_fetch_remote_version() {
  local remote
  remote=$(curl -fsSL "$REMOTE_VERSION_URL" 2>/dev/null) || return 1
  remote=$(_normalize_version "$remote")
  [[ -n "$remote" ]] || return 1
  echo "$remote"
}

# Refresh the update banner file. Returns:
#   0 = update available (banner written)
#   1 = up to date (banner emptied)
#   2 = could not reach server (banner left untouched, no nagging)
check_for_update() {
  local local_version remote_version
  local_version=$(_read_local_version)
  remote_version=$(_fetch_remote_version) || return 2

  if [[ "$(_version_cmp "$remote_version" "$local_version")" == "1" ]]; then
    {
      echo "[⬆️] New version available: $remote_version (current: $local_version)"
      echo "[ℹ️] Run: ssm-connect --update to upgrade."
    } > "$UPDATE_INFO_FILE"
    return 0
  fi

  : > "$UPDATE_INFO_FILE"  # up to date — clear any stale banner
  return 1
}

show_update_info() {
  if [[ -s "$UPDATE_INFO_FILE" ]]; then
    cat "$UPDATE_INFO_FILE"
  fi
}

# === Run version check only once per day ===
run_daily_update_check() {
  local today rc=0
  today=$(date +%Y-%m-%d)

  # Skip if we already checked today.
  if [[ -f "$LAST_CHECK_FILE" && "$(cat "$LAST_CHECK_FILE")" == "$today" ]]; then
    return 0
  fi

  check_for_update || rc=$?
  # Only record the check if we actually reached the server (rc 0 or 1);
  # a transient network failure (rc 2) should be retried on the next run.
  if [[ $rc -ne 2 ]]; then
    echo "$today" > "$LAST_CHECK_FILE"
  fi
}

run_daily_update_check >> /dev/null 2>&1 &

show_update_info

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


install_completion() {
  # Detect the appropriate bash-completion directory for this platform.
  local completion_dir=""
  case "$(uname -s)" in
    Darwin)
      if command -v brew &>/dev/null; then
        completion_dir="$(brew --prefix)/etc/bash_completion.d"
      fi
      ;;
    Linux)
      if [[ -d /etc/bash_completion.d ]]; then
        completion_dir="/etc/bash_completion.d"
      elif [[ -d /usr/share/bash-completion/completions ]]; then
        completion_dir="/usr/share/bash-completion/completions"
      fi
      ;;
  esac

  if [[ -z "$completion_dir" ]]; then
    echo "[ℹ️] Could not detect a bash-completion directory; skipping completion install."
    return 0
  fi

  # Writing to system completion dirs needs root on Linux; Homebrew dirs don't.
  local sudo_cmd=""
  if [[ ! -w "$completion_dir" ]]; then
    sudo_cmd="sudo"
  fi

  $sudo_cmd mkdir -p "$completion_dir" 2>/dev/null || true
  if $sudo_cmd curl -fsSL "$COMPLETION_URL" -o "$completion_dir/ssm-connect" 2>/dev/null; then
    echo "[✅] Bash completion installed to $completion_dir/ssm-connect"
    echo "[ℹ️] Restart your shell or run: source $completion_dir/ssm-connect"
  else
    echo "[ℹ️] Skipped bash completion (download failed)."
  fi
}

# Download the new release to temp files and only swap them into place once
# every download has succeeded, so a mid-update failure can't leave a
# half-written binary or a version file that disagrees with the script.
do_update() {
  local new_version="$1"
  local tmp_script tmp_version tmp_changelog
  tmp_script=$(mktemp "${TMPDIR:-/tmp}/ssm-connect.XXXXXX")
  tmp_version=$(mktemp "${TMPDIR:-/tmp}/ssm-version.XXXXXX")
  tmp_changelog=$(mktemp "${TMPDIR:-/tmp}/ssm-changelog.XXXXXX")
  trap 'rm -f "$tmp_script" "$tmp_version" "$tmp_changelog"' RETURN

  if ! curl -fsSL "$SCRIPT_URL"            -o "$tmp_script"    \
    || ! curl -fsSL "$REMOTE_VERSION_URL"   -o "$tmp_version"   \
    || ! curl -fsSL "$REMOTE_CHANGELOG_FILE" -o "$tmp_changelog"; then
    echo "[❌] Download failed; no changes were made."
    return 1
  fi

  if [[ ! -s "$tmp_script" ]]; then
    echo "[❌] Downloaded script is empty; aborting."
    return 1
  fi

  # Swap into place. The CLI lives in a root-owned dir; the config files don't.
  sudo install -m 0755 "$tmp_script" "$SCRIPT_PATH"
  install -m 0644 "$tmp_version" "$VERSION_FILE"
  install -m 0644 "$tmp_changelog" "$CHANGELOG_PATH"

  install_completion
  echo "[✅] ssm-connect updated to version $new_version!"
}

show_help() {
cat <<EOF
Usage:
  ssm-connect                     Launch interactive instance selector
  ssm-connect <alias>             Connect directly to instance using alias
  ssm-connect <group>             Pick from instances under a group

  ssm-connect --add-alias -a a id [group]
                                     Add or update alias (alias, instance-id, optional group)
  ssm-connect --remove-alias -r a    Remove an alias
  ssm-connect --list-aliases -l      List all aliases (sectioned by group)
  ssm-connect --set-group <alias> <group>
                                     Set or change the group of an existing alias
  ssm-connect --unset-group <alias>
                                     Remove the group from an existing alias
  ssm-connect --scp <source> <destination>
                                   Copy files via SSM/S3. Use alias:path for remote.
                                   Upload: ssm-connect --scp local.txt alias:/remote/path
                                   Download: ssm-connect --scp alias:/remote/file.txt local/
  ssm-connect --check-update         Check for updates
  ssm-connect --update               Update to latest version
  ssm-connect --install-bash-completion
                                     Install bash completion for ssm-connect
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

  echo "[ℹ️] What's new in version $version:"
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

list_group_aliases() {
  local GROUP_NAME="$1"
  awk -v grp="$GROUP_NAME" 'NF >= 3 && $3 == grp {print $1, $2, $3}' "$ALIAS_FILE"
}

ensure_sso_login() {
  AWS_CRED_FILE="$HOME/.aws/credentials"
  AWS_CONFIG_FILE="$HOME/.aws/config"

  if aws configure list-profiles 2>/dev/null | grep -q "^$AWS_PROFILE$"; then
    if [[ -z "$(aws configure get sso_start_url --profile "$AWS_PROFILE" 2>/dev/null)" ]] \
       && [[ -z "$(aws configure get sso_session --profile "$AWS_PROFILE" 2>/dev/null)" ]]; then
      echo "[🧹] Detected legacy (non-SSO) profile '$AWS_PROFILE'. Removing..."

      if [[ -f "$AWS_CRED_FILE" ]] && grep -q "^\[$AWS_PROFILE\]" "$AWS_CRED_FILE"; then
        sed -i.bak "/^\[$AWS_PROFILE\]/,/^\[/{/^\[$AWS_PROFILE\]/d;/^\[/!d;}" "$AWS_CRED_FILE"
      fi
      if [[ -f "$AWS_CONFIG_FILE" ]] && grep -q "^\[profile $AWS_PROFILE\]" "$AWS_CONFIG_FILE"; then
        sed -i.bak "/^\[profile $AWS_PROFILE\]/,/^\[/{/^\[profile $AWS_PROFILE\]/d;/^\[/!d;}" "$AWS_CONFIG_FILE"
      fi
      rm -f "$AWS_CRED_FILE.bak" "$AWS_CONFIG_FILE.bak" 2>/dev/null || true
    fi
  fi

  if ! aws configure list-profiles 2>/dev/null | grep -q "^$AWS_PROFILE$"; then
    echo "[INFO] AWS profile '$AWS_PROFILE' not found. Starting SSO setup..."
    echo "[⚠️ ] When prompted for a role, choose: ssm-access-<your-name>"
    aws configure sso --profile "$AWS_PROFILE"
  fi

  if ! aws sts get-caller-identity --profile "$AWS_PROFILE" --region "$AWS_REGION" >/dev/null 2>&1; then
    echo "[🔐] SSO session expired or not signed in. Launching 'aws sso login'..."
    aws sso login --profile "$AWS_PROFILE"
  fi
}

case "${1:-}" in
  --help|-h)
    show_help
    exit 0
    ;;
  --add-alias|-a)
    if [[ $# -lt 3 || $# -gt 4 ]]; then
      echo "[ERROR] Usage: ssm-connect -a <alias> <instance-id> [group]"
      exit 1
    fi
    NEW_ALIAS="$2"
    NEW_ID="$3"
    NEW_GROUP="${4:-}"

    sed -i.bak "/^$NEW_ALIAS /d" "$ALIAS_FILE"
    if [[ -n "$NEW_GROUP" ]]; then
      echo "$NEW_ALIAS $NEW_ID $NEW_GROUP" >> "$ALIAS_FILE"
      echo "[✅] Alias '$NEW_ALIAS' → '$NEW_ID' (group: $NEW_GROUP) added."
    else
      echo "$NEW_ALIAS $NEW_ID" >> "$ALIAS_FILE"
      echo "[✅] Alias '$NEW_ALIAS' → '$NEW_ID' added."
    fi
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
  --set-group)
    if [[ $# -ne 3 ]]; then
      echo "[ERROR] Usage: ssm-connect --set-group <alias> <group>"
      exit 1
    fi
    TARGET_ALIAS="$2"
    TARGET_GROUP="$3"
    EXISTING_ID=$(get_instance_id "$TARGET_ALIAS")
    if [[ -z "$EXISTING_ID" ]]; then
      echo "[ERROR] Alias '$TARGET_ALIAS' not found."
      exit 1
    fi
    sed -i.bak "/^$TARGET_ALIAS /d" "$ALIAS_FILE"
    echo "$TARGET_ALIAS $EXISTING_ID $TARGET_GROUP" >> "$ALIAS_FILE"
    echo "[✅] Alias '$TARGET_ALIAS' added to group '$TARGET_GROUP'."
    exit 0
    ;;
  --unset-group)
    if [[ $# -ne 2 ]]; then
      echo "[ERROR] Usage: ssm-connect --unset-group <alias>"
      exit 1
    fi
    TARGET_ALIAS="$2"
    EXISTING_ID=$(get_instance_id "$TARGET_ALIAS")
    if [[ -z "$EXISTING_ID" ]]; then
      echo "[ERROR] Alias '$TARGET_ALIAS' not found."
      exit 1
    fi
    sed -i.bak "/^$TARGET_ALIAS /d" "$ALIAS_FILE"
    echo "$TARGET_ALIAS $EXISTING_ID" >> "$ALIAS_FILE"
    echo "[✅] Alias '$TARGET_ALIAS' group cleared."
    exit 0
    ;;
  --list-aliases|-l)
    if [[ ! -s "$ALIAS_FILE" ]]; then
      echo "[📭] No aliases found."
      exit 0
    fi
    echo "[📋] Current aliases:"
    awk '
      NF >= 3 { print $3 "\t" $1 "\t" $2; next }
      { print "~\t" $1 "\t" $2 }
    ' "$ALIAS_FILE" |
      sort -t $'\t' -k1,1 -k2,2 |
      awk -F'\t' \
        -v c_grp="$C_GRP" -v c_hdr="$C_HDR" -v c_dim="$C_DIM" -v c_reset="$C_RESET" '
        {
          if ($1 != prev) {
            if (NR > 1) print ""
            if ($1 == "~") print c_dim "ungrouped" c_reset
            else print c_hdr c_grp $1 c_reset
            prev = $1
          }
          printf "  %s\t%s\n", $2, $3
        }
      ' | column -t -s $'\t'
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
    if [[ $# -ne 3 ]]; then
      echo "[ERROR] Usage: ssm-connect --scp <source> <destination>"
      echo "         Use alias:path for remote, e.g.:"
      echo "           Upload:   ssm-connect --scp local.txt myserver:/home/ubuntu/"
      echo "           Download: ssm-connect --scp myserver:/home/ubuntu/file.txt ./"
      exit 1
    fi

    SOURCE="$2"
    DESTINATION="$3"

    if [[ "$SOURCE" == *:* ]]; then
      SCP_ALIAS="${SOURCE%%:*}"
      REMOTE_PATH="${SOURCE#*:}"
      LOCAL_PATH="$DESTINATION"
      DIRECTION="download"
    elif [[ "$DESTINATION" == *:* ]]; then
      SCP_ALIAS="${DESTINATION%%:*}"
      REMOTE_PATH="${DESTINATION#*:}"
      LOCAL_PATH="$SOURCE"
      DIRECTION="upload"
    else
      echo "[ERROR] One of source or destination must be a remote path in alias:path format."
      exit 1
    fi

    INSTANCE_ID=$(get_instance_id "$SCP_ALIAS")
    if [[ -z "$INSTANCE_ID" ]]; then
      echo "[ERROR] Alias '$SCP_ALIAS' not found."
      exit 1
    fi

    ensure_sso_login

    TMP_NAME="ssm-tmp-$(date +%s)-$RANDOM"
    TMP_S3="s3://$S3_BUCKET/$TMP_NAME"

    if [[ "$DIRECTION" == "upload" ]]; then
      if [[ ! -f "$LOCAL_PATH" ]]; then
        echo "[ERROR] Local file '$LOCAL_PATH' not found."
        exit 1
      fi

      if [[ "$REMOTE_PATH" == */ ]]; then
        REMOTE_PATH="${REMOTE_PATH}$(basename "$LOCAL_PATH")"
      fi

      echo "[📤] Uploading local file to S3..."
      aws s3 cp "$LOCAL_PATH" "$TMP_S3" --region "$AWS_REGION" --profile "$AWS_PROFILE"

      echo "[📦] Triggering SSM command to copy from S3 to instance..."
      COMMAND_ID=$(aws ssm send-command \
        --region "$AWS_REGION" \
        --profile "$AWS_PROFILE" \
        --instance-ids "$INSTANCE_ID" \
        --document-name "AWS-RunShellScript" \
        --comment "ssm-connect scp upload" \
        --parameters "commands=[\"sudo -u ubuntu aws s3 cp $TMP_S3 $REMOTE_PATH --profile=ssm\",\"sudo -u ubuntu aws s3 rm $TMP_S3 --profile=ssm\"]" \
        --query "Command.CommandId" --output text)

      check_ssm_command "$COMMAND_ID"
      echo "[✅] Upload complete."

    else
      if [[ -d "$LOCAL_PATH" ]] || [[ "$LOCAL_PATH" == */ ]]; then
        LOCAL_PATH="${LOCAL_PATH%/}/$(basename "$REMOTE_PATH")"
      fi

      echo "[📦] Triggering SSM command to upload from instance to S3..."
      COMMAND_ID=$(aws ssm send-command \
        --region "$AWS_REGION" \
        --profile "$AWS_PROFILE" \
        --instance-ids "$INSTANCE_ID" \
        --document-name "AWS-RunShellScript" \
        --comment "ssm-connect scp download" \
        --parameters "commands=[\"sudo -u ubuntu aws s3 cp $REMOTE_PATH $TMP_S3 --profile=ssm\"]" \
        --query "Command.CommandId" --output text)

      check_ssm_command "$COMMAND_ID"

      echo "[📥] Downloading file from S3..."
      aws s3 cp "$TMP_S3" "$LOCAL_PATH" --region "$AWS_REGION" --profile "$AWS_PROFILE"

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
  --check-update)
    # Force a fresh, synchronous check and report the outcome clearly.
    rc=0
    check_for_update || rc=$?
    case $rc in
      0) show_update_info ;;
      1) echo "[✅] ssm-connect is up to date (version $(_read_local_version))." ;;
      2) echo "[⚠️] Could not check for updates (network or server unreachable)." ;;
    esac
    exit 0
    ;;
  --install-bash-completion)
    install_completion
    exit 0
    ;;
  --update)
      # Do our own version check rather than trusting the background flag, so
      # --update is correct even on a fresh shell where the flag doesn't exist.
      local_version=$(_read_local_version)
      rc=0
      remote_version=$(_fetch_remote_version) || rc=$?
      if [[ $rc -ne 0 ]]; then
        echo "[⚠️] Could not reach the update server. Please try again later."
        exit 1
      fi

      if [[ "$(_version_cmp "$remote_version" "$local_version")" != "1" ]]; then
        echo "[✅] ssm-connect is already up to date (version $local_version)."
        : > "$UPDATE_INFO_FILE"
        exit 0
      fi

      echo "[⬇️] Updating ssm-connect $local_version → $remote_version..."
      if ! do_update "$remote_version"; then
        exit 1
      fi
      : > "$UPDATE_INFO_FILE"
      print_changelog "$remote_version"
      exit 0
      ;;
  --*|-*)
    echo "[❌] Unknown option: $1"
    show_help
    exit 1
    ;;
esac

# === AWS SSO Profile Config ===
ensure_sso_login

# === Direct connect ===
if [[ $# -eq 1 ]]; then
  ALIAS_NAME="$1"
  INSTANCE_ID=$(get_instance_id "$ALIAS_NAME")

  if [[ -z "$INSTANCE_ID" ]]; then
    # Fallback: maybe the arg is a group name
    GROUP_LIST=$(list_group_aliases "$ALIAS_NAME")

    if [[ -z "$GROUP_LIST" ]]; then
      echo "[ERROR] No alias or group named '$ALIAS_NAME' found in $ALIAS_FILE"
      exit 1
    fi

    GROUP_NAME="$ALIAS_NAME"
    COUNT=$(echo "$GROUP_LIST" | wc -l | tr -d ' ')
    echo "[🔍] Group '$GROUP_NAME' — $COUNT instance(s):"

    DISPLAY_LIST=$({
      printf "ALIAS\tINSTANCE\n"
      echo "$GROUP_LIST" | awk '{ printf "%s\t%s\n", $1, $2 }' | sort
    } | column -t -s $'\t')

    SELECTED_LINE=$(echo "$DISPLAY_LIST" | fzf --ansi --header-lines=1 --color=header:bold --prompt="$GROUP_NAME › ")

    if [[ -z "$SELECTED_LINE" ]]; then
      echo "[⚠️] No instance selected."
      exit 0
    fi

    ALIAS_NAME=$(echo "$SELECTED_LINE" | awk '{print $1}')
    INSTANCE_ID=$(get_instance_id "$ALIAS_NAME")
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

mkdir -p "$(dirname "$USAGE_FILE")"
touch "$USAGE_FILE"

echo "[🔍] Selecting instance interactively..."

# Show group column only when at least one alias has a group
HAS_GROUPS=$(awk 'NF >= 3 {print 1; exit}' "$ALIAS_FILE")

# Merge usage data (keyed by alias name) and sort by group then recency
SORTED_ROWS=$(awk -F'\t' '
  NR==FNR { count[$1] = $2 + 0; lastused[$1] = $3 + 0; next }
  {
    n = split($0, f, /[ \t]+/)
    a = f[1]; id = f[2]; grp = (n >= 3) ? f[3] : ""
    c = (a in count) ? count[a] : 0
    l = (a in lastused) ? lastused[a] : 0
    sort_grp = (grp == "") ? "~" : grp   # ungrouped sorts last
    print sort_grp "\t" l "\t" c "\t" a "\t" id "\t" grp
  }
' "$USAGE_FILE" "$ALIAS_FILE" | sort -t $'\t' -k1,1 -k2,2nr -k3,3nr)

if [[ "$HAS_GROUPS" == "1" ]]; then
  DISPLAY_LIST=$({
    printf "ALIAS\tINSTANCE\tGROUP\n"
    echo "$SORTED_ROWS" | awk -F'\t' \
      -v c_grp="$C_GRP" -v c_dim="$C_DIM" -v c_reset="$C_RESET" '
      {
        grp = ($6 == "") ? (c_dim "—" c_reset) : (c_grp $6 c_reset)
        printf "%s\t%s\t%s\n", $4, $5, grp
      }'
  } | column -t -s $'\t')
else
  DISPLAY_LIST=$({
    printf "ALIAS\tINSTANCE\n"
    echo "$SORTED_ROWS" | awk -F'\t' '{ printf "%s\t%s\n", $4, $5 }'
  } | column -t -s $'\t')
fi

SELECTED_LINE=$(echo "$DISPLAY_LIST" | fzf --ansi --header-lines=1 --color=header:bold --prompt="Select instance: ")

if [[ -z "$SELECTED_LINE" ]]; then
  echo "[⚠️] No instance selected."
  exit 0
fi

ALIAS_NAME=$(echo "$SELECTED_LINE" | awk '{print $1}')
INSTANCE_ID=$(get_instance_id "$ALIAS_NAME")

# Update usage file (keyed by alias name)
now=$(date +%s)
awk -F'\t' -v a="$ALIAS_NAME" -v t="$now" '
  BEGIN { found=0 }
  $1 == a { print $1 "\t" $2+1 "\t" t; found=1; next }
  { print }
  END { if (!found) print a "\t1\t" t }
' "$USAGE_FILE" > "$USAGE_FILE.tmp"
mv "$USAGE_FILE.tmp" "$USAGE_FILE"

echo "[🔌] Connecting to '$ALIAS_NAME' ($INSTANCE_ID)..."
aws ssm start-session \
  --target "$INSTANCE_ID" \
  --region "$AWS_REGION" \
  --profile "$AWS_PROFILE"

echo "[✅] Session ended."
