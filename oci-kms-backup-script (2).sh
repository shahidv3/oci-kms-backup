#!/bin/bash

# Strict mode for better error handling
set -euo pipefail

# Configuration - REPLACE THESE WITH YOUR ACTUAL VALUES
VAULT_OCID="ocid1.vault.oc1..your_vault_ocid"
COMPARTMENT_OCID="ocid1.compartment.oc1..your_compartment_ocid"
BACKUP_BUCKET="your-kms-backup-bucket"
BACKUP_DIR="/path/to/secure/backup/directory"
OCI_PROFILE="DEFAULT"  # OCI CLI configuration profile

# Create backup directory if it doesn't exist
mkdir -p "${BACKUP_DIR}"

# Log function
log() {
    local message="$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${message}" | tee -a "${BACKUP_DIR}/kms_backup.log"
}

# Error handling function
error_exit() {
    log "ERROR: $1" >&2
    exit 1
}

# Validate OCI CLI and required tools
validate_dependencies() {
    command -v oci >/dev/null 2>&1 || error_exit "OCI CLI is not installed. Please install Oracle Cloud Infrastructure CLI."
    command -v jq >/dev/null 2>&1 || error_exit "jq is not installed. Please install jq JSON processor."
    command -v openssl >/dev/null 2>&1 || error_exit "OpenSSL is not installed. Please install OpenSSL."
}

# Generate a secure encryption key
generate_encryption_key() {
    local key_path="${BACKUP_DIR}/backup_encryption.key"
    
    # Generate 256-bit key
    openssl rand -base64 32 > "${key_path}"
    chmod 600 "${key_path}"
    
    echo "${key_path}"
}

# Backup KMS keys for a specific vault
backup_vault_keys() {
    local backup_date=$(date +"%Y%m%d_%H%M%S")
    local backup_dir="${BACKUP_DIR}/${backup_date}"
    local encryption_key
    
    mkdir -p "${backup_dir}"
    
    # Generate encryption key
    encryption_key=$(generate_encryption_key)
    
    log "Starting KMS key backup for Vault: ${VAULT_OCID}"
    
    # List all keys in the vault
    oci --profile "${OCI_PROFILE}" kms management key list \
        --compartment-id "${COMPARTMENT_OCID}" \
        --vault-id "${VAULT_OCID}" \
        --all \
        | jq -r '.data[] | .id' | while read -r key_id; do
        
        # Get key details
        key_details=$(oci --profile "${OCI_PROFILE}" kms management key get \
            --key-id "${key_id}")
        
        key_name=$(echo "${key_details}" | jq -r '.data["display-name"]')
        safe_key_name=$(echo "${key_name}" | tr -cd '[:alnum:]_-')
        
        log "Backing up key: ${key_name}"
        
        # Export key metadata
        oci --profile "${OCI_PROFILE}" kms management key export \
            --key-id "${key_id}" \
            --output-file "${backup_dir}/${safe_key_name}_metadata.json"
        
        # List and export key versions
        oci --profile "${OCI_PROFILE}" kms management key-version list \
            --key-id "${key_id}" \
            --all \
            | jq -r '.data[].id' | while read -r version_id; do
            
            oci --profile "${OCI_PROFILE}" kms management key-version export \
                --key-id "${key_id}" \
                --key-version-id "${version_id}" \
                --output-file "${backup_dir}/${safe_key_name}_version_${version_id}.json"
        done
    done
    
    # Create encrypted tar archive
    tar -czf "${backup_dir}.tar.gz" -C "${BACKUP_DIR}" "${backup_date}"
    
    # Encrypt the archive
    openssl enc -aes-256-cbc -salt \
        -in "${backup_dir}.tar.gz" \
        -out "${backup_dir}.tar.gz.enc" \
        -pass file:"${encryption_key}"
    
    # Upload encrypted backup to OCI Object Storage
    oci --profile "${OCI_PROFILE}" os object put \
        --bucket-name "${BACKUP_BUCKET}" \
        --file "${backup_dir}.tar.gz.enc" \
        --name "vault_backup_${backup_date}.tar.gz.enc"
    
    # Cleanup
    rm -f "${backup_dir}.tar.gz" "${backup_dir}.tar.gz.enc"
    rm -rf "${backup_dir}"
    
    log "Vault key backup completed successfully"
}

# Main execution
main() {
    validate_dependencies
    backup_vault_keys
}

# Run the backup
main
