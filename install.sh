#!/bin/bash
set -euo pipefail

SCRIPT_URL="https://raw.githubusercontent.com/muhammadsemeer/ssm-connect/refs/heads/master/ssm-connect.sh"
REMOTE_VERSION_URL="https://raw.githubusercontent.com/muhammadsemeer/ssm-connect/master/version"
SCRIPT_PATH="/usr/local/bin/ssm-connect"

echo "[🔧] Installing ssm-connect..."

# === Detect OS ===
OS="$(uname -s)"
IS_MAC=false
IS_LINUX=false
case "$OS" in
  Darwin) IS_MAC=true ;;
  Linux)  IS_LINUX=true ;;
  *) echo "[❌] Unsupported OS: $OS"; exit 1 ;;
esac

if $IS_LINUX; then
  # === Require sudo/root ===
  if [[ "$EUID" -ne 0 ]]; then
    echo "[❌] Please run this script using: sudo ./install.sh"
    exit 1
  fi
fi

# === Sudo user's context ===
DEFAULT_USER=${SUDO_USER:-$(whoami)}
HOME_DIR=$(eval echo "~$DEFAULT_USER")
ALIAS_DIR="$HOME_DIR/.ssm-connect"
ALIAS_FILE="$ALIAS_DIR/aliases"

# === Helper for install check ===
install_if_missing_linux() {
  missing_pkgs=()
  for pkg in "$@"; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
      missing_pkgs+=("$pkg")
    fi
  done

  if [[ ${#missing_pkgs[@]} -gt 0 ]]; then
    echo "[📦] Installing missing packages: ${missing_pkgs[*]}"
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y "${missing_pkgs[@]}" >/dev/null 2>&1 || echo "[ERROR] Failed to install <package>"
  else
    echo "[✅] All required packages are already installed."
  fi
}

install_if_missing_brew() {
  for pkg in "$@"; do
    if ! brew list --formula "$pkg" &>/dev/null; then
      echo "[📦] Installing $pkg..."
      brew install --quiet "$pkg" >/dev/null 2>&1 || echo "[ERROR] Failed to install $pkg"
    else
      echo "[✅] $pkg already installed."
    fi
  done
}

# === Install system packages ===
if $IS_LINUX; then
  echo "[📦] Checking required packages on Linux..."
  install_if_missing_linux curl jq fzf unzip
elif $IS_MAC; then
  echo "[📦] Checking required packages on macOS..."
  if ! command -v brew &>/dev/null; then
    echo "[❌] Homebrew not found. Please install it from https://brew.sh/"
    exit 1
  fi
  install_if_missing_brew curl jq fzf unzip
fi

# === Install AWS CLI ===
if ! command -v aws &>/dev/null; then
  echo "[🌐] Installing AWS CLI..."
  if $IS_LINUX; then
    curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "/tmp/awscliv2.zip"
    unzip -q -o /tmp/awscliv2.zip -d /tmp
    /tmp/aws/install
    rm -rf /tmp/aws /tmp/awscliv2.zip
  elif $IS_MAC; then
    curl -fsSL "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o "/tmp/AWSCLIV2.pkg"
    sudo installer -pkg /tmp/AWSCLIV2.pkg -target /
    rm /tmp/AWSCLIV2.pkg
  fi
else
  echo "[✅] AWS CLI already installed."
fi

# === Install Session Manager Plugin ===
if ! command -v session-manager-plugin &>/dev/null; then
  echo "[📦] Installing Session Manager Plugin..."
  if $IS_LINUX; then
    curl -fsSL "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" -o /tmp/session-manager-plugin.deb
    dpkg -i /tmp/session-manager-plugin.deb
    rm /tmp/session-manager-plugin.deb
  elif $IS_MAC; then
      if ! command -v session-manager-plugin &>/dev/null; then
        echo "[📦] Installing Session Manager Plugin for macOS..."

        ARCH=$(uname -m)
        TMP_DIR="/tmp/ssm-install"
        mkdir -p "$TMP_DIR"
        cd "$TMP_DIR"

        if [[ "$ARCH" == "arm64" ]]; then
          PLUGIN_URL="https://s3.amazonaws.com/session-manager-downloads/plugin/latest/mac_arm64/session-manager-plugin.pkg"
        else
          PLUGIN_URL="https://s3.amazonaws.com/session-manager-downloads/plugin/latest/mac/session-manager-plugin.pkg"
        fi

        echo "[⬇️] Downloading plugin from: $PLUGIN_URL"
        curl -fsSL "$PLUGIN_URL" -o "session-manager-plugin.pkg"

        echo "[⚙️] Installing plugin..."
        sudo installer -pkg "session-manager-plugin.pkg" -target /

        echo "[🔗] Linking binary..."
        sudo ln -sf /usr/local/sessionmanagerplugin/bin/session-manager-plugin /usr/local/bin/session-manager-plugin

        rm -rf "$TMP_DIR"
      else
        echo "[✅] Session Manager Plugin already installed."
      fi
    fi
else
  echo "[✅] Session Manager Plugin already installed."
fi

# === Download CLI script ===
echo "[⬇️] Installing ssm-connect CLI to $SCRIPT_PATH"
sudo curl -fsSL "$SCRIPT_URL" -o "$SCRIPT_PATH"
sudo chmod +x "$SCRIPT_PATH"
# === Version file setup ===
VERSION_FILE="$ALIAS_DIR/version"
mkdir -p "$(dirname "$VERSION_FILE")"
curl -fsSL "$REMOTE_VERSION_URL" -o "$VERSION_FILE"

# === Setup alias config dir ===
echo "[📁] Setting up alias directory at $ALIAS_DIR"
mkdir -p "$ALIAS_DIR"
touch "$ALIAS_FILE"
if $IS_LINUX; then
  if id "$DEFAULT_USER" &>/dev/null; then
    echo "[🔧] Setting ownership and permissions for alias directory..."
    chown -R "$DEFAULT_USER:$DEFAULT_USER" "$ALIAS_DIR"
  else
    echo "[⚠️] Warning: Could not find user $DEFAULT_USER, skipping chown for alias directory."
  fi
fi
chmod 700 "$ALIAS_DIR"
chmod 600 "$ALIAS_FILE"

echo
echo "[✅] 'ssm-connect' installed successfully!"
echo "[ℹ️] Run: ssm-connect --help"
