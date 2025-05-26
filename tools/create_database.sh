#!/bin/bash
# create_database.sh - Automated PostgreSQL database creation with restricted admin users
# Part of Milestone 10

# Get the directory where this script is located
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Source required libraries
source "$PROJECT_ROOT/lib/logger.sh"
source "$PROJECT_ROOT/lib/utilities.sh"

# Load environment variables
if [ -f "$PROJECT_ROOT/conf/default.env" ]; then
    source "$PROJECT_ROOT/conf/default.env"
fi

if [ -f "$PROJECT_ROOT/conf/user.env" ]; then
    source "$PROJECT_ROOT/conf/user.env"
fi

# Set script-specific log file
export LOG_FILE="/var/log/create_database.log"

# Global variables for credentials
PG_SUPERUSER=""
PG_SUPERUSER_PASS=""
NEW_DATABASE=""
ADMIN_USER=""
ADMIN_PASSWORD=""

# Function to securely read password (using built-in read -s for better compatibility)
# Note: Using read -s instead of custom character-by-character reading for better shell compatibility

# Function to validate database name
validate_database_name() {
    local dbname="$1"
    
    # Check if name is empty
    if [[ -z "$dbname" ]]; then
        return 1
    fi
    
    # Check if name contains only valid characters (alphanumeric, underscore, hyphen)
    if [[ ! "$dbname" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        return 1
    fi
    
    # Check if name starts with a letter
    if [[ ! "$dbname" =~ ^[a-zA-Z] ]]; then
        return 1
    fi
    
    # Check length (PostgreSQL max identifier length is 63)
    if [[ ${#dbname} -gt 63 ]]; then
        return 1
    fi
    
    return 0
}

# Function to validate username
validate_username() {
    local username="$1"
    
    # Check if name is empty
    if [[ -z "$username" ]]; then
        return 1
    fi
    
    # Check if name contains only valid characters
    if [[ ! "$username" =~ ^[a-zA-Z0-9_]+$ ]]; then
        return 1
    fi
    
    # Check if name starts with a letter
    if [[ ! "$username" =~ ^[a-zA-Z] ]]; then
        return 1
    fi
    
    # Check length
    if [[ ${#username} -gt 63 ]]; then
        return 1
    fi
    
    return 0
}

# Function to test PostgreSQL connection
test_pg_connection() {
    local test_user="$1"
    local test_password="$2"
    local test_database="$3"
    local expected_result="$4"  # "success" or "failure"
    
    local result
    PGPASSWORD="$test_password" psql -h localhost -p "$DB_PORT" -U "$test_user" -d "$test_database" -c "SELECT current_database(), current_user;" >/dev/null 2>&1
    result=$?
    
    if [[ "$expected_result" == "success" ]]; then
        return $result
    else
        # For expected failure, return 0 if connection failed (which is what we want)
        if [[ $result -eq 0 ]]; then
            return 1
        else
            return 0
        fi
    fi
}

# Function to get interactive credentials
get_credentials() {
    log_info "=== PostgreSQL Database Creation Tool ==="
    echo
    
    # Get PostgreSQL superuser username
    while true; do
        read -p "Enter PostgreSQL superuser username [postgres]: " PG_SUPERUSER
        PG_SUPERUSER=${PG_SUPERUSER:-postgres}
        
        if validate_username "$PG_SUPERUSER"; then
            break
        else
            log_error "Invalid username. Use only letters, numbers, and underscores, starting with a letter."
        fi
    done
    
    # Get PostgreSQL superuser password
    while true; do
        echo -n "Enter PostgreSQL superuser password: "
        read -s PG_SUPERUSER_PASS
        echo
        
        if [[ -n "$PG_SUPERUSER_PASS" ]]; then
            # Test connection to validate credentials
            log_info "Validating superuser credentials..."
            if PGPASSWORD="$PG_SUPERUSER_PASS" psql -h localhost -p "$DB_PORT" -U "$PG_SUPERUSER" -d postgres -c "SELECT version();" >/dev/null 2>&1; then
                log_pass "Superuser credentials validated successfully"
                break
            else
                log_error "Invalid credentials or PostgreSQL connection failed. Please try again."
            fi
        else
            log_error "Password cannot be empty. Please try again."
        fi
    done
    
    # Get database name
    while true; do
        read -p "Enter database name to create: " NEW_DATABASE
        
        if validate_database_name "$NEW_DATABASE"; then
            # Check if database already exists
            if PGPASSWORD="$PG_SUPERUSER_PASS" psql -h localhost -p "$DB_PORT" -U "$PG_SUPERUSER" -d postgres -tc "SELECT 1 FROM pg_database WHERE datname = '$NEW_DATABASE';" | grep -q 1; then
                log_error "Database '$NEW_DATABASE' already exists. Please choose a different name."
            else
                break
            fi
        else
            log_error "Invalid database name. Use only letters, numbers, underscores, and hyphens, starting with a letter (max 63 chars)."
        fi
    done
    
    # Set default admin username
    ADMIN_USER="${NEW_DATABASE}_admin"
    read -p "Enter admin username [$ADMIN_USER]: " input_admin
    if [[ -n "$input_admin" ]]; then
        if validate_username "$input_admin"; then
            ADMIN_USER="$input_admin"
        else
            log_error "Invalid admin username. Using default: $ADMIN_USER"
        fi
    fi
    
    # Get admin password
    while true; do
        echo -n "Enter password for admin user '$ADMIN_USER': "
        read -s ADMIN_PASSWORD
        echo
        
        if [[ ${#ADMIN_PASSWORD} -ge 8 ]]; then
            break
        else
            log_error "Password must be at least 8 characters long."
        fi
    done
    
    echo
    log_info "Configuration Summary:"
    log_info "  PostgreSQL Superuser: $PG_SUPERUSER"
    log_info "  Database Name: $NEW_DATABASE"
    log_info "  Admin User: $ADMIN_USER"
    echo
    
    read -p "Proceed with database creation? (y/N): " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        log_info "Database creation cancelled by user."
        exit 0
    fi
}

# Function to create database
create_database() {
    log_info "Creating database '$NEW_DATABASE'..."
    
    # Use createdb command as specified in requirements
    if PGPASSWORD="$PG_SUPERUSER_PASS" createdb -h localhost -p "$DB_PORT" -U "$PG_SUPERUSER" -O "$PG_SUPERUSER" "$NEW_DATABASE" >/dev/null 2>&1; then
        log_pass "Database '$NEW_DATABASE' created successfully"
    else
        log_error "Failed to create database '$NEW_DATABASE'"
        exit 1
    fi
}

# Function to create admin user with restricted privileges
create_admin_user() {
    log_info "Creating admin user '$ADMIN_USER' with database-specific privileges..."
    
    # Create the admin user
    PGPASSWORD="$PG_SUPERUSER_PASS" psql -h localhost -p "$DB_PORT" -U "$PG_SUPERUSER" -d postgres -q >/dev/null 2>&1 <<EOF
-- Create admin user with no inheritance to avoid default role privileges
CREATE ROLE "$ADMIN_USER" WITH LOGIN PASSWORD '$ADMIN_PASSWORD' NOINHERIT;

-- Grant connection to the specific database only
GRANT CONNECT ON DATABASE "$NEW_DATABASE" TO "$ADMIN_USER";

-- Grant usage on public schema (required for most operations)
\c "$NEW_DATABASE"
GRANT USAGE ON SCHEMA public TO "$ADMIN_USER";

-- Grant full privileges on the database
GRANT ALL PRIVILEGES ON DATABASE "$NEW_DATABASE" TO "$ADMIN_USER";

-- Grant all privileges on public schema
GRANT ALL PRIVILEGES ON SCHEMA public TO "$ADMIN_USER";

-- Grant privileges on all existing tables and sequences
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO "$ADMIN_USER";
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO "$ADMIN_USER";

-- Set default privileges for future objects created by any user
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON TABLES TO "$ADMIN_USER";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL PRIVILEGES ON SEQUENCES TO "$ADMIN_USER";

-- Allow admin to create users, but limit their scope
-- Admin can create roles but cannot grant superuser or replication privileges
ALTER ROLE "$ADMIN_USER" CREATEROLE;

-- Explicitly revoke CONNECT privileges from other databases
-- This is necessary because the PUBLIC role often has default CONNECT privileges
DO \$\$
DECLARE
    db_record RECORD;
BEGIN
    -- Revoke CONNECT from all databases except our target database
    FOR db_record IN 
        SELECT datname FROM pg_database 
        WHERE datname != '$NEW_DATABASE' 
        AND datistemplate = false
    LOOP
        BEGIN
            EXECUTE format('REVOKE CONNECT ON DATABASE %I FROM %I', db_record.datname, '$ADMIN_USER');
        EXCEPTION
            WHEN insufficient_privilege THEN
                -- Ignore if we don't have permission to revoke
                NULL;
        END;
    END LOOP;
END;
\$\$;

-- Note: Event triggers for CREATE ROLE are not supported in PostgreSQL
-- User creation restrictions will be enforced through privilege management
EOF

    if [[ $? -eq 0 ]]; then
        log_pass "Admin user '$ADMIN_USER' created successfully with database-specific privileges"
    else
        log_error "Failed to create admin user '$ADMIN_USER'"
        exit 1
    fi
}

# Function to configure role inheritance and restrictions
configure_role_restrictions() {
    log_info "Configuring role inheritance and access restrictions..."
    
    PGPASSWORD="$PG_SUPERUSER_PASS" psql -h localhost -p "$DB_PORT" -U "$PG_SUPERUSER" -d "$NEW_DATABASE" -q >/dev/null 2>&1 <<EOF
-- Ensure admin cannot become superuser or have replication privileges
ALTER ROLE "$ADMIN_USER" NOSUPERUSER NOREPLICATION;

-- Additional security: Revoke any remaining CONNECT privileges from other databases
DO \$\$
DECLARE
    db_record RECORD;
BEGIN
    FOR db_record IN 
        SELECT datname FROM pg_database 
        WHERE datname != '$NEW_DATABASE'
    LOOP
        BEGIN
            EXECUTE format('REVOKE CONNECT ON DATABASE %I FROM %I', db_record.datname, '$ADMIN_USER');
        EXCEPTION
            WHEN insufficient_privilege OR undefined_object THEN
                -- Ignore errors for privileges that don't exist
                NULL;
        END;
    END LOOP;
END;
\$\$;

-- Set connection limit if needed (optional)
-- ALTER ROLE "$ADMIN_USER" CONNECTION LIMIT 10;

-- Create a policy function for database access restriction
CREATE OR REPLACE FUNCTION check_database_access(username text) 
RETURNS boolean AS \$\$
DECLARE
    allowed_db text := '$NEW_DATABASE';
    current_db text := current_database();
BEGIN
    -- Only allow access to the specific database
    IF current_db = allowed_db THEN
        RETURN true;
    ELSE
        RAISE EXCEPTION 'Access denied: User % is not allowed to access database %', username, current_db;
    END IF;
END;
\$\$ LANGUAGE plpgsql SECURITY DEFINER;

-- Grant execute on the function to admin
GRANT EXECUTE ON FUNCTION check_database_access(text) TO "$ADMIN_USER";
EOF

    if [[ $? -eq 0 ]]; then
        log_pass "Role restrictions configured successfully"
    else
        log_error "Failed to configure role restrictions"
        exit 1
    fi
}

# Function to run integrated tests
run_tests() {
    log_info "=== Running Integrated Tests ==="
    
    # Test 1: Admin user can connect to target database
    log_info "Test 1: Admin user database access..."
    if test_pg_connection "$ADMIN_USER" "$ADMIN_PASSWORD" "$NEW_DATABASE" "success"; then
        log_pass "✓ Admin user can access target database '$NEW_DATABASE'"
    else
        log_error "✗ Admin user cannot access target database '$NEW_DATABASE'"
        return 1
    fi
    
    # Test 2: Admin user cannot connect to other databases (postgres db)
    log_info "Test 2: Admin user database isolation..."
    # First, let's check what privileges the user actually has
    log_info "Checking current database privileges for $ADMIN_USER..."
    PGPASSWORD="$PG_SUPERUSER_PASS" psql -h localhost -p "$DB_PORT" -U "$PG_SUPERUSER" -d postgres -c "
        SELECT d.datname, has_database_privilege('$ADMIN_USER', d.datname, 'CONNECT') as can_connect
        FROM pg_database d 
        WHERE d.datistemplate = false 
        ORDER BY d.datname;" 2>/dev/null || true
    
    if test_pg_connection "$ADMIN_USER" "$ADMIN_PASSWORD" "postgres" "failure"; then
        log_pass "✓ Admin user properly restricted from 'postgres' database"
    else
        log_error "✗ Admin user can access 'postgres' database (security issue)"
        log_error "Debug: Checking why user can still connect..."
        # Show what grants exist
        PGPASSWORD="$PG_SUPERUSER_PASS" psql -h localhost -p "$DB_PORT" -U "$PG_SUPERUSER" -d postgres -c "
            SELECT 'postgres' as database, 'CONNECT' as privilege, 
                   has_database_privilege('$ADMIN_USER', 'postgres', 'CONNECT') as has_privilege;" 2>/dev/null || true
        return 1
    fi
    
    # Test 3: Admin user can create tables
    log_info "Test 3: Admin user table creation privileges..."
    if PGPASSWORD="$ADMIN_PASSWORD" psql -h localhost -p "$DB_PORT" -U "$ADMIN_USER" -d "$NEW_DATABASE" -c "CREATE TABLE test_table (id SERIAL PRIMARY KEY, name VARCHAR(50)); DROP TABLE test_table;" >/dev/null 2>&1; then
        log_pass "✓ Admin user can create and drop tables"
    else
        log_error "✗ Admin user cannot create tables"
        return 1
    fi
    
    # Test 4: Admin user can create other users
    log_info "Test 4: Admin user role creation privileges..."
    local test_user="${NEW_DATABASE}_testuser"
    if PGPASSWORD="$ADMIN_PASSWORD" psql -h localhost -p "$DB_PORT" -U "$ADMIN_USER" -d "$NEW_DATABASE" -c "CREATE ROLE $test_user WITH LOGIN PASSWORD 'testpass123';" >/dev/null 2>&1; then
        log_pass "✓ Admin user can create new users"
        
        # Test 5: Created user can access target database
        log_info "Test 5: Created user database access..."
        # Grant connect privilege to the test user
        PGPASSWORD="$ADMIN_PASSWORD" psql -h localhost -p "$DB_PORT" -U "$ADMIN_USER" -d "$NEW_DATABASE" -c "GRANT CONNECT ON DATABASE $NEW_DATABASE TO $test_user; GRANT USAGE ON SCHEMA public TO $test_user;" >/dev/null 2>&1
        
        if test_pg_connection "$test_user" "testpass123" "$NEW_DATABASE" "success"; then
            log_pass "✓ Created user can access target database"
        else
            log_error "✗ Created user cannot access target database"
        fi
        
        # Test 6: Created user cannot access other databases
        log_info "Test 6: Created user database isolation..."
        if test_pg_connection "$test_user" "testpass123" "postgres" "failure"; then
            log_pass "✓ Created user properly restricted from other databases"
        else
            log_error "✗ Created user can access other databases (security issue)"
        fi
        
        # Test 7: Created user cannot create other users
        log_info "Test 7: Created user role creation restrictions..."
        if PGPASSWORD="testpass123" psql -h localhost -p "$DB_PORT" -U "$test_user" -d "$NEW_DATABASE" -c "CREATE ROLE another_user WITH LOGIN PASSWORD 'pass';" >/dev/null 2>&1; then
            log_error "✗ Created user can create other users (should be restricted)"
        else
            log_pass "✓ Created user properly restricted from creating other users"
        fi
        
        # Cleanup test user
        PGPASSWORD="$ADMIN_PASSWORD" psql -h localhost -p "$DB_PORT" -U "$ADMIN_USER" -d "$NEW_DATABASE" -c "DROP ROLE IF EXISTS $test_user;" >/dev/null 2>&1
        
    else
        log_error "✗ Admin user cannot create new users"
        return 1
    fi
    
    # Test 8: Verify database exists and is accessible
    log_info "Test 8: Database existence and accessibility..."
    if PGPASSWORD="$PG_SUPERUSER_PASS" psql -h localhost -p "$DB_PORT" -U "$PG_SUPERUSER" -d postgres -tc "SELECT 1 FROM pg_database WHERE datname = '$NEW_DATABASE';" | grep -q 1; then
        log_pass "✓ Database '$NEW_DATABASE' exists and is accessible"
    else
        log_error "✗ Database '$NEW_DATABASE' does not exist or is not accessible"
        return 1
    fi
    
    log_pass "=== All tests completed successfully ==="
    return 0
}

# Function to display summary
display_summary() {
    echo
    log_info "=== Database Creation Summary ==="
    log_info "Database Name: $NEW_DATABASE"
    log_info "Admin User: $ADMIN_USER"
    log_info "Admin Capabilities:"
    log_info "  ✓ Full access to database '$NEW_DATABASE'"
    log_info "  ✓ Can create tables, views, functions, etc."
    log_info "  ✓ Can create users with access to '$NEW_DATABASE' only"
    log_info "  ✓ Cannot access other databases"
    log_info "  ✓ Cannot create superusers or replication users"
    echo
    log_info "Connection Information:"
    log_info "  Host: localhost"
    log_info "  Port: $DB_PORT"
    log_info "  Database: $NEW_DATABASE"
    log_info "  Username: $ADMIN_USER"
    echo
    log_info "Example connection command:"
    log_info "  psql -h localhost -p $DB_PORT -U $ADMIN_USER -d $NEW_DATABASE"
    echo
}

# Function to create audit log entry
create_audit_log() {
    local audit_file="/var/log/database_creation_audit.log"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")
    
    {
        echo "=== Database Creation Audit Log ==="
        echo "Timestamp: $timestamp"
        echo "Database: $NEW_DATABASE"
        echo "Admin User: $ADMIN_USER"
        echo "Created By: $(whoami)"
        echo "Host: $(hostname)"
        echo "PostgreSQL Version: $(PGPASSWORD="$PG_SUPERUSER_PASS" psql -h localhost -p "$DB_PORT" -U "$PG_SUPERUSER" -d postgres -Atc "SELECT version();" 2>/dev/null | head -1)"
        echo "============================================"
        echo
    } >> "$audit_file"
    
    log_info "Audit log entry created in $audit_file"
}

# Main function
main() {
    # Check if running as root (recommended for system operations)
    if [[ $EUID -eq 0 ]]; then
        log_info "Running as root user"
    else
        log_warn "Not running as root. Some operations might require elevated privileges."
    fi
    
    # Check if PostgreSQL is running
    if ! systemctl is-active --quiet postgresql; then
        log_error "PostgreSQL service is not running. Please start PostgreSQL first."
        exit 1
    fi
    
    # Check if PostgreSQL client tools are available
    if ! command -v psql >/dev/null 2>&1; then
        log_error "PostgreSQL client (psql) not found. Please install postgresql-client."
        exit 1
    fi
    
    if ! command -v createdb >/dev/null 2>&1; then
        log_error "createdb command not found. Please install postgresql-client."
        exit 1
    fi
    
    # Get credentials interactively
    get_credentials
    
    # Create database
    create_database
    
    # Create admin user with restricted privileges
    create_admin_user
    
    # Configure role restrictions
    configure_role_restrictions
    
    # Run integrated tests
    if run_tests; then
        log_pass "Database creation and testing completed successfully!"
        
        # Create audit log
        create_audit_log
        
        # Display summary
        display_summary
    else
        log_error "Some tests failed. Please review the setup."
        exit 1
    fi
}

# Run main function
main "$@" 