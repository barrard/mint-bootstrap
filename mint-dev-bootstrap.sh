#!/usr/bin/env bash
set -euo pipefail

log()  { printf "\n\033[1;32m==>\033[0m %s\n" "$*"; }
warn() { printf "\n\033[1;33m!!\033[0m %s\n" "$*"; }
die()  { printf "\n\033[1;31mxx\033[0m %s\n" "$*"; exit 1; }

require_cmd() { command -v "$1" >/dev/null 2>&1; }

if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
  die "Run as your normal user, not root"
fi

sudo -v

# -------------------------------------------------
# Base packages
# -------------------------------------------------
log "Installing base packages"
sudo apt-get update -y
sudo apt-get install -y \
  ca-certificates curl wget gnupg lsb-release software-properties-common \
  build-essential pkg-config \
  unzip zip tar \
  git jq ripgrep fzf htop tmux \
  net-tools openssh-client \
  python3 python3-pip \
  shellcheck \
  logrotate needrestart

# -------------------------------------------------
# Zsh + Oh My Zsh
# -------------------------------------------------
log "Installing zsh"
sudo apt-get install -y zsh

if [[ ! -d "$HOME/.oh-my-zsh" ]]; then
  log "Installing Oh My Zsh"
  RUNZSH=no CHSH=no KEEP_ZSHRC=yes \
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
fi

# Create .zshrc if needed
if [[ ! -f "$HOME/.zshrc" ]] || ! grep -q "oh-my-zsh.sh" "$HOME/.zshrc"; then
  log "Creating ~/.zshrc"
  cat > "$HOME/.zshrc" <<'EOF'
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="robbyrussell"
plugins=(git)
source "$ZSH/oh-my-zsh.sh"
EOF
fi

# Mint/GNOME terminal sometimes forces bash; ensure new terminals land in zsh
log "Configuring bashrc to auto-switch to zsh"
touch "$HOME/.bashrc"
if ! grep -q "__AUTO_ZSH_DONE" "$HOME/.bashrc"; then
  cat >> "$HOME/.bashrc" <<'EOF'

# --- Auto-switch to zsh (Linux Mint / GNOME Terminal) ---
if [ -t 1 ] && [ -z "${ZSH_VERSION:-}" ] && command -v zsh >/dev/null 2>&1; then
  if [ -z "${__AUTO_ZSH_DONE:-}" ]; then
    export __AUTO_ZSH_DONE=1
    exec zsh -l
  fi
fi
EOF
fi

# Change default shell (will take effect on next login)
ZSH_PATH="$(command -v zsh)"
if [[ "$(getent passwd "$USER" | cut -d: -f7)" != "$ZSH_PATH" ]]; then
  log "Setting zsh as default shell (requires password)"
  chsh -s "$ZSH_PATH"
fi

# -------------------------------------------------
# SSH key setup (ed25519, passphrase-protected)
# -------------------------------------------------
log "Setting up SSH keys"

SSH_KEY="$HOME/.ssh/id_ed25519"

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

if [[ ! -f "$SSH_KEY" ]]; then
  echo
  echo "No SSH key found."
  echo "You will now be prompted to create one (with a passphrase)."
  echo

  ssh-keygen -t ed25519 -a 100 -f "$SSH_KEY"

  echo
  echo "SSH key created:"
  echo "  Public key: $SSH_KEY.pub"
else
  log "SSH key already exists: $SSH_KEY"
fi

# Start ssh-agent if not running
if ! pgrep -u "$USER" ssh-agent >/dev/null; then
  eval "$(ssh-agent -s)"
fi

# Add key to agent (will prompt for passphrase)
ssh-add "$SSH_KEY" || true

# Persist ssh-agent usage across shells
for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
  touch "$rc"
  if ! grep -q "ssh-agent -s" "$rc"; then
    cat >> "$rc" <<'EOF'

# --- SSH agent auto-start ---
if [ -z "$SSH_AUTH_SOCK" ]; then
  eval "$(ssh-agent -s)" >/dev/null
fi
EOF
  fi
done

# -------------------------------------------------
# VS Code (Mint-safe, NO SNAP)
# -------------------------------------------------
log "Installing VS Code (Microsoft APT repo)"
if ! require_cmd code; then
  sudo install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | \
    gpg --dearmor | sudo tee /etc/apt/keyrings/microsoft.gpg >/dev/null

  echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/code stable main" | \
    sudo tee /etc/apt/sources.list.d/vscode.list >/dev/null

  sudo apt-get update -y
  sudo apt-get install -y code
fi
require_cmd code || die "`code` command missing after install"

# -------------------------------------------------
# nvm + latest Node LTS
# -------------------------------------------------
log "Installing nvm + Node LTS"

# Install nvm if not present
if [[ ! -d "$HOME/.nvm" ]]; then
  curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/master/install.sh | bash
fi

# Add nvm to both bashrc and zshrc if not already there
for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
  touch "$rc"
  if ! grep -q 'NVM_DIR' "$rc"; then
    cat >> "$rc" <<'EOF'

# --- NVM setup ---
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
EOF
  fi
done

# Load nvm in current bash session to install Node
export NVM_DIR="$HOME/.nvm"
# shellcheck disable=SC1091
[ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"

nvm install --lts
nvm alias default 'lts/*'
npm install -g npm@latest

# -------------------------------------------------
# MongoDB Community (Mint-safe: use Ubuntu base codename)
# -------------------------------------------------
log "Installing MongoDB (using Ubuntu base codename)"
UBU_CODENAME="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}")"
[[ -n "$UBU_CODENAME" ]] || die "Could not detect Ubuntu base codename from /etc/os-release"
log "Ubuntu base codename detected: $UBU_CODENAME"

# Remove any old/bad list from prior runs
sudo rm -f /etc/apt/sources.list.d/mongodb-org-8.0.list

curl -fsSL https://www.mongodb.org/static/pgp/server-8.0.asc | \
  sudo gpg -o /usr/share/keyrings/mongodb-server-8.0.gpg --dearmor

echo "deb [arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-8.0.gpg] https://repo.mongodb.org/apt/ubuntu ${UBU_CODENAME}/mongodb-org/8.0 multiverse" | \
  sudo tee /etc/apt/sources.list.d/mongodb-org-8.0.list >/dev/null

sudo apt-get update -y
sudo apt-get remove -y mongodb || true
sudo apt-get install -y mongodb-org
sudo systemctl enable --now mongod

# -------------------------------------------------
# Redis
# -------------------------------------------------
log "Installing Redis"
sudo apt-get install -y redis-server
sudo systemctl enable --now redis-server

# -------------------------------------------------
# Docker
# -------------------------------------------------
log "Installing Docker"
sudo apt-get install -y docker.io docker-compose-plugin
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER" || true

# -------------------------------------------------
# GitHub CLI (gh)
# -------------------------------------------------
log "Installing GitHub CLI"
if ! require_cmd gh; then
  sudo install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | \
    sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
  sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | \
    sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
  sudo apt-get update -y
  sudo apt-get install -y gh
fi

# -------------------------------------------------
# Web server: Apache + Certbot
# -------------------------------------------------
log "Installing Apache + Certbot"
sudo apt-get install -y apache2
sudo systemctl enable --now apache2

sudo apt-get install -y certbot python3-certbot-apache

# -------------------------------------------------
# Security baseline: fail2ban + ufw + unattended upgrades
# -------------------------------------------------
log "Installing fail2ban"
sudo apt-get install -y fail2ban
sudo systemctl enable --now fail2ban

log "Installing and configuring ufw firewall"
sudo apt-get install -y ufw

# Safe defaults: allow SSH so you can't lock yourself out
sudo ufw allow OpenSSH >/dev/null || true
# If you're running Apache, allow web traffic
sudo ufw allow "Apache Full" >/dev/null || true

# Enable firewall (idempotent)
if sudo ufw status | grep -q "Status: inactive"; then
  sudo ufw --force enable
fi

log "Enabling unattended upgrades (security updates)"
sudo apt-get install -y unattended-upgrades
sudo dpkg-reconfigure -f noninteractive unattended-upgrades >/dev/null || true

# Optional but safe auditing package
log "Installing auditd (optional baseline auditing)"
sudo apt-get install -y auditd || true
sudo systemctl enable --now auditd || true

# -------------------------------------------------
# AI CLIs
# -------------------------------------------------
log "Installing AI CLIs"

# Make sure we have Node/npm loaded
export NVM_DIR="$HOME/.nvm"
# shellcheck disable=SC1091
[ -s "$NVM_DIR/nvm.sh" ] && source "$NVM_DIR/nvm.sh"

npm i -g @openai/codex
npm install -g @google/gemini-cli

if ! require_cmd claude; then
  log "Installing Claude Code CLI"
  curl -fsSL https://claude.ai/install.sh | zsh
fi

# -------------------------------------------------
# Summary
# -------------------------------------------------
log "Bootstrap complete"
echo
echo "=========================================="
echo "IMPORTANT: Log out and log back in for zsh to become your default shell."
echo "=========================================="
echo
echo "After logging back in, verify:"
echo "  echo \$0                    # Should show 'zsh' or '-zsh'"
echo "  ps -p \$\$ -o comm=          # Should show 'zsh'"
echo
echo "Other checks:"
echo "  code .                      # Launch VS Code"
echo "  node --version              # Check Node.js"
echo "  sudo ufw status             # Check firewall"
echo
echo "To issue a Let's Encrypt cert (once DNS points to this box):"
echo "  sudo certbot --apache -d yourdomain.com -d www.yourdomain.com"
echo
