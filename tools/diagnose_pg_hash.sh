#!/bin/bash
# diagnose_pg_hash.sh - Diagnose PostgreSQL password hash extraction issues
# This is a diagnostic script to troubleshoot cases where password hash extraction fails

# Source required files
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
source "$SCRIPT_DIR/logger.sh"
source "$SCRIPT_DIR/pg_extract_hash.sh"

# Set log level to DEBUG for diagnostic purposes
export LOG_LEVEL=0

# Check if running as root
if [ "$(id -u)" -ne 0 ]; then
    log_error "This script must be run as root"
    exit 1
fi

# Test user
USER=${1:-"postgres"}

log_info "Running PostgreSQL password hash diagnostic for user: $USER"

# Check PostgreSQL version
PG_VERSION=$(psql --version | head -1 | sed 's/^psql (PostgreSQL) //')
log_info "PostgreSQL version: $PG_VERSION"

# Check PostgreSQL service status
log_info "PostgreSQL service status:"
systemctl status postgresql | grep "Active:" || echo "Service status check failed"

# Check password encryption setting
log_info "Password encryption method:"
su - postgres -c "psql -t -c \"SHOW password_encryption;\"" || echo "Failed to check password encryption"

# Check password hashing method table access
log_info "Testing pg_authid access:"
su - postgres -c "psql -t -c \"SELECT COUNT(*) FROM pg_authid;\"" || echo "Failed to access pg_authid table"

log_info "Testing pg_shadow access:"
su - postgres -c "psql -t -c \"SELECT COUNT(*) FROM pg_shadow;\"" || echo "Failed to access pg_shadow table"

# Check pgbouncer configuration
if [ -f "/etc/pgbouncer/pgbouncer.ini" ]; then
    log_info "pgbouncer authentication type:"
    grep -i "auth_type" /etc/pgbouncer/pgbouncer.ini || echo "Could not find auth_type in pgbouncer.ini"
else
    log_warn "pgbouncer.ini not found"
fi

# Test hash extraction
log_info "Testing hash extraction for user: $USER"
TEMP_FILE=$(mktemp)

log_info "Extracting hash..."
if extract_hash "$USER" "$TEMP_FILE"; then
    log_info "Hash extraction succeeded:"
    cat "$TEMP_FILE" | sed 's/"[^"]*"$/"********"/' || echo "Failed to read hash file"
    
    # Verify the hash content
    if grep -q "SCRAM-SHA-256" "$TEMP_FILE"; then
        log_info "Hash is in SCRAM-SHA-256 format (correct)"
    elif grep -q "md5" "$TEMP_FILE"; then
        log_warn "Hash is in MD5 format (not SCRAM-SHA-256)"
    else
        log_warn "Hash format could not be determined"
    fi
else
    log_error "Hash extraction failed"
    
    # Try direct methods to help diagnose
    log_info "Attempting direct hash query:"
    su - postgres -c "psql -t -c \"SELECT rolpassword FROM pg_authid WHERE rolname='$USER';\"" | tr -d ' \n\r\t' || echo "Failed direct query"
fi

# Clean up
rm -f "$TEMP_FILE"

log_info "Diagnostic complete" 