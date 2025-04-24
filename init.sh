#!/bin/bash
# init.sh - PostgreSQL server initialization script
# Part of Milestone 1
# This script updates the Ubuntu server silently and sets up initial environment

# Exit immediately if a command exits with a non-zero status
set -e

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source logger
source "$SCRIPT_DIR/tools/logger.sh"

# Load default environment variables
source "$SCRIPT_DIR/default.env"

# Create system log file if it doesn't exist
SYSTEM_LOG_FILE="${SYSTEM_LOG_FILE:-/var/log/pg_system_init.log}"
touch "$SYSTEM_LOG_FILE" 2>/dev/null || true

# Function to execute system commands silently
# Only debug logs and errors are displayed, all other output is redirected to log file
execute_silently() {
    local cmd="$1"
    local msg="$2"
    local err_msg="$3"
    
    log_debug "Executing: $cmd"
    
    # Execute command, redirect stdout to log file, redirect stderr to variable
    if ! output=$(eval "$cmd" >> "$SYSTEM_LOG_FILE" 2>&1); then
        log_error "$err_msg"
        log_debug "Command failed with output: $output"
        return 1
    fi
    
    if [ -n "$msg" ]; then
        log_info "$msg"
    fi
    
    return 0
}

# Load user environment variables if they exist (overrides defaults)
if [ -f "$SCRIPT_DIR/user.env" ]; then
    log_info "Loading user environment variables from user.env"
    source "$SCRIPT_DIR/user.env"
else
    log_warn "No user.env file found, using default settings only"
    log_info "You can create user.env by copying user.env.template and modifying it"
fi

# Display init banner
display_banner() {
    echo "-----------------------------------------------"
    echo "PostgreSQL Server Initialization"
    echo "Version: 1.0.0 (Milestone 1)"
    echo "-----------------------------------------------"
    log_info "Starting initialization process"
}

# Update system packages silently
update_system() {
    if [ "$SYSTEM_UPDATE" = true ]; then
        log_info "Updating system packages silently. This may take a while..."
        
        # Clear previous logs
        > "$SYSTEM_LOG_FILE"
        
        # Update package lists silently
        execute_silently "apt-get update -qq" \
            "" \
            "Failed to update package lists" || return 1
        
        # Upgrade packages silently with no prompts
        execute_silently "DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq" \
            "System packages updated successfully" \
            "Failed to upgrade packages" || return 1
    else
        log_info "System update skipped as per configuration"
    fi
}

# Set timezone
set_timezone() {
    log_info "Setting timezone to $TIMEZONE"
    
    execute_silently "timedatectl set-timezone \"$TIMEZONE\"" \
        "" \
        "Failed to set timezone to $TIMEZONE" || return 1
    
    # Get current timezone
    current_tz=$(timedatectl | grep "Time zone" | awk '{print $3}')
    log_info "Timezone set to $current_tz"
}

# Main function
main() {
    display_banner
    
    # Check if running as root
    if [ "$(id -u)" -ne 0 ]; then
        log_error "This script must be run as root"
        exit 1
    fi
    
    log_info "Initializing with PostgreSQL version $PG_VERSION"
    log_debug "System log file: $SYSTEM_LOG_FILE"
    
    # Update system packages
    update_system
    
    # Set timezone
    set_timezone
    
    log_info "Initialization complete"
    
    if [ "$LOG_LEVEL" -eq "$LOG_LEVEL_DEBUG" ]; then
        log_debug "For detailed system logs, check: $SYSTEM_LOG_FILE"
    fi
}

# Execute main function
main "$@" 