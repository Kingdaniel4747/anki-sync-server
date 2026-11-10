#!/bin/bash
set -e

# =============================================================================
# Anki Sync Server Enhanced - Entrypoint
# =============================================================================

# -----------------------------------------------------------------------------
# Handle PUID/PGID for file permissions
# -----------------------------------------------------------------------------
PUID=${PUID:-1000}
PGID=${PGID:-1000}
for value in "$PUID" "$PGID"; do
    if ! [[ "$value" =~ ^[1-9][0-9]{0,9}$ ]] || (( value > 2147483647 )); then
        echo "PUID and PGID must be positive numeric IDs." >&2
        exit 1
    fi
done

if [ "$PGID" != "1000" ]; then
    groupmod -o -g "$PGID" anki
fi
if [ "$PUID" != "1000" ]; then
    usermod -o -u "$PUID" anki
fi

# Data and configuration are local. Leave the external backup share's ACLs alone.
for dir in /data /config /var/log/anki /var/lib/anki; do
    if [ "$(stat -c '%u:%g' "$dir")" != "$PUID:$PGID" ]; then
        chown -hR "$PUID:$PGID" "$dir"
    fi
done

run_as_anki() {
    umask 077
    exec setpriv --reuid anki --regid anki --init-groups --no-new-privs "$@"
}

# -----------------------------------------------------------------------------
# Configuration with defaults
# -----------------------------------------------------------------------------
export SYNC_BASE="${SYNC_BASE:-/data}"
export SYNC_HOST="${SYNC_HOST:-0.0.0.0}"
export SYNC_PORT="${SYNC_PORT:-8080}"
export LOG_LEVEL="${LOG_LEVEL:-info}"
export TZ="${TZ:-UTC}"

# Upstream enables hashed mode if this var exists at all, so leave it unset
if [ "$PASSWORDS_HASHED" = "true" ] || [ "$PASSWORDS_HASHED" = "1" ]; then
    export PASSWORDS_HASHED=1
else
    unset PASSWORDS_HASHED
fi

# Dashboard settings
export DASHBOARD_PORT="${DASHBOARD_PORT:-8081}"
export DASHBOARD_AUTH="${DASHBOARD_AUTH:-}"

# Version info
ANKI_VERSION=$(cat /anki_version.txt 2>/dev/null || echo "unknown")

# -----------------------------------------------------------------------------
# Logging functions
# -----------------------------------------------------------------------------
log_level_num() {
    case "$1" in
        debug) echo 0 ;;
        info)  echo 1 ;;
        warn)  echo 2 ;;
        error) echo 3 ;;
        *)     echo 1 ;;
    esac
}

CURRENT_LOG_LEVEL=$(log_level_num "$LOG_LEVEL")

log() {
    local level="$1"
    shift
    local level_num=$(log_level_num "$level")
    if [ "$level_num" -ge "$CURRENT_LOG_LEVEL" ]; then
        echo "[$(date '+%Y-%m-%d %H:%M:%S')] [${level^^}] $*"
    fi
}

log_debug() { log debug "$@"; }
log_info()  { log info "$@"; }
log_warn()  { log warn "$@"; }
log_error() { log error "$@"; }

# -----------------------------------------------------------------------------
# Graceful shutdown handler
# -----------------------------------------------------------------------------
shutdown_handler() {
    # bash 5.2 kills the shell mid-handler under set -e (fixed in 5.3)
    set +e
    log_info "Received shutdown signal, stopping gracefully..."
    for pid in "$SYNC_PID" "$BACKUP_PID" "$DASHBOARD_PID" "$MONITOR_PID"; do
        if [ -n "$pid" ]; then
            kill -TERM "$pid" 2>/dev/null
        fi
    done
    for pid in "$SYNC_PID" "$BACKUP_PID"; do
        if [ -n "$pid" ]; then
            wait "$pid"
        fi
    done

    log_info "Shutdown complete"
    exit "${1:-0}"
}

trap shutdown_handler SIGTERM SIGINT SIGQUIT

# -----------------------------------------------------------------------------
# Docker secrets support
# -----------------------------------------------------------------------------
while IFS= read -r var; do
    name="${var%%=*}"
    file="${var#*=}"
    base_name="${name%_FILE}"
    if [ -f "$file" ]; then
        export "$base_name"="$(cat "$file")"
        log_debug "Loaded secret from $file"
    else
        log_warn "Secret file not found: $file"
    fi
done < <(env | grep -E '^SYNC_USER[0-9]+_FILE=' | sort)

load_secret() {
    local var_name="$1"
    local file_var="${var_name}_FILE"
    local file_path="${!file_var}"

    if [ -n "$file_path" ] && [ -f "$file_path" ]; then
        export "$var_name"="$(cat "$file_path")"
        log_debug "Loaded secret for $var_name"
    fi
}

load_secret "DASHBOARD_AUTH"

# -----------------------------------------------------------------------------
# Import legacy configuration once, after reading Docker secrets.
export BACKUP_DIR="${BACKUP_DIR:-/backups}"
export LOG_DIR="/var/log/anki"
(run_as_anki sh -c 'test -w "$SYNC_BASE" && test -w /config') || {
    log_error "Anki data and config directories must be writable by PUID:PGID=$PUID:$PGID"
    exit 1
}
(run_as_anki python3 /usr/local/bin/service.py init)

# The workers read persisted settings instead of inheriting legacy secrets.
while IFS='=' read -r name _; do
    unset "$name"
done < <(env | grep -E '^(SYNC_USER[0-9]+(_FILE)?|DASHBOARD_AUTH(_FILE)?|PASSWORDS_HASHED)=')

[ -f /var/lib/anki/sync_count.txt ] || echo "0" > /var/lib/anki/sync_count.txt
cp /anki_version.txt /var/lib/anki/version.txt 2>/dev/null || true
date +%s > /var/lib/anki/start_time.txt

# -----------------------------------------------------------------------------
# Start the backup scheduler regardless of the initial backup setting.
run_as_anki python3 /usr/local/bin/service.py backups &
BACKUP_PID=$!

log_info "Starting dashboard on port $DASHBOARD_PORT"
run_as_anki python3 /usr/local/bin/dashboard.py &
DASHBOARD_PID=$!

# -----------------------------------------------------------------------------
# Monitor sync server output for sync/auth events
# -----------------------------------------------------------------------------
# Server request lines: request{uri="..." ip=...}: finished ... httpstatus=NNN
monitor_sync_output() {
    local logfile="$1"
    tail -F "$logfile" 2>/dev/null | sed -u 's/\x1b\[[0-9;]*m//g' | while IFS= read -r line; do
        case "$line" in
            *'finished'*'httpstatus='*) ;;
            *) continue ;;
        esac
        status=$(echo "$line" | grep -o 'httpstatus=[0-9]*' | head -1)
        status="${status#httpstatus=}"
        ip=$(echo "$line" | grep -o 'ip=[^ }]*' | head -1)
        ip="${ip#ip=}"; ip="${ip%\"}"; ip="${ip#\"}"

        # authenticated requests carry uid=; record their latency
        case "$line" in
            *'uid="'*)
                if [ "$status" = "200" ]; then
                    elap=$(echo "$line" | grep -o 'elap_ms=[0-9]*' | head -1)
                    elap="${elap#elap_ms=}"
                    uri=$(echo "$line" | grep -o 'uri="[^"]*"' | head -1)
                    [ -n "$elap" ] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] LATENCY ${uri} ms=${elap}" >> /var/log/anki/latency.log
                fi
                ;;
        esac

        case "$line" in
            *'uri="/sync/hostKey"'*)
                if [ "$status" = "200" ]; then
                    echo "[$(date '+%Y-%m-%d %H:%M:%S')] AUTH_SUCCESS ip=\"${ip:-unknown}\"" >> /var/log/anki/auth.log
                else
                    echo "[$(date '+%Y-%m-%d %H:%M:%S')] AUTH_FAILED ip=\"${ip:-unknown}\"" >> /var/log/anki/auth.log
                fi
                ;;
            *'uri="/sync/meta"'*)
                if [ "$status" = "200" ]; then
                    uid=$(echo "$line" | grep -o 'uid="[^"]*"' | head -1)
                    client=$(echo "$line" | grep -o 'client="[^"]*"' | head -1)
                    [ -n "$uid" ] && echo "[$(date '+%Y-%m-%d %H:%M:%S')] DEVICE ${uid} ${client}" >> /var/log/anki/devices.log
                fi
                ;;
            *'uri="/sync/finish"'*)
                if [ "$status" = "200" ]; then
                    uid=$(echo "$line" | grep -o 'uid="[^"]*"' | head -1)
                    uid="${uid#uid=\"}"; uid="${uid%\"}"
                    echo "[$(date '+%Y-%m-%d %H:%M:%S')] SYNC_COMPLETE uid=\"${uid:-unknown}\"" >> /var/log/anki/sync.log
                    count=$(cat /var/lib/anki/sync_count.txt 2>/dev/null || echo 0)
                    echo $((count + 1)) > /var/lib/anki/sync_count.txt
                fi
                ;;
        esac
    done
}

# Start the sync supervisor and monitor. The supervisor restarts only Anki
# when a user's credentials change.
log_info "Starting Anki sync service..."
run_as_anki python3 /usr/local/bin/service.py sync >> /var/log/anki/server.log 2>&1 &
SYNC_PID=$!
monitor_sync_output /var/log/anki/server.log &
MONITOR_PID=$!

wait -n "$SYNC_PID" "$BACKUP_PID" "$DASHBOARD_PID" && EXIT_CODE=0 || EXIT_CODE=$?
log_error "A required worker stopped (exit code: $EXIT_CODE)"
shutdown_handler "$(( EXIT_CODE == 0 ? 1 : EXIT_CODE ))"
