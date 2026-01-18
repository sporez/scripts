#!/bin/bash

# 1. Colors for slick output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}>>> Starting Micro Installer & Configurator...${NC}"

# 2. Download and Install Micro (Official Script)
if ! command -v micro &> /dev/null; then
    echo -e "${BLUE}>>> Downloading Micro...${NC}"
    # Downloads to current dir
    curl https://getmic.ro | bash
    
    echo -e "${BLUE}>>> Moving Micro to /usr/local/bin (requires sudo)...${NC}"
    sudo mv micro /usr/local/bin/micro
else
    echo -e "${GREEN}>>> Micro is already installed.$(NC)"
fi

# 3. Register Micro with the OS (Fixes the select-editor/crontab menu)
MICRO_PATH=$(which micro)
echo -e "${BLUE}>>> Registering Micro with update-alternatives...${NC}"
# Install it as an alternative with high priority (100)
sudo update-alternatives --install /usr/bin/editor editor "$MICRO_PATH" 100
# Force it to be the active selection
sudo update-alternatives --set editor "$MICRO_PATH"

# 4. Update User Environment (Fixes terminal/git/other apps)
# We append to .bashrc only if it's not already there to avoid duplicates
if ! grep -q "export EDITOR=micro" ~/.bashrc; then
    echo -e "${BLUE}>>> Updating .bashrc...${NC}"
    echo "" >> ~/.bashrc
    echo "# Set Micro as default editor" >> ~/.bashrc
    echo "export EDITOR=micro" >> ~/.bashrc
    echo "export VISUAL=micro" >> ~/.bashrc
else
    echo -e "${GREEN}>>> .bashrc is already configured.$(NC)"
fi

echo -e "${GREEN}>>> Done! Micro is now the default editor for everything.${NC}"
echo -e "${GREEN}>>> Please run: ${NC}source ~/.bashrc${GREEN} to apply changes to this session.${NC}"
