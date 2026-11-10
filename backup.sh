#!/bin/bash
# Anki Sync Server - local backup

set -euo pipefail

if [ "${ANKI_MANAGED_ENV:-}" != "1" ]; then
    if [ "$(id -u)" = "0" ]; then
        exec setpriv --reuid anki --regid anki --init-groups --no-new-privs python3 /usr/local/bin/service.py with-settings /usr/local/bin/backup.sh "$@"
    fi
    exec python3 /usr/local/bin/service.py with-settings /usr/local/bin/backup.sh "$@"
fi

BACKUP_DIR="${BACKUP_DIR:-/backups}"
STATE_DIR="${STATE_DIR:-/var/lib/anki}"
umask 077
DATA_DIR="${SYNC_BASE:-/data}"
RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-7}"
TIMESTAMP=$(date -u +%Y%m%d_%H%M%S_%N)
BACKUP_FILE="anki_backup_${TIMESTAMP}.tar.gz"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [BACKUP] $*"
}

log "Starting backup..."

if [ ! -d "$BACKUP_DIR" ] || [ ! -w "$BACKUP_DIR" ]; then
    log "ERROR: The backup destination is unavailable or not writable: $BACKUP_DIR"
    exit 1
fi

# The lock and SQLite staging files stay on the container's local storage.
exec 9>"$STATE_DIR/backup.lock"
flock -n -E 75 9
STAGING=""
ARCHIVE=""
cleanup() {
    [ -z "$STAGING" ] || rm -rf -- "$STAGING"
    [ -z "$ARCHIVE" ] || rm -f -- "$ARCHIVE"
}
trap cleanup EXIT
trap 'exit 143' TERM
STAGING=$(mktemp -d "${STATE_DIR}/backup-stage.XXXXXX")
ARCHIVE=$(mktemp "${BACKUP_DIR}/.archive.XXXXXX")
python3 /usr/local/bin/service.py snapshot "$DATA_DIR" "$STAGING" "$BACKUP_DIR"
tar -C "$STAGING" -I pigz -cf "$ARCHIVE" .
ARCHIVE_PATH="${BACKUP_DIR}/${BACKUP_FILE}"
# The temporary archive and final name are on the same filesystem.
mv -- "$ARCHIVE" "$ARCHIVE_PATH"

BACKUP_SIZE=$(du -sh "${BACKUP_DIR}/${BACKUP_FILE}" | cut -f1)
log "Backup created: $BACKUP_FILE ($BACKUP_SIZE)"

log "Cleaning up backups older than $RETENTION_DAYS days..."
DELETED_COUNT=$(find "$BACKUP_DIR" -maxdepth 1 -regextype posix-extended -type f \
    -regex '.*/(anki_backup|pre_restore)_[0-9]{8}_[0-9]{6}(_[0-9]{9})?\.tar\.gz' \
    -mmin "+$(( 10#$RETENTION_DAYS * 1440 ))" -delete -print | wc -l)
log "Deleted $DELETED_COUNT old local backup(s)"

BACKUP_COUNT=$(find "$BACKUP_DIR" -maxdepth 1 -type f -name "anki_backup_*.tar.gz" | wc -l)
TOTAL_SIZE=$(du -sh "$BACKUP_DIR" 2>/dev/null | cut -f1 || echo "unknown")
log "Backup complete. Total: $BACKUP_COUNT backups, $TOTAL_SIZE"
