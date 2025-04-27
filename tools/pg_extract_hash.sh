#!/bin/bash
# pg_extract_hash.sh - Extract password hash from PostgreSQL
# Part of Milestone 2

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
    su - postgres -c "psql -c \"ALTER SYSTEM SET password_encryption = 'scram-sha-256';\""
    su - postgres -c "psql -c \"SELECT pg_reload_conf();\""
    log_info "Updated PostgreSQL configuration to use scram-sha-256 password encryption"
    
    # Reset the superuser password to force rehashing with scram-sha-256
    if [ -n "$PG_SUPERUSER_PASSWORD" ] && [ "$username" = "postgres" ]; then
      su - postgres -c "psql -c \"ALTER USER postgres PASSWORD '${PG_SUPERUSER_PASSWORD}';\""
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
            su - postgres -c "psql -c \"ALTER USER postgres PASSWORD '${PG_SUPERUSER_PASSWORD}';\""
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
            su - postgres -c "psql -c \"ALTER USER postgres PASSWORD '${PG_SUPERUSER_PASSWORD}';\""
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
            su - postgres -c "psql -c \"ALTER SYSTEM SET password_encryption = 'scram-sha-256';\""
            su - postgres -c "psql -c \"SELECT pg_reload_conf();\""
            # Reset the password to force rehashing
            su - postgres -c "psql -c \"ALTER USER postgres PASSWORD '${PG_SUPERUSER_PASSWORD}';\""
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

# If script is run directly, use command line parameters
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  # If run directly, we need to source the logger first
  SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")"
  source "$SCRIPT_DIR/logger.sh"
  
  extract_hash "$1" "$2"
  exit $?
fi 