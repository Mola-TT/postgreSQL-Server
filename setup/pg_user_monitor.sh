#!/bin/bash
# pg_user_monitor.sh - PostgreSQL User Monitor for pgbouncer userlist updates
# Part of Milestone 8

# Script directory
PG_USER_MONITOR_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source required libraries
if ! type log_info &>/dev/null; then
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
  
  # Query PostgreSQL for all users with their password hashes and modification times
  su - postgres -c "psql -t -c \"
    SELECT 
      json_agg(
        json_build_object(
          'username', rolname,
          'password_hash', COALESCE(rolpassword, ''),
          'can_login', rolcanlogin,
          'valid_until', COALESCE(rolvaliduntil::text, ''),
          'last_modified', EXTRACT(EPOCH FROM GREATEST(
            COALESCE((SELECT max(xact_start) FROM pg_stat_activity WHERE usename = rolname), '1970-01-01'::timestamp),
            '1970-01-01'::timestamp
          ))
        )
      )
    FROM pg_authid 
    WHERE rolname NOT LIKE 'pg_%' 
    AND rolname != 'postgres_exporter'
    ORDER BY rolname;
  \"" 2>/dev/null > "$temp_file"
  
  if [ $? -eq 0 ] && [ -s "$temp_file" ]; then
    # Clean up the JSON output and save to state file
    cat "$temp_file" | tr -d '\n\r\t ' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' > "$state_file"
    rm -f "$temp_file"
    return 0
  else
    rm -f "$temp_file"
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
            continue
        
        # For SCRAM-SHA-256, use the hash directly from PostgreSQL
        if '$auth_type' == 'scram-sha-256':
            password_hash = user['password_hash']
        elif '$auth_type' == 'md5':
            password_hash = user['password_hash']
        else:
            # For plain auth, we would need the plain password which we don't have
            continue
        
        # Update userlist entry
        userlist_entries[username] = password_hash
        updated = True
        
        action = 'Added' if user in changes['added'] else 'Updated'
        print(f'{action} user: {username}', file=sys.stderr)
    
    # Write updated userlist
    with open('$temp_userlist', 'w') as f:
        f.write('# pgbouncer userlist.txt - Auto-generated by pg_user_monitor\\n')
        f.write('# Do not edit manually - changes will be overwritten\\n')
        f.write('\\n')
        
        for username, password_hash in sorted(userlist_entries.items()):
            f.write(f'\"{username}\" \"{password_hash}\"\\n')
    
    # Exit with code indicating if updates were made
    sys.exit(0 if updated else 1)
    
except Exception as e:
    print(f'Error updating userlist: {e}', file=sys.stderr)
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
  
  # Ensure state directory exists
  mkdir -p "$state_dir" 2>/dev/null
  chown postgres:postgres "$state_dir" 2>/dev/null
  
  # Get current user state
  if get_current_user_state "$temp_state_file"; then
    # Create a fake "all users added" changes file
    python3 -c "
import json
import sys

try:
    with open('$temp_state_file', 'r') as f:
        users = json.load(f)
    
    if users is None:
        users = []
    
    changes = {
        'added': [user for user in users if user['can_login'] and user['password_hash']],
        'modified': [],
        'deleted': []
    }
    
    with open('${temp_state_file}.changes', 'w') as f:
        json.dump(changes, f, indent=2)
    
    sys.exit(0)
    
except Exception as e:
    print(f'Error creating initial changes: {e}', file=sys.stderr)
    sys.exit(1)
" 2>/dev/null

    if [ $? -eq 0 ]; then
      # Update pgbouncer userlist
      if update_pgbouncer_userlist "${temp_state_file}.changes" "$PGB_USERLIST_PATH"; then
        log_info "Initial pgbouncer userlist created successfully"
        
        # Save current state as baseline
        mv "$temp_state_file" "$state_file" 2>/dev/null
        
        # Reload pgbouncer
        reload_pgbouncer
        
        return 0
      else
        log_error "Failed to create initial pgbouncer userlist"
        return 1
      fi
    else
      log_error "Failed to create initial changes file"
      return 1
    fi
  else
    log_error "Failed to get initial user state from PostgreSQL"
    return 1
  fi
  
  # Clean up temporary files
  rm -f "${temp_state_file}" "${temp_state_file}.changes" 2>/dev/null
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
  
  # Perform initial userlist sync
  initial_userlist_sync
  
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

# If script is run directly with setup, execute setup
if [[ "${BASH_SOURCE[0]}" == "${0}" ]] && [ "${1:-setup}" = "setup" ]; then
  setup_pg_user_monitor
fi 