#!/usr/bin/env bash
#
# ssm-connect — connect to EC2 instances over AWS SSM, with aliases, groups,
# file transfer (SCP-over-S3), and self-update.
#
# This script is distributed and self-updated as a SINGLE file (see --update).
# Keep it self-contained: do not split it into sourced libraries, or the
# install/update mechanism breaks.

set -euo pipefail

# ============================================================================
# Configuration
# ============================================================================
readonly AWS_PROFILE="ssm-session-manager"
readonly AWS_REGION="ap-south-1"
# Common flags appended to every aws invocation.
readonly AWS_ARGS=(--region "$AWS_REGION" --profile "$AWS_PROFILE")

readonly CONFIG_DIR="$HOME/.ssm-connect"
readonly ALIAS_FILE="$CONFIG_DIR/aliases"
readonly VERSION_FILE="$CONFIG_DIR/version"
readonly CHANGELOG_PATH="$CONFIG_DIR/CHANGELOG.md"
readonly USAGE_FILE="$HOME/.cache/ssm-connect/usage"
readonly SCRIPT_PATH="/usr/local/bin/ssm-connect"
readonly S3_BUCKET="ssm-scp"

readonly AWS_CRED_FILE="$HOME/.aws/credentials"
readonly AWS_CONFIG_FILE="$HOME/.aws/config"

readonly REPO_RAW="https://raw.githubusercontent.com/muhammadsemeer/ssm-connect/master"
readonly REMOTE_VERSION_URL="$REPO_RAW/version"
readonly SCRIPT_URL="$REPO_RAW/ssm-connect.sh"
readonly REMOTE_CHANGELOG_URL="$REPO_RAW/CHANGELOG.md"
readonly COMPLETION_URL="$REPO_RAW/completions/ssm-connect.bash"

readonly UPDATE_INFO_FILE="${TMPDIR:-/tmp}/ssm-connect-update-info"
readonly LAST_CHECK_FILE="${TMPDIR:-/tmp}/ssm-connect-last-check"

# Colours, populated by setup_colors() once we know whether stdout is a TTY.
C_GRP=""; C_DIM=""; C_HDR=""; C_RESET=""

# ============================================================================
# Output helpers
# ============================================================================
say()  { printf '%s\n' "$*"; }
warn() { printf '[⚠️] %s\n' "$*" >&2; }
die()  { printf '[ERROR] %s\n' "$*" >&2; exit 1; }

setup_colors() {
  if [[ -t 1 ]]; then
    C_GRP=$'\033[36m'    # cyan — group name
    C_DIM=$'\033[90m'    # gray — ungrouped marker
    C_HDR=$'\033[1m'     # bold — header row
    C_RESET=$'\033[0m'
  fi
}

# ============================================================================
# Runtime setup
# ============================================================================
init_runtime() {
  mkdir -p "$CONFIG_DIR"
  touch "$ALIAS_FILE"
  chmod 600 "$ALIAS_FILE"
  setup_colors
}

# require_tools cmd... — abort if any named command is missing.
require_tools() {
  local cmd missing=()
  for cmd in "$@"; do
    command -v "$cmd" &>/dev/null || missing+=("$cmd")
  done
  (( ${#missing[@]} == 0 )) || die "Missing required tool(s): ${missing[*]}"
}

# ============================================================================
# Versioning & self-update
# ============================================================================

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
  [[ -s "$UPDATE_INFO_FILE" ]] && cat "$UPDATE_INFO_FILE"
  return 0
}

# Run the update check at most once per calendar day (in the background).
run_daily_update_check() {
  local today rc=0
  today=$(date +%Y-%m-%d)

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

# Detect the platform's bash-completion directory, or print nothing.
detect_completion_dir() {
  case "$(uname -s)" in
    Darwin)
      # bash-completion@2 lazy-loads command-named files from here. (macOS
      # defaults to zsh; this only applies to bash sessions.)
      command -v brew &>/dev/null \
        && printf '%s\n' "$(brew --prefix)/share/bash-completion/completions"
      ;;
    Linux)
      if [[ -d /etc/bash_completion.d ]]; then
        printf '%s\n' /etc/bash_completion.d
      elif [[ -d /usr/share/bash-completion/completions ]]; then
        printf '%s\n' /usr/share/bash-completion/completions
      fi
      ;;
  esac
  return 0  # empty output means "not found"; never fail (would trip set -e in $(...))
}

# macOS needs the bash-completion@2 package to load ANY completion (its loader
# is what reads our file). Install it if missing so existing users who just
# `--update` get working completion without a manual step.
ensure_macos_completion_deps() {
  [[ "$(uname -s)" == "Darwin" ]] || return 0
  command -v brew &>/dev/null || return 0
  brew list --formula "bash-completion@2" &>/dev/null && return 0
  say "[📦] Installing bash-completion@2 (required for completion on macOS)..."
  if brew install --quiet "bash-completion@2" >/dev/null 2>&1; then
    say "[✅] Installed bash-completion@2."
  else
    warn "Could not install bash-completion@2 automatically. Run: brew install bash-completion@2"
  fi
}

# Remaining manual step on macOS: brew doesn't wire the loader into your shell.
completion_macos_hint() {
  [[ "$(uname -s)" == "Darwin" ]] || return 0
  say "[ℹ️] macOS: completion runs in bash (not the default zsh). Ensure ~/.bash_profile sources bash-completion:"
  say '       [[ -r "$(brew --prefix)/etc/profile.d/bash_completion.sh" ]] && . "$(brew --prefix)/etc/profile.d/bash_completion.sh"'
}

install_completion() {
  local completion_dir
  completion_dir=$(detect_completion_dir)
  if [[ -z "$completion_dir" ]]; then
    say "[ℹ️] Could not detect a bash-completion directory; skipping completion install."
    return 0
  fi

  ensure_macos_completion_deps

  # Homebrew dirs are user-owned; Linux system dirs need root. Try without sudo
  # first so we don't create a root-owned dir inside the user's Homebrew tree.
  local sudo_cmd=""
  if ! mkdir -p "$completion_dir" 2>/dev/null; then
    sudo_cmd="sudo"
    $sudo_cmd mkdir -p "$completion_dir" 2>/dev/null || true
  fi
  if [[ -z "$sudo_cmd" && ! -w "$completion_dir" ]]; then
    sudo_cmd="sudo"
  fi

  if $sudo_cmd curl -fsSL "$COMPLETION_URL" -o "$completion_dir/ssm-connect" 2>/dev/null; then
    say "[✅] Bash completion installed to $completion_dir/ssm-connect"
    say "[ℹ️] Restart your shell or run: source $completion_dir/ssm-connect"
    completion_macos_hint
  else
    say "[ℹ️] Skipped bash completion (download failed)."
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
  # Clean up temp files when do_update returns, then self-clear: a RETURN trap
  # is global without functrace, so without `trap - RETURN` it would re-fire on
  # the caller's return and hit these now-out-of-scope locals under set -u. The
  # :- guards are extra insurance.
  trap 'rm -f "${tmp_script:-}" "${tmp_version:-}" "${tmp_changelog:-}"; trap - RETURN' RETURN

  if ! curl -fsSL "$SCRIPT_URL"           -o "$tmp_script"    \
    || ! curl -fsSL "$REMOTE_VERSION_URL"   -o "$tmp_version"   \
    || ! curl -fsSL "$REMOTE_CHANGELOG_URL" -o "$tmp_changelog"; then
    warn "Download failed; no changes were made."
    return 1
  fi

  if [[ ! -s "$tmp_script" ]]; then
    warn "Downloaded script is empty; aborting."
    return 1
  fi

  # Swap into place. The CLI lives in a root-owned dir; the config files don't.
  sudo install -m 0755 "$tmp_script" "$SCRIPT_PATH"
  install -m 0644 "$tmp_version" "$VERSION_FILE"
  install -m 0644 "$tmp_changelog" "$CHANGELOG_PATH"

  install_completion
  say "[✅] ssm-connect updated to version $new_version!"
}

# Print the CHANGELOG section for a given version (macOS/BSD-safe — no GNU
# `head -n -1`). Uses literal substring matching so version dots aren't regex.
print_changelog() {
  local version="$1"
  if [[ ! -f "$CHANGELOG_PATH" ]]; then
    warn "$CHANGELOG_PATH not found"
    return 1
  fi

  say "[ℹ️] What's new in version $version:"
  awk -v header="## [$version]" '
    index($0, header) == 1 { capture = 1; print; next }
    capture && /^## \[/    { exit }
    capture                { print }
  ' "$CHANGELOG_PATH"
}

# ============================================================================
# Alias storage
#
# The alias file is whitespace-delimited: "alias instance-id [group]". All
# lookups/edits match the alias as an exact awk field, so alias names with
# regex/glob metacharacters can't match or delete the wrong line (and we never
# leave sed .bak litter behind).
# ============================================================================

get_instance_id() {
  awk -v a="$1" '$1 == a { print $2; exit }' "$ALIAS_FILE"
}

alias_exists() {
  awk -v a="$1" '$1 == a { found = 1 } END { exit found ? 0 : 1 }' "$ALIAS_FILE"
}

list_group_aliases() {
  awk -v grp="$1" 'NF >= 3 && $3 == grp { print $1, $2, $3 }' "$ALIAS_FILE"
}

# Delete any line whose first field equals the given alias.
remove_alias_line() {
  local tmp
  tmp=$(mktemp)
  awk -v a="$1" '$1 != a' "$ALIAS_FILE" > "$tmp"
  mv "$tmp" "$ALIAS_FILE"
  chmod 600 "$ALIAS_FILE"
}

# Add or replace an alias entry: set_alias <alias> <id> [group]
set_alias() {
  local alias="$1" id="$2" grp="${3:-}"
  remove_alias_line "$alias"
  if [[ -n "$grp" ]]; then
    printf '%s %s %s\n' "$alias" "$id" "$grp" >> "$ALIAS_FILE"
  else
    printf '%s %s\n' "$alias" "$id" >> "$ALIAS_FILE"
  fi
}

# ============================================================================
# Input validation
# ============================================================================

# Alias and group names must be a single whitespace-free token (the alias file
# is whitespace-delimited) and may not look like a flag.
validate_name() {
  local name="$1" kind="$2"
  [[ -n "$name" ]] || die "$kind name is empty."
  case "$name" in
    -*)            die "$kind name may not start with '-': '$name'" ;;
    *[[:space:]]*) die "$kind name may not contain whitespace: '$name'" ;;
  esac
}

# Soft check — warn on a value that doesn't look like an EC2 instance ID, but
# don't block it (lets unusual targets through).
validate_instance_id() {
  [[ "$1" =~ ^i-[0-9a-fA-F]{6,}$ ]] \
    || warn "'$1' doesn't look like an EC2 instance ID (expected i-xxxxxxxx)."
}

# Remote paths are interpolated into a shell command we run on the instance via
# SSM RunShellScript. Restrict them to ordinary path characters so they can't
# break out of the single-quoted argument or the JSON we send.
validate_remote_path() {
  local p="$1" leftover
  [[ -n "$p" ]] || die "Remote path is empty."
  # Strip the allowed characters; anything left over is disallowed. Done with
  # tr (not ${p//[...]/}) because a '/' inside a substitution pattern would
  # terminate the pattern early.
  leftover=$(printf '%s' "$p" | tr -d 'A-Za-z0-9/._~+:= -')
  [[ -z "$leftover" ]] || die "Remote path contains unsafe characters ('$leftover') in: $p"
}

# ============================================================================
# AWS SSO / SSM
# ============================================================================
ensure_sso_login() {
  if aws configure list-profiles 2>/dev/null | grep -q "^$AWS_PROFILE$"; then
    if [[ -z "$(aws configure get sso_start_url --profile "$AWS_PROFILE" 2>/dev/null)" ]] \
       && [[ -z "$(aws configure get sso_session --profile "$AWS_PROFILE" 2>/dev/null)" ]]; then
      say "[🧹] Detected legacy (non-SSO) profile '$AWS_PROFILE'. Removing..."

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
    say "[INFO] AWS profile '$AWS_PROFILE' not found. Starting SSO setup..."
    say "[⚠️ ] When prompted for a role, choose: ssm-access-<your-name>"
    aws configure sso --profile "$AWS_PROFILE"
  fi

  if ! aws sts get-caller-identity "${AWS_ARGS[@]}" >/dev/null 2>&1; then
    say "[🔐] SSO session expired or not signed in. Launching 'aws sso login'..."
    aws sso login --profile "$AWS_PROFILE"
  fi
}

# Block until an SSM command finishes; abort with guidance if it fails.
wait_for_ssm_command() {
  local command_id="$1" status
  say "[⏳] Waiting for SSM command ($command_id) to complete..."

  while true; do
    status=$(aws ssm list-command-invocations "${AWS_ARGS[@]}" \
      --command-id "$command_id" --details \
      --query "CommandInvocations[0].Status" --output text)

    case "$status" in
      Success) return 0 ;;
      Failed|Cancelled|TimedOut)
        warn "SSM command failed with status: $status"
        say "[ℹ️] Ensure the instance has AWS CLI installed in the home directory of the user 'ubuntu'"
        say "[ℹ️] No need to configure AWS CLI on the instance; it uses the instance's IAM role."
        say "[ℹ️] The role must allow access to the S3 bucket '$S3_BUCKET'."
        exit 1
        ;;
    esac
    sleep 2
  done
}

start_session() {
  local name="$1" instance_id="$2"
  say "[🔌] Connecting to '$name' ($instance_id)..."
  aws ssm start-session --target "$instance_id" "${AWS_ARGS[@]}"
}

# ============================================================================
# Commands
# ============================================================================
cmd_help() {
cat <<EOF
Usage:
  ssm-connect                     Launch interactive instance selector
  ssm-connect <alias>             Connect directly to instance using alias
  ssm-connect <group>             Pick from instances under a group

  ssm-connect --add-alias    -a <alias> <id> [group]
                                     Add or update an alias (optional group)
  ssm-connect --remove-alias -r <alias>
                                     Remove an alias
  ssm-connect --list-aliases -l      List all aliases (sectioned by group)
  ssm-connect --set-group <alias> <group>
                                     Set or change the group of an existing alias
  ssm-connect --unset-group <alias>
                                     Remove the group from an existing alias
  ssm-connect --scp <source> <destination>
                                     Copy files via SSM/S3. Use alias:path for remote.
                                     Upload:   ssm-connect --scp local.txt alias:/remote/path
                                     Download: ssm-connect --scp alias:/remote/file.txt local/
  ssm-connect --check-update         Check for updates
  ssm-connect --update               Update to the latest version
  ssm-connect --install-bash-completion
                                     Install bash completion for ssm-connect
  ssm-connect --whats-new            Show what's new in the latest version
  ssm-connect --version              Show the installed version
  ssm-connect --uninstall            Uninstall ssm-connect
  ssm-connect --help         -h      Show this help
EOF
}

cmd_add_alias() {
  (( $# >= 2 && $# <= 3 )) || die "Usage: ssm-connect -a <alias> <instance-id> [group]"
  local alias="$1" id="$2" grp="${3:-}"
  validate_name "$alias" "Alias"
  [[ -n "$grp" ]] && validate_name "$grp" "Group"
  validate_instance_id "$id"

  set_alias "$alias" "$id" "$grp"
  if [[ -n "$grp" ]]; then
    say "[✅] Alias '$alias' → '$id' (group: $grp) added."
  else
    say "[✅] Alias '$alias' → '$id' added."
  fi
}

cmd_remove_alias() {
  (( $# == 1 )) || die "Usage: ssm-connect -r <alias>"
  local alias="$1"
  if alias_exists "$alias"; then
    remove_alias_line "$alias"
    say "[🗑️] Alias '$alias' removed."
  else
    warn "Alias '$alias' not found."
  fi
}

cmd_set_group() {
  (( $# == 2 )) || die "Usage: ssm-connect --set-group <alias> <group>"
  local alias="$1" grp="$2" id
  validate_name "$grp" "Group"
  id=$(get_instance_id "$alias")
  [[ -n "$id" ]] || die "Alias '$alias' not found."
  set_alias "$alias" "$id" "$grp"
  say "[✅] Alias '$alias' added to group '$grp'."
}

cmd_unset_group() {
  (( $# == 1 )) || die "Usage: ssm-connect --unset-group <alias>"
  local alias="$1" id
  id=$(get_instance_id "$alias")
  [[ -n "$id" ]] || die "Alias '$alias' not found."
  set_alias "$alias" "$id"
  say "[✅] Alias '$alias' group cleared."
}

cmd_list_aliases() {
  if [[ ! -s "$ALIAS_FILE" ]]; then
    say "[📭] No aliases found."
    return 0
  fi
  say "[📋] Current aliases:"
  awk '
    NF >= 3 { print $3 "\t" $1 "\t" $2; next }
            { print "~\t" $1 "\t" $2 }
  ' "$ALIAS_FILE" \
    | sort -t $'\t' -k1,1 -k2,2 \
    | awk -F'\t' -v c_grp="$C_GRP" -v c_hdr="$C_HDR" -v c_dim="$C_DIM" -v c_reset="$C_RESET" '
        {
          if ($1 != prev) {
            if (NR > 1) print ""
            if ($1 == "~") print c_dim "ungrouped" c_reset
            else print c_hdr c_grp $1 c_reset
            prev = $1
          }
          printf "  %s\t%s\n", $2, $3
        }
      ' \
    | column -t -s $'\t'
}

cmd_version() {
  if [[ -f "$VERSION_FILE" ]]; then
    say "[ℹ️] Current version: $(_read_local_version)"
  else
    warn "Version file not found. Please run: ssm-connect --update"
  fi
}

cmd_whats_new() {
  print_changelog "$(_read_local_version)"
}

cmd_check_update() {
  # Force a fresh, synchronous check and report the outcome clearly.
  local rc=0
  check_for_update || rc=$?
  case $rc in
    0) show_update_info ;;
    1) say "[✅] ssm-connect is up to date (version $(_read_local_version))." ;;
    2) warn "Could not check for updates (network or server unreachable)." ;;
  esac
}

cmd_install_completion() {
  install_completion
}

cmd_update() {
  # Do our own version check rather than trusting the background flag, so
  # --update is correct even on a fresh shell where the flag doesn't exist.
  local local_version remote_version rc=0
  local_version=$(_read_local_version)
  remote_version=$(_fetch_remote_version) || rc=$?
  if [[ $rc -ne 0 ]]; then
    die "Could not reach the update server. Please try again later."
  fi

  if [[ "$(_version_cmp "$remote_version" "$local_version")" != "1" ]]; then
    say "[✅] ssm-connect is already up to date (version $local_version)."
    : > "$UPDATE_INFO_FILE"
    return 0
  fi

  say "[⬇️] Updating ssm-connect $local_version → $remote_version..."
  do_update "$remote_version" || exit 1
  : > "$UPDATE_INFO_FILE"
  print_changelog "$remote_version"
  # do_update just replaced this script file on disk. Exit from memory now so
  # bash never returns to the top level and re-reads the (now longer) file,
  # which would execute misaligned trailing bytes.
  exit 0
}

cmd_uninstall() {
  say "[🗑️] Uninstalling ssm-connect..."

  # Remove CLI
  if [[ -f "$SCRIPT_PATH" ]]; then
    sudo rm -f "$SCRIPT_PATH"
    say "[✅] Removed CLI: $SCRIPT_PATH"
  else
    say "[ℹ️] CLI script not found at $SCRIPT_PATH"
  fi

  # Remove bash completion
  local comp_dir
  comp_dir=$(detect_completion_dir)
  if [[ -n "$comp_dir" && -f "$comp_dir/ssm-connect" ]]; then
    local sudo_cmd=""
    [[ -w "$comp_dir" ]] || sudo_cmd="sudo"
    $sudo_cmd rm -f "$comp_dir/ssm-connect"
    say "[✅] Removed bash completion: $comp_dir/ssm-connect"
  fi

  # Remove config
  if [[ -d "$CONFIG_DIR" ]]; then
    rm -rf "$CONFIG_DIR"
    say "[✅] Removed config dir: $CONFIG_DIR"
  else
    say "[ℹ️] Config directory not found: $CONFIG_DIR"
  fi

  # Remove AWS profile credentials/config
  if [[ -f "$AWS_CRED_FILE" ]] && grep -q "^\[$AWS_PROFILE\]" "$AWS_CRED_FILE"; then
    sed -i.bak "/^\[$AWS_PROFILE\]/,/^\[/d" "$AWS_CRED_FILE"
    say "[✅] Removed credentials for profile: $AWS_PROFILE"
  fi
  if [[ -f "$AWS_CONFIG_FILE" ]] && grep -q "^\[profile $AWS_PROFILE\]" "$AWS_CONFIG_FILE"; then
    sed -i.bak "/^\[profile $AWS_PROFILE\]/,/^\[/d" "$AWS_CONFIG_FILE"
    say "[✅] Removed config for profile: $AWS_PROFILE"
  fi
  rm -f "$AWS_CRED_FILE.bak" "$AWS_CONFIG_FILE.bak" 2>/dev/null || true

  say "[🧹] Uninstall complete."
}

cmd_scp() {
  (( $# == 2 )) || {
    warn "Usage: ssm-connect --scp <source> <destination>"
    say  "         Use alias:path for remote, e.g.:"
    say  "           Upload:   ssm-connect --scp local.txt myserver:/home/ubuntu/"
    say  "           Download: ssm-connect --scp myserver:/home/ubuntu/file.txt ./"
    exit 1
  }
  require_tools aws

  local source="$1" destination="$2"
  local scp_alias remote_path local_path direction

  if [[ "$source" == *:* ]]; then
    scp_alias="${source%%:*}"; remote_path="${source#*:}"
    local_path="$destination"; direction="download"
  elif [[ "$destination" == *:* ]]; then
    scp_alias="${destination%%:*}"; remote_path="${destination#*:}"
    local_path="$source"; direction="upload"
  else
    die "One of source or destination must be a remote path in alias:path format."
  fi

  validate_remote_path "$remote_path"

  local instance_id
  instance_id=$(get_instance_id "$scp_alias")
  [[ -n "$instance_id" ]] || die "Alias '$scp_alias' not found."

  ensure_sso_login

  local tmp_name tmp_s3 command_id
  tmp_name="ssm-tmp-$(date +%s)-$RANDOM"
  tmp_s3="s3://$S3_BUCKET/$tmp_name"

  if [[ "$direction" == "upload" ]]; then
    [[ -f "$local_path" ]] || die "Local file '$local_path' not found."
    # Append the basename when uploading into a directory path.
    [[ "$remote_path" == */ ]] && remote_path="${remote_path}$(basename "$local_path")"

    say "[📤] Uploading local file to S3..."
    aws s3 cp "$local_path" "$tmp_s3" "${AWS_ARGS[@]}"

    say "[📦] Triggering SSM command to copy from S3 to instance..."
    command_id=$(aws ssm send-command "${AWS_ARGS[@]}" \
      --instance-ids "$instance_id" \
      --document-name "AWS-RunShellScript" \
      --comment "ssm-connect scp upload" \
      --parameters "commands=[\"sudo -u ubuntu aws s3 cp '$tmp_s3' '$remote_path' --profile=ssm\",\"sudo -u ubuntu aws s3 rm '$tmp_s3' --profile=ssm\"]" \
      --query "Command.CommandId" --output text)

    wait_for_ssm_command "$command_id"
    say "[✅] Upload complete."
  else
    # Append the remote basename when downloading into a directory.
    if [[ -d "$local_path" || "$local_path" == */ ]]; then
      local_path="${local_path%/}/$(basename "$remote_path")"
    fi

    say "[📦] Triggering SSM command to upload from instance to S3..."
    command_id=$(aws ssm send-command "${AWS_ARGS[@]}" \
      --instance-ids "$instance_id" \
      --document-name "AWS-RunShellScript" \
      --comment "ssm-connect scp download" \
      --parameters "commands=[\"sudo -u ubuntu aws s3 cp '$remote_path' '$tmp_s3' --profile=ssm\"]" \
      --query "Command.CommandId" --output text)

    wait_for_ssm_command "$command_id"

    say "[📥] Downloading file from S3..."
    aws s3 cp "$tmp_s3" "$local_path" "${AWS_ARGS[@]}"

    say "[🧹] Cleaning up S3..."
    aws s3 rm "$tmp_s3" "${AWS_ARGS[@]}"

    say "[✅] Download complete."
  fi

  say "[✅] SCP operation completed successfully!"
}

# ----------------------------------------------------------------------------
# Connecting (default action when no flag is given)
# ----------------------------------------------------------------------------

# Bump the usage counter and last-used timestamp for an alias.
record_usage() {
  local name="$1" now tmp
  now=$(date +%s)
  tmp="$USAGE_FILE.tmp"
  awk -F'\t' -v a="$name" -v t="$now" '
    $1 == a { print $1 "\t" $2 + 1 "\t" t; found = 1; next }
            { print }
    END     { if (!found) print a "\t1\t" t }
  ' "$USAGE_FILE" > "$tmp"
  mv "$tmp" "$USAGE_FILE"
}

# Connect to a single alias, or fall back to an fzf picker over a group.
connect_direct() {
  local name="$1" instance_id
  instance_id=$(get_instance_id "$name")

  if [[ -z "$instance_id" ]]; then
    # The argument might be a group name instead of an alias.
    local group_list
    group_list=$(list_group_aliases "$name")
    [[ -n "$group_list" ]] || die "No alias or group named '$name' found in $ALIAS_FILE"

    local count display selected
    count=$(printf '%s\n' "$group_list" | wc -l | tr -d ' ')
    say "[🔍] Group '$name' — $count instance(s):"

    display=$({
      printf "ALIAS\tINSTANCE\n"
      printf '%s\n' "$group_list" | awk '{ printf "%s\t%s\n", $1, $2 }' | sort
    } | column -t -s $'\t')

    selected=$(printf '%s\n' "$display" \
      | fzf --ansi --header-lines=1 --color=header:bold --prompt="$name › ")
    [[ -n "$selected" ]] || { say "[⚠️] No instance selected."; return 0; }

    name=$(awk '{print $1}' <<<"$selected")
    instance_id=$(get_instance_id "$name")
  fi

  start_session "$name" "$instance_id"
}

# Interactive picker over all aliases, sorted by group then recent usage.
connect_interactive() {
  if [[ ! -s "$ALIAS_FILE" ]]; then
    say "[📭] No aliases found. Use: ssm-connect --add-alias <alias> <id>"
    return 0
  fi

  mkdir -p "$(dirname "$USAGE_FILE")"
  touch "$USAGE_FILE"
  say "[🔍] Selecting instance interactively..."

  local has_groups sorted_rows display selected name instance_id
  has_groups=$(awk 'NF >= 3 { print 1; exit }' "$ALIAS_FILE")

  # Merge usage data (keyed by alias) and sort by group then recency. Match on
  # FILENAME, not the NR==FNR idiom, which misfires when the usage file is empty
  # (then the alias file's first line would be swallowed as usage data).
  sorted_rows=$(awk -F'\t' -v usage="$USAGE_FILE" '
    FILENAME == usage { count[$1] = $2 + 0; lastused[$1] = $3 + 0; next }
    {
      n = split($0, f, /[ \t]+/)
      a = f[1]; id = f[2]; grp = (n >= 3) ? f[3] : ""
      c = (a in count)    ? count[a]    : 0
      l = (a in lastused) ? lastused[a] : 0
      sort_grp = (grp == "") ? "~" : grp   # ungrouped sorts last
      print sort_grp "\t" l "\t" c "\t" a "\t" id "\t" grp
    }
  ' "$USAGE_FILE" "$ALIAS_FILE" | sort -t $'\t' -k1,1 -k2,2nr -k3,3nr)

  if [[ "$has_groups" == "1" ]]; then
    display=$({
      printf "ALIAS\tINSTANCE\tGROUP\n"
      printf '%s\n' "$sorted_rows" | awk -F'\t' \
        -v c_grp="$C_GRP" -v c_dim="$C_DIM" -v c_reset="$C_RESET" '
        {
          grp = ($6 == "") ? (c_dim "—" c_reset) : (c_grp $6 c_reset)
          printf "%s\t%s\t%s\n", $4, $5, grp
        }'
    } | column -t -s $'\t')
  else
    display=$({
      printf "ALIAS\tINSTANCE\n"
      printf '%s\n' "$sorted_rows" | awk -F'\t' '{ printf "%s\t%s\n", $4, $5 }'
    } | column -t -s $'\t')
  fi

  selected=$(printf '%s\n' "$display" \
    | fzf --ansi --header-lines=1 --color=header:bold --prompt="Select instance: ")
  [[ -n "$selected" ]] || { say "[⚠️] No instance selected."; return 0; }

  name=$(awk '{print $1}' <<<"$selected")
  instance_id=$(get_instance_id "$name")

  record_usage "$name"
  start_session "$name" "$instance_id"
  say "[✅] Session ended."
}

cmd_connect() {
  require_tools aws fzf
  ensure_sso_login
  if (( $# == 1 )); then
    connect_direct "$1"
  else
    connect_interactive
  fi
}

# ============================================================================
# Entry point
# ============================================================================
main() {
  init_runtime

  # Daily, in the background, check for a newer release and stash a banner;
  # show the previous run's banner now without ever blocking on the network.
  run_daily_update_check >/dev/null 2>&1 &
  show_update_info

  case "${1:-}" in
    --help|-h)                 cmd_help ;;
    --add-alias|-a)            shift; cmd_add_alias "$@" ;;
    --remove-alias|-r)         shift; cmd_remove_alias "$@" ;;
    --set-group)               shift; cmd_set_group "$@" ;;
    --unset-group)             shift; cmd_unset_group "$@" ;;
    --list-aliases|-l)         cmd_list_aliases ;;
    --version)                 cmd_version ;;
    --whats-new)               cmd_whats_new ;;
    --check-update)            cmd_check_update ;;
    --install-bash-completion) cmd_install_completion ;;
    --update)                  cmd_update ;;
    --uninstall)               cmd_uninstall ;;
    --scp)                     shift; cmd_scp "$@" ;;
    --*|-*)                    warn "Unknown option: ${1:-}"; cmd_help; exit 1 ;;
    *)                         cmd_connect "$@" ;;
  esac
}

main "$@"
