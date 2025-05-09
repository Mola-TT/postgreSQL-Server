#!/bin/bash
# pg_extract_hash.sh - Extract password hash from PostgreSQL
# Part of Milestone 2

# Script directory
PG_EXTRACT_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source other libraries if not already done
if ! type log_info &>/dev/null; then
  source "$PG_EXTRACT_SCRIPT_DIR/logger.sh"
fi

# Helper function to execute PostgreSQL commands silently (no output in logs)
execute_pg_command() {
  local user="$1"
  local command="$2"
  su - "$user" -c "psql -c \"$command\"" > /dev/null 2>&1
  return $?
}

# Helper function to execute PostgreSQL queries that need to return a value
execute_pg_query() {
  local user="$1"
  local query="$2"
  local output
  output=$(su - "$user" -c "psql -t -c \"$query\"" 2>/dev/null)
  local status=$?
  echo "$output"
  return $status
}

# Helper function to extract SCRAM-SHA-256 hash directly
extract_hash_scram_direct() {
  local username="$1"
  local output_file="$2"
  
  # Try to extract from pg_authid directly
  local hash
  hash=$(execute_pg_query "postgres" "SELECT '\"${username}\" \"' || rolpassword || '\"' FROM pg_authid WHERE rolname='${username}'")
  
  if [ -n "$hash" ]; then
    echo "$hash" > "$output_file"
    return 0
  fi
  
  return 1
}

# Function to extract password hash for a user
extract_hash() {
  local username="$1"
  local output_file="$2"
  
  # Check if parameters are provided
  if [ -z "$username" ] || [ -z "$output_file" ]; then
    log_error "Missing parameters. Usage: extract_hash <username> <output_file>"
    return 1
  fi
  
  log_info "Extracting password hash for user: $username"
  
  # Check authentication type (default to scram-sha-256 if not set)
  local auth_type="${PGB_AUTH_TYPE:-scram-sha-256}"
  log_info "Using authentication type: $auth_type"
  
  if [ "$auth_type" = "plain" ]; then
    # For plain auth, we can just store the plain password directly
    if [ -n "$PG_SUPERUSER_PASSWORD" ] && [ "$username" = "postgres" ]; then
      echo "\"${username}\" \"${PG_SUPERUSER_PASSWORD}\"" > "$output_file"
      log_info "Created plain auth entry for user: $username"
      return 0
    else
      log_error "Plain authentication requested but password not available for $username"
      return 1
    fi
  fi
  
  # Method 0: Check if password encryption is properly set up
  local pg_encryption
  pg_encryption=$(su - postgres -c "psql -t -c \"SHOW password_encryption;\"" 2>/dev/null | tr -d ' \n\r\t')
  
  if [ "$auth_type" = "scram-sha-256" ] && [ "$pg_encryption" != "scram-sha-256" ]; then
    log_warn "PostgreSQL password_encryption ($pg_encryption) doesn't match auth_type ($auth_type)"
    log_warn "This may cause password hash extraction to fail"
    
    # Force set password_encryption to scram-sha-256
    su - postgres -c "psql -c \"ALTER SYSTEM SET password_encryption = 'scram-sha-256';\"" > /dev/null 2>&1
    su - postgres -c "psql -c \"SELECT pg_reload_conf();\"" > /dev/null 2>&1
    log_info "Updated PostgreSQL configuration to use scram-sha-256 password encryption"
    
    # Reset the superuser password to force rehashing with scram-sha-256
    if [ -n "$PG_SUPERUSER_PASSWORD" ] && [ "$username" = "postgres" ]; then
      su - postgres -c "psql -c \"ALTER USER postgres PASSWORD '${PG_SUPERUSER_PASSWORD}';\""  > /dev/null 2>&1
      log_info "Reset superuser password with scram-sha-256 encryption"
    fi
  fi
  
  # For SCRAM-SHA-256 or MD5, extract the hash from PostgreSQL
  
  # Method 1: Direct query using pg_catalog.pg_authid (prioritize this method first)
  log_info "Trying direct query method first"
  if password_hash=$(su - postgres -c "psql -t -c \"SELECT rolpassword FROM pg_catalog.pg_authid WHERE rolname='${username}';\"" 2>/dev/null); then
    if [ -n "$password_hash" ]; then
      # Trim whitespace and add quotes
      password_hash=$(echo "$password_hash" | tr -d ' \n\r\t')
      # Format for pgbouncer authentication
      echo "\"${username}\" \"${password_hash}\"" > "$output_file"
      
      # Verify the hash format is correct for SCRAM-SHA-256
      if [ "$auth_type" = "scram-sha-256" ]; then
        if grep -q "SCRAM-SHA-256" "$output_file"; then
          log_info "Successfully extracted SCRAM-SHA-256 password hash with direct query method"
          return 0
        else
          log_warn "Password hash does not appear to be in SCRAM-SHA-256 format"
          log_warn "Trying to fix password encryption and retry..."
          
          # Force re-encryption of password with scram-sha-256
          if [ -n "$PG_SUPERUSER_PASSWORD" ] && [ "$username" = "postgres" ]; then
            su - postgres -c "psql -c \"ALTER USER postgres PASSWORD '${PG_SUPERUSER_PASSWORD}';\""  > /dev/null 2>&1
            log_info "Forced re-encryption of superuser password"
            
            # Try extracting again after forcing re-encryption
            password_hash=$(su - postgres -c "psql -t -c \"SELECT rolpassword FROM pg_catalog.pg_authid WHERE rolname='${username}';\"" 2>/dev/null | tr -d ' \n\r\t')
            echo "\"${username}\" \"${password_hash}\"" > "$output_file"
            
            if grep -q "SCRAM-SHA-256" "$output_file"; then
              log_info "Successfully extracted SCRAM-SHA-256 password hash after re-encryption"
              return 0
            else
              log_warn "Still unable to get proper SCRAM-SHA-256 hash format"
            fi
          fi
        fi
      else
        log_info "Successfully extracted password hash to $output_file"
        return 0
      fi
    fi
  fi
  
  # Method 2: Have postgres create a temp file with the password hash directly
  # This avoids permission issues with writing to files created by root
  if [ "$auth_type" = "scram-sha-256" ]; then
    # For SCRAM-SHA-256, we need to use pg_authid instead of pg_shadow
    if su - postgres -c "psql -t -c \"COPY (SELECT '\\\"${username}\\\" \\\"' || rolpassword || '\\\"' FROM pg_authid WHERE rolname='${username}') TO STDOUT\" > \"$output_file\" 2>/dev/null"; then
      # Check if we got a valid result
      if [ -s "$output_file" ]; then
        log_info "Successfully extracted SCRAM-SHA-256 password hash from pg_authid to $output_file"
        
        # Verify the hash format is correct for SCRAM-SHA-256
        if ! grep -q "SCRAM-SHA-256" "$output_file"; then
          log_warn "Password hash does not appear to be in SCRAM-SHA-256 format"
          log_warn "Make sure PostgreSQL password_encryption is set to 'scram-sha-256'"
          log_warn "You may need to reset the password to get it in the correct format"
          
          # Try force re-encryption as a last attempt
          if [ -n "$PG_SUPERUSER_PASSWORD" ] && [ "$username" = "postgres" ]; then
            su - postgres -c "psql -c \"ALTER USER postgres PASSWORD '${PG_SUPERUSER_PASSWORD}';\""  > /dev/null 2>&1
            log_info "Last attempt: Forced re-encryption of superuser password"
            
            # Try again with COPY method
            su - postgres -c "psql -t -c \"COPY (SELECT '\\\"${username}\\\" \\\"' || rolpassword || '\\\"' FROM pg_authid WHERE rolname='${username}') TO STDOUT\" > \"$output_file\" 2>/dev/null"
            
            if grep -q "SCRAM-SHA-256" "$output_file"; then
              log_info "Successfully extracted SCRAM-SHA-256 password hash after final re-encryption"
              return 0
            fi
          fi
          
          return 1
        fi
        
        return 0
      else
        log_warn "Method 2 with pg_authid succeeded but produced an empty file, trying alternate method"
      fi
    else
      log_warn "Method 2 with pg_authid failed, trying alternate method"
    fi
  else
    # For MD5 or other methods, use pg_shadow
    if su - postgres -c "psql -t -c \"COPY (SELECT '\\\"${username}\\\" \\\"' || passwd || '\\\"' FROM pg_shadow WHERE usename='${username}') TO STDOUT\" > \"$output_file\" 2>/dev/null"; then
      # Check if we got a valid result
      if [ -s "$output_file" ]; then
        log_info "Successfully extracted password hash to $output_file"
        return 0
      else
        log_warn "Method 2 succeeded but produced an empty file, trying alternate method"
      fi
    else
      log_warn "Method 2 failed, trying alternate method"
    fi
  fi
  
  # Method 3: Use simpler output format and post-process
  local temp_raw="/tmp/pg_extract_$(date +%s)_$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 8).raw"
  
  if [ "$auth_type" = "scram-sha-256" ]; then
    # For SCRAM-SHA-256, we need to use pg_authid instead of pg_shadow
    if su - postgres -c "psql -t -c \"SELECT rolpassword FROM pg_authid WHERE rolname='${username}'\" > \"$temp_raw\" 2>/dev/null"; then
      # Check if we got a valid result
      if [ -s "$temp_raw" ]; then
        # Trim whitespace and add quotes - do this from the root account since we can read the file
        passwd=$(cat "$temp_raw" | tr -d ' \n\r\t')
        # Format for pgbouncer authentication
        echo "\"${username}\" \"${passwd}\"" > "$output_file"
        
        # Verify the hash format is correct for SCRAM-SHA-256
        if ! grep -q "SCRAM-SHA-256" "$output_file"; then
          log_warn "Password hash does not appear to be in SCRAM-SHA-256 format"
          log_warn "Make sure PostgreSQL password_encryption is set to 'scram-sha-256'"
          log_warn "You may need to reset the password to get it in the correct format"
          
          # One last attempt with forced password reset
          if [ -n "$PG_SUPERUSER_PASSWORD" ] && [ "$username" = "postgres" ]; then
            # Force password_encryption to be scram-sha-256
            su - postgres -c "psql -c \"ALTER SYSTEM SET password_encryption = 'scram-sha-256';\"" > /dev/null 2>&1
            su - postgres -c "psql -c \"SELECT pg_reload_conf();\"" > /dev/null 2>&1
            # Reset the password to force rehashing
            su - postgres -c "psql -c \"ALTER USER postgres PASSWORD '${PG_SUPERUSER_PASSWORD}';\""  > /dev/null 2>&1
            log_info "Final attempt: Reset password with forced scram-sha-256 encryption"
            
            # Try extraction one more time
            su - postgres -c "psql -t -c \"SELECT rolpassword FROM pg_authid WHERE rolname='${username}'\" > \"$temp_raw\" 2>/dev/null"
            passwd=$(cat "$temp_raw" | tr -d ' \n\r\t')
            echo "\"${username}\" \"${passwd}\"" > "$output_file"
            
            if grep -q "SCRAM-SHA-256" "$output_file"; then
              log_info "Successfully extracted SCRAM-SHA-256 password hash after final attempt"
            else
              log_error "Failed to get SCRAM-SHA-256 hash even after forced re-encryption"
              # Clean up temp files
              su - postgres -c "rm -f \"$temp_raw\"" 2>/dev/null
              return 1
            fi
          else
            # Clean up temp files
            su - postgres -c "rm -f \"$temp_raw\"" 2>/dev/null
            return 1
          fi
        fi
        
        log_info "Successfully extracted SCRAM-SHA-256 password hash from pg_authid"
        # Clean up temp files
        su - postgres -c "rm -f \"$temp_raw\"" 2>/dev/null
        return 0
      else
        log_error "Method 3 with pg_authid succeeded but password hash extraction returned empty result"
        su - postgres -c "rm -f \"$temp_raw\"" 2>/dev/null
      fi
    else
      log_error "Method 3 with pg_authid failed"
    fi
  else
    # For MD5 or other methods, use pg_shadow
    if su - postgres -c "psql -t -c \"SELECT passwd FROM pg_shadow WHERE usename='${username}'\" > \"$temp_raw\" 2>/dev/null"; then
      # Check if we got a valid result
      if [ -s "$temp_raw" ]; then
        # Trim whitespace and add quotes - do this from the root account since we can read the file
        passwd=$(cat "$temp_raw" | tr -d ' \n\r\t')
        # Format for pgbouncer authentication
        echo "\"${username}\" \"${passwd}\"" > "$output_file"
        
        log_info "Successfully extracted password hash to $output_file"
        # Clean up temp files
        su - postgres -c "rm -f \"$temp_raw\"" 2>/dev/null
        return 0
      else
        log_error "Method 3 succeeded but password hash extraction returned empty result"
        su - postgres -c "rm -f \"$temp_raw\"" 2>/dev/null
      fi
    else
      log_error "Method 3 failed"
    fi
  fi
  
  log_error "All methods failed to extract password hash"
  
  # Final fallback - if we have a plain password, warn and use it
  if [ -n "$PG_SUPERUSER_PASSWORD" ] && [ "$username" = "postgres" ]; then
    log_warn "Using plain text password as last resort (this is not secure)"
    echo "\"${username}\" \"${PG_SUPERUSER_PASSWORD}\"" > "$output_file"
    log_warn "Please check PostgreSQL configuration and fix password encryption method"
    return 0
  fi
  
  return 1
}

# Main function for password hash extraction
extract_password_hash() {
  local username="$1"
  local auth_type="${2:-scram-sha-256}"
  local output_file="$3"
  local PG_SUPERUSER_PASSWORD="${4:-}"

  log_info "Extracting password hash for user: $username"
  log_info "Using authentication type: $auth_type"
  
  # Ensure we're using the right encryption method first
  if [ "$auth_type" = "scram-sha-256" ]; then
    # Check if scram-sha-256 is enabled
    local current_encryption
    current_encryption=$(execute_pg_query "postgres" "SHOW password_encryption" | tr -d '[:space:]')
    
    if [ "$current_encryption" != "scram-sha-256" ]; then
      log_info "Trying direct query method first"
      
      # Try to extract hash with direct query first without modifying anything
      if extract_hash_scram_direct "$username" "$output_file"; then
        log_info "Successfully extracted SCRAM-SHA-256 password hash with direct query method"
        return 0
      fi
      
      # If we have a password, try to update the password encoding method
      if [ -n "$PG_SUPERUSER_PASSWORD" ]; then
        # Update PostgreSQL configuration to use scram-sha-256
        execute_pg_command "postgres" "ALTER SYSTEM SET password_encryption = 'scram-sha-256';"
        execute_pg_command "postgres" "SELECT pg_reload_conf();"
        
        log_info "Updated PostgreSQL configuration to use scram-sha-256 password encryption"
        
        # Reset the password to force re-encryption with scram-sha-256
        execute_pg_command "postgres" "ALTER USER postgres PASSWORD '${PG_SUPERUSER_PASSWORD}';"
        log_info "Reset superuser password with scram-sha-256 encryption"
        
        # Try again after changing encryption settings
        if extract_hash_scram_direct "$username" "$output_file"; then
          log_info "Successfully extracted SCRAM-SHA-256 password hash after re-encryption"
          return 0
        fi
      fi
    else
      log_info "Trying direct query method first"
      
      # Try direct query method since scram-sha-256 is already enabled
      if extract_hash_scram_direct "$username" "$output_file"; then
        log_info "Successfully extracted SCRAM-SHA-256 password hash with direct query method"
        return 0
      fi
      
      # If we have a password, try to reset it to ensure it uses scram-sha-256
      if [ -n "$PG_SUPERUSER_PASSWORD" ]; then
        # Reset the password to force re-encryption with scram-sha-256
        execute_pg_command "postgres" "ALTER USER postgres PASSWORD '${PG_SUPERUSER_PASSWORD}';"
        log_info "Forced re-encryption of superuser password"
        
        # Try again after resetting password
        if extract_hash_scram_direct "$username" "$output_file"; then
          log_info "Successfully extracted SCRAM-SHA-256 password hash after re-encryption"
          return 0
        fi
      fi
    fi
    
    # If direct method fails, try extracting using pg_authid COPY command
    log_info "Trying pg_authid extraction method"
    if su - postgres -c "psql -t -c \"COPY (SELECT '\\\"${username}\\\" \\\"' || rolpassword || '\\\"' FROM pg_authid WHERE rolname='${username}') TO STDOUT\" > \"$output_file\" 2>/dev/null"; then
      log_info "Successfully extracted SCRAM-SHA-256 password hash from pg_authid to $output_file"
      return 0
    fi
    
    # Last resort if we have a password, force reset and try again
    if [ -n "$PG_SUPERUSER_PASSWORD" ]; then
      log_info "Last attempt: Forced re-encryption of superuser password"
      execute_pg_command "postgres" "ALTER USER postgres PASSWORD '${PG_SUPERUSER_PASSWORD}';"
      
      if su - postgres -c "psql -t -c \"COPY (SELECT '\\\"${username}\\\" \\\"' || rolpassword || '\\\"' FROM pg_authid WHERE rolname='${username}') TO STDOUT\" > \"$output_file\" 2>/dev/null"; then
        log_info "Successfully extracted SCRAM-SHA-256 password hash after final re-encryption"
        return 0
      fi
    fi
    
    # Try pg_shadow (older PostgreSQL versions)
    log_info "Trying pg_shadow extraction method"
    if su - postgres -c "psql -t -c \"COPY (SELECT '\\\"${username}\\\" \\\"' || passwd || '\\\"' FROM pg_shadow WHERE usename='${username}') TO STDOUT\" > \"$output_file\" 2>/dev/null"; then
      log_info "Successfully extracted password hash to $output_file"
      return 0
    fi
    
    # Final attempt with direct configuration change
    if [ -n "$PG_SUPERUSER_PASSWORD" ]; then
      log_info "Final recovery attempt: direct configuration change"
      
      # Force configuration change
      execute_pg_command "postgres" "ALTER SYSTEM SET password_encryption = 'scram-sha-256';"
      execute_pg_command "postgres" "SELECT pg_reload_conf();"
      
      execute_pg_command "postgres" "ALTER USER postgres PASSWORD '${PG_SUPERUSER_PASSWORD}';"
      log_info "Final attempt: Reset password with forced scram-sha-256 encryption"
      
      # Try direct extraction again
      if extract_hash_scram_direct "$username" "$output_file"; then
        log_info "Successfully extracted SCRAM-SHA-256 password hash after final attempt"
        return 0
      fi
    fi
    
    # If all methods fail, we cannot extract a SCRAM-SHA-256 hash
    log_error "Failed to extract SCRAM-SHA-256 password hash"
    return 1
  elif [ "$auth_type" = "md5" ]; then
    # Extract MD5 hash
    if su - postgres -c "psql -t -c \"SELECT '\\\"${username}\\\" \\\"md5' || md5('${username}' || '${PG_SUPERUSER_PASSWORD}') || '\\\"'\" > \"$output_file\" 2>/dev/null"; then
      log_info "Successfully extracted MD5 password hash to $output_file"
      return 0
    fi
    
    # Try pg_authid method for MD5
    if su - postgres -c "psql -t -c \"COPY (SELECT '\\\"${username}\\\" \\\"' || rolpassword || '\\\"' FROM pg_authid WHERE rolname='${username}') TO STDOUT\" > \"$output_file\" 2>/dev/null"; then
      log_info "Successfully extracted MD5 password hash from pg_authid"
      return 0
    fi
    
    log_error "Failed to extract MD5 password hash"
    return 1
  else
    # Plain auth (not recommended for production)
    if [ -n "$PG_SUPERUSER_PASSWORD" ]; then
      echo "\"$username\" \"$PG_SUPERUSER_PASSWORD\"" > "$output_file"
      log_info "Created plain auth entry for user: $username"
      return 0
    else
      log_error "Cannot create plain auth entry (password not provided)"
      return 1
    fi
  fi
}

# If script is run directly, use command line parameters
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # If run directly, we need to source the logger first
  SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
  source "$SCRIPT_DIR/logger.sh"
  
  extract_hash "$1" "$2"
  exit $?
fi 