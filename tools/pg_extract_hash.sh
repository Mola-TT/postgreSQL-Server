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
  
  # For SCRAM-SHA-256 or MD5, extract the hash from PostgreSQL
  
  # Method 1: Have postgres create a temp file with the password hash directly
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
          return 1
        fi
        
        return 0
      else
        log_warn "Method 1 with pg_authid succeeded but produced an empty file, trying alternate method"
      fi
    else
      log_warn "Method 1 with pg_authid failed, trying alternate method"
    fi
  else
    # For MD5 or other methods, use pg_shadow
    if su - postgres -c "psql -t -c \"COPY (SELECT '\\\"${username}\\\" \\\"' || passwd || '\\\"' FROM pg_shadow WHERE usename='${username}') TO STDOUT\" > \"$output_file\" 2>/dev/null"; then
      # Check if we got a valid result
      if [ -s "$output_file" ]; then
        log_info "Successfully extracted password hash to $output_file"
        return 0
      else
        log_warn "Method 1 succeeded but produced an empty file, trying alternate method"
      fi
    else
      log_warn "Method 1 failed, trying alternate method"
    fi
  fi
  
  # Method 2: Create a temp SQL file as postgres user
  # First create a random filename in a secure manner
  local timestamp=$(date +%s)
  local random_str=$(tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 8)
  local temp_sql="/tmp/pg_extract_${timestamp}_${random_str}.sql"
  local temp_out="/tmp/pg_extract_${timestamp}_${random_str}.out"
  
  # Have postgres create and use the temp SQL file
  if [ "$auth_type" = "scram-sha-256" ]; then
    # For SCRAM-SHA-256, we need to use pg_authid instead of pg_shadow
    if su - postgres -c "echo \"SELECT '\\\"${username}\\\" \\\"' || rolpassword || '\\\"' FROM pg_authid WHERE rolname='${username}';\" > \"$temp_sql\" && psql -t -f \"$temp_sql\" > \"$temp_out\" 2>/dev/null"; then
      # Check if we got a valid result
      if [ -s "$temp_out" ]; then
        # Copy result to the output file
        cat "$temp_out" > "$output_file"
        # Clean up temp files as postgres user
        su - postgres -c "rm -f \"$temp_sql\" \"$temp_out\"" 2>/dev/null
        
        # Verify the hash format is correct for SCRAM-SHA-256
        if ! grep -q "SCRAM-SHA-256" "$output_file"; then
          log_warn "Password hash does not appear to be in SCRAM-SHA-256 format"
          log_warn "Make sure PostgreSQL password_encryption is set to 'scram-sha-256'"
          log_warn "You may need to reset the password to get it in the correct format"
          return 1
        fi
        
        log_info "Successfully extracted SCRAM-SHA-256 password hash from pg_authid"
        return 0
      else
        log_warn "Method 2 with pg_authid succeeded but produced an empty file, trying simpler approach"
      fi
    else
      log_warn "Method 2 with pg_authid failed, trying simpler approach"
    fi
  else
    # For MD5 or other methods, use pg_shadow
    if su - postgres -c "echo \"SELECT '\\\"${username}\\\" \\\"' || passwd || '\\\"' FROM pg_shadow WHERE usename='${username}';\" > \"$temp_sql\" && psql -t -f \"$temp_sql\" > \"$temp_out\" 2>/dev/null"; then
      # Check if we got a valid result
      if [ -s "$temp_out" ]; then
        # Copy result to the output file
        cat "$temp_out" > "$output_file"
        # Clean up temp files as postgres user
        su - postgres -c "rm -f \"$temp_sql\" \"$temp_out\"" 2>/dev/null
        log_info "Successfully extracted password hash to $output_file"
        return 0
      else
        log_warn "Method 2 succeeded but produced an empty file, trying simpler approach"
      fi
    else
      log_warn "Method 2 failed, trying simpler approach"
    fi
  fi
  
  # Method 3: Use simpler output format and post-process
  local temp_raw="/tmp/pg_extract_${timestamp}_${random_str}.raw"
  
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
          return 1
        fi
        
        log_info "Successfully extracted SCRAM-SHA-256 password hash from pg_authid"
        # Clean up temp files as postgres user
        su - postgres -c "rm -f \"$temp_raw\"" 2>/dev/null
        return 0
      else
        log_error "Method 3 with pg_authid succeeded but password hash extraction returned empty result"
        su - postgres -c "rm -f \"$temp_raw\"" 2>/dev/null
        return 1
      fi
    else
      log_error "All methods failed to extract SCRAM-SHA-256 password hash"
      return 1
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
        # Clean up temp files as postgres user
        su - postgres -c "rm -f \"$temp_raw\"" 2>/dev/null
        return 0
      else
        log_error "Method 3 succeeded but password hash extraction returned empty result"
        su - postgres -c "rm -f \"$temp_raw\"" 2>/dev/null
        return 1
      fi
    else
      log_error "All methods failed to extract password hash"
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