#!/bin/sh
#
# Description: Alpine Linux version of the Zsh/Oh My Zsh/P10k setup script.
#              Automates installation of Zsh, OMZ, Powerlevel10k, direnv.
# Author: Gemini (Adapted for Alpine)
# Date: 2025-11-26

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Subroutines / Functions ---

# Function to print a standardized log message.
log() {
    echo "[LOG] $1"
}

# Function to check if running on WSL.
is_wsl() {
    if grep -qi "microsoft" /proc/version 2>/dev/null; then
        return 0
    else
        return 1
    fi
}

# Function to check for and install required system packages.
install_dependencies() {
    log "Updating package list and installing dependencies (zsh, curl, git, fontconfig, direnv, shadow)..."
    
    # Check if sudo is available, otherwise assume we are root (common in Alpine containers)
    if command -v sudo >/dev/null 2>&1; then
        sudo apk update
        # 'shadow' is needed for chsh command
        sudo apk add zsh curl git fontconfig direnv shadow ncurses
    else
        apk update
        apk add zsh curl git fontconfig direnv shadow ncurses
    fi
    log "Dependencies installed successfully."
}

# Function to install Oh My Zsh.
install_oh_my_zsh() {
    if [ -d "$HOME/.oh-my-zsh" ]; then
        log "Oh My Zsh is already installed. Skipping installation."
    else
        log "Installing Oh My Zsh..."
        # Install unattended
        sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
        log "Oh My Zsh installed successfully."
    fi
}

# Function to install the Powerlevel10k theme for Oh My Zsh.
install_powerlevel10k() {
    # POSIX compatible way to define default value
    ZSH_CUSTOM="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}"
    p10k_dir="$ZSH_CUSTOM/themes/powerlevel10k"
    
    if [ -d "$p10k_dir" ]; then
        log "Powerlevel10k is already installed. Skipping installation."
    else
        log "Cloning Powerlevel10k theme..."
        git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$p10k_dir"
        log "Powerlevel10k theme cloned successfully."
    fi
}

# Function to set Powerlevel10k as the default theme in .zshrc.
configure_zshrc() {
    log "Setting ZSH_THEME to powerlevel10k in ~/.zshrc..."
    if grep -q 'ZSH_THEME="powerlevel10k/powerlevel10k"' "$HOME/.zshrc"; then
        log "ZSH_THEME is already set correctly. Skipping."
    else
        sed -i 's|^ZSH_THEME=.*|ZSH_THEME="powerlevel10k/powerlevel10k"|' "$HOME/.zshrc"
        log "Theme configured successfully in .zshrc."
    fi
}

# Function to download and install fonts.
# Note: On a headless server, this is mostly symbolic, but kept for completeness.
install_fonts() {
    font_dir="$HOME/.local/share/fonts"
    log "Installing MesloLGS Nerd Fonts..."
    
    if [ -f "$font_dir/MesloLGS NF Regular.ttf" ]; then
        log "MesloLGS NF fonts appear to be already installed. Skipping."
        return
    fi
    
    mkdir -p "$font_dir"
    base_url="https://github.com/romkatv/powerlevel10k-media/raw/master"
    
    # Manual download calls to avoid array syntax incompatibility in standard sh
    log "Downloading fonts..."
    curl -fLo "$font_dir/MesloLGS NF Regular.ttf" "$base_url/MesloLGS%20NF%20Regular.ttf"
    curl -fLo "$font_dir/MesloLGS NF Bold.ttf" "$base_url/MesloLGS%20NF%20Bold.ttf"
    curl -fLo "$font_dir/MesloLGS NF Italic.ttf" "$base_url/MesloLGS%20NF%20Italic.ttf"
    curl -fLo "$font_dir/MesloLGS NF Bold Italic.ttf" "$base_url/MesloLGS%20NF%20Bold%20Italic.ttf"

    log "Updating font cache..."
    if command -v fc-cache >/dev/null 2>&1; then
        fc-cache -f -v
    else
        log "Warning: fc-cache not found. Fonts downloaded but cache not updated (common in minimal Alpine)."
    fi
    log "Fonts installed."
}

# Function to fix Powerlevel10k path in .zshrc.
fix_powerlevel10k_path() {
    log "Fixing Powerlevel10k theme path..."
    # Ensure HOME variable is expanded in the sed replacement
    sed -i "s|source  .oh-my-zsh/custom/themes/powerlevel10k/powerlevel10k.zsh-theme|source $HOME/.oh-my-zsh/custom/themes/powerlevel10k/powerlevel10k.zsh-theme|" "$HOME/.zshrc"
}

# Function to configure virtual environment display.
configure_virtualenv_display() {
    log "Configuring virtual environment display..."
    
    # Enable virtualenv display even when pyenv is active
    if [ -f "$HOME/.p10k.zsh" ]; then
        sed -i 's/POWERLEVEL9K_VIRTUALENV_SHOW_WITH_PYENV=false/POWERLEVEL9K_VIRTUALENV_SHOW_WITH_PYENV=true/' "$HOME/.p10k.zsh"
    fi
    
    # Remove VIRTUAL_ENV_DISABLE_PROMPT if it exists
    sed -i '/^export VIRTUAL_ENV_DISABLE_PROMPT=/d' "$HOME/.zshrc"
    
    # Add auto-activation of .venv if not already present
    if ! grep -q "# Auto-activate .venv" "$HOME/.zshrc"; then
        cat >> "$HOME/.zshrc" << 'EOF'

# Auto-activate .venv if in a directory with one
if [[ -d ".venv" ]]; then
  source .venv/bin/activate
fi
EOF
    fi
}

# Function to configure direnv.
configure_direnv() {
    log "Configuring direnv..."
    if ! grep -q 'direnv hook zsh' "$HOME/.zshrc"; then
        echo 'eval "$(direnv hook zsh)"' >> "$HOME/.zshrc"
        log "Added direnv hook to .zshrc."
    fi
}

# Function to configure Docker wrapper (simplified for POSIX sh).
configure_docker_wrapper() {
    log "Configuring Docker wrapper function..."
    
    if ! grep -q "# Docker wrapper alias" "$HOME/.zshrc"; then
        cat >> "$HOME/.zshrc" << 'EOF'

# Docker wrapper alias
docker() {
  if ! command -v docker > /dev/null; then
    echo "❌ Docker command not found."
    return 1
  fi
  /usr/bin/env docker "$@"
}
EOF
        log "Added Docker wrapper function to .zshrc."
    fi
}

# Function to change the user's default shell to zsh.
change_default_shell() {
    current_shell=$(echo "$SHELL")
    if ! echo "$current_shell" | grep -q "zsh"; then
        log "Changing default shell to zsh for user $(whoami)..."
        zsh_path=$(which zsh)
        
        # Try chsh. If it fails, warn the user.
        if chsh -s "$zsh_path"; then
            log "Default shell changed successfully."
        else
            log "WARNING: 'chsh' failed. You might need to edit /etc/passwd manually or run this script as root."
            log "Command to run manually: chsh -s $zsh_path $(whoami)"
        fi
    else
        log "Default shell is already zsh. Skipping."
    fi
}

# --- Main script execution ---
main() {
    log "Starting Alpine Zsh setup..."

    install_dependencies
    install_oh_my_zsh
    install_powerlevel10k
    configure_zshrc
    install_fonts
    fix_powerlevel10k_path
    configure_virtualenv_display
    configure_direnv
    
    if is_wsl; then
        configure_docker_wrapper
    fi
    
    change_default_shell

    echo ""
    log "--- Installation Complete! ---"
    echo "Please restart your session or type 'zsh' to start."
}

# Run main
main

