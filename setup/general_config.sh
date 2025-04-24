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
    # Validate timezone format before setting it
    if [[ "$TIMEZONE" =~ ^[A-Za-z]+/[A-Za-z_]+$ ]]; then
        # Valid timezone format like "Region/City"
        log_info "Setting timezone to $TIMEZONE"
        
        execute_silently "timedatectl set-timezone \"$TIMEZONE\"" \
            "" \
            "Failed to set timezone to $TIMEZONE" || return 1
    elif [[ "$TIMEZONE" == "UTC" ]]; then
        # UTC is a valid timezone
        log_info "Setting timezone to UTC"
        
        execute_silently "timedatectl set-timezone UTC" \
            "" \
            "Failed to set timezone to UTC" || return 1
    else
        # Handle three-letter time zone codes by mapping them to proper timezone
        case "$TIMEZONE" in
            "HKT")
                actual_timezone="Asia/Hong_Kong"
                ;;
            "EST")
                actual_timezone="America/New_York"
                ;;
            "CST")
                actual_timezone="America/Chicago"
                ;;
            "MST")
                actual_timezone="America/Denver"
                ;;
            "PST")
                actual_timezone="America/Los_Angeles"
                ;;
            "JST")
                actual_timezone="Asia/Tokyo"
                ;;
            "GMT")
                actual_timezone="Europe/London"
                ;;
            *)
                log_error "Invalid timezone format: $TIMEZONE"
                log_info "Using default timezone: UTC"
                actual_timezone="UTC"
                ;;
        esac

        log_info "Mapping $TIMEZONE to $actual_timezone"
        
        execute_silently "timedatectl set-timezone \"$actual_timezone\"" \
            "" \
            "Failed to set timezone to $actual_timezone" || return 1
    fi
    
    # Get current timezone
    current_tz=$(timedatectl | grep "Time zone" | awk '{print $3}')
    log_info "Timezone set to $current_tz"
}

# Export functions
export -f update_system
export -f set_timezone 