#!/bin/bash
# init.sh - PostgreSQL server initialization script
# Part of Milestone 1 & 2
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

# Source general configuration
source "$SCRIPT_DIR/setup/general_config.sh"

# Source PostgreSQL configuration
source "$SCRIPT_DIR/setup/postgresql_config.sh"

# Display init banner
display_banner() {
    echo "-----------------------------------------------"
    echo "PostgreSQL Server Initialization"
    echo "-----------------------------------------------"
}

# Main function
main() {
    display_banner

    # Set timezone first
    set_timezone
    log_info "Set system timezone to $TIMEZONE"

    log_info "Starting initialization process"   
    
    # Load user environment variables if they exist (overrides defaults)
    if [ -f "$SCRIPT_DIR/user.env" ]; then
        log_info "Loading user environment variables from user.env"
        source "$SCRIPT_DIR/user.env"
    else
        log_info "No user.env file found. Use default settings"
        log_info "You can create user.env by copying user.env.template and modifying it"
    fi

    # Check if running as root
    if [ "$(id -u)" -ne 0 ]; then
        log_error "This script must be run as root"
        exit 1
    fi
    
    log_debug "Log file: $LOG_FILE"
    
    # Update system packages
    update_system
    
    # Setup PostgreSQL and pgbouncer
    setup_postgresql
    
    log_info "Initialization complete"
    
    if [ "$LOG_LEVEL" -eq "$LOG_LEVEL_DEBUG" ]; then
        log_debug "For detailed logs, check: $LOG_FILE"
    fi
}

# Execute main function
main "$@" 