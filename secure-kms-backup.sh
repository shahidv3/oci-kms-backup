#!/bin/bash

# Configuration
COMPARTMENT_ID="your_compartment_id"
VAULT_ENDPOINT="your_vault_endpoint"
BACKUP_BUCKET="kms-backup-bucket"
RETENTION_DAYS=90
BACKUP_DIR="/path/to/backup/directory"
OCI_VAULT_SECRET_ID="your_secret_id"  # ID of the secret containing encryption key

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
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "${BACKUP_DIR}/backup.log"
}

# Retrieve encryption key from OCI Vault
get_encryption_key() {
    log "Retrieving encryption key from OCI Vault"
    oci vault secret get-secret-bundle \
        --secret-id "${OCI_VAULT_SECRET_ID}" | \
        jq -r '.data."secret-bundle-content".content' | \
        base64 -d > "$ENCRYPTION_KEY"
    
    chmod 400 "$ENCRYPTION_KEY"
}

# Encrypt file function
encrypt_file() {
    local input_file=$1
    local output_file="${input_file}.enc"
    
    openssl enc -aes-256-cbc \
        -salt \
        -in "$input_file" \
        -out "$output_file" \
        -pass file:"$ENCRYPTION_KEY"
    
    echo "$output_file"
}

# Backup function
backup_key() {
    local key_id=$1
    local key_name=$2
    local backup_path="$3"
    
    log "Starting backup for key: ${key_name}"
    
    # Export master key
    oci kms management key export \
        --key-id "${key_id}" \
        --endpoint "${VAULT_ENDPOINT}" \
        --output-file "${backup_path}/${key_name}_master.json"
    
    # Get and export all key versions
    versions=$(oci kms management key-version list \
        --key-id "${key_id}" \
        --endpoint "${VAULT_ENDPOINT}" \
        --all)
    
    echo "$versions" | jq -r '.data[].id' | while read -r version_id; do
        oci kms management key-version export \
            --key-id "${key_id}" \
            --key-version-id "${version_id}" \
            --endpoint "${VAULT_ENDPOINT}" \
            --output-file "${backup_path}/${key_name}_version_${version_id}.json"
    done
}

# Upload backup function
upload_backup() {
    local backup_path=$1
    local encrypted_archive
    
    # Create tar archive
    tar -czf "${TEMP_DIR}/backup.tar.gz" -C "$(dirname "${backup_path}")" "$(basename "${backup_path}")"
    
    # Encrypt the archive
    encrypted_archive=$(encrypt_file "${TEMP_DIR}/backup.tar.gz")
    
    # Upload to OCI bucket
    oci os object put \
        --bucket-name "${BACKUP_BUCKET}" \
        --file "$encrypted_archive" \
        --name "kms_backup_${BACKUP_DATE}.tar.gz.enc"
    
    # Cleanup temporary files
    rm -f "$encrypted_archive" "${TEMP_DIR}/backup.tar.gz"
}

# Main execution
log "Starting KMS backup process"

# Retrieve encryption key
get_encryption_key

# Create backup directory with date
BACKUP_DATE=$(date +%Y%m%d)
BACKUP_PATH="${TEMP_DIR}/${BACKUP_DATE}"
mkdir -p "$BACKUP_PATH"

# Get all keys in compartment
keys=$(oci kms management key list \
    --compartment-id "${COMPARTMENT_ID}" \
    --endpoint "${VAULT_ENDPOINT}" \
    --all)

# Backup each key
echo "$keys" | jq -r '.data[] | [.id, .display-name] | @tsv' | while IFS=$'\t' read -r key_id key_name; do
    backup_key "$key_id" "$key_name" "$BACKUP_PATH"
done

# Upload backup
upload_backup "$BACKUP_PATH"

# Cleanup is handled by trap

log "Backup process completed successfully"
exit 0
