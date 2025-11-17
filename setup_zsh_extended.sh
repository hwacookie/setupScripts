#!/bin/bash
#
# Description: This script automates the installation of Zsh, Oh My Zsh,
#              the Powerlevel10k theme, the recommended MesloLGS NF fonts,
#              direnv for virtual environment management, and configures
#              Docker integration for WSL 2.
#              This version includes fixes for Powerlevel10k, virtual environment
#              display, and Docker Desktop availability checking.
# Author: Gemini (extended with VoiceKeyboard project enhancements)
# Date: 2025-11-18

# Exit immediately if a command exits with a non-zero status.
set -e

# --- Subroutines / Functions ---

# Function to print a standardized log message.
log() {
    # Using a recognizable prefix for log statements.
    echo "[LOG - $(basename "$0")] $1"
}

# Function to check if running on WSL 2.
is_wsl2() {
    # Check if /proc/version contains "microsoft" (WSL 1 and 2)
    # and if /proc/sys/kernel/osrelease contains "wsl2" or if running on WSL 2
    if grep -qi "microsoft" /proc/version 2>/dev/null; then
        return 0  # True - running on WSL
    else
        return 1  # False - not running on WSL
    fi
}

# Function to check for and install required system packages.
install_dependencies() {
    log "Updating package list and installing dependencies (zsh, curl, git, fontconfig, direnv)..."
    sudo apt-get update
    sudo apt-get install -y zsh curl git fontconfig direnv
    log "Dependencies installed successfully."
}

# Function to install Oh My Zsh.
install_oh_my_zsh() {
    # Check if Oh My Zsh is already installed to prevent re-installation.
    if [ -d "$HOME/.oh-my-zsh" ]; then
        log "Oh My Zsh is already installed. Skipping installation."
    else
        log "Installing Oh My Zsh..."
        # Run the installer non-interactively.
        # We will change the shell manually later for better control.
        sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
        log "Oh My Zsh installed successfully."
    fi
}

# Function to install the Powerlevel10k theme for Oh My Zsh.
install_powerlevel10k() {
    local p10k_dir="${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/themes/powerlevel10k"
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
    # Use sed to safely replace the theme setting.
    if grep -q 'ZSH_THEME="powerlevel10k/powerlevel10k"' "$HOME/.zshrc"; then
        log "ZSH_THEME is already set correctly. Skipping."
    else
        sed -i 's|^ZSH_THEME=.*|ZSH_THEME="powerlevel10k/powerlevel10k"|' "$HOME/.zshrc"
        log "Theme configured successfully in .zshrc."
    fi
}

# Function to download and install the recommended MesloLGS NF fonts.
# This is the corrected version that handles spaces in filenames.
install_fonts() {
    local font_dir="$HOME/.local/share/fonts"
    log "Installing MesloLGS Nerd Fonts..."
    
    # Check if the first font already exists to skip re-downloading.
    if [ -f "$font_dir/MesloLGS NF Regular.ttf" ]; then
        log "MesloLGS NF fonts appear to be already installed. Skipping."
        return
    fi
    
    mkdir -p "$font_dir"
    
    local base_url="https://github.com/romkatv/powerlevel10k-media/raw/master"
    
    # These are the correct filenames, with spaces.
    local fonts=(
        "MesloLGS NF Regular.ttf"
        "MesloLGS NF Bold.ttf"
        "MesloLGS NF Italic.ttf"
        "MesloLGS NF Bold Italic.ttf"
    )

    # Download each font.
    for font_filename in "${fonts[@]}"; do
        # Create a URL-safe version of the filename by replacing spaces with %20.
        local font_url_path="${font_filename// /%20}"
        local full_url="$base_url/$font_url_path"
        
        log "Downloading '$font_filename'..."
        
        # Use the URL-safe version for the download and the original name for the local file.
        curl -fLo "$font_dir/$font_filename" "$full_url"
    done

    log "Updating font cache... This may take a moment."
    fc-cache -f -v
    log "Fonts installed and cache updated."
}

# Function to fix Powerlevel10k path in .zshrc for WSL 2 compatibility.
fix_powerlevel10k_path() {
    log "Fixing Powerlevel10k theme path for absolute path resolution..."
    if grep -q 'source $HOME/.oh-my-zsh/custom/themes/powerlevel10k/powerlevel10k.zsh-theme' "$HOME/.zshrc"; then
        log "Powerlevel10k path is already correct. Skipping."
    else
        sed -i 's|source  \.oh-my-zsh/custom/themes/powerlevel10k/powerlevel10k.zsh-theme|source $HOME/.oh-my-zsh/custom/themes/powerlevel10k/powerlevel10k.zsh-theme|' "$HOME/.zshrc"
        log "Powerlevel10k path fixed successfully."
    fi
}

# Function to configure virtual environment display and auto-activation.
configure_virtualenv_display() {
    log "Configuring virtual environment display in Powerlevel10k..."
    
    # Enable virtualenv display even when pyenv is active
    if grep -q "POWERLEVEL9K_VIRTUALENV_SHOW_WITH_PYENV=false" "$HOME/.p10k.zsh"; then
        sed -i 's/POWERLEVEL9K_VIRTUALENV_SHOW_WITH_PYENV=false/POWERLEVEL9K_VIRTUALENV_SHOW_WITH_PYENV=true/' "$HOME/.p10k.zsh"
        log "Enabled virtualenv display in Powerlevel10k."
    fi
    
    # Remove VIRTUAL_ENV_DISABLE_PROMPT if it exists
    if grep -q "^export VIRTUAL_ENV_DISABLE_PROMPT=" "$HOME/.zshrc"; then
        sed -i '/^export VIRTUAL_ENV_DISABLE_PROMPT=/d' "$HOME/.zshrc"
        log "Removed VIRTUAL_ENV_DISABLE_PROMPT from .zshrc."
    fi
    
    # Add auto-activation of .venv if not already present
    if ! grep -q "# Auto-activate .venv if in a directory with one" "$HOME/.zshrc"; then
        cat >> "$HOME/.zshrc" << 'EOF'

# Auto-activate .venv if in a directory with one
if [[ -d ".venv" ]]; then
  source .venv/bin/activate
fi
EOF
        log "Added .venv auto-activation to .zshrc."
    fi
}

# Function to configure direnv for automatic virtual environment management.
configure_direnv() {
    log "Configuring direnv for automatic virtual environment management..."
    
    # Add direnv hook to .zshrc if not already present
    if ! grep -q 'eval "\$(direnv hook zsh)"' "$HOME/.zshrc"; then
        cat >> "$HOME/.zshrc" << 'EOF'

# direnv hook for automatic virtual environment management
eval "$(direnv hook zsh)"
EOF
        log "Added direnv hook to .zshrc."
    else
        log "direnv hook already configured. Skipping."
    fi
}

# Function to configure Docker wrapper for WSL 2.
configure_docker_wrapper() {
    log "Configuring Docker wrapper function for WSL 2..."
    
    # Add docker wrapper if not already present
    if ! grep -q "# Docker wrapper alias - checks if Docker is running" "$HOME/.zshrc"; then
        cat >> "$HOME/.zshrc" << 'EOF'

# Docker wrapper alias - checks if Docker is running before executing
docker() {
  if ! command -v /usr/bin/docker &> /dev/null; then
    echo "❌ Docker command not found. Make sure Docker Desktop is running on Windows."
    echo "   Then enable WSL integration in Docker Desktop settings."
    return 1
  fi
  
  if ! /usr/bin/docker ps &> /dev/null; then
    echo "❌ Docker Desktop hasn't been started yet."
    echo "   Please start Docker Desktop on Windows to use Docker commands."
    return 1
  fi
  
  /usr/bin/docker "$@"
}
EOF
        log "Added Docker wrapper function to .zshrc."
    else
        log "Docker wrapper already configured. Skipping."
    fi
}

# Function to change the user's default shell to zsh.
change_default_shell() {
    # Check if the current shell is already zsh.
    if [[ "$SHELL" != *"zsh"* ]]; then
        log "Changing default shell to zsh for user $(whoami)..."
        # This command requires the user's password to complete.
        if chsh -s "$(which zsh)"; then
            log "Default shell changed successfully."
            echo "NOTE: You will need to log out and log back in for the shell change to take effect everywhere."
        else
            log "Failed to change shell. Please try running 'chsh -s $(which zsh)' manually."
        fi
    else
        log "Default shell is already zsh. Skipping."
    fi
}

# --- Main script execution ---
main() {
    log "Starting Zsh, Oh My Zsh, Powerlevel10k, direnv, and Docker setup..."

    # Refresh sudo timestamp before we start asking for it.
    if ! sudo -v; then
        echo "ERROR: sudo credentials are required to install packages. Aborting."
        exit 1
    fi

    install_dependencies
    install_oh_my_zsh
    install_powerlevel10k
    configure_zshrc
    install_fonts
    fix_powerlevel10k_path
    configure_virtualenv_display
    configure_direnv
    
    # Only configure Docker wrapper on WSL 2
    if is_wsl2; then
        log "WSL 2 detected. Configuring Docker wrapper..."
        configure_docker_wrapper
    else
        log "Native Ubuntu detected. Skipping Docker wrapper configuration."
    fi
    
    change_default_shell

    echo ""
    log "--- Installation Complete! ---"
    echo ""
    echo "IMPORTANT NEXT STEPS:"
    echo "1. CLOSE and RE-OPEN your terminal to start using Zsh."
    echo "2. The first time you open the new terminal, the Powerlevel10k configuration wizard should launch automatically."
    echo "   - If it doesn't, you can run it manually with the command: p10k configure"
    echo "3. Change your terminal's font setting to 'MesloLGS NF'."
    echo "   - This is REQUIRED for icons and symbols to display correctly."
    echo ""
    echo "VIRTUAL ENVIRONMENT SETUP:"
    echo "- .venv directories will auto-activate when you enter their directory."
    echo "- direnv is configured for automatic virtual environment management."
    echo "- Virtual environment names will display in your Powerlevel10k prompt."
    echo ""
    
    if is_wsl2; then
        echo "DOCKER SETUP (for WSL 2):"
        echo "- Docker commands will check if Docker Desktop is running before execution."
        echo "- Make sure Docker Desktop WSL 2 integration is enabled in settings."
        echo ""
    fi
    
    echo "Enjoy your new prompt!"
}

# Run the main function of the script.
main
