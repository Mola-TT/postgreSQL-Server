#!/bin/bash
# general_config.sh - General system configuration functions
# Part of Milestone 1

# Script directory - using unique variable name to avoid conflicts
GENERAL_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Update system packages with enhanced timeout and progress handling
update_system() {
    if [ "$SYSTEM_UPDATE" = true ]; then
        log_info "Updating system packages. This may take a while..."
        
        # Clear logs
        clear_logs
        
        # Clean any existing locks first
        log_info "Preparing system for updates..."
        clean_apt_locks
        
        # Show current system status
        show_system_update_status
        
        # Update package lists with enhanced handling
        log_info "Updating package index..."
        if ! update_package_lists_with_progress; then
            log_error "Failed to update package lists after multiple attempts"
            return 1
        fi
        
        # Upgrade packages with progress monitoring
        log_info "Upgrading system packages..."
        if ! upgrade_packages_with_progress; then
            log_error "Failed to upgrade packages after multiple attempts"
            return 1
        fi
        
        log_info "System packages updated successfully"
    else
        log_info "System update skipped as per configuration"
    fi
}

# Update package lists with progress monitoring and timeout
update_package_lists_with_progress() {
    local max_attempts=${SYSTEM_UPDATE_MAX_ATTEMPTS:-3}
    local timeout_duration=${SYSTEM_UPDATE_TIMEOUT:-300}  # 5 minutes default
    
    for attempt in $(seq 1 $max_attempts); do
        log_info "Updating package lists (attempt $attempt of $max_attempts)..."
        
        # Clean locks before each attempt
        if [ $attempt -gt 1 ]; then
            log_info "Cleaning locks and stuck processes before retry..."
            clean_apt_locks
        fi
        
        # Create a background process to monitor progress
        local temp_log="/tmp/apt_update_progress_$$.log"
        local pid_file="/tmp/apt_update_pid_$$.txt"
        
        # Start apt update in background with timeout
        (
            echo $$ > "$pid_file"
            DEBIAN_FRONTEND=noninteractive apt-get update -qq > "$temp_log" 2>&1
            echo $? > "${temp_log}.exit"
        ) &
        local update_pid=$!
        
        # Monitor progress with timeout
        local elapsed=0
        local check_interval=10
        local last_progress_time=0
        
        while [ $elapsed -lt $timeout_duration ]; do
            if ! kill -0 $update_pid 2>/dev/null; then
                # Process finished
                wait $update_pid
                local exit_code=$(cat "${temp_log}.exit" 2>/dev/null || echo "1")
                
                if [ "$exit_code" = "0" ]; then
                    log_info "Package lists updated successfully"
                    rm -f "$temp_log" "${temp_log}.exit" "$pid_file"
                    return 0
                else
                    log_warn "Package list update failed (exit code: $exit_code)"
                    if [ -s "$temp_log" ]; then
                        log_warn "Last few lines of error:"
                        tail -5 "$temp_log" | while read line; do
                            log_warn "  $line"
                        done
                    fi
                fi
                break
            fi
            
            # Show progress indicator every 30 seconds
            if [ $((elapsed % 30)) -eq 0 ] && [ $elapsed -gt 0 ]; then
                log_info "Still updating package lists... ($elapsed seconds elapsed)"
            fi
            
            sleep $check_interval
            elapsed=$((elapsed + check_interval))
        done
        
        # If we reach here, either timeout or failure occurred
        if kill -0 $update_pid 2>/dev/null; then
            log_warn "Package list update timed out after $timeout_duration seconds, terminating..."
            
            # Try graceful termination first
            kill $update_pid 2>/dev/null || true
            sleep 5
            
            # Force kill if still running
            if kill -0 $update_pid 2>/dev/null; then
                kill -9 $update_pid 2>/dev/null || true
            fi
            
            # Clean up any stuck processes
            if [ -f "$pid_file" ]; then
                local inner_pid=$(cat "$pid_file" 2>/dev/null)
                if [ -n "$inner_pid" ]; then
                    kill -9 $inner_pid 2>/dev/null || true
                fi
            fi
        fi
        
        # Clean up temp files
        rm -f "$temp_log" "${temp_log}.exit" "$pid_file"
        
        if [ $attempt -lt $max_attempts ]; then
            log_info "Waiting 30 seconds before next attempt..."
            sleep 30
        fi
    done
    
    log_error "Failed to update package lists after $max_attempts attempts"
    return 1
}

# Upgrade packages with progress monitoring and timeout
upgrade_packages_with_progress() {
    local max_attempts=${SYSTEM_UPDATE_MAX_ATTEMPTS:-3}
    local timeout_duration=${SYSTEM_UPGRADE_TIMEOUT:-1800}  # 30 minutes default
    
    for attempt in $(seq 1 $max_attempts); do
        log_info "Upgrading packages (attempt $attempt of $max_attempts)..."
        
        # Clean locks before each attempt
        if [ $attempt -gt 1 ]; then
            log_info "Cleaning locks and stuck processes before retry..."
            clean_apt_locks
        fi
        
        # Create a background process to monitor progress
        local temp_log="/tmp/apt_upgrade_progress_$$.log"
        local pid_file="/tmp/apt_upgrade_pid_$$.txt"
        
        # Start apt upgrade in background with timeout
        (
            echo $$ > "$pid_file"
            DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq > "$temp_log" 2>&1
            echo $? > "${temp_log}.exit"
        ) &
        local upgrade_pid=$!
        
        # Monitor progress with timeout
        local elapsed=0
        local check_interval=30
        
        while [ $elapsed -lt $timeout_duration ]; do
            if ! kill -0 $upgrade_pid 2>/dev/null; then
                # Process finished
                wait $upgrade_pid
                local exit_code=$(cat "${temp_log}.exit" 2>/dev/null || echo "1")
                
                if [ "$exit_code" = "0" ]; then
                    log_info "Packages upgraded successfully"
                    rm -f "$temp_log" "${temp_log}.exit" "$pid_file"
                    return 0
                else
                    log_warn "Package upgrade failed (exit code: $exit_code)"
                    if [ -s "$temp_log" ]; then
                        log_warn "Last few lines of error:"
                        tail -5 "$temp_log" | while read line; do
                            log_warn "  $line"
                        done
                    fi
                fi
                break
            fi
            
            # Show progress indicator every 60 seconds
            if [ $((elapsed % 60)) -eq 0 ] && [ $elapsed -gt 0 ]; then
                log_info "Still upgrading packages... ($elapsed seconds elapsed)"
            fi
            
            sleep $check_interval
            elapsed=$((elapsed + check_interval))
        done
        
        # If we reach here, either timeout or failure occurred
        if kill -0 $upgrade_pid 2>/dev/null; then
            log_warn "Package upgrade timed out after $timeout_duration seconds, terminating..."
            
            # Try graceful termination first
            kill $upgrade_pid 2>/dev/null || true
            sleep 5
            
            # Force kill if still running
            if kill -0 $upgrade_pid 2>/dev/null; then
                kill -9 $upgrade_pid 2>/dev/null || true
            fi
            
            # Clean up any stuck processes
            if [ -f "$pid_file" ]; then
                local inner_pid=$(cat "$pid_file" 2>/dev/null)
                if [ -n "$inner_pid" ]; then
                    kill -9 $inner_pid 2>/dev/null || true
                fi
            fi
        fi
        
        # Clean up temp files
        rm -f "$temp_log" "${temp_log}.exit" "$pid_file"
        
        if [ $attempt -lt $max_attempts ]; then
            log_info "Waiting 60 seconds before next attempt..."
            sleep 60
        fi
    done
    
    log_error "Failed to upgrade packages after $max_attempts attempts"
    return 1
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
export -f apt_update_with_retry\n\n# Show system update status and information\nshow_system_update_status() {\n    log_info \"System Update Information:\"\n    log_info \"  - Update timeout: ${SYSTEM_UPDATE_TIMEOUT:-300} seconds\"\n    log_info \"  - Upgrade timeout: ${SYSTEM_UPGRADE_TIMEOUT:-1800} seconds\"\n    log_info \"  - Max attempts: ${SYSTEM_UPDATE_MAX_ATTEMPTS:-3}\"\n    log_info \"  - Progress updates every 30-60 seconds\"\n    \n    # Show current system info\n    local os_info=$(lsb_release -d 2>/dev/null | cut -f2 || echo \"Unknown\")\n    local uptime_info=$(uptime | awk '{print $3,$4}' | sed 's/,$//')\n    \n    log_info \"  - OS: $os_info\"\n    log_info \"  - Uptime: $uptime_info\"\n    \n    # Check available disk space\n    local disk_space=$(df -h / | awk 'NR==2 {print $4}' 2>/dev/null || echo \"Unknown\")\n    log_info \"  - Available disk space: $disk_space\"\n    \n    # Check if running in screen/tmux for better experience\n    if [ -n \"$STY\" ] || [ -n \"$TMUX\" ]; then\n        log_info \"  - Running in screen/tmux: YES (good for long operations)\"\n    else\n        log_info \"  - Running in screen/tmux: NO (consider using screen/tmux for stability)\"\n    fi\n    \n    log_info \"Starting system update process...\"\n}\n\nexport -f update_package_lists_with_progress\nexport -f upgrade_packages_with_progress\nexport -f show_system_update_status 