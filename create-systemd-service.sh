#!/bin/bash

# Interactive Systemd Service Creator
# A friendly script to help create systemd services for your scripts and programs

set -e

# Colors for better readability
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Helper functions
print_info() {
    echo -e "${BLUE}ℹ ${NC}$1"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_section() {
    echo ""
    echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
    echo -e "${GREEN}  $1${NC}"
    echo -e "${GREEN}═══════════════════════════════════════════════════${NC}"
    echo ""
}

# Function to ask yes/no questions
ask_yes_no() {
    local prompt="$1"
    local default="${2:-n}"

    if [[ "$default" == "y" ]]; then
        prompt="$prompt [Y/n]: "
    else
        prompt="$prompt [y/N]: "
    fi

    read -p "$prompt" response
    response=${response:-$default}

    [[ "$response" =~ ^[Yy] ]]
}

# Function to ask questions with default values
ask_with_default() {
    local prompt="$1"
    local default="$2"

    if [[ -n "$default" ]]; then
        read -p "$prompt [$default]: " response
        echo "${response:-$default}"
    else
        read -p "$prompt: " response
        echo "$response"
    fi
}

# Start of script
clear
print_section "Systemd Service Creator"

echo "This script will help you create a systemd service for your programs."
echo "Perfect for keeping Python scripts, monitoring tools, and other programs running!"
echo ""

# Check if running as root (needed for installation)
if [[ $EUID -eq 0 ]]; then
    CAN_INSTALL=true
else
    CAN_INSTALL=false
    print_warning "Not running as root - service file will be created but not installed"
    print_info "Run with sudo to automatically install the service"
    echo ""
fi

# 1. Service Name
print_section "Step 1: Service Name"
echo "This is what you'll use with 'systemctl start/stop/status <name>'"
echo "Use lowercase, no spaces. Example: my-monitor, backup-script, etc."
echo ""

while true; do
    SERVICE_NAME=$(ask_with_default "Service name" "")

    if [[ -z "$SERVICE_NAME" ]]; then
        print_error "Service name cannot be empty"
        continue
    fi

    if [[ ! "$SERVICE_NAME" =~ ^[a-z0-9_-]+$ ]]; then
        print_error "Service name should only contain lowercase letters, numbers, hyphens, and underscores"
        continue
    fi

    if [[ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]]; then
        print_warning "A service with this name already exists!"
        if ! ask_yes_no "Overwrite it?"; then
            continue
        fi
    fi

    break
done

# 2. Description
print_section "Step 2: Description"
echo "A human-readable description of what this service does."
echo "This shows up when you run 'systemctl status ${SERVICE_NAME}'"
echo ""

DESCRIPTION=$(ask_with_default "Description" "My custom service")

# 3. Executable Path
print_section "Step 3: Program/Script to Run"
echo "This is the full path to your script or program."
echo "Examples:"
echo "  /home/user/scripts/monitor.py"
echo "  /usr/local/bin/backup.sh"
echo "  /opt/myapp/server"
echo ""

while true; do
    EXEC_PATH=$(ask_with_default "Path to executable" "")

    if [[ -z "$EXEC_PATH" ]]; then
        print_error "Executable path cannot be empty"
        continue
    fi

    # Expand ~ to home directory
    EXEC_PATH="${EXEC_PATH/#\~/$HOME}"

    if [[ ! -f "$EXEC_PATH" ]]; then
        print_warning "File does not exist: $EXEC_PATH"
        if ! ask_yes_no "Use it anyway?"; then
            continue
        fi
    elif [[ ! -x "$EXEC_PATH" ]]; then
        print_warning "File is not executable: $EXEC_PATH"
        print_info "You may need to run: chmod +x $EXEC_PATH"
        if ! ask_yes_no "Continue anyway?"; then
            continue
        fi
    fi

    break
done

# Detect if it's a Python script
IS_PYTHON=false
if [[ "$EXEC_PATH" =~ \.py$ ]]; then
    IS_PYTHON=true
    print_info "Detected Python script!"

    echo ""
    echo "For Python scripts, you have two options:"
    echo "  1. Use the script directly (requires shebang: #!/usr/bin/env python3)"
    echo "  2. Explicitly call python3 (e.g., python3 /path/to/script.py)"
    echo ""

    if ask_yes_no "Explicitly use 'python3' to run the script?" "y"; then
        EXEC_START="python3 $EXEC_PATH"
    else
        EXEC_START="$EXEC_PATH"
    fi
else
    EXEC_START="$EXEC_PATH"
fi

# 4. Arguments
print_section "Step 4: Command Arguments (Optional)"
echo "Any arguments/flags to pass to your program."
echo "Example: --config /etc/myapp.conf --verbose"
echo "Leave empty if none needed."
echo ""

ARGS=$(ask_with_default "Arguments" "")
if [[ -n "$ARGS" ]]; then
    EXEC_START="$EXEC_START $ARGS"
fi

# 4.5. Service Type Detection
print_section "Step 4.5: Service Type"
echo "Systemd needs to know how your program behaves:"
echo ""
echo "  simple   - Program runs in foreground (most common)"
echo "             Example: A Python script that loops forever"
echo ""
echo "  forking  - Program backgrounds itself and exits immediately"
echo "             Example: Scripts using 'nohup ... &' or management scripts"
echo ""

# Try to detect if the script backgrounds processes
SERVICE_TYPE="simple"
USES_FORKING=false
EXEC_STOP=""
EXEC_RELOAD=""
REMAIN_AFTER_EXIT="no"

if [[ -f "$EXEC_PATH" ]]; then
    if grep -q "nohup.*&" "$EXEC_PATH" 2>/dev/null; then
        print_warning "Detected 'nohup ... &' pattern in script - this backgrounds processes"
        USES_FORKING=true
    elif grep -q "&$" "$EXEC_PATH" 2>/dev/null && grep -q "^start" "$EXEC_PATH" 2>/dev/null; then
        print_warning "Detected backgrounding pattern in script"
        USES_FORKING=true
    fi
fi

if [[ "$USES_FORKING" == true ]]; then
    echo "Your script appears to background processes."
    echo ""
    print_info "Recommendation: Use 'forking' type"
    echo ""
    if ask_yes_no "Use 'forking' type?" "y"; then
        SERVICE_TYPE="forking"
        REMAIN_AFTER_EXIT="yes"

        # Ask if there's a stop command
        echo ""
        echo "Does your script have a 'stop' command?"
        echo "Example: If you start with './script.sh start', can you stop with './script.sh stop'?"
        echo ""
        if ask_yes_no "Script has a stop command?"; then
            STOP_CMD=$(ask_with_default "Stop command (e.g., 'stop')" "stop")
            EXEC_STOP="$EXEC_PATH $STOP_CMD"

            # Ask about restart command
            echo ""
            if ask_yes_no "Does it also have a 'restart' command?"; then
                RESTART_CMD=$(ask_with_default "Restart command (e.g., 'restart')" "restart")
                EXEC_RELOAD="$EXEC_PATH $RESTART_CMD"
            fi
        fi
    fi
else
    echo "Does your program:"
    echo "  - Use 'nohup ... &' to background processes?"
    echo "  - Fork/daemonize itself?"
    echo "  - Exit immediately after starting background services?"
    echo ""
    if ask_yes_no "Program backgrounds itself?"; then
        SERVICE_TYPE="forking"
        REMAIN_AFTER_EXIT="yes"

        # Ask if there's a stop command
        echo ""
        echo "Does your script have a 'stop' command?"
        if ask_yes_no "Script has a stop command?"; then
            STOP_CMD=$(ask_with_default "Stop command argument" "stop")
            if [[ "$STOP_CMD" == "$ARGS" ]]; then
                # Stop cmd is different from start args
                echo "What argument stops the service? (start was: $ARGS)"
                STOP_ARG=$(ask_with_default "Stop argument" "stop")
                EXEC_STOP="${EXEC_START/$ARGS/$STOP_ARG}"
            else
                EXEC_STOP="$EXEC_PATH $STOP_CMD"
            fi

            # Ask about restart command
            echo ""
            if ask_yes_no "Does it also have a 'restart' command?"; then
                RESTART_CMD=$(ask_with_default "Restart command argument" "restart")
                EXEC_RELOAD="$EXEC_PATH $RESTART_CMD"
            fi
        fi
    fi
fi

print_success "Using service type: $SERVICE_TYPE"
if [[ -n "$EXEC_STOP" ]]; then
    print_info "Stop command: $EXEC_STOP"
fi
if [[ -n "$EXEC_RELOAD" ]]; then
    print_info "Reload command: $EXEC_RELOAD"
fi

# 5. Working Directory
print_section "Step 5: Working Directory (Optional)"
echo "The directory the program should run from."
echo "This is where the program will look for relative file paths."
echo "If your script uses files like './config.json', set this to the script's directory."
echo ""

DEFAULT_WORK_DIR=$(dirname "$EXEC_PATH")
WORK_DIR=$(ask_with_default "Working directory" "$DEFAULT_WORK_DIR")

# 6. User
print_section "Step 6: User to Run As"
echo "Which user should run this service?"
echo "  - root: Full system access (use with caution!)"
echo "  - your-user: Safer, runs with your user's permissions"
echo "  - specific user: For dedicated service accounts"
echo ""
print_info "Running as non-root is more secure for most use cases"
echo ""

DEFAULT_USER=$(whoami)
RUN_USER=$(ask_with_default "User" "$DEFAULT_USER")

# Validate user exists
if ! id "$RUN_USER" &>/dev/null; then
    print_warning "User '$RUN_USER' does not exist on this system"
    if ! ask_yes_no "Use anyway?"; then
        RUN_USER=$(whoami)
    fi
fi

# 7. Restart Policy
print_section "Step 7: Restart Policy"
echo "What should happen if your program crashes or exits?"
echo ""
echo "Options:"
echo "  always       - Always restart, even if it exits successfully"
echo "  on-failure   - Only restart if it crashes (recommended for most scripts)"
echo "  on-abnormal  - Restart on crashes and timeouts"
echo "  no           - Never restart automatically"
echo ""
print_info "For monitoring scripts and services: use 'on-failure' or 'always'"
print_info "For one-time tasks: use 'no'"
echo ""

RESTART_OPTIONS=("on-failure" "always" "on-abnormal" "no")
echo "Choose restart policy:"
echo "  1) on-failure (recommended)"
echo "  2) always"
echo "  3) on-abnormal"
echo "  4) no"
echo ""

read -p "Choice [1]: " restart_choice
restart_choice=${restart_choice:-1}

case $restart_choice in
    1) RESTART="on-failure" ;;
    2) RESTART="always" ;;
    3) RESTART="on-abnormal" ;;
    4) RESTART="no" ;;
    *) RESTART="on-failure" ;;
esac

print_success "Using restart policy: $RESTART"

# 8. Restart Delay
if [[ "$RESTART" != "no" ]]; then
    echo ""
    echo "How long to wait before restarting after a failure?"
    RESTART_SEC=$(ask_with_default "Restart delay in seconds" "10")
fi

# 9. Environment Variables
print_section "Step 8: Environment Variables (Optional)"
echo "Set custom environment variables for your service."
echo "Example: API_KEY=abc123 or DEBUG=true"
echo ""

ENV_VARS=()
if ask_yes_no "Add environment variables?"; then
    echo ""
    echo "Enter environment variables one per line (format: KEY=value)"
    echo "Press Enter with empty line when done:"
    echo ""

    while true; do
        read -p "Environment variable: " env_var
        if [[ -z "$env_var" ]]; then
            break
        fi

        if [[ "$env_var" =~ ^[A-Za-z_][A-Za-z0-9_]*=.*$ ]]; then
            ENV_VARS+=("$env_var")
            print_success "Added: $env_var"
        else
            print_error "Invalid format. Use: KEY=value"
        fi
    done
fi

# 10. Start on Boot
print_section "Step 9: Auto-Start on Boot"
echo "Should this service start automatically when the system boots?"
echo ""

AUTO_START=$(ask_yes_no "Enable auto-start on boot?" "y")

# 11. Advanced Options
print_section "Step 10: Advanced Options (Optional)"
echo "A few extra options for reliability:"
echo ""

# Standard output/error
echo "Logging:"
echo "  journal - Use systemd journal (view with: journalctl -u $SERVICE_NAME)"
echo "  file    - Write to a specific log file"
echo ""

if ask_yes_no "Use systemd journal for logging (recommended)?" "y"; then
    STD_OUTPUT="journal"
    STD_ERROR="journal"
    LOG_FILE=""
else
    echo ""
    LOG_FILE=$(ask_with_default "Path to log file" "/var/log/${SERVICE_NAME}.log")
    STD_OUTPUT="append:$LOG_FILE"
    STD_ERROR="append:$LOG_FILE"
fi

# Generate the service file
print_section "Generating Service File"

SERVICE_FILE_CONTENT="[Unit]
Description=$DESCRIPTION
After=network.target

[Service]
Type=$SERVICE_TYPE
User=$RUN_USER
WorkingDirectory=$WORK_DIR
ExecStart=$EXEC_START"

# Add ExecStop if it exists
if [[ -n "$EXEC_STOP" ]]; then
    SERVICE_FILE_CONTENT="${SERVICE_FILE_CONTENT}
ExecStop=$EXEC_STOP"
fi

# Add ExecReload if it exists
if [[ -n "$EXEC_RELOAD" ]]; then
    SERVICE_FILE_CONTENT="${SERVICE_FILE_CONTENT}
ExecReload=$EXEC_RELOAD"
fi

# Add RemainAfterExit for forking services
if [[ "$REMAIN_AFTER_EXIT" == "yes" ]]; then
    SERVICE_FILE_CONTENT="${SERVICE_FILE_CONTENT}
RemainAfterExit=yes"
fi

SERVICE_FILE_CONTENT="${SERVICE_FILE_CONTENT}
Restart=$RESTART"

if [[ "$RESTART" != "no" ]]; then
    SERVICE_FILE_CONTENT="${SERVICE_FILE_CONTENT}
RestartSec=$RESTART_SEC"
fi

# Add environment variables
for env_var in "${ENV_VARS[@]}"; do
    SERVICE_FILE_CONTENT="${SERVICE_FILE_CONTENT}
Environment=\"$env_var\""
done

# Add logging
SERVICE_FILE_CONTENT="${SERVICE_FILE_CONTENT}
StandardOutput=$STD_OUTPUT
StandardError=$STD_ERROR

# Security: Don't allow new privileges
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target"

# Save to temporary location first
TEMP_SERVICE_FILE="/tmp/${SERVICE_NAME}.service"
echo "$SERVICE_FILE_CONTENT" > "$TEMP_SERVICE_FILE"

print_success "Service file created!"
echo ""
echo "═══════════════════════════════════════════════════"
echo "Generated service file:"
echo "═══════════════════════════════════════════════════"
echo "$SERVICE_FILE_CONTENT"
echo "═══════════════════════════════════════════════════"
echo ""

# Save to current directory as backup
cp "$TEMP_SERVICE_FILE" "./${SERVICE_NAME}.service"
print_success "Saved backup to: $(pwd)/${SERVICE_NAME}.service"

# Installation
print_section "Installation"

if [[ "$CAN_INSTALL" == true ]]; then
    if ask_yes_no "Install this service now?" "y"; then
        # Copy to systemd directory
        cp "$TEMP_SERVICE_FILE" "/etc/systemd/system/${SERVICE_NAME}.service"
        print_success "Service file installed to /etc/systemd/system/${SERVICE_NAME}.service"

        # Reload systemd
        systemctl daemon-reload
        print_success "Systemd reloaded"

        # Enable if requested
        if [[ "$AUTO_START" == true ]]; then
            systemctl enable "${SERVICE_NAME}.service"
            print_success "Service enabled (will start on boot)"
        fi

        # Start now?
        echo ""
        if ask_yes_no "Start the service now?" "y"; then
            if systemctl start "${SERVICE_NAME}.service"; then
                print_success "Service started!"
                echo ""
                systemctl status "${SERVICE_NAME}.service" --no-pager -l
            else
                print_error "Failed to start service"
                echo ""
                journalctl -u "${SERVICE_NAME}.service" -n 20 --no-pager
            fi
        fi

        echo ""
        print_section "Setup Complete!"
        echo "Useful commands for managing your service:"
        echo ""
        echo "  Start:   sudo systemctl start ${SERVICE_NAME}"
        echo "  Stop:    sudo systemctl stop ${SERVICE_NAME}"
        echo "  Restart: sudo systemctl restart ${SERVICE_NAME}"
        if [[ -n "$EXEC_RELOAD" ]]; then
            echo "  Reload:  sudo systemctl reload ${SERVICE_NAME}  # Calls custom reload command"
        fi
        echo "  Status:  sudo systemctl status ${SERVICE_NAME}"
        echo "  Logs:    sudo journalctl -u ${SERVICE_NAME} -f"
        echo "  Enable:  sudo systemctl enable ${SERVICE_NAME}  # Start on boot"
        echo "  Disable: sudo systemctl disable ${SERVICE_NAME} # Don't start on boot"
        echo ""
    else
        print_info "Service file created but not installed"
        echo ""
        echo "To install manually, run:"
        echo "  sudo cp ${SERVICE_NAME}.service /etc/systemd/system/"
        echo "  sudo systemctl daemon-reload"
        echo "  sudo systemctl enable ${SERVICE_NAME}.service"
        echo "  sudo systemctl start ${SERVICE_NAME}.service"
        echo ""
    fi
else
    print_warning "Service file created but not installed (not running as root)"
    echo ""
    echo "To install, run:"
    echo "  sudo cp ${SERVICE_NAME}.service /etc/systemd/system/"
    echo "  sudo systemctl daemon-reload"

    if [[ "$AUTO_START" == true ]]; then
        echo "  sudo systemctl enable ${SERVICE_NAME}.service"
    fi

    echo "  sudo systemctl start ${SERVICE_NAME}.service"
    echo ""
fi

print_success "Done!"
