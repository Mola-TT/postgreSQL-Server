#!/bin/bash
# general_config.sh - General system configuration functions
# Part of Milestone 1

# Update system packages silently
update_system() {
    if [ "$SYSTEM_UPDATE" = true ]; then
        log_info "Updating system packages silently. This may take a while..."
        
        # Clear logs
        clear_logs
        
        # Update package lists silently with maximum output suppression
        if ! DEBIAN_FRONTEND=noninteractive apt-get update -y -qq > /dev/null 2>&1; then
            log_error "Failed to update package lists"
            return 1
        fi
        
        # Upgrade packages silently with maximum output suppression
        if ! DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq > /dev/null 2>&1; then
            log_error "Failed to upgrade packages"
            return 1
        fi
        
        log_info "System packages updated successfully"
    else
        log_info "System update skipped as per configuration"
    fi
}

# Set timezone
set_timezone() {    
    # Use SERVER_TIMEZONE if defined, otherwise fallback to UTC
    local timezone="${SERVER_TIMEZONE:-UTC}"
    
    execute_silently "timedatectl set-timezone \"$timezone\"" \
        "Timezone set to $timezone" \
        "Failed to set timezone to $timezone" || return 1
    
    # Get current timezone
    current_tz=$(timedatectl | grep "Time zone" | awk '{print $3}')
    export TIMEZONE="$timezone"  # Set TIMEZONE for backward compatibility
}

# Export functions
export -f update_system
export -f set_timezone 