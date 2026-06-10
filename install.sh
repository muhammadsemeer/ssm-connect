#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_URL="https://raw.githubusercontent.com/muhammadsemeer/ssm-connect/refs/heads/master/ssm-connect.sh"
readonly REMOTE_VERSION_URL="https://raw.githubusercontent.com/muhammadsemeer/ssm-connect/master/version"
readonly COMPLETION_URL="https://raw.githubusercontent.com/muhammadsemeer/ssm-connect/master/completions/ssm-connect.bash"
readonly COMPLETION_ZSH_URL="https://raw.githubusercontent.com/muhammadsemeer/ssm-connect/master/completions/ssm-connect.zsh"

# === Output helpers ===
say()  { printf '%s\n' "$*"; }
warn() { printf '[⚠️] %s\n' "$*" >&2; }
die()  { printf '[❌] %s\n' "$*" >&2; exit 1; }

say "[🔧] Installing ssm-connect..."

# === Detect OS and architecture ===
OS="$(uname -s)"
ARCH="$(uname -m)"
IS_MAC=false
IS_LINUX=false
IS_ARCH=false
case "$OS" in
  Darwin) IS_MAC=true ;;
  Linux)
    IS_LINUX=true
    grep -qi 'arch' /etc/os-release && IS_ARCH=true
    ;;
  *) die "Unsupported OS: $OS" ;;
esac

if $IS_LINUX && [[ "$EUID" -ne 0 ]]; then
  die "Please run this script using: sudo ./install.sh"
fi

# === Sudo user's context ===
DEFAULT_USER=${SUDO_USER:-$(whoami)}
HOME_DIR=$(eval echo "~$DEFAULT_USER")
ALIAS_DIR="$HOME_DIR/.ssm-connect"
ALIAS_FILE="$ALIAS_DIR/aliases"
VERSION_FILE="$ALIAS_DIR/version"

# === Choose binary install path ===
if $IS_MAC && [[ "$ARCH" == "arm64" ]]; then
  SCRIPT_PATH="/opt/homebrew/bin/ssm-connect"
else
  SCRIPT_PATH="/usr/local/bin/ssm-connect"
fi

# === Package install helpers ===
install_if_missing_apt() {
  local pkg missing=()
  for pkg in "$@"; do
    dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
  done
  if (( ${#missing[@]} > 0 )); then
    say "[📦] Installing missing packages: ${missing[*]}"
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y "${missing[@]}" >/dev/null 2>&1 || warn "Failed to install one or more packages."
  else
    say "[✅] All required packages are already installed."
  fi
}

install_if_missing_pacman() {
  local pkg missing=()
  for pkg in "$@"; do
    pacman -Q "$pkg" &>/dev/null || missing+=("$pkg")
  done
  if (( ${#missing[@]} > 0 )); then
    say "[📦] Installing missing packages: ${missing[*]}"
    sudo pacman -Sy --noconfirm "${missing[@]}"
  else
    say "[✅] All required packages are already installed."
  fi
}

install_if_missing_brew() {
  local pkg
  for pkg in "$@"; do
    if brew list --formula "$pkg" &>/dev/null; then
      say "[✅] $pkg already installed."
    else
      say "[📦] Installing $pkg..."
      brew install --quiet "$pkg" >/dev/null 2>&1 || warn "Failed to install $pkg"
    fi
  done
}

# === Install system packages ===
if $IS_LINUX; then
  say "[📦] Checking required packages on Linux..."
  if $IS_ARCH; then
    install_if_missing_pacman curl jq fzf unzip git base-devel
  else
    install_if_missing_apt curl jq fzf unzip
  fi
elif $IS_MAC; then
  say "[📦] Checking required packages on macOS..."
  command -v brew &>/dev/null || die "Homebrew not found. Please install it from https://brew.sh/"
  install_if_missing_brew curl jq fzf unzip bash-completion@2
fi

# === Install AWS CLI ===
if command -v aws &>/dev/null; then
  say "[✅] AWS CLI already installed."
else
  say "[🌐] Installing AWS CLI..."
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
fi

# === Install Session Manager Plugin ===
if command -v session-manager-plugin &>/dev/null; then
  say "[✅] Session Manager Plugin already installed."
else
  say "[📦] Installing Session Manager Plugin..."
  if $IS_LINUX && $IS_ARCH; then
    say "[📦] Installing Session Manager Plugin from AUR..."
    BUILD_DIR="$HOME_DIR/.cache/aur/aws-session-manager-plugin"
    rm -rf "$BUILD_DIR"
    sudo -u "$DEFAULT_USER" git clone --depth=1 \
      https://aur.archlinux.org/aws-session-manager-plugin.git "$BUILD_DIR"
    say "[⚙️] Building package as $DEFAULT_USER..."
    sudo -u "$DEFAULT_USER" bash -c "cd '$BUILD_DIR' && makepkg -si --noconfirm"
    rm -rf "$BUILD_DIR"
  elif $IS_LINUX; then
    curl -fsSL "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" \
      -o /tmp/session-manager-plugin.deb
    dpkg -i /tmp/session-manager-plugin.deb
    rm /tmp/session-manager-plugin.deb
  elif $IS_MAC; then
    if [[ "$ARCH" == "arm64" ]]; then
      PLUGIN_URL="https://s3.amazonaws.com/session-manager-downloads/plugin/latest/mac_arm64/session-manager-plugin.pkg"
    else
      PLUGIN_URL="https://s3.amazonaws.com/session-manager-downloads/plugin/latest/mac/session-manager-plugin.pkg"
    fi
    say "[⬇️] Downloading plugin from: $PLUGIN_URL"
    TMP_PKG=$(mktemp /tmp/session-manager-plugin.XXXXXX.pkg)
    curl -fsSL "$PLUGIN_URL" -o "$TMP_PKG"
    say "[⚙️] Installing plugin..."
    sudo installer -pkg "$TMP_PKG" -target /
    say "[🔗] Linking binary..."
    sudo ln -sf /usr/local/sessionmanagerplugin/bin/session-manager-plugin /usr/local/bin/session-manager-plugin
    rm -f "$TMP_PKG"
  fi
fi

# === Install ssm-connect CLI ===
say "[⬇️] Installing ssm-connect CLI to $SCRIPT_PATH"
sudo mkdir -p "$(dirname "$SCRIPT_PATH")"
sudo curl -fsSL "$SCRIPT_URL" -o "$SCRIPT_PATH"
sudo chmod +x "$SCRIPT_PATH"

# === Install bash completion ===
say "[⌨️ ] Installing bash completion..."
COMPLETION_DIR=""
if $IS_MAC; then
  # bash-completion@2 lazy-loads command-named files from here.
  command -v brew &>/dev/null && COMPLETION_DIR="$(brew --prefix)/share/bash-completion/completions"
elif $IS_ARCH; then
  COMPLETION_DIR="/usr/share/bash-completion/completions"
elif $IS_LINUX; then
  if [[ -d /etc/bash_completion.d ]]; then
    COMPLETION_DIR="/etc/bash_completion.d"
  elif [[ -d /usr/share/bash-completion/completions ]]; then
    COMPLETION_DIR="/usr/share/bash-completion/completions"
  fi
fi

if [[ -n "$COMPLETION_DIR" ]]; then
  mkdir -p "$COMPLETION_DIR"
  if curl -fsSL "$COMPLETION_URL" -o "$COMPLETION_DIR/ssm-connect" 2>/dev/null; then
    say "[✅] Bash completion installed to $COMPLETION_DIR/ssm-connect"
    say "[ℹ️] Restart your shell or run: source $COMPLETION_DIR/ssm-connect"
    if $IS_MAC; then
      say "[ℹ️] macOS: completion runs in bash (not the default zsh). Add to ~/.bash_profile:"
      say '       [[ -r "$(brew --prefix)/etc/profile.d/bash_completion.sh" ]] && . "$(brew --prefix)/etc/profile.d/bash_completion.sh"'
    fi
  else
    say "[ℹ️] Skipped bash completion (download failed)."
  fi
else
  say "[ℹ️] Could not detect a bash-completion directory; skipping completion install."
fi

# === Install zsh completion ===
say "[⌨️ ] Installing zsh completion..."
ZSH_COMPLETION_DIR=""
if $IS_MAC; then
  command -v brew &>/dev/null && ZSH_COMPLETION_DIR="$(brew --prefix)/share/zsh/site-functions"
elif $IS_LINUX; then
  if [[ -d /usr/local/share/zsh/site-functions ]]; then
    ZSH_COMPLETION_DIR="/usr/local/share/zsh/site-functions"
  else
    ZSH_COMPLETION_DIR="/usr/share/zsh/site-functions"
  fi
fi

if [[ -n "$ZSH_COMPLETION_DIR" ]]; then
  mkdir -p "$ZSH_COMPLETION_DIR"
  if curl -fsSL "$COMPLETION_ZSH_URL" -o "$ZSH_COMPLETION_DIR/_ssm-connect" 2>/dev/null; then
    say "[✅] Zsh completion installed to $ZSH_COMPLETION_DIR/_ssm-connect"
    if $IS_MAC; then
      say "[ℹ️] zsh: ensure ~/.zshrc has Homebrew's site-functions on fpath before compinit:"
      say '       FPATH="$(brew --prefix)/share/zsh/site-functions:$FPATH"'
      say "       autoload -Uz compinit && compinit"
    else
      say "[ℹ️] zsh: run 'compinit' or open a new shell to load completion."
    fi
  else
    say "[ℹ️] Skipped zsh completion (download failed)."
  fi
fi

# === Setup alias and version config ===
say "[📁] Setting up config directory at $ALIAS_DIR"
mkdir -p "$ALIAS_DIR"
touch "$ALIAS_FILE"
chmod 700 "$ALIAS_DIR"
chmod 600 "$ALIAS_FILE"

curl -fsSL "$REMOTE_VERSION_URL" -o "$VERSION_FILE" || echo "0.0.0" > "$VERSION_FILE"
chmod 644 "$VERSION_FILE"

# === Set ownership on Linux ===
if $IS_LINUX && id "$DEFAULT_USER" &>/dev/null; then
  say "[🔧] Adjusting ownership..."
  chown -R "$DEFAULT_USER:$DEFAULT_USER" "$ALIAS_DIR"
fi

say ""
say "[✅] 'ssm-connect' installed successfully!"
say "[ℹ️] Run: ssm-connect --help"
