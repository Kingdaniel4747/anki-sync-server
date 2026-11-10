#!/bin/bash
# Anki Sync Server - backup with optional S3 upload

set -euo pipefail

if [ "${ANKI_MANAGED_ENV:-}" != "1" ]; then
    if [ "$(id -u)" = "0" ]; then
        exec setpriv --reuid anki --regid anki --init-groups python3 /usr/local/bin/service.py with-settings /usr/local/bin/backup.sh "$@"
    fi
    exec python3 /usr/local/bin/service.py with-settings /usr/local/bin/backup.sh "$@"
fi

BACKUP_DIR="${BACKUP_DIR:-/backups}"
DATA_DIR="${SYNC_BASE:-/data}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"
TIMESTAMP=$(date -u +%Y%m%d_%H%M%S_%N)
BACKUP_FILE="anki_backup_${TIMESTAMP}.tar.gz"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [BACKUP] $*"
}

notify() {
    python3 /usr/local/bin/service.py notify "$1" "Anki Backup" || true
}

upload_to_s3() {
    if [ "${S3_BACKUP_ENABLED:-false}" != "true" ] || [ -z "${S3_BUCKET:-}" ]; then
        return 0
    fi

    log "Uploading to S3: $S3_BUCKET"

    python3 - <<'EOF'
import boto3
import os
import sys
from botocore.config import Config

endpoint = os.environ.get('S3_ENDPOINT', '')
bucket = os.environ.get('S3_BUCKET', '')
access_key = os.environ.get('S3_ACCESS_KEY', '')
secret_key = os.environ.get('S3_SECRET_KEY', '')
region = os.environ.get('S3_REGION', 'us-east-1')

if not bucket or not access_key or not secret_key:
    print("S3 credentials not fully configured")
    sys.exit(1)

kwargs = dict(
    aws_access_key_id=access_key,
    aws_secret_access_key=secret_key,
    region_name=region,
    config=Config(signature_version='s3v4'),
)
if endpoint:
    kwargs['endpoint_url'] = endpoint

try:
    s3 = boto3.client('s3', **kwargs)
    local_file = os.environ["ARCHIVE_PATH"]
    s3_key = "anki-backups/" + os.path.basename(local_file)
    print(f"Uploading {local_file} to s3://{bucket}/{s3_key}")
    s3.upload_file(local_file, bucket, s3_key)
    print("Upload complete")
except Exception as e:
    print(f"S3 upload failed ({type(e).__name__})")
    sys.exit(1)
EOF
    return $?
}

cleanup_s3() {
    if [ "${S3_BACKUP_ENABLED:-false}" != "true" ] || [ -z "${S3_BUCKET:-}" ]; then
        return 0
    fi

    log "Cleaning up old S3 backups..."

    python3 - <<'EOF'
import boto3
import os
from datetime import datetime, timedelta, timezone
from botocore.config import Config

endpoint = os.environ.get('S3_ENDPOINT', '')
bucket = os.environ.get('S3_BUCKET', '')
access_key = os.environ.get('S3_ACCESS_KEY', '')
secret_key = os.environ.get('S3_SECRET_KEY', '')
region = os.environ.get('S3_REGION', 'us-east-1')
retention_days = int(os.environ.get('BACKUP_RETENTION_DAYS', '7'))

kwargs = dict(
    aws_access_key_id=access_key,
    aws_secret_access_key=secret_key,
    region_name=region,
    config=Config(signature_version='s3v4'),
)
if endpoint:
    kwargs['endpoint_url'] = endpoint

try:
    s3 = boto3.client('s3', **kwargs)
    cutoff = datetime.now(timezone.utc) - timedelta(days=retention_days)
    deleted = 0
    pages = s3.get_paginator("list_objects_v2").paginate(Bucket=bucket, Prefix="anki-backups/")
    for page in pages:
        for obj in page.get("Contents", []):
            if obj["LastModified"] < cutoff:
                s3.delete_object(Bucket=bucket, Key=obj["Key"])
                print(f"Deleted: {obj['Key']}")
                deleted += 1
    print(f"Deleted {deleted} old S3 backups")
except Exception as e:
    print(f"S3 cleanup failed ({type(e).__name__})")
EOF
}

log "Starting backup..."

mkdir -p "$BACKUP_DIR"

# A shared lock covers both the scheduler and the CLI. Publish only complete archives.
exec 9>"$BACKUP_DIR/.backup.lock"
flock -n -E 75 9
STAGING=""
ARCHIVE=""
cleanup() {
    [ -z "$STAGING" ] || rm -rf -- "$STAGING"
    [ -z "$ARCHIVE" ] || rm -f -- "$ARCHIVE"
}
trap cleanup EXIT
trap 'exit 143' TERM
STAGING=$(mktemp -d "${BACKUP_DIR}/.staging.XXXXXX")
ARCHIVE=$(mktemp "${BACKUP_DIR}/.archive.XXXXXX")
python3 /usr/local/bin/service.py snapshot "$DATA_DIR" "$STAGING"
tar -C "$STAGING" -I pigz -cf "$ARCHIVE" .
export ARCHIVE_PATH="${BACKUP_DIR}/${BACKUP_FILE}"
mv -- "$ARCHIVE" "$ARCHIVE_PATH"

BACKUP_SIZE=$(du -sh "${BACKUP_DIR}/${BACKUP_FILE}" | cut -f1)
log "Backup created: $BACKUP_FILE ($BACKUP_SIZE)"

S3_STATUS="N/A"
if [ "$S3_BACKUP_ENABLED" = "true" ]; then
    if upload_to_s3; then
        S3_STATUS="OK"
        cleanup_s3
    else
        S3_STATUS="FAILED"
    fi
fi

log "Cleaning up backups older than $RETENTION_DAYS days..."
DELETED_COUNT=$(find "$BACKUP_DIR" -maxdepth 1 -type f \( -name "anki_backup_*.tar.gz" -o -name "pre_restore_*.tar.gz" \) -mmin "+$(( 10#$RETENTION_DAYS * 1440 ))" -delete -print 2>/dev/null | wc -l || echo 0)
log "Deleted $DELETED_COUNT old local backup(s)"

BACKUP_COUNT=$(find "$BACKUP_DIR" -maxdepth 1 -type f -name "anki_backup_*.tar.gz" | wc -l)
TOTAL_SIZE=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1 || echo "unknown")
log "Backup complete. Total: $BACKUP_COUNT backups, $TOTAL_SIZE"

notify "Backup finished
File: $BACKUP_FILE
Size: $BACKUP_SIZE
S3: $S3_STATUS
Total: $BACKUP_COUNT backups"

[ "$S3_STATUS" != "FAILED" ]
