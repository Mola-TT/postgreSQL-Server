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

# Source utilities
source "$SCRIPT_DIR/tools/utilities.sh"

# Display init banner
display_banner() {
    echo "-----------------------------------------------"
    echo "PostgreSQL Server Initialization"
    echo "-----------------------------------------------"
    log_info "Starting initialization process"
}

# Update system packages silently
update_system() {
    if [ "$SYSTEM_UPDATE" = true ]; then
        log_info "Updating system packages silently. This may take a while..."
        
        # Clear logs
        clear_logs
        
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
    
    # Load user environment variables if they exist (overrides defaults)
    if [ -f "$SCRIPT_DIR/user.env" ]; then
        log_info "Loading user environment variables from user.env"
        source "$SCRIPT_DIR/user.env"
    else
        log_info "No user.env file found, using default settings only"
        log_info "You can create user.env by copying user.env.template and modifying it"
    fi

    # Check if running as root
    if [ "$(id -u)" -ne 0 ]; then
        log_error "This script must be run as root"
        exit 1
    fi
    
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