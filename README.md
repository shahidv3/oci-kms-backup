# Complete Implementation Guide: OCI KMS Backup & Restore

<img width="672" alt="Screenshot 2024-11-25 at 4 37 20 PM" src="https://github.com/user-attachments/assets/c1f92034-021f-44a1-9d77-f31eb5d30bb8">


## Prerequisites

### 1. OCI Environment Setup
```bash
# Install OCI CLI
bash -c "$(curl -L https://raw.githubusercontent.com/oracle/oci-cli/master/scripts/install/install.sh)"

# Configure OCI CLI
oci setup config
```

### 2. Required IAM Components

```bash
# Create Dynamic Group for Bastion/Cloud Shell
oci iam dynamic-group create \
    --compartment-id <tenancy-ocid> \
    --name "kms-backup-hosts" \
    --description "Hosts that can perform KMS backup/restore" \
    --matching-rule "instance.compartment.id = '<compartment-ocid>'"

# Create Required Policies
oci iam policy create \
    --compartment-id <compartment-ocid> \
    --name "kms-backup-policy" \
    --description "Policy for KMS backup operations" \
    --statements '[
        "Allow dynamic-group kms-backup-hosts to manage keys in compartment <compartment-name>",
        "Allow dynamic-group kms-backup-hosts to manage objects in compartment <compartment-name>",
        "Allow dynamic-group kms-backup-hosts to read secrets in compartment <compartment-name>",
        "Allow dynamic-group kms-backup-hosts to manage vaults in compartment <compartment-name>"
    ]'
```

### 3. Create Required OCI Resources

```bash
# Create Vault for storing encryption key
oci kms vault create \
    --compartment-id <compartment-ocid> \
    --display-name "backup-keys-vault" \
    --vault-type DEFAULT

# Create Encryption Key in Vault
oci kms management key create \
    --compartment-id <compartment-ocid> \
    --display-name "backup-encryption-key" \
    --key-shape '{"algorithm":"AES","length":32}' \
    --endpoint <vault-endpoint>

# Generate and store backup encryption key
openssl rand -base64 32 | \
oci vault secret create-base64 \
    --compartment-id <compartment-ocid> \
    --secret-content-base64 - \
    --secret-name "backup-encryption-key" \
    --vault-id <vault-ocid> \
    --key-id <key-ocid>

# Create Object Storage Bucket
oci os bucket create \
    --compartment-id <compartment-ocid> \
    --name "kms-backup-bucket" \
    --versioning Enabled \
    --storage-tier Standard
```

## Implementation Steps

### 1. Setup Directory Structure

```bash
# Create directory structure
sudo mkdir -p /opt/oci/kms/{scripts,logs,config}
sudo chown -R opc:opc /opt/oci/kms

# Create config file
cat > /opt/oci/kms/config/settings.conf << 'EOF'
COMPARTMENT_ID="<your-compartment-id>"
VAULT_ENDPOINT="<your-vault-endpoint>"
BACKUP_BUCKET="kms-backup-bucket"
OCI_VAULT_SECRET_ID="<your-secret-id>"
RETENTION_DAYS=90
EOF

# Set proper permissions
chmod 600 /opt/oci/kms/config/settings.conf
```

### 2. Install Required Packages

```bash
# For Oracle Linux/RHEL
sudo yum install -y jq openssl tar gzip

# For Ubuntu
sudo apt-get install -y jq openssl tar gzip
```

### 3. Deploy Scripts

#### a. Create Main Backup Script
```bash
# Download and set up backup script
curl -o /opt/oci/kms/scripts/backup.sh https://raw.githubusercontent.com/your-repo/kms-backup.sh
chmod +x /opt/oci/kms/scripts/backup.sh
```

#### b. Create Main Restore Script
```bash
# Download and set up restore script
curl -o /opt/oci/kms/scripts/restore.sh https://raw.githubusercontent.com/your-repo/kms-restore.sh
chmod +x /opt/oci/kms/scripts/restore.sh
```

### 4. Set Up Monitoring

```bash
# Create Metrics Namespace
oci monitoring metric-data post \
    --metric-data '[{
        "namespace": "custom_kms_backup",
        "compartmentId": "<compartment-ocid>",
        "name": "backup_status",
        "datapoints": [{"timestamp": "2024-01-25T00:00:00Z", "value": 1}]
    }]'

# Create Alarm
oci monitoring alarm create \
    --compartment-id <compartment-ocid> \
    --display-name "KMS-Backup-Alert" \
    --metric-compartment-id <compartment-ocid> \
    --namespace "custom_kms_backup" \
    --query "backup_status[1m].count() == 0" \
    --severity "CRITICAL" \
    --body "KMS backup operation failed" \
    --metric-compartment-name <compartment-name> \
    --pending-duration "PT5M" \
    --resolution "1m" \
    --destinations '["<topic-ocid>"]'
```

### 5. Set Up Automated Execution

```bash
# Create cron job for backup
(crontab -l 2>/dev/null; echo "0 0 * * * /opt/oci/kms/scripts/backup.sh >> /opt/oci/kms/logs/backup.log 2>&1") | crontab -

# Create log rotation
sudo tee /etc/logrotate.d/kms-backup << EOF
/opt/oci/kms/logs/*.log {
    daily
    rotate 30
    compress
    missingok
    notifempty
    create 0640 opc opc
}
EOF
```

## Verification & Testing

### 1. Test Backup Process
```bash
# Run manual backup
/opt/oci/kms/scripts/backup.sh

# Verify backup files
oci os object list \
    --bucket-name kms-backup-bucket \
    --prefix "kms_backup_" \
    --output table
```

### 2. Test Restore Process
```bash
# Get backup date
BACKUP_DATE=$(date +%Y%m%d)

# Run restore test
/opt/oci/kms/scripts/restore.sh $BACKUP_DATE

# Verify restored keys
oci kms management key list \
    --compartment-id <compartment-id> \
    --endpoint <vault-endpoint> \
    --output table
```

## Recovery Procedures

### 1. Emergency Restore
```bash
# 1. Stop any running backup jobs
crontab -l | grep -v "backup.sh" | crontab -

# 2. Identify latest backup
LATEST_BACKUP=$(oci os object list \
    --bucket-name kms-backup-bucket \
    --prefix "kms_backup_" \
    --sort-by timeCreated \
    --sort-order DESC \
    --limit 1 \
    --query 'data[0].name' \
    --raw-output)

# 3. Extract date from backup name
BACKUP_DATE=$(echo $LATEST_BACKUP | grep -o '[0-9]\{8\}')

# 4. Run restore
/opt/oci/kms/scripts/restore.sh $BACKUP_DATE
```

### 2. Validation Steps
```bash
# Check key status
oci kms management key list \
    --compartment-id <compartment-id> \
    --endpoint <vault-endpoint> \
    --all \
    --output table

# Verify key versions
for key in $(oci kms management key list \
    --compartment-id <compartment-id> \
    --endpoint <vault-endpoint> \
    --query 'data[].id' \
    --raw-output); do
    echo "Checking versions for key: $key"
    oci kms management key-version list \
        --key-id "$key" \
        --endpoint <vault-endpoint> \
        --output table
done
```

## Maintenance Procedures

### 1. Regular Cleanup
```bash
# Clean old backups
/opt/oci/kms/scripts/cleanup.sh

# Verify cleanup
oci os object list \
    --bucket-name kms-backup-bucket \
    --output table
```

### 2. Key Rotation
```bash
# Rotate backup encryption key
oci vault secret update-base64 \
    --secret-id <secret-id> \
    --secret-content-base64 $(openssl rand -base64 32)
```

## Troubleshooting

### 1. Check Logs
```bash
# View backup logs
tail -f /opt/oci/kms/logs/backup.log

# View restore logs
tail -f /opt/oci/kms/logs/restore.log
```

### 2. Verify Permissions
```bash
# Check policy assignments
oci iam policy get \
    --policy-id <policy-id>

# Check dynamic group membership
oci iam dynamic-group get \
    --dynamic-group-id <dynamic-group-id>
```

### 3. Monitor Resource Usage
```bash
# Check bucket usage
oci os bucket get \
    --bucket-name kms-backup-bucket \
    --fields approximateCount,approximateSize

# Check vault status
oci kms vault get \
    --vault-id <vault-id>
```
