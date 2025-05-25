#!/bin/bash
# pg_user_monitor.sh - PostgreSQL User Monitor for pgbouncer userlist updates
# Part of Milestone 8

# Script directory
PG_USER_MONITOR_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Load environment variables if not already loaded
if [ -z "$PG_USER_MONITOR_ENABLED" ]; then
  # Load default environment
  if [ -f "$PG_USER_MONITOR_SCRIPT_DIR/../conf/default.env" ]; then
    source "$PG_USER_MONITOR_SCRIPT_DIR/../conf/default.env"
  fi
  
  # Load user environment if available
  if [ -f "$PG_USER_MONITOR_SCRIPT_DIR/../conf/user.env" ]; then
    source "$PG_USER_MONITOR_SCRIPT_DIR/../conf/user.env"
  fi
fi

# Source required libraries
if ! type log_info &>/dev/null; then
  # Set LOG_FILE to match the monitor log path for consistent logging
  export LOG_FILE="$PG_USER_MONITOR_LOG_PATH"
  source "$PG_USER_MONITOR_SCRIPT_DIR/../lib/logger.sh"
fi

if ! type extract_password_hash &>/dev/null; then
  source "$PG_USER_MONITOR_SCRIPT_DIR/../lib/pg_extract_hash.sh"
fi

# Configuration variables with defaults
PG_USER_MONITOR_ENABLED="${PG_USER_MONITOR_ENABLED:-true}"
PG_USER_MONITOR_INTERVAL="${PG_USER_MONITOR_INTERVAL:-30}"
PG_USER_MONITOR_SERVICE_NAME="${PG_USER_MONITOR_SERVICE_NAME:-pg-user-monitor}"
PG_USER_MONITOR_LOG_PATH="${PG_USER_MONITOR_LOG_PATH:-/var/log/pg-user-monitor.log}"
PGB_USERLIST_PATH="${PGB_USERLIST_PATH:-/etc/pgbouncer/userlist.txt}"
PG_USER_MONITOR_STATE_FILE="${PG_USER_MONITOR_STATE_FILE:-/var/lib/postgresql/user_monitor_state.json}"

# Function to get current user state from PostgreSQL
get_current_user_state() {
  local state_file="$1"
  local temp_file=$(mktemp)
  local max_retries=5
  local retry_delay=2
  local retry_count=0
  
  # Ensure state file directory exists
  local state_dir=$(dirname "$state_file")
  mkdir -p "$state_dir" 2>/dev/null
  chown postgres:postgres "$state_dir" 2>/dev/null
  
  # Test PostgreSQL connection first
  while [ $retry_count -lt $max_retries ]; do
    # Try a simple connection test
    if su - postgres -c "psql -c 'SELECT 1;'" >/dev/null 2>&1; then
      break
    fi
    
    retry_count=$((retry_count + 1))
    if [ $retry_count -lt $max_retries ]; then
      log_info "PostgreSQL not ready, retrying in ${retry_delay}s (attempt $retry_count/$max_retries)..."
      sleep $retry_delay
    else
      log_error "PostgreSQL connection failed after $max_retries attempts"
      rm -f "$temp_file"
      return 1
    fi
  done
  
  # Test access to pg_authid table
  if ! su - postgres -c "psql -c 'SELECT COUNT(*) FROM pg_authid;'" >/dev/null 2>&1; then
    log_error "Cannot access pg_authid table - insufficient privileges"
    rm -f "$temp_file"
    return 1
  fi
  
  # Query PostgreSQL for all users with their password hashes and modification times
  # Try JSON aggregation first
  su - postgres -c "psql -t -c \"
    SELECT 
      json_agg(
        json_build_object(
          'username', rolname,
          'password_hash', COALESCE(rolpassword, ''),
          'can_login', rolcanlogin,
          'valid_until', COALESCE(rolvaliduntil::text, ''),
          'last_modified', EXTRACT(EPOCH FROM NOW())
        )
      )
    FROM pg_authid 
    WHERE rolname NOT LIKE 'pg_%' 
    AND rolname != 'postgres_exporter'
    ORDER BY rolname;
  \"" 2>"$temp_file.err" > "$temp_file"
  
  # If JSON aggregation failed, try a simpler approach
  if [ $? -ne 0 ] || [ ! -s "$temp_file" ]; then
    log_info "JSON aggregation failed, trying simpler query..."
    su - postgres -c "psql -t -c \"
      SELECT rolname, COALESCE(rolpassword, ''), rolcanlogin, COALESCE(rolvaliduntil::text, '')
      FROM pg_authid 
      WHERE rolname NOT LIKE 'pg_%' 
      AND rolname != 'postgres_exporter'
      ORDER BY rolname;
    \"" 2>"$temp_file.err" > "$temp_file.raw"
    
    # Convert to JSON format using Python
    python3 -c "
import sys
import json

users = []
try:
    with open('$temp_file.raw', 'r') as f:
        for line in f:
            line = line.strip()
            if line and '|' in line:
                parts = [p.strip() for p in line.split('|')]
                if len(parts) >= 4:
                    users.append({
                        'username': parts[0],
                        'password_hash': parts[1],
                        'can_login': parts[2].lower() == 't',
                        'valid_until': parts[3],
                        'last_modified': 0
                    })
    
    with open('$temp_file', 'w') as f:
        json.dump(users, f)
    
    sys.exit(0)
except Exception as e:
    print(f'Error converting to JSON: {e}', file=sys.stderr)
    sys.exit(1)
" 2>>"$temp_file.err"
    
    rm -f "$temp_file.raw"
  fi
  
  if [ $? -eq 0 ] && [ -s "$temp_file" ]; then
    # Clean up the JSON output and save to state file
    # First check if the content is valid JSON
    if python3 -c "import json; json.load(open('$temp_file'))" 2>/dev/null; then
      cp "$temp_file" "$state_file"
      log_info "Successfully retrieved user state data ($(wc -c < "$temp_file") bytes)"
    else
      log_error "Retrieved data is not valid JSON, attempting to fix..."
      # Try to clean up the JSON
      cat "$temp_file" | tr -d '\n\r\t ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' > "$state_file"
      # Verify the cleaned JSON
      if python3 -c "import json; json.load(open('$state_file'))" 2>/dev/null; then
        log_info "Successfully cleaned and saved user state data"
      else
        log_error "Failed to create valid JSON from retrieved data"
        log_error "Raw data: $(head -c 200 "$temp_file")"
        rm -f "$temp_file" "$temp_file.err"
        return 1
      fi
    fi
    rm -f "$temp_file" "$temp_file.err"
    return 0
  else
    log_error "Failed to query PostgreSQL user data"
    if [ -f "$temp_file.err" ] && [ -s "$temp_file.err" ]; then
      log_error "PostgreSQL error: $(cat "$temp_file.err")"
    fi
    if [ -f "$temp_file" ]; then
      log_error "Query output size: $(wc -c < "$temp_file") bytes"
      if [ -s "$temp_file" ]; then
        log_error "Query output content: $(head -c 200 "$temp_file")"
      fi
    fi
    rm -f "$temp_file" "$temp_file.err"
    return 1
  fi
}

# Function to compare user states and detect changes
detect_user_changes() {
  local old_state_file="$1"
  local new_state_file="$2"
  local changes_file="$3"
  
  # If old state doesn't exist, treat all users as new
  if [ ! -f "$old_state_file" ]; then
    echo "[]" > "$old_state_file"
  fi
  
  # Use Python to compare JSON states and detect changes
  python3 -c "
import json
import sys

try:
    with open('$old_state_file', 'r') as f:
        old_data = json.load(f)
    with open('$new_state_file', 'r') as f:
        new_data = json.load(f)
    
    if old_data is None:
        old_data = []
    if new_data is None:
        new_data = []
    
    # Create dictionaries for easier comparison
    old_users = {user['username']: user for user in old_data} if old_data else {}
    new_users = {user['username']: user for user in new_data} if new_data else {}
    
    changes = {
        'added': [],
        'modified': [],
        'deleted': []
    }
    
    # Check for new and modified users
    for username, user_data in new_users.items():
        if username not in old_users:
            changes['added'].append(user_data)
        elif (old_users[username]['password_hash'] != user_data['password_hash'] or
              old_users[username]['can_login'] != user_data['can_login'] or
              old_users[username]['valid_until'] != user_data['valid_until']):
            changes['modified'].append(user_data)
    
    # Check for deleted users
    for username, user_data in old_users.items():
        if username not in new_users:
            changes['deleted'].append(user_data)
    
    # Write changes to file
    with open('$changes_file', 'w') as f:
        json.dump(changes, f, indent=2)
    
    # Exit with code indicating if changes were found
    total_changes = len(changes['added']) + len(changes['modified']) + len(changes['deleted'])
    sys.exit(0 if total_changes > 0 else 1)
    
except Exception as e:
    print(f'Error comparing user states: {e}', file=sys.stderr)
    sys.exit(2)
" 2>/dev/null

  return $?
}

# Function to update pgbouncer userlist.txt
update_pgbouncer_userlist() {
  local changes_file="$1"
  local userlist_file="$2"
  local auth_type="${PGB_AUTH_TYPE:-scram-sha-256}"
  local updated=false
  
  # Create backup of current userlist
  if [ -f "$userlist_file" ]; then
    cp "$userlist_file" "${userlist_file}.bak.$(date +%s)" 2>/dev/null
  fi
  
  # Create temporary userlist file
  local temp_userlist=$(mktemp)
  
  # Start with existing userlist if it exists
  if [ -f "$userlist_file" ]; then
    cp "$userlist_file" "$temp_userlist" 2>/dev/null
  fi
  
  # Process changes using Python
  python3 -c "
import json
import sys
import os
import subprocess

try:
    with open('$changes_file', 'r') as f:
        changes = json.load(f)
    
    # Read current userlist
    userlist_entries = {}
    if os.path.exists('$temp_userlist'):
        with open('$temp_userlist', 'r') as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith('#'):
                    parts = line.split(' ', 1)
                    if len(parts) == 2:
                        username = parts[0].strip('\"')
                        password = parts[1].strip('\"')
                        userlist_entries[username] = password
    
    updated = False
    total_changes = len(changes['added']) + len(changes['modified']) + len(changes['deleted'])
    
    print(f'Processing {total_changes} total changes', file=sys.stderr)
    
    # Handle deleted users
    for user in changes['deleted']:
        username = user['username']
        if username in userlist_entries:
            del userlist_entries[username]
            updated = True
            print(f'Removed user: {username}', file=sys.stderr)
    
    # Handle added and modified users
    for user in changes['added'] + changes['modified']:
        username = user['username']
        
        # Skip users that cannot login
        if not user['can_login']:
            if username in userlist_entries:
                del userlist_entries[username]
                updated = True
                print(f'Removed non-login user: {username}', file=sys.stderr)
            continue
        
        # Skip users without password hash
        if not user['password_hash']:
            print(f'Skipping user {username} - no password hash', file=sys.stderr)
            continue
        
        # For SCRAM-SHA-256, use the hash directly from PostgreSQL
        if '$auth_type' == 'scram-sha-256':
            password_hash = user['password_hash']
        elif '$auth_type' == 'md5':
            password_hash = user['password_hash']
        else:
            # For plain auth, we would need the plain password which we don't have
            print(f'Skipping user {username} - unsupported auth type: $auth_type', file=sys.stderr)
            continue
        
        # Update userlist entry
        userlist_entries[username] = password_hash
        updated = True
        
        action = 'Added' if user in changes['added'] else 'Updated'
        print(f'{action} user: {username}', file=sys.stderr)
    
    # Always write the userlist file to ensure proper format and headers
    with open('$temp_userlist', 'w') as f:
        f.write('# pgbouncer userlist.txt - Auto-generated by pg_user_monitor\\n')
        f.write('# Do not edit manually - changes will be overwritten\\n')
        f.write('\\n')
        
        for username, password_hash in sorted(userlist_entries.items()):
            f.write(f'\"{username}\" \"{password_hash}\"\\n')
    
    if total_changes == 0:
        print('No changes to process, but userlist file updated with proper format', file=sys.stderr)
    
    # Exit with code indicating if updates were made
    sys.exit(0 if updated else 1)
    
except Exception as e:
    print(f'Error updating userlist: {e}', file=sys.stderr)
    import traceback
    traceback.print_exc(file=sys.stderr)
    sys.exit(2)
" 2>&1

  local result=$?
  
  if [ $result -eq 0 ]; then
    # Move temp file to actual userlist location
    mv "$temp_userlist" "$userlist_file" 2>/dev/null
    
    # Set proper permissions
    chown postgres:postgres "$userlist_file" 2>/dev/null
    chmod 640 "$userlist_file" 2>/dev/null
    
    updated=true
  else
    rm -f "$temp_userlist" 2>/dev/null
  fi
  
  if [ "$updated" = true ]; then
    return 0
  else
    return 1
  fi
}

# Function to reload pgbouncer
reload_pgbouncer() {
  log_info "Reloading pgbouncer to apply userlist changes..."
  
  # Try graceful reload first
  if systemctl reload pgbouncer > /dev/null 2>&1; then
    log_info "pgbouncer reloaded successfully"
    return 0
  else
    log_warn "pgbouncer reload failed, attempting restart..."
    if systemctl restart pgbouncer > /dev/null 2>&1; then
      log_info "pgbouncer restarted successfully"
      return 0
    else
      log_error "Failed to reload/restart pgbouncer"
      return 1
    fi
  fi
}

# Function to run the monitoring loop
run_monitor_loop() {
  local state_file="$PG_USER_MONITOR_STATE_FILE"
  local state_dir=$(dirname "$state_file")
  local old_state_file="${state_file}.old"
  local new_state_file="${state_file}.new"
  local changes_file="${state_file}.changes"
  
  # Ensure state directory exists
  mkdir -p "$state_dir" 2>/dev/null
  chown postgres:postgres "$state_dir" 2>/dev/null
  
  log_info "Starting PostgreSQL user monitor loop (interval: ${PG_USER_MONITOR_INTERVAL}s)"
  
  while true; do
    # Get current user state
    if get_current_user_state "$new_state_file"; then
      # Compare with previous state
      if detect_user_changes "$old_state_file" "$new_state_file" "$changes_file"; then
        log_info "User changes detected, updating pgbouncer userlist..."
        
        # Update pgbouncer userlist
        if update_pgbouncer_userlist "$changes_file" "$PGB_USERLIST_PATH"; then
          log_info "pgbouncer userlist updated successfully"
          
          # Reload pgbouncer
          reload_pgbouncer
        else
          log_error "Failed to update pgbouncer userlist"
        fi
        
        # Move new state to old state for next iteration
        mv "$new_state_file" "$old_state_file" 2>/dev/null
      else
        # No changes detected, just update the old state file
        mv "$new_state_file" "$old_state_file" 2>/dev/null
      fi
    else
      log_error "Failed to get current user state from PostgreSQL"
    fi
    
    # Clean up temporary files
    rm -f "$changes_file" 2>/dev/null
    
    # Wait for next iteration
    sleep "$PG_USER_MONITOR_INTERVAL"
  done
}

# Function to create systemd service
create_systemd_service() {
  local service_name="$PG_USER_MONITOR_SERVICE_NAME"
  local service_file="/etc/systemd/system/${service_name}.service"
  local script_path="$PG_USER_MONITOR_SCRIPT_DIR/pg_user_monitor.sh"
  
  log_info "Creating systemd service: $service_name"
  
  # Ensure log directory and file exist before creating service
  local log_dir=$(dirname "$PG_USER_MONITOR_LOG_PATH")
  mkdir -p "$log_dir" 2>/dev/null
  touch "$PG_USER_MONITOR_LOG_PATH" 2>/dev/null
  chmod 644 "$PG_USER_MONITOR_LOG_PATH" 2>/dev/null
  
  # Create service file
  cat > "$service_file" << EOF
[Unit]
Description=PostgreSQL User Monitor for pgbouncer
After=postgresql.service pgbouncer.service
Requires=postgresql.service
Wants=pgbouncer.service

[Service]
Type=simple
User=root
Group=root
ExecStart=/bin/bash $script_path --daemon
Restart=always
RestartSec=10
StandardOutput=append:$PG_USER_MONITOR_LOG_PATH
StandardError=append:$PG_USER_MONITOR_LOG_PATH

# Environment variables
Environment=PG_USER_MONITOR_ENABLED=$PG_USER_MONITOR_ENABLED
Environment=PG_USER_MONITOR_INTERVAL=$PG_USER_MONITOR_INTERVAL
Environment=PG_USER_MONITOR_LOG_PATH=$PG_USER_MONITOR_LOG_PATH
Environment=PGB_USERLIST_PATH=$PGB_USERLIST_PATH
Environment=PG_USER_MONITOR_STATE_FILE=$PG_USER_MONITOR_STATE_FILE
Environment=PGB_AUTH_TYPE=${PGB_AUTH_TYPE:-scram-sha-256}

[Install]
WantedBy=multi-user.target
EOF

  # Set proper permissions
  chmod 644 "$service_file" 2>/dev/null
  
  # Reload systemd and enable service
  systemctl daemon-reload > /dev/null 2>&1
  systemctl enable "$service_name" > /dev/null 2>&1
  
  log_info "Systemd service created and enabled: $service_name"
}

# Function to start the monitoring service
start_monitor_service() {
  local service_name="$PG_USER_MONITOR_SERVICE_NAME"
  
  log_info "Starting PostgreSQL user monitor service..."
  
  # Stop service if it's already running
  systemctl stop "$service_name" > /dev/null 2>&1
  
  # Start the service
  if systemctl start "$service_name" > /dev/null 2>&1; then
    log_info "PostgreSQL user monitor service started successfully"
    
    # Check service status
    if systemctl is-active --quiet "$service_name"; then
      log_info "Service is running and active"
      return 0
    else
      log_error "Service started but is not active"
      return 1
    fi
  else
    log_error "Failed to start PostgreSQL user monitor service"
    return 1
  fi
}

# Function to stop the monitoring service
stop_monitor_service() {
  local service_name="$PG_USER_MONITOR_SERVICE_NAME"
  
  log_info "Stopping PostgreSQL user monitor service..."
  
  if systemctl stop "$service_name" > /dev/null 2>&1; then
    log_info "PostgreSQL user monitor service stopped successfully"
    return 0
  else
    log_error "Failed to stop PostgreSQL user monitor service"
    return 1
  fi
}

# Function to check service status
check_service_status() {
  local service_name="$PG_USER_MONITOR_SERVICE_NAME"
  
  if systemctl is-active --quiet "$service_name"; then
    log_info "PostgreSQL user monitor service is running"
    return 0
  else
    log_warn "PostgreSQL user monitor service is not running"
    return 1
  fi
}

# Function to perform initial userlist sync
initial_userlist_sync() {
  log_info "Performing initial pgbouncer userlist synchronization..."
  
  local state_file="$PG_USER_MONITOR_STATE_FILE"
  local state_dir=$(dirname "$state_file")
  local temp_state_file="${state_file}.initial"
  local existing_users_file="${state_file}.existing"
  
  # Ensure state directory exists
  mkdir -p "$state_dir" 2>/dev/null
  chown postgres:postgres "$state_dir" 2>/dev/null
  
  # Get current user state
  if get_current_user_state "$temp_state_file"; then
    # Read existing userlist to preserve current entries and write to temp file
    > "$existing_users_file"  # Create empty file
    if [ -f "$PGB_USERLIST_PATH" ]; then
      while IFS= read -r line; do
        if [[ "$line" =~ ^\"([^\"]+)\" ]]; then
          echo "${BASH_REMATCH[1]}" >> "$existing_users_file"
        fi
      done < "$PGB_USERLIST_PATH"
    fi
    
    log_info "Found $(wc -l < "$existing_users_file") existing users in userlist"
    
    # Create a changes file that only adds users not already in userlist
    python3 -c "
import json
import sys
import os

try:
    # Read current users from PostgreSQL
    with open('$temp_state_file', 'r') as f:
        users = json.load(f)
    
    if users is None:
        users = []
    
    print(f'Found {len(users)} users from PostgreSQL', file=sys.stderr)
    
    # Read existing users from file
    existing_users = []
    if os.path.exists('$existing_users_file'):
        with open('$existing_users_file', 'r') as f:
            existing_users = [line.strip() for line in f if line.strip()]
    
    print(f'Found {len(existing_users)} existing users in userlist', file=sys.stderr)
    
    # Only add users that are not already in the userlist
    new_users = []
    for user in users:
        if user.get('can_login', False) and user.get('password_hash', '') and user.get('username', '') not in existing_users:
            new_users.append(user)
            print(f'Will add new user: {user.get(\"username\", \"unknown\")}', file=sys.stderr)
    
    changes = {
        'added': new_users,
        'modified': [],
        'deleted': []
    }
    
    print(f'Creating changes file with {len(new_users)} new users', file=sys.stderr)
    
    with open('${temp_state_file}.changes', 'w') as f:
        json.dump(changes, f, indent=2)
    
    print('Changes file created successfully', file=sys.stderr)
    sys.exit(0)
    
except Exception as e:
    print(f'Error creating initial changes: {e}', file=sys.stderr)
    import traceback
    traceback.print_exc(file=sys.stderr)
    sys.exit(1)
"

    local python_exit_code=$?
    if [ $python_exit_code -eq 0 ]; then
      log_info "Initial changes file created successfully"
      
      # Update pgbouncer userlist
      if update_pgbouncer_userlist "${temp_state_file}.changes" "$PGB_USERLIST_PATH"; then
        log_info "Initial pgbouncer userlist updated successfully"
        
        # Save current state as baseline
        mv "$temp_state_file" "$state_file" 2>/dev/null
        
        # Reload pgbouncer
        reload_pgbouncer
        
        # Clean up temporary files
        rm -f "${temp_state_file}.changes" "$existing_users_file" 2>/dev/null
        
        return 0
      else
        # Check if the failure was due to no changes needed
        local update_exit_code=$?
        if [ $update_exit_code -eq 1 ]; then
          log_info "No userlist updates needed - all users already synchronized"
          
          # Save current state as baseline
          mv "$temp_state_file" "$state_file" 2>/dev/null
          
          # Clean up temporary files
          rm -f "${temp_state_file}.changes" "$existing_users_file" 2>/dev/null
          
          return 0
        else
          log_error "Failed to create initial pgbouncer userlist"
          rm -f "${temp_state_file}" "${temp_state_file}.changes" "$existing_users_file" 2>/dev/null
          return 1
        fi
      fi
    else
      log_error "Failed to create initial changes file (Python exit code: $python_exit_code)"
      rm -f "${temp_state_file}" "${temp_state_file}.changes" "$existing_users_file" 2>/dev/null
      return 1
    fi
  else
    log_error "Failed to get initial user state from PostgreSQL"
    rm -f "$existing_users_file" 2>/dev/null
    return 1
  fi
}

# Main setup function
setup_pg_user_monitor() {
  log_info "Setting up PostgreSQL user monitor..."
  
  # Check if monitoring is enabled
  if [ "$PG_USER_MONITOR_ENABLED" != "true" ]; then
    log_info "PostgreSQL user monitor is disabled (PG_USER_MONITOR_ENABLED != true)"
    return 0
  fi
  
  # Check dependencies
  if ! command -v python3 >/dev/null 2>&1; then
    log_error "Python3 is required for PostgreSQL user monitor"
    return 1
  fi
  
  if ! systemctl is-active --quiet postgresql; then
    log_error "PostgreSQL service is not running"
    return 1
  fi
  
  # Create log directory
  local log_dir=$(dirname "$PG_USER_MONITOR_LOG_PATH")
  mkdir -p "$log_dir" 2>/dev/null
  
  # Create log file with proper permissions
  touch "$PG_USER_MONITOR_LOG_PATH" 2>/dev/null
  chown root:root "$PG_USER_MONITOR_LOG_PATH" 2>/dev/null
  chmod 644 "$PG_USER_MONITOR_LOG_PATH" 2>/dev/null
  
  # Perform initial userlist sync
  if ! initial_userlist_sync; then
    log_error "Initial userlist sync failed, PostgreSQL user monitor setup aborted"
    return 1
  fi
  
  # Create systemd service
  create_systemd_service
  
  # Start monitoring service
  start_monitor_service
  
  log_info "PostgreSQL user monitor setup completed successfully"
}

# Command line interface
case "${1:-setup}" in
  "setup")
    setup_pg_user_monitor
    ;;
  "--daemon")
    run_monitor_loop
    ;;
  "start")
    start_monitor_service
    ;;
  "stop")
    stop_monitor_service
    ;;
  "restart")
    stop_monitor_service
    sleep 2
    start_monitor_service
    ;;
  "status")
    check_service_status
    ;;
  "sync")
    initial_userlist_sync
    ;;
  *)
    echo "Usage: $0 {setup|start|stop|restart|status|sync|--daemon}"
    echo "  setup    - Set up the PostgreSQL user monitor service"
    echo "  start    - Start the monitoring service"
    echo "  stop     - Stop the monitoring service"
    echo "  restart  - Restart the monitoring service"
    echo "  status   - Check service status"
    echo "  sync     - Perform initial userlist synchronization"
    echo "  --daemon - Run in daemon mode (used by systemd)"
    exit 1
    ;;
esac

# Note: setup_pg_user_monitor is called via the case statement above 