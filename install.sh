#!/bin/bash
#
# Install script for CheckSSR.sh
#
# This script installs and configures the CheckSSR script for NASDAQ and NYSE Short Sale Restriction (SSR) monitoring.
# It is designed to be idempotent - running it multiple times will not break your installation.
#
# Features:
# - Creates necessary directories
# - Installs script to appropriate locations
# - Sets up configuration files
# - Creates sample positions file
# - Sets up logging
# - Can configure launchd for scheduled execution (optional)
#

# Enable strict mode
set -euo pipefail

# Set umask to create files with safe permissions (user read-write, group/others read)
umask 022

# Track installation actions for rollback
ACTIONS_PERFORMED=()

# Variable to track if we need to exit with error
SHOULD_EXIT_WITH_ERROR=false

# Colors for pretty output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script variables
SCRIPT_NAME="CheckSSR"
SCRIPT_VERSION="2.0.0"
# Get current script directory for resolving source file path
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_SCRIPT_RELATIVE="./CheckSSR.sh"
SOURCE_SCRIPT="${SCRIPT_DIR}/$(basename "${SOURCE_SCRIPT_RELATIVE}")"

# Installation directories
INSTALL_BIN_DIR="${HOME}/bin"
CONFIG_DIR="${HOME}/.config/CheckSSR"
# The positions file lives next to the config, not in Documents: iCloud can manage Documents
# and Desktop, and scheduled (launchd) runs may then be unable to read a file kept there.
DATA_DIR="${CONFIG_DIR}"
LOG_DIR="${HOME}/Library/Logs/CheckSSR"
LAUNCHD_DIR="${HOME}/Library/LaunchAgents"
LAUNCHD_FILE="com.user.checkssr.plist"

# Temp directory for rollback files
TEMP_DIR=""

# Print banner
print_banner() {
    echo -e "${BLUE}"
    echo "==============================================="
    echo "  ${SCRIPT_NAME} Installer v${SCRIPT_VERSION}"
    echo "==============================================="
    echo -e "${NC}"
    echo "This will install the CheckSSR script for monitoring the"
    echo "NASDAQ and NYSE Short Sale Restriction (SSR) lists for your stock positions."
    echo ""
}

# Print success message
print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

# Print error message and exit (unless we're in the process of cleanup)
print_error() {
    echo -e "${RED}✗ ERROR: $1${NC}" >&2
    if [[ "${SHOULD_EXIT_WITH_ERROR}" == "false" ]]; then
        SHOULD_EXIT_WITH_ERROR=true
        cleanup_and_exit 1
    fi
}

# Print warning message
print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

# Print info message
print_info() {
    echo -e "${BLUE}ℹ $1${NC}"
}

# Setup error handling and signal trapping
setup_error_handling() {
    # Create temporary directory for rollback files
    TEMP_DIR=$(mktemp -d "${HOME}/.checkssr_installer_temp.XXXXXX") || {
        echo -e "${RED}✗ ERROR: Failed to create temporary directory${NC}" >&2
        exit 1
    }
    
    # Trap exit signals to ensure cleanup
    trap 'cleanup_and_exit 1' SIGHUP SIGINT SIGTERM ERR
    
    print_success "Error handling and signal trapping set up"
}

# Cleanup function for error handling
cleanup_and_exit() {
    local exit_code=$1
    
    if [[ "${exit_code}" -ne 0 ]]; then
        echo -e "${RED}Installation failed. Rolling back changes...${NC}" >&2
        
        # Roll back actions in reverse order
        for ((i=${#ACTIONS_PERFORMED[@]}-1; i>=0; i--)); do
            local action="${ACTIONS_PERFORMED[$i]}"
            case "${action}" in
                "installed_script")
                    echo "Rolling back script installation..."
                    if [[ -f "${TEMP_DIR}/checkssr.bak" ]]; then
                        if [[ -f "${INSTALL_BIN_DIR}/checkssr" ]]; then
                            mv "${TEMP_DIR}/checkssr.bak" "${INSTALL_BIN_DIR}/checkssr" 2>/dev/null || true
                        fi
                    elif [[ -f "${INSTALL_BIN_DIR}/checkssr" ]]; then
                        rm -f "${INSTALL_BIN_DIR}/checkssr" 2>/dev/null || true
                    fi
                    ;;
                "created_config")
                    echo "Rolling back configuration..."
                    if [[ -f "${TEMP_DIR}/config.sh.bak" ]]; then
                        if [[ -f "${CONFIG_DIR}/config.sh" ]]; then
                            mv "${TEMP_DIR}/config.sh.bak" "${CONFIG_DIR}/config.sh" 2>/dev/null || true
                        fi
                    elif [[ -f "${CONFIG_DIR}/config.sh" ]] && [[ ! -s "${CONFIG_DIR}/config.sh" ]]; then
                        rm -f "${CONFIG_DIR}/config.sh" 2>/dev/null || true
                    fi
                    ;;
                "created_positions")
                    echo "Rolling back positions file..."
                    if [[ -f "${TEMP_DIR}/positions.txt.bak" ]]; then
                        if [[ -f "${DATA_DIR}/positions.txt" ]]; then
                            mv "${TEMP_DIR}/positions.txt.bak" "${DATA_DIR}/positions.txt" 2>/dev/null || true
                        fi
                    elif [[ -f "${DATA_DIR}/positions.txt" ]] && [[ ! -s "${DATA_DIR}/positions.txt" ]]; then
                        rm -f "${DATA_DIR}/positions.txt" 2>/dev/null || true
                    fi
                    ;;
                "created_launchd")
                    echo "Rolling back launchd configuration..."
                    launchctl unload "${LAUNCHD_DIR}/${LAUNCHD_FILE}" 2>/dev/null || true
                    if [[ -f "${TEMP_DIR}/checkssr.plist.bak" ]]; then
                        if [[ -f "${LAUNCHD_DIR}/${LAUNCHD_FILE}" ]]; then
                            mv "${TEMP_DIR}/checkssr.plist.bak" "${LAUNCHD_DIR}/${LAUNCHD_FILE}" 2>/dev/null || true
                        fi
                    elif [[ -f "${LAUNCHD_DIR}/${LAUNCHD_FILE}" ]]; then
                        rm -f "${LAUNCHD_DIR}/${LAUNCHD_FILE}" 2>/dev/null || true
                    fi
                    ;;
            esac
        done
    fi
    
    # Always cleanup temporary directory
    if [[ -d "${TEMP_DIR}" ]]; then
        rm -rf "${TEMP_DIR}" 2>/dev/null || true
    fi
    
    # Remove trap
    trap - SIGHUP SIGINT SIGTERM ERR
    
    if [[ "${exit_code}" -ne 0 ]]; then
        echo -e "${RED}Installation aborted.${NC}" >&2
    fi
    
    exit "${exit_code}"
}

# Validate path exists and is accessible
validate_path() {
    local path="$1"
    local type="$2" # "dir" or "file"
    local check_write="$3" # "true" or "false"
    
    if [[ "${type}" == "dir" ]]; then
        if [[ ! -d "${path}" ]]; then
            return 1
        fi
        
        if [[ "${check_write}" == "true" ]]; then
            if [[ ! -w "${path}" ]]; then
                return 2
            fi
        fi
    elif [[ "${type}" == "file" ]]; then
        if [[ ! -f "${path}" ]]; then
            return 1
        fi
        
        if [[ "${check_write}" == "true" ]]; then
            if [[ ! -w "${path}" ]]; then
                return 2
            fi
        fi
    fi
    
    return 0
}

# Check if required commands are available
check_requirements() {
    echo "Checking system requirements..."
    
    # Check bash version
    if [[ ${BASH_VERSINFO[0]} -lt 3 ]]; then
        print_error "Bash version 3.0 or higher is required"
    fi
    
    # Check if curl is installed
    if ! command -v curl &> /dev/null; then
        print_error "curl is required but not found. Please install curl and try again."
    else
        print_success "curl found"
    fi
    
    # Check for a way to send email: msmtp (recommended) or the system mail command
    if command -v msmtp &> /dev/null; then
        print_success "msmtp found (will be used to send email)"
    elif command -v mail &> /dev/null; then
        print_success "mail command found"
        print_warning "Mail sent with the mail command often cannot be delivered from a home network."
        print_info "msmtp with an app password is more reliable (for example: brew install msmtp)."
    else
        print_warning "Neither msmtp nor mail was found. Email notifications will not work without one."
        print_info "Install msmtp with your package manager (for example: brew install msmtp)."
        sleep 2
    fi

    # Check for python3 (needed to read the NYSE list, which is an Excel file)
    if command -v python3 &> /dev/null && python3 -c 'import struct' &> /dev/null; then
        print_success "python3 found"
    else
        print_warning "python3 not found or not working. The NYSE list cannot be read without it."
        print_info "Install Python 3 (python.org or your package manager), or check NASDAQ only"
        print_info "by setting MARKETS=\"NASDAQ\" in the configuration file."
        sleep 2
    fi
    
    # Check for launchctl (needed for scheduling)
    if ! command -v launchctl &> /dev/null; then
        print_warning "launchctl not found. Scheduled execution won't be available."
    else
        print_success "launchctl found"
    fi
    
    # Check for source script
    if ! validate_path "${SOURCE_SCRIPT}" "file" "false"; then
        print_error "Source script ${SOURCE_SCRIPT} not found"
    else
        if ! validate_path "${SOURCE_SCRIPT}" "file" "true"; then
            print_error "Source script ${SOURCE_SCRIPT} is not readable"
        else
            print_success "Source script found and readable"
        fi
    fi
    
    # Check if ~/bin is in PATH
    if ! grep -q "${INSTALL_BIN_DIR}" <<< "${PATH}"; then
        print_warning "${INSTALL_BIN_DIR} is not in your PATH. You may need to add it."
        print_info "Add this line to your ~/.bashrc or ~/.zshrc file:"
        print_info "export PATH=\"\$HOME/bin:\$PATH\""
    else
        print_success "${INSTALL_BIN_DIR} is in your PATH"
    fi
    
    # Check operating system
    if [[ "$(uname -s)" != "Darwin" ]]; then
        print_warning "This script is designed for macOS. Some features may not work on other systems."
    else
        print_success "macOS detected"
    fi
}

# Create necessary directories with proper permissions
create_directories() {
    echo "Creating required directories..."
    
    # Create bin directory if it doesn't exist
    if [[ ! -d "${INSTALL_BIN_DIR}" ]]; then
        mkdir -p "${INSTALL_BIN_DIR}" || print_error "Failed to create bin directory ${INSTALL_BIN_DIR}"
        chmod 755 "${INSTALL_BIN_DIR}" || print_warning "Failed to set permissions on ${INSTALL_BIN_DIR}"
        print_success "Created bin directory at ${INSTALL_BIN_DIR}"
        ACTIONS_PERFORMED+=("created_bin_dir")
    else
        if ! validate_path "${INSTALL_BIN_DIR}" "dir" "true"; then
            print_error "Cannot write to bin directory ${INSTALL_BIN_DIR}"
        fi
        print_info "Bin directory already exists at ${INSTALL_BIN_DIR}"
    fi
    
    # Create config directory if it doesn't exist
    if [[ ! -d "${CONFIG_DIR}" ]]; then
        mkdir -p "${CONFIG_DIR}" || print_error "Failed to create config directory ${CONFIG_DIR}"
        chmod 700 "${CONFIG_DIR}" || print_warning "Failed to set permissions on ${CONFIG_DIR}"
        print_success "Created config directory at ${CONFIG_DIR}"
        ACTIONS_PERFORMED+=("created_config_dir")
    else
        if ! validate_path "${CONFIG_DIR}" "dir" "true"; then
            print_error "Cannot write to config directory ${CONFIG_DIR}"
        fi
        print_info "Config directory already exists at ${CONFIG_DIR}"
    fi
    
    # Create data directory if it doesn't exist
    if [[ ! -d "${DATA_DIR}" ]]; then
        mkdir -p "${DATA_DIR}" || print_error "Failed to create data directory ${DATA_DIR}"
        chmod 755 "${DATA_DIR}" || print_warning "Failed to set permissions on ${DATA_DIR}"
        print_success "Created data directory at ${DATA_DIR}"
        ACTIONS_PERFORMED+=("created_data_dir")
    else
        if ! validate_path "${DATA_DIR}" "dir" "true"; then
            print_error "Cannot write to data directory ${DATA_DIR}"
        fi
        print_info "Data directory already exists at ${DATA_DIR}"
    fi
    
    # Create log directory if it doesn't exist
    if [[ ! -d "${LOG_DIR}" ]]; then
        mkdir -p "${LOG_DIR}" || print_error "Failed to create log directory ${LOG_DIR}"
        chmod 755 "${LOG_DIR}" || print_warning "Failed to set permissions on ${LOG_DIR}"
        print_success "Created log directory at ${LOG_DIR}"
        ACTIONS_PERFORMED+=("created_log_dir")
    else
        if ! validate_path "${LOG_DIR}" "dir" "true"; then
            print_error "Cannot write to log directory ${LOG_DIR}"
        fi
        print_info "Log directory already exists at ${LOG_DIR}"
    fi
}

# Install script
install_script() {
    echo "Installing CheckSSR script..."
    
    # Backup existing script if it exists
    if [[ -f "${INSTALL_BIN_DIR}/checkssr" ]]; then
        cp "${INSTALL_BIN_DIR}/checkssr" "${TEMP_DIR}/checkssr.bak" || print_warning "Failed to backup existing script"
    fi
    
    # Copy script to bin directory
    cp "${SOURCE_SCRIPT}" "${INSTALL_BIN_DIR}/checkssr" || print_error "Failed to copy script to ${INSTALL_BIN_DIR}/checkssr"
    chmod +x "${INSTALL_BIN_DIR}/checkssr" || print_warning "Failed to make script executable"
    
    # Verify the script was installed properly
    if ! validate_path "${INSTALL_BIN_DIR}/checkssr" "file" "false"; then
        print_error "Script installation failed - file not found at ${INSTALL_BIN_DIR}/checkssr"
    fi
    
    ACTIONS_PERFORMED+=("installed_script")
    print_success "Installed CheckSSR script to ${INSTALL_BIN_DIR}/checkssr"
}

# Create configuration file
create_config() {
    echo "Setting up configuration..."
    
    # Backup existing config if it exists
    if [[ -f "${CONFIG_DIR}/config.sh" ]]; then
        cp "${CONFIG_DIR}/config.sh" "${TEMP_DIR}/config.sh.bak" || print_warning "Failed to backup existing config"
    fi
    
    # Create default config if it doesn't exist
    if [[ ! -f "${CONFIG_DIR}/config.sh" ]]; then
        cat > "${CONFIG_DIR}/config.sh" << EOL || print_error "Failed to create configuration file"
# CheckSSR Configuration File
# Generated by installer on $(date)

# Email address to receive notifications
MAILTO="your.email@example.com"

# Path to your stock positions file (one ticker per line, used for every market)
STOCKS="${DATA_DIR}/positions.txt"

# Which SSR lists to check: NASDAQ, NYSE or both
MARKETS="NASDAQ NYSE"

# How many most recently listed stocks to show per market
TOPN=10
EOL
        chmod 600 "${CONFIG_DIR}/config.sh" || print_warning "Failed to set secure permissions on config file"
        ACTIONS_PERFORMED+=("created_config")
        print_success "Created default configuration at ${CONFIG_DIR}/config.sh"
        print_warning "Please edit ${CONFIG_DIR}/config.sh to set your email address!"
    else
        print_info "Configuration file already exists at ${CONFIG_DIR}/config.sh"
    fi
}

# Create sample positions file
create_positions_file() {
    echo "Setting up positions file..."
    
    # Backup existing positions file if it exists
    if [[ -f "${DATA_DIR}/positions.txt" ]]; then
        cp "${DATA_DIR}/positions.txt" "${TEMP_DIR}/positions.txt.bak" || print_warning "Failed to backup existing positions file"
    fi
    
    # Create sample positions file if it doesn't exist
    if [[ ! -f "${DATA_DIR}/positions.txt" ]]; then
        cat > "${DATA_DIR}/positions.txt" << EOL || print_error "Failed to create positions file"
# CheckSSR Positions File
# Add one ticker symbol per line (lines starting with # are ignored).
# The same list is checked against every market (NASDAQ and NYSE), so just list
# everything you own. Class shares and preferreds can be written with a dot: BRK.B
#
# The examples below are commented out on purpose. Remove the leading # to activate one,
# and delete the ones that are not yours: CheckSSR reports on every ticker listed here.
#
# Technology
# AAPL
# MSFT
#
# Financial
# JPM
# BRK.B
EOL
        chmod 644 "${DATA_DIR}/positions.txt" || print_warning "Failed to set permissions on positions file"
        ACTIONS_PERFORMED+=("created_positions")
        print_success "Created sample positions file at ${DATA_DIR}/positions.txt"
        print_warning "Please edit ${DATA_DIR}/positions.txt to add your stock positions!"
    else
        print_info "Positions file already exists at ${DATA_DIR}/positions.txt"
    fi
}

# Ask user if they want to set up scheduled execution
setup_scheduled_execution() {
    echo
    echo "Would you like to set up scheduled execution of CheckSSR?"
    echo "This will create a launchd job to run CheckSSR automatically on weekdays at 8:40am."
    
    # Skip if launchctl is not available
    if ! command -v launchctl &> /dev/null; then
        print_warning "launchctl not found. Scheduled execution is not available on this system."
        return
    fi
    
    read -p "Set up scheduled execution? (y/n) " -n 1 -r
    echo
    
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        echo "Setting up scheduled execution..."
        
        # Backup existing launchd file if it exists
        if [[ -f "${LAUNCHD_DIR}/${LAUNCHD_FILE}" ]]; then
            cp "${LAUNCHD_DIR}/${LAUNCHD_FILE}" "${TEMP_DIR}/checkssr.plist.bak" || print_warning "Failed to backup existing launchd file"
            # Try to unload existing service first
            launchctl unload "${LAUNCHD_DIR}/${LAUNCHD_FILE}" 2>/dev/null || true
        fi
        
        # Create LaunchAgents directory if it doesn't exist
        if [[ ! -d "${LAUNCHD_DIR}" ]]; then
            mkdir -p "${LAUNCHD_DIR}" || print_error "Failed to create LaunchAgents directory"
            chmod 755 "${LAUNCHD_DIR}" || print_warning "Failed to set permissions on LaunchAgents directory"
        fi
        
        # Create launchd plist
        cat > "${LAUNCHD_DIR}/${LAUNCHD_FILE}" << EOL || print_error "Failed to create launchd plist file"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.user.checkssr</string>
    <key>ProgramArguments</key>
    <array>
        <string>${INSTALL_BIN_DIR}/checkssr</string>
    </array>
    <key>StartCalendarInterval</key>
    <array>
        <dict>
            <key>Hour</key>
            <integer>8</integer>
            <key>Minute</key>
            <integer>40</integer>
            <key>Weekday</key>
            <integer>1</integer>
        </dict>
        <dict>
            <key>Hour</key>
            <integer>8</integer>
            <key>Minute</key>
            <integer>40</integer>
            <key>Weekday</key>
            <integer>2</integer>
        </dict>
        <dict>
            <key>Hour</key>
            <integer>8</integer>
            <key>Minute</key>
            <integer>40</integer>
            <key>Weekday</key>
            <integer>3</integer>
        </dict>
        <dict>
            <key>Hour</key>
            <integer>8</integer>
            <key>Minute</key>
            <integer>40</integer>
            <key>Weekday</key>
            <integer>4</integer>
        </dict>
        <dict>
            <key>Hour</key>
            <integer>8</integer>
            <key>Minute</key>
            <integer>40</integer>
            <key>Weekday</key>
            <integer>5</integer>
        </dict>
    </array>
    <key>RunAtLoad</key>
    <false/>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/checkssr_error.log</string>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/checkssr_output.log</string>
</dict>
</plist>
EOL
        
        # Set proper permissions on plist file
        chmod 644 "${LAUNCHD_DIR}/${LAUNCHD_FILE}" || print_warning "Failed to set permissions on launchd plist file"
        
        # Load the launchd job
        if ! launchctl load "${LAUNCHD_DIR}/${LAUNCHD_FILE}"; then
            print_warning "Failed to load launchd job. You may need to load it manually with:"
            print_info "launchctl load ${LAUNCHD_DIR}/${LAUNCHD_FILE}"
        else
            ACTIONS_PERFORMED+=("created_launchd")
            print_success "Scheduled CheckSSR to run at 8:40am on weekdays"
            print_info "The schedule was added through launchd at ${LAUNCHD_DIR}/${LAUNCHD_FILE}"
        fi
    else
        print_info "Skipping scheduled execution setup"
    fi
}

# Print usage instructions
print_usage_instructions() {
    echo
    echo -e "${GREEN}===============================================${NC}"
    echo -e "${GREEN}  Installation Complete!${NC}"
    echo -e "${GREEN}===============================================${NC}"
    echo
    echo "CheckSSR has been installed successfully. Here's how to use it:"
    echo
    echo "1. Edit your configuration:"
    echo "   nano ${CONFIG_DIR}/config.sh"
    echo
    echo "2. Edit your stock positions:"
    echo "   nano ${DATA_DIR}/positions.txt"
    echo
    echo "3. Try it without sending any email (prints the report to the screen):"
    echo "   ${INSTALL_BIN_DIR}/checkssr --print"
    echo "   Then run it for real (emails the report): ${INSTALL_BIN_DIR}/checkssr"
    echo "   Use --market nasdaq or --market nyse to check just one list."
    echo
    echo "4. Check the logs if needed:"
    echo "   cat ${LOG_DIR}/checkssr_\$(date +%Y%m%d).log"
    echo
    
    if [[ -f "${LAUNCHD_DIR}/${LAUNCHD_FILE}" ]]; then
        echo "5. CheckSSR is scheduled to run automatically at 8:40am on weekdays"
        echo "   To disable scheduled execution:"
        echo "   launchctl unload ${LAUNCHD_DIR}/${LAUNCHD_FILE}"
        echo "   To enable it again:"
        echo "   launchctl load ${LAUNCHD_DIR}/${LAUNCHD_FILE}"
    else
        echo "5. To set up scheduled execution later, run this installer again"
        echo "   or manually create a launchd plist in ${LAUNCHD_DIR}"
    fi
    
    echo
    echo "Enjoy monitoring the NASDAQ and NYSE SSR lists!"
    echo
}

# Main execution
main() {
    print_banner
    check_requirements
    create_directories
    install_script
    create_config
    create_positions_file
    setup_scheduled_execution
    print_usage_instructions
}

# Run the main function
main

