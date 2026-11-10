#!/bin/bash
# Anki Sync Server - local backup

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

log "Cleaning up backups older than $RETENTION_DAYS days..."
DELETED_COUNT=$(find "$BACKUP_DIR" -maxdepth 1 -type f \( -name "anki_backup_*.tar.gz" -o -name "pre_restore_*.tar.gz" \) -mmin "+$(( 10#$RETENTION_DAYS * 1440 ))" -delete -print 2>/dev/null | wc -l || echo 0)
log "Deleted $DELETED_COUNT old local backup(s)"

BACKUP_COUNT=$(find "$BACKUP_DIR" -maxdepth 1 -type f -name "anki_backup_*.tar.gz" | wc -l)
TOTAL_SIZE=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1 || echo "unknown")
log "Backup complete. Total: $BACKUP_COUNT backups, $TOTAL_SIZE"
