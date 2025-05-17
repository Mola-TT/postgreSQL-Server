#!/bin/bash
# pg_user_monitor.sh - Monitors PostgreSQL user changes and updates pgbouncer userlist
# Part of Milestone 8

# Script directory
PG_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source logger
source "$PG_SCRIPT_DIR/../lib/logger.sh"

# Source utilities
source "$PG_SCRIPT_DIR/../lib/utilities.sh"

# Source PostgreSQL extraction utilities
source "$PG_SCRIPT_DIR/../lib/pg_extract_hash.sh"

# Load default environment variables
source "$PG_SCRIPT_DIR/../conf/default.env"

# Override with user environment if available
if [ -f "$PG_SCRIPT_DIR/../conf/user.env" ]; then
    source "$PG_SCRIPT_DIR/../conf/user.env"
fi

# Configuration
PGB_USERLIST_PATH="${PGB_USERLIST_PATH:-/etc/pgbouncer/userlist.txt}"
PG_USER_MONITOR_INTERVAL="${PG_USER_MONITOR_INTERVAL:-30}"  # Check interval in seconds
PG_USER_MONITOR_LOG="${PG_USER_MONITOR_LOG:-/var/log/pg_user_monitor.log}"
PG_USER_MONITOR_ENABLED="${PG_USER_MONITOR_ENABLED:-true}"
PG_USER_MONITOR_SERVICE_NAME="${PG_USER_MONITOR_SERVICE_NAME:-pg-user-monitor}"

# Function to generate pgbouncer userlist from PostgreSQL
generate_pgbouncer_userlist() {
    log_info "Generating pgbouncer userlist from PostgreSQL user database"
    
    # Create temp userlist file
    local temp_userlist=$(mktemp)
    local hash_methods_tried=0
    local postgres_hash_extracted=false
    
    # Extremely important: Always add the postgres user first
    log_info "Extracting password hash for postgres user (critical for pgbouncer operation)"
    
    # Method 1: Using extract_hash function (most reliable method)
    if extract_hash "postgres" "$temp_userlist"; then
        # Verify the extracted hash is valid
        if grep -q "\"postgres\"" "$temp_userlist" && [ -s "$temp_userlist" ]; then
            postgres_hash_extracted=true
            log_info "Successfully extracted postgres user hash via extract_hash function"
            hash_methods_tried=$((hash_methods_tried+1))
        else
            log_warn "extract_hash function succeeded but produced invalid output"
            # Clear the file for next attempt
            > "$temp_userlist"
        fi
    else
        log_warn "Failed to extract hash for postgres user using extract_hash function"
        
        # Method 2: Direct query with proper quoting
        log_info "Trying direct SQL query method for postgres user"
        hash_methods_tried=$((hash_methods_tried+1))
        if su - postgres -c "psql -t -c \"SELECT '\\\"postgres\\\" \\\"' || rolpassword || '\\\"' FROM pg_authid WHERE rolname='postgres';\"" 2>/dev/null | grep -v "^$" > "$temp_userlist"; then
            # Verify the content is valid
            if grep -q "\"postgres\"" "$temp_userlist" && [ -s "$temp_userlist" ]; then
                postgres_hash_extracted=true
                log_info "Successfully extracted postgres user hash via direct SQL query"
            else
                log_warn "Direct SQL query produced invalid output"
                # Clear the file for next attempt
                > "$temp_userlist"
            fi
        else
            log_warn "Direct SQL query method failed"
            # Clear the file for next attempt
            > "$temp_userlist"
            
            # Method 3: Most direct approach with minimal quoting issues
            log_info "Trying simplified approach for postgres user"
            hash_methods_tried=$((hash_methods_tried+1))
            if su - postgres -c "psql -t -c \"SELECT rolpassword FROM pg_authid WHERE rolname='postgres';\"" 2>/dev/null | grep -v "^$" > "/tmp/pg_hash_$$.tmp"; then
                # Process the hash file
                if [ -s "/tmp/pg_hash_$$.tmp" ]; then
                    # Format the hash correctly for pgbouncer
                    local raw_hash=$(cat "/tmp/pg_hash_$$.tmp" | tr -d ' \n\r\t')
                    if [ -n "$raw_hash" ]; then
                        echo "\"postgres\" \"$raw_hash\"" > "$temp_userlist"
                        # Verify the entry is properly formatted
                        if grep -q "\"postgres\"" "$temp_userlist" && [ -s "$temp_userlist" ]; then
                            postgres_hash_extracted=true
                            log_info "Successfully extracted postgres user hash via simplified approach"
                        else
                            log_warn "Simplified query produced invalid output"
                            # Clear the file for next attempt
                            > "$temp_userlist"
                        fi
                    fi
                fi
                # Clean up
                rm -f "/tmp/pg_hash_$$.tmp" 2>/dev/null
            fi
        fi
    fi
    
    # Method 4: Reset password and retry
    if [ "$postgres_hash_extracted" = false ] && [ -n "$PG_SUPERUSER_PASSWORD" ]; then
        hash_methods_tried=$((hash_methods_tried+1))
        log_warn "Standard extraction methods failed, attempting password reset to create a known hash"
        
        # Reset the password and force scram-sha-256 encryption
        su - postgres -c "psql -c \"ALTER SYSTEM SET password_encryption = 'scram-sha-256';\"" > /dev/null 2>&1
        su - postgres -c "psql -c \"SELECT pg_reload_conf();\"" > /dev/null 2>&1
        su - postgres -c "psql -c \"ALTER USER postgres PASSWORD '$PG_SUPERUSER_PASSWORD';\"" > /dev/null 2>&1
        log_info "Reset postgres password with scram-sha-256 encryption"
        
        # Try again with direct method
        if su - postgres -c "psql -t -c \"SELECT rolpassword FROM pg_authid WHERE rolname='postgres';\"" 2>/dev/null | grep -v "^$" > "/tmp/pg_hash_$$.tmp"; then
            # Process the hash file
            if [ -s "/tmp/pg_hash_$$.tmp" ]; then
                # Format the hash correctly for pgbouncer
                local raw_hash=$(cat "/tmp/pg_hash_$$.tmp" | tr -d ' \n\r\t')
                if [ -n "$raw_hash" ]; then
                    echo "\"postgres\" \"$raw_hash\"" > "$temp_userlist"
                    # Verify the entry is properly formatted
                    if grep -q "\"postgres\"" "$temp_userlist" && [ -s "$temp_userlist" ]; then
                        postgres_hash_extracted=true
                        log_info "Successfully extracted postgres user hash via password reset method"
                    else
                        log_warn "Password reset method produced invalid output"
                        # Clear the file for next attempt
                        > "$temp_userlist"
                    fi
                fi
            fi
            # Clean up
            rm -f "/tmp/pg_hash_$$.tmp" 2>/dev/null
        else
            log_warn "Failed to extract hash after password reset"
        fi
    fi
    
    # Method 5: Emergency MD5 hash fallback
    if [ "$postgres_hash_extracted" = false ] && [ -n "$PG_SUPERUSER_PASSWORD" ]; then
        hash_methods_tried=$((hash_methods_tried+1))
        log_warn "EMERGENCY FALLBACK: Creating MD5 hash for postgres user"
        # For testing or emergency recovery, use MD5 hash
        local md5pass=$(echo -n "md5$(echo -n "${PG_SUPERUSER_PASSWORD}postgres" | md5sum | cut -d' ' -f1)")
        echo "\"postgres\" \"$md5pass\"" > "$temp_userlist"
        log_warn "Created emergency MD5 authentication entry for postgres (may not work with scram-sha-256)"
        # Verify the emergency hash
        if grep -q "\"postgres\"" "$temp_userlist" && [ -s "$temp_userlist" ]; then
            postgres_hash_extracted=true
        else
            log_error "Emergency MD5 hash creation failed or produced invalid output"
            # Clear the file for next attempt
            > "$temp_userlist"
        fi
    fi
    
    # Final verification for postgres user
    if ! grep -q "\"postgres\"" "$temp_userlist" || ! [ -s "$temp_userlist" ]; then
        log_error "CRITICAL ERROR: Failed to add postgres user to userlist after $hash_methods_tried methods"
        log_error "pgbouncer will not function correctly without postgres user in userlist.txt"
        
        # Last resort emergency entry
        if [ -n "$PG_SUPERUSER_PASSWORD" ]; then
            # For last resort emergency, use simple MD5
            log_warn "LAST RESORT EMERGENCY: Creating simplified auth entry for postgres"
            local md5pass=$(echo -n "md5$(echo -n "${PG_SUPERUSER_PASSWORD}postgres" | md5sum | cut -d' ' -f1)")
            echo "\"postgres\" \"$md5pass\"" > "$temp_userlist"
            log_warn "Created last resort emergency authentication entry for postgres"
            
            # Verify one more time
            if grep -q "\"postgres\"" "$temp_userlist" && [ -s "$temp_userlist" ]; then
                postgres_hash_extracted=true
                log_warn "Last resort emergency method worked"
            else
                log_error "Last resort emergency method failed - cannot proceed"
                rm -f "$temp_userlist"
                return 1
            fi
        else
            log_error "Cannot create emergency entry because PG_SUPERUSER_PASSWORD is not set"
            rm -f "$temp_userlist"
            return 1
        fi
    else
        log_info "Successfully added postgres user to pgbouncer userlist"
    fi
    
    # Get a list of all non-system users from PostgreSQL
    local user_list
    user_list=$(su - postgres -c "psql -t -c \"SELECT usename FROM pg_catalog.pg_user WHERE usename NOT IN ('postgres') AND usesysid >= 16384;\"" 2>/dev/null | tr -d ' ')
    
    # Add each user to the userlist
    if [ -n "$user_list" ]; then
        for user in $user_list; do
            log_info "Adding user $user to pgbouncer userlist"
            
            # Check if user already exists in userlist - if so, skip
            if grep -q "\"$user\"" "$temp_userlist"; then
                log_info "User $user already exists in userlist, skipping"
                continue
            fi
            
            if ! extract_hash "$user" "$temp_userlist"; then
                log_warn "Failed to extract hash for user $user using extract_hash function"
                
                # Try direct query method
                log_info "Trying direct SQL query method for user $user"
                local user_hash_entry
                if user_hash_entry=$(su - postgres -c "psql -t -c \"SELECT '\\\"${user}\\\" \\\"' || rolpassword || '\\\"' FROM pg_authid WHERE rolname='${user}';\"" 2>/dev/null | grep -v "^$" | tr -d '\n'); then
                    if [ -n "$user_hash_entry" ]; then
                        echo "$user_hash_entry" >> "$temp_userlist"
                        log_info "Added user $user via direct SQL query"
                    fi
                fi
            else
                log_info "Added user $user via extract_hash function"
            fi
        done
    fi
    
    # Verify the userlist has been created correctly
    if [ ! -s "$temp_userlist" ]; then
        log_error "Failed to generate pgbouncer userlist"
        rm -f "$temp_userlist"
        return 1
    fi
    
    # Debug: output userlist content (without passwords)
    log_info "Generated userlist contains these users:"
    grep -o '"[^"]*"' "$temp_userlist" | grep -v "SCRAM-SHA-256\|md5" | sort | uniq | while read user; do
        log_debug "  $user"
    done
    
    # Compare with existing userlist
    local changed=false
    if [ -f "$PGB_USERLIST_PATH" ]; then
        if ! diff -q "$temp_userlist" "$PGB_USERLIST_PATH" &>/dev/null; then
            changed=true
        fi
    else
        changed=true
    fi
    
    # Update userlist if changed
    if [ "$changed" = true ]; then
        log_info "Userlist has changed, updating pgbouncer configuration"
        
        # Backup existing userlist if it exists
        if [ -f "$PGB_USERLIST_PATH" ]; then
            cp "$PGB_USERLIST_PATH" "${PGB_USERLIST_PATH}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null
        fi
        
        # Create directory if it doesn't exist
        mkdir -p "$(dirname "$PGB_USERLIST_PATH")" 2>/dev/null
        
        # Try multiple methods to copy the file - don't give up easily
        local copy_success=false
        
        # Method 1: Direct copy
        if cp "$temp_userlist" "$PGB_USERLIST_PATH" 2>/dev/null; then
            copy_success=true
            log_info "Updated userlist using direct copy"
        else
            log_warn "Direct copy failed, trying sudo copy"
            
            # Method 2: Sudo copy
            if sudo cp "$temp_userlist" "$PGB_USERLIST_PATH" 2>/dev/null; then
                copy_success=true
                log_info "Updated userlist using sudo copy"
            else
                log_warn "Sudo copy failed, trying cat with tee"
                
                # Method 3: Cat with tee
                if cat "$temp_userlist" | sudo tee "$PGB_USERLIST_PATH" > /dev/null 2>&1; then
                    copy_success=true
                    log_info "Updated userlist using cat | sudo tee"
                else
                    log_warn "Cat with tee failed, trying bash -c approach"
                    
                    # Method 4: Bash -c approach
                    if sudo bash -c "cat '$temp_userlist' > '$PGB_USERLIST_PATH'" 2>/dev/null; then
                        copy_success=true
                        log_info "Updated userlist using sudo bash -c approach"
                    fi
                fi
            fi
        fi
        
        # If all copy methods failed
        if [ "$copy_success" = false ]; then
            log_error "All methods to update userlist file failed"
            rm -f "$temp_userlist"
            return 1
        fi
        
        # ALWAYS set proper ownership and permissions - this is critical for pgbouncer
        sudo chown postgres:postgres "$PGB_USERLIST_PATH" 2>/dev/null || chown postgres:postgres "$PGB_USERLIST_PATH" 2>/dev/null
        sudo chmod 600 "$PGB_USERLIST_PATH" 2>/dev/null || chmod 600 "$PGB_USERLIST_PATH" 2>/dev/null
        
        # Double check permissions
        log_info "Verifying userlist file permissions"
        local permissions
        permissions=$(stat -c "%a" "$PGB_USERLIST_PATH" 2>/dev/null || stat -f "%p" "$PGB_USERLIST_PATH" 2>/dev/null)
        local owner
        owner=$(stat -c "%U:%G" "$PGB_USERLIST_PATH" 2>/dev/null || stat -f "%Su:%Sg" "$PGB_USERLIST_PATH" 2>/dev/null)
        log_info "Userlist permissions: $permissions, owner: $owner"
        
        # If permissions aren't strict enough, try again with sudo
        if [ "$permissions" != "600" ]; then
            log_warn "Permissions aren't set to 600, trying again with sudo"
            sudo chmod 600 "$PGB_USERLIST_PATH" 2>/dev/null
            permissions=$(stat -c "%a" "$PGB_USERLIST_PATH" 2>/dev/null || stat -f "%p" "$PGB_USERLIST_PATH" 2>/dev/null)
            log_info "Updated permissions: $permissions"
        fi
        
        # If owner isn't correct, try again with sudo
        if [ "$owner" != "postgres:postgres" ]; then
            log_warn "Owner isn't postgres:postgres, trying again with sudo"
            sudo chown postgres:postgres "$PGB_USERLIST_PATH" 2>/dev/null
            owner=$(stat -c "%U:%G" "$PGB_USERLIST_PATH" 2>/dev/null || stat -f "%Su:%Sg" "$PGB_USERLIST_PATH" 2>/dev/null)
            log_info "Updated owner: $owner"
        fi
        
        # Reload pgbouncer
        log_info "Reloading pgbouncer to apply new userlist"
        if systemctl is-active --quiet pgbouncer; then
            if ! systemctl reload pgbouncer &>/dev/null; then
                log_warn "Failed to reload pgbouncer, attempting restart"
                systemctl restart pgbouncer &>/dev/null
                sleep 5 # Give pgbouncer time to restart
                
                # Verify pgbouncer restarted
                if ! systemctl is-active --quiet pgbouncer; then
                    log_error "pgbouncer failed to restart, attempting one more start"
                    systemctl start pgbouncer &>/dev/null
                    sleep 3
                fi
            fi
        else
            log_warn "pgbouncer is not running, attempting to start"
            systemctl start pgbouncer &>/dev/null
            sleep 5 # Give pgbouncer time to start
            
            # Verify pgbouncer started
            if systemctl is-active --quiet pgbouncer; then
                log_info "Successfully started pgbouncer"
            else
                log_error "Failed to start pgbouncer"
            fi
        fi
        
        log_info "pgbouncer userlist updated successfully"
    else
        log_info "No changes detected in userlist, skipping update"
    fi
    
    # Clean up
    rm -f "$temp_userlist"
    return 0
}

# Function to install PostgreSQL triggers for user changes
install_pg_triggers() {
    log_info "Installing PostgreSQL triggers to monitor user changes"
    
    # Check if PostgreSQL is running
    if ! systemctl is-active --quiet postgresql; then
        log_error "PostgreSQL is not running, cannot install triggers"
        return 1
    fi
    
    # Create a SQL script with proper permissions
    # Create the script in a location where postgres user has access
    local sql_script="/tmp/pg_user_monitor_triggers.sql"
    
    # Clean up any existing file
    rm -f "$sql_script" 2>/dev/null
    
    # Create the script
    cat > "$sql_script" << 'EOF'
-- Create a table to track user operations
CREATE TABLE IF NOT EXISTS pg_user_monitor (
    operation_id SERIAL PRIMARY KEY,
    operation_type TEXT NOT NULL,
    username TEXT NOT NULL,
    operation_time TIMESTAMP WITH TIME ZONE DEFAULT NOW()
);

-- Create a function to notify when users are modified
CREATE OR REPLACE FUNCTION notify_user_change() RETURNS event_trigger AS $$
DECLARE
    obj record;
    command_tag text;
BEGIN
    -- Get the command tag
    command_tag := tg_tag;
    
    -- For CREATE/ALTER/DROP USER or ROLE commands
    IF command_tag IN ('CREATE ROLE', 'ALTER ROLE', 'DROP ROLE', 'CREATE USER', 'ALTER USER', 'DROP USER') THEN
        -- Extract the username from the command
        FOR obj IN SELECT object_identity FROM pg_event_trigger_ddl_commands()
        LOOP
            -- Insert into monitoring table
            INSERT INTO pg_user_monitor (operation_type, username)
            VALUES (command_tag, obj.object_identity);
        END LOOP;
    END IF;
END;
$$ LANGUAGE plpgsql;

-- Create or replace the event trigger
DROP EVENT TRIGGER IF EXISTS user_change_trigger;
CREATE EVENT TRIGGER user_change_trigger ON ddl_command_end
    WHEN TAG IN ('CREATE ROLE', 'ALTER ROLE', 'DROP ROLE', 'CREATE USER', 'ALTER USER', 'DROP USER')
    EXECUTE FUNCTION notify_user_change();

-- Create a function to handle password changes via SQL
CREATE OR REPLACE FUNCTION log_password_change() RETURNS TRIGGER AS $$
BEGIN
    IF TG_OP = 'UPDATE' AND OLD.passwd IS DISTINCT FROM NEW.passwd THEN
        INSERT INTO pg_user_monitor (operation_type, username)
        VALUES ('PASSWORD CHANGE', NEW.usename);
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Add trigger on pg_authid table for password changes
DROP TRIGGER IF EXISTS password_change_trigger ON pg_authid;
CREATE TRIGGER password_change_trigger
AFTER UPDATE ON pg_authid
FOR EACH ROW
EXECUTE FUNCTION log_password_change();

-- Grant permissions for the custom monitor table
GRANT SELECT ON pg_user_monitor TO postgres;
GRANT SELECT, INSERT ON pg_user_monitor_operation_id_seq TO postgres;
GRANT INSERT ON pg_user_monitor TO postgres;
EOF
    
    # Make sure we have the right permissions
    chmod 644 "$sql_script"
    chown postgres:postgres "$sql_script" 2>/dev/null
    
    # Make sure we have the right permissions - attempt to verify postgres user is superuser
    local is_superuser
    is_superuser=$(su - postgres -c "psql -t -c \"SELECT usesuper FROM pg_user WHERE usename = 'postgres';\"" 2>/dev/null | tr -d ' ')
    
    if [ "$is_superuser" != "t" ]; then
        log_warn "User 'postgres' might not have the necessary superuser privileges"
    fi
    
    # Execute the SQL script with error output
    log_info "Executing SQL script to create triggers and monitoring table..."
    local err_output
    err_output=$(su - postgres -c "psql -d postgres -f '$sql_script'" 2>&1)
    local sql_result=$?
    
    if [ $sql_result -ne 0 ]; then
        log_error "Failed to install PostgreSQL triggers: $err_output"
        rm -f "$sql_script"
        return 1
    fi
    
    # Verify the table and trigger created successfully
    local table_exists
    table_exists=$(su - postgres -c "psql -t -c \"SELECT EXISTS(SELECT 1 FROM information_schema.tables WHERE table_name='pg_user_monitor');\"" 2>/dev/null | tr -d ' ')
    
    if [ "$table_exists" != "t" ]; then
        log_error "Failed to create pg_user_monitor table"
        rm -f "$sql_script"
        return 1
    fi
    
    # Clean up
    rm -f "$sql_script"
    
    log_info "PostgreSQL triggers for user monitoring installed successfully"
    return 0
}

# Function to check for user changes and update pgbouncer userlist
check_user_changes() {
    log_info "Checking for user changes"
    
    # Check if PostgreSQL is running
    if ! systemctl is-active --quiet postgresql; then
        log_warn "PostgreSQL is not running, skipping check"
        return 1
    fi
    
    # Check for pending user change notifications
    local changes
    changes=$(su - postgres -c "psql -t -c \"SELECT COUNT(*) FROM pg_user_monitor WHERE operation_time > (NOW() - INTERVAL '5 minutes');\"" 2>/dev/null | tr -d ' ')
    
    if [ "$changes" -gt 0 ]; then
        log_info "Detected $changes recent user changes, updating pgbouncer userlist"
        
        # Update pgbouncer userlist
        generate_pgbouncer_userlist
        
        # Mark notifications as processed (purge older than 15 minutes)
        su - postgres -c "psql -c \"DELETE FROM pg_user_monitor WHERE operation_time < (NOW() - INTERVAL '15 minutes');\"" &>/dev/null
    else
        log_info "No recent user changes detected"
    fi
    
    return 0
}

# Function to create systemd service for continuous monitoring
create_systemd_service() {
    log_info "Creating systemd service for user monitoring"
    
    # Service file path
    local service_file="/etc/systemd/system/${PG_USER_MONITOR_SERVICE_NAME}.service"
    
    # Create service file
    cat > "$service_file" << EOF
[Unit]
Description=PostgreSQL User Change Monitor
After=postgresql.service pgbouncer.service
Requires=postgresql.service pgbouncer.service

[Service]
Type=simple
User=root
ExecStart=/bin/bash $PG_SCRIPT_DIR/pg_user_monitor.sh run
Restart=always
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF
    
    # Reload systemd manager
    systemctl daemon-reload
    
    # Enable and start the service
    if ! systemctl enable --now "${PG_USER_MONITOR_SERVICE_NAME}" &>/dev/null; then
        log_error "Failed to enable and start ${PG_USER_MONITOR_SERVICE_NAME} service"
        return 1
    fi
    
    log_info "${PG_USER_MONITOR_SERVICE_NAME} service created and started successfully"
    return 0
}

# Run the monitor service continuously
run_monitor_service() {
    log_info "Starting PostgreSQL user monitor service"
    
    # Install triggers first - retry up to 3 times with increasing backoff
    local attempts=0
    local max_attempts=3
    local backoff=10
    local triggers_installed=false
    
    while [ $attempts -lt $max_attempts ] && [ "$triggers_installed" = false ]; do
        if install_pg_triggers; then
            triggers_installed=true
            log_info "Triggers installed successfully after $((attempts+1)) attempt(s)"
        else
            attempts=$((attempts+1))
            if [ $attempts -lt $max_attempts ]; then
                log_warn "Failed to install triggers, retrying in $backoff seconds (attempt $attempts of $max_attempts)"
                sleep $backoff
                backoff=$((backoff * 2))
            else
                log_warn "Failed to install triggers after $max_attempts attempts"
                log_warn "Running in limited functionality mode - will use direct userlist generation"
            fi
        fi
    done
    
    # Initial userlist generation
    generate_pgbouncer_userlist
    
    # Main monitoring loop
    while true; do
        # In limited functionality mode, update more frequently
        if [ "$triggers_installed" = false ]; then
            log_info "Running in limited functionality mode - generating userlist"
            if ! generate_pgbouncer_userlist; then
                log_error "Failed to generate userlist in limited functionality mode"
                
                # Verify pgbouncer userlist permissions and content
                if [ -f "$PGB_USERLIST_PATH" ]; then
                    if ! grep -q "\"postgres\"" "$PGB_USERLIST_PATH"; then
                        log_error "postgres user not found in $PGB_USERLIST_PATH"
                    fi
                    
                    # Check permissions
                    permissions=$(stat -c "%a" "$PGB_USERLIST_PATH" 2>/dev/null || stat -f "%p" "$PGB_USERLIST_PATH" 2>/dev/null)
                    owner=$(stat -c "%U:%G" "$PGB_USERLIST_PATH" 2>/dev/null || stat -f "%Su:%Sg" "$PGB_USERLIST_PATH" 2>/dev/null)
                    log_info "Current userlist permissions: $permissions, owner: $owner"
                    
                    # Fix permissions if needed
                    if [ "$owner" != "postgres:postgres" ] || [ "$permissions" != "600" ]; then
                        log_warn "Incorrect permissions or ownership, fixing"
                        sudo chown postgres:postgres "$PGB_USERLIST_PATH" 2>/dev/null || chown postgres:postgres "$PGB_USERLIST_PATH" 2>/dev/null
                        sudo chmod 600 "$PGB_USERLIST_PATH" 2>/dev/null || chmod 600 "$PGB_USERLIST_PATH" 2>/dev/null
                    fi
                else
                    log_error "$PGB_USERLIST_PATH does not exist"
                fi
            fi
            
            # Check pgbouncer is working by attempting a quick connection
            if PGPASSWORD="$PG_SUPERUSER_PASSWORD" psql "host=localhost port=$PGB_LISTEN_PORT dbname=postgres user=postgres sslmode=require" -c "SELECT 1;" &>/dev/null; then
                log_info "pgbouncer connection test successful"
            else
                log_error "Failed to connect to pgbouncer, checking server status"
                
                # Check if pgbouncer is running
                if ! systemctl is-active --quiet pgbouncer; then
                    log_warn "pgbouncer service is not running, starting"
                    systemctl start pgbouncer
                    sleep 3
                else
                    log_info "pgbouncer service is running but connection failed, restarting"
                    systemctl restart pgbouncer
                    sleep 3
                fi
            fi
            
            # Sleep for a shorter time in limited functionality mode
            sleep 1  # Check very frequently in limited functionality mode
        else
            # Check the monitoring table for changes or run a direct check if needed
            check_user_changes
            sleep "${PG_USER_MONITOR_INTERVAL}"
        fi
    done
}

# Function to set up the user monitor
setup_user_monitor() {
    log_info "Setting up PostgreSQL user monitor..."
    
    # Check if enabled
    if [ "${PG_USER_MONITOR_ENABLED}" != "true" ]; then
        log_info "PostgreSQL user monitor is disabled, skipping setup"
        return 0
    fi
    
    # Install PostgreSQL triggers - but continue even if it fails
    local trigger_install_result=0
    if ! install_pg_triggers; then
        log_warn "Trigger installation failed, but continuing with setup. Monitor will use direct userlist generation."
        trigger_install_result=1
    fi
    
    # Initial userlist generation
    generate_pgbouncer_userlist
    
    # Create systemd service
    create_systemd_service
    
    log_info "PostgreSQL user monitor setup completed successfully"
    
    # Return the result of trigger installation for tracking in the main script
    return $trigger_install_result
}

# Main entry point
main() {
    log_info "PostgreSQL User Monitor - Milestone 8"
    
    # Check command
    if [ "$1" = "run" ]; then
        # Run the monitor service
        run_monitor_service
    else
        # Setup the monitor
        setup_user_monitor
    fi
}

# Execute main function if script is run directly
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi 