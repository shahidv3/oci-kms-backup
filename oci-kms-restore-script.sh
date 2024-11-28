#!/bin/bash

# Strict mode for better error handling
set -euo pipefail

# Configuration - REPLACE THESE WITH YOUR ACTUAL VALUES
VAULT_OCID="ocid1.vault.oc1..your_vault_ocid"
COMPARTMENT_OCID="ocid1.compartment.oc1..your_compartment_ocid"
BACKUP_BUCKET="your-kms-backup-bucket"
RESTORE_DIR="/path/to/restore/directory"
OCI_PROFILE="DEFAULT"  # OCI CLI configuration profile

# Log function
log() {
    local message="$1"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] ${message}" | tee -a "${RESTORE_DIR}/kms_restore.log"
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

# Restore function
restore_vault_keys() {
    local backup_file=$1
    local encryption_key_path=$2

    # Create restore directory
    mkdir -p "${RESTORE_DIR}"

    # Decrypt the backup
    openssl enc -d -aes-256-cbc -salt \
        -in "${backup_file}" \
        -out "${RESTORE_DIR}/backup.tar.gz" \
        -pass file:"${encryption_key_path}"

    # Extract backup
    tar -xzf "${RESTORE_DIR}/backup.tar.gz" -C "${RESTORE_DIR}"

    # Find the extracted backup directory
    backup_dir=$(find "${RESTORE_DIR}" -maxdepth 1 -type d -name "*" | grep -v "${RESTORE_DIR}$")

    log "Starting key restoration from backup"

    # Restore each key
    for metadata_file in "${backup_dir}"/*_metadata.json; do
        if [[ ! -f "${metadata_file}" ]]; then
            log "No metadata files found. Skipping."
            continue
        }

        # Extract key details from metadata
        key_name=$(basename "${metadata_file}" | sed 's/_metadata.json//')
        
        log "Restoring key: ${key_name}"

        # Import the key
        restored_key=$(oci --profile "${OCI_PROFILE}" kms management key create \
            --compartment-id "${COMPARTMENT_OCID}" \
            --vault-id "${VAULT_OCID}" \
            --display-name "${key_name}" \
            --key-shape '{"algorithm":"AES", "length":256}')

        restored_key_id=$(echo "${restored_key}" | jq -r '.data.id')

        # Restore key versions
        for version_file in "${backup_dir}"/*"${key_name}"_version_*.json; do
            if [[ ! -f "${version_file}" ]]; then
                log "No version files found for ${key_name}. Skipping."
                continue
            }

            # Import key version
            oci --profile "${OCI_PROFILE}" kms management key-version import \
                --key-id "${restored_key_id}" \
                --key-version-export-file "${version_file}"
        done
    done

    # Cleanup
    rm -rf "${RESTORE_DIR}/backup.tar.gz" "${backup_dir}"

    log "Vault key restoration completed successfully"
}

# Usage function
usage() {
    echo "Usage: $0 <backup_file_path> <encryption_key_path>"
    echo "Example: $0 /path/to/vault_backup_20240101_120000.tar.gz.enc /path/to/encryption.key"
    exit 1
}

# Main execution
main() {
    # Check for correct number of arguments
    if [[ $# -ne 2 ]]; then
        usage
    fi

    validate_dependencies
    restore_vault_keys "$1" "$2"
}

# Run the restore
main "$@"
