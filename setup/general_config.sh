#!/bin/bash
# general_config.sh - General system configuration functions
# Part of Milestone 1

# Script directory - using unique variable name to avoid conflicts
GENERAL_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Update system packages silently
update_system() {
    if [ "$SYSTEM_UPDATE" = true ]; then
        log_info "Updating system packages silently. This may take a while..."
        
        # Clear logs
        clear_logs
        
        # Update package lists silently with retry logic
        if ! apt_update_with_retry 5 45; then
            log_error "Failed to update package lists after multiple retries"
            return 1
        fi
        
        # Upgrade packages silently with retry logic for apt lock issues
        if ! DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq > /dev/null 2>&1; then
            local retry_count=0
            local max_retries=5
            
            while [ $retry_count -lt $max_retries ]; do
                log_warn "Failed to upgrade packages, retrying in 45 seconds (retry $((retry_count+1))/$max_retries)..."
                sleep 45
                retry_count=$((retry_count + 1))
                
                if DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq > /dev/null 2>&1; then
                    log_info "System packages upgraded successfully on retry $retry_count"
                    break
                fi
                
                if [ $retry_count -ge $max_retries ]; then
                    log_error "Failed to upgrade packages after $max_retries retries"
                    return 1
                fi
            done
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
export -f apt_install_with_retry
export -f apt_update_with_retry 