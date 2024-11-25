#!/bin/bash

# Configuration
COMPARTMENT_ID="your_compartment_id"
VAULT_ENDPOINT="your_vault_endpoint"
BACKUP_BUCKET="kms-backup-bucket"
OCI_VAULT_SECRET_ID="your_secret_id"  # ID of the secret containing encryption key
RESTORE_DIR="/path/to/restore/directory"

# Create temporary directory with secure permissions
TEMP_DIR=$(mktemp -d)
chmod 700 "$TEMP_DIR"
ENCRYPTION_KEY="${TEMP_DIR}/encryption.key"

# Cleanup function
cleanup() {
    rm -rf "$TEMP_DIR"
}
trap cleanup EXIT

# Log function
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "${RESTORE_DIR}/restore.log"
}

# Get encryption key from vault
get_encryption_key() {
    log "Retrieving encryption key from OCI Vault"
    oci vault secret get-secret-bundle \
        --secret-id "${OCI_VAULT_SECRET_ID}" | \
        jq -r '.data."secret-bundle-content".content' | \
        base64 -d > "$ENCRYPTION_KEY"
    
    chmod 400 "$ENCRYPTION_KEY"
}

# Decrypt file function
decrypt_file() {
    local input_file=$1
    local output_file="${input_file%.*}"
    
    openssl enc -d -aes-256-cbc \
        -in "$input_file" \
        -out "$output_file" \
        -pass file:"$ENCRYPTION_KEY"
    
    echo "$output_file"
}

# Download and decrypt backup
download_backup() {
    local backup_date=$1
    local backup_file="kms_backup_${backup_date}.tar.gz.enc"
    
    # Download encrypted backup
    oci os object get \
        --bucket-name "${BACKUP_BUCKET}" \
        --name "${backup_file}" \
        --file "${TEMP_DIR}/${backup_file}"
    
    # Decrypt backup
    local decrypted_file=$(decrypt_file "${TEMP_DIR}/${backup_file}")
    
    # Extract backup
    tar -xzf "$decrypted_file" -C "$TEMP_DIR"
    
    # Find extracted directory
    find "$TEMP_DIR" -type d -name "${backup_date}"
}

# Restore key function
restore_key() {
    local key_file=$1
    local key_name=$2
    
    log "Restoring key: ${key_name}"
    
    # Import master key
    local key_id=$(oci kms management key import \
        --compartment-id "${COMPARTMENT_ID}" \
        --display-name "${key_name}" \
        --wrapped-import-key "file://${key_file}" \
        --endpoint "${VAULT_ENDPOINT}" \
        --query 'data.id' \
        --raw-output)
    
    # Import key versions
    local key_dir=$(dirname "$key_file")
    find "$key_dir" -name "${key_name}_version_*.json" | while read -r version_file; do
        oci kms management key-version import \
            --key-id "${key_id}" \
            --wrapped-import-key "file://${version_file}" \
            --endpoint "${VAULT_ENDPOINT}"
    done
    
    echo "$key_id"
}

# Validate restore function
validate_restore() {
    local key_id=$1
    local key_name=$2
    
    log "Validating restored key: ${key_name}"
    
    # Check key status
    local key_status=$(oci kms management key get \
        --key-id "${key_id}" \
        --endpoint "${VAULT_ENDPOINT}" \
        --query 'data.lifecycle-state' \
        --raw-output)
    
    if [[ "$key_status" != "ACTIVE" ]]; then
        log "ERROR: Key ${key_name} is not in ACTIVE state"
        return 1
    fi
    
    # Check key versions
    local versions=$(oci kms management key-version list \
        --key-id "${key_id}" \
        --endpoint "${VAULT_ENDPOINT}" \
        --all)
    
    if [[ $(echo "$versions" | jq '.data | length') -eq 0 ]]; then
        log "ERROR: No versions found for key ${key_name}"
        return 1
    fi
    
    return 0
}

# Main execution
if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <backup_date>"
    echo "Example: $0 20240125"
    exit 1
fi

BACKUP_DATE=$1
log "Starting KMS restore process for backup date: ${BACKUP_DATE}"

# Get encryption key
get_encryption_key

# Download and extract backup
BACKUP_PATH=$(download_backup "$BACKUP_DATE")

if [[ ! -d "$BACKUP_PATH" ]]; then
    log "ERROR: Backup not found or invalid"
    exit 1
fi

# Restore each key
find "$BACKUP_PATH" -name "*_master.json" | while read -r key_file; do
    key_name=$(basename "$key_file" "_master.json")
    
    # Restore key and versions
    key_id=$(restore_key "$key_file" "$key_name")
    
    # Validate restore
    if validate_restore "$key_id" "$key_name"; then
        log "Successfully restored key: ${key_name}"
    else
        log "Failed to restore key: ${key_name}"
    fi
done

log "Restore process completed"
exit 0
