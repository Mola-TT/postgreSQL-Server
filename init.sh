#!/bin/bash
# init.sh - PostgreSQL server initialization script
# Part of Milestone 1
# This script updates the Ubuntu server silently and sets up initial environment

# Exit immediately if a command exits with a non-zero status
set -e

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source logger
source "$SCRIPT_DIR/logger.sh"

# Load default environment variables
source "$SCRIPT_DIR/default.env"

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
        
        # Update package lists silently
        apt-get update -qq || {
            log_error "Failed to update package lists"
            return 1
        }
        
        # Upgrade packages silently with no prompts
        DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq || {
            log_error "Failed to upgrade packages"
            return 1
        }
        
        log_info "System packages updated successfully"
    else
        log_info "System update skipped as per configuration"
    fi
}

# Set timezone
set_timezone() {
    log_info "Setting timezone to $TIMEZONE"
    timedatectl set-timezone "$TIMEZONE" || {
        log_error "Failed to set timezone to $TIMEZONE"
        return 1
    }
    log_info "Timezone set to $(timedatectl | grep "Time zone" | awk '{print $3}')"
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
    
    # Update system packages
    update_system
    
    # Set timezone
    set_timezone
    
    log_info "Initialization complete"
}

# Execute main function
main "$@" 