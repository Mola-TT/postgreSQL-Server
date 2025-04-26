#!/bin/bash
# general_config.sh - General system configuration functions
# Part of Milestone 1

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
    execute_silently "timedatectl set-timezone \"$TIMEZONE\"" \
        "" \
        "Failed to set timezone to $TIMEZONE" || return 1
    
    # Get current timezone
    current_tz=$(timedatectl | grep "Time zone" | awk '{print $3}')
}

# Export functions
export -f update_system
export -f set_timezone 