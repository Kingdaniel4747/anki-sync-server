#!/bin/bash
# =============================================================================
# Anki Sync Server - Restore Script
# =============================================================================

set -e

BACKUP_DIR="${BACKUP_DIR:-/backups}"
DATA_DIR="${SYNC_BASE:-/data}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [RESTORE] $*"
}

usage() {
    cat << EOF
Usage: restore.sh [OPTIONS] [backup_file]

Restore Anki sync server data from a backup.

Options:
  -l, --list       List available local backups
  -f, --force      Skip confirmation prompt
  -h, --help       Show this help message

Examples:
  restore.sh --list
  restore.sh anki_backup_20240101_030000.tar.gz
EOF
}

list_local_backups() {
    echo ""
    echo "Local backups in $BACKUP_DIR:"
    echo "============================================"
    if ls "$BACKUP_DIR"/anki_backup_*.tar.gz 1>/dev/null 2>&1; then
        for f in $(ls -1t "$BACKUP_DIR"/anki_backup_*.tar.gz); do
            size=$(du -h "$f" | cut -f1)
            date=$(stat -c %y "$f" | cut -d. -f1)
            name=$(basename "$f")
            echo "  $name  ($size)  $date"
        done
    else
        echo "  No backups found."
    fi
    echo ""
}

do_restore() {
    local backup_path="$1"
    
    log "Restoring from $(basename "$backup_path")..."
    
    # Create safety backup (SQLite-safe staging, same approach as backup.sh)
    SAFETY_BACKUP="pre_restore_$(date +%Y%m%d_%H%M%S).tar.gz"
    if [ -d "$DATA_DIR" ] && [ "$(ls -A "$DATA_DIR" 2>/dev/null)" ]; then
        log "Creating safety backup: $SAFETY_BACKUP"
        STAGING=$(mktemp -d "${BACKUP_DIR}/.staging.XXXXXX")
        (
            cd "$DATA_DIR"
            find . -type d -exec mkdir -p "$STAGING/{}" \;
            find . -type f ! -name '*.anki2*' ! -name '*.db' ! -name '*-wal' ! -name '*-shm' \
                -exec cp -a {} "$STAGING/{}" \;
            find . -type f \( -name '*.anki2' -o -name '*.db' \) -print0 | while IFS= read -r -d '' db; do
                if ! sqlite3 -cmd '.timeout 10000' "$db" ".backup '$STAGING/$db'" 2>/dev/null; then
                    cp -a "$db" "$STAGING/$db"
                    for sib in "$db-wal" "$db-shm"; do
                        [ -f "$sib" ] && cp -a "$sib" "$STAGING/$sib" || true
                    done
                fi
            done
            tar -C "$STAGING" -czf "${BACKUP_DIR}/${SAFETY_BACKUP}" .
        ) || log "WARN: safety backup failed"
        rm -rf "$STAGING"
    fi
    
    # Clear and restore
    log "Clearing current data..."
    rm -rf "${DATA_DIR:?}"/* 2>/dev/null || true
    
    log "Extracting backup..."
    tar -xzf "$backup_path" -C "$DATA_DIR"
    
    # Fix permissions
    chown -R anki:anki "$DATA_DIR" 2>/dev/null || true
    
    log "Restore complete!"
    [ -f "${BACKUP_DIR}/${SAFETY_BACKUP}" ] && log "Safety backup: $SAFETY_BACKUP"
    echo ""
    echo "IMPORTANT: Restart the container to apply changes."
}

# =============================================================================
# Parse arguments
# =============================================================================

LIST_LOCAL=false
FORCE=false
BACKUP_FILE=""

while [[ $# -gt 0 ]]; do
    case $1 in
        -l|--list)
            LIST_LOCAL=true
            shift
            ;;
        -f|--force)
            FORCE=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            BACKUP_FILE="$1"
            shift
            ;;
    esac
done

if [ "$LIST_LOCAL" = "true" ] || [ -z "$BACKUP_FILE" ]; then
    list_local_backups
    exit 0
fi

# Check backup exists
BACKUP_PATH="${BACKUP_DIR}/${BACKUP_FILE}"
if [ ! -f "$BACKUP_PATH" ]; then
    log "Error: Backup not found: $BACKUP_PATH"
    list_local_backups
    exit 1
fi

# Confirmation
if [ "$FORCE" != "true" ]; then
    echo ""
    echo "WARNING: This will overwrite all data in $DATA_DIR"
    echo "Backup: $BACKUP_PATH"
    echo ""
    read -p "Proceed? (yes/no): " confirm
    [ "$confirm" != "yes" ] && { echo "Cancelled."; exit 0; }
fi

do_restore "$BACKUP_PATH"
