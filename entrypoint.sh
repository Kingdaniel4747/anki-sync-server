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

if [ "$PUID" != "1000" ] || [ "$PGID" != "1000" ]; then
    groupmod -o -g "$PGID" anki 2>/dev/null || true
    usermod -o -u "$PUID" anki 2>/dev/null || true
fi

# Fix ownership of volumes created by older root-running releases
for dir in /data /backups /config /var/log/anki /var/lib/anki; do
    if [ -d "$dir" ] && [ "$(stat -c %u "$dir")" != "$(id -u anki)" ]; then
        chown -R anki:anki "$dir" 2>/dev/null || true
    fi
done

run_as_anki() {
    exec setpriv --reuid anki --regid anki --init-groups "$@"
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

# TLS settings
export TLS_ENABLED="${TLS_ENABLED:-false}"
export TLS_PORT="${TLS_PORT:-8443}"
export TLS_DOMAIN="${TLS_DOMAIN:-}"
export DASHBOARD_TLS_DOMAIN="${DASHBOARD_TLS_DOMAIN:-}"
export TLS_EMAIL="${TLS_EMAIL:-}"
export TLS_CERT="${TLS_CERT:-}"
export TLS_KEY="${TLS_KEY:-}"

# Fail2ban settings
export FAIL2BAN_ENABLED="${FAIL2BAN_ENABLED:-false}"
export FAIL2BAN_MAX_RETRIES="${FAIL2BAN_MAX_RETRIES:-5}"
export FAIL2BAN_BAN_TIME="${FAIL2BAN_BAN_TIME:-3600}"
export FAIL2BAN_FIND_TIME="${FAIL2BAN_FIND_TIME:-600}"

# Metrics settings
export METRICS_ENABLED="${METRICS_ENABLED:-false}"
export METRICS_PORT="${METRICS_PORT:-9090}"

# Dashboard settings
export DASHBOARD_ENABLED="${DASHBOARD_ENABLED:-true}"
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
# Notifications use the current settings from the configuration volume.
send_notification() {
    (run_as_anki python3 /usr/local/bin/service.py notify "$@") >/dev/null 2>&1 || true
}

# -----------------------------------------------------------------------------
# Graceful shutdown handler
# -----------------------------------------------------------------------------
shutdown_handler() {
    # bash 5.2 kills the shell mid-handler under set -e (fixed in 5.3)
    set +e
    log_info "Received shutdown signal, stopping gracefully..."
    for pid in "$SYNC_PID" "$BACKUP_PID" "$DASHBOARD_PID" "$METRICS_PID" "$CADDY_PID" "$MONITOR_PID"; do
        if [ -n "$pid" ]; then
            kill -TERM "$pid" 2>/dev/null
        fi
    done
    for pid in "$SYNC_PID" "$BACKUP_PID"; do
        if [ -n "$pid" ]; then
            wait "$pid"
        fi
    done

    pkill fail2ban 2>/dev/null || true

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

load_secret "NOTIFY_WEBHOOK_URL"
load_secret "EMAIL_PASS"
load_secret "S3_ACCESS_KEY"
load_secret "S3_SECRET_KEY"
load_secret "DASHBOARD_AUTH"

# -----------------------------------------------------------------------------
# Import legacy configuration once, after reading Docker secrets.
export BACKUP_DIR="${BACKUP_DIR:-/backups}"
export LOG_DIR="/var/log/anki"
(run_as_anki python3 /usr/local/bin/service.py init)

# The workers read persisted settings instead of inheriting legacy secrets.
while IFS='=' read -r name _; do
    unset "$name"
done < <(env | grep -E '^(SYNC_USER[0-9]+(_FILE)?|DASHBOARD_AUTH(_FILE)?|PASSWORDS_HASHED|EMAIL_PASS(_FILE)?|S3_(ACCESS|SECRET)_KEY(_FILE)?|NOTIFY_WEBHOOK_URL(_FILE)?)=')

[ -f /var/lib/anki/sync_count.txt ] || echo "0" > /var/lib/anki/sync_count.txt
[ -f /var/lib/anki/bytes_synced.txt ] || echo "0" > /var/lib/anki/bytes_synced.txt
cp /anki_version.txt /var/lib/anki/version.txt 2>/dev/null || true
date +%s > /var/lib/anki/start_time.txt

# -----------------------------------------------------------------------------
# Setup TLS with Caddy
# -----------------------------------------------------------------------------
setup_tls() {
    log_info "Setting up TLS with Caddy..."

    local CADDYFILE="/config/caddy/Caddyfile"
    mkdir -p /config/caddy

    if [ -n "$TLS_DOMAIN" ]; then
        log_info "Using Let's Encrypt for $TLS_DOMAIN"
        {
            echo "{"
            echo "    admin off"
            if [ -n "$TLS_EMAIL" ]; then
                printf '    email %s\n' "$TLS_EMAIL"
            fi
            echo "}"
        } > "$CADDYFILE"
        cat >> "$CADDYFILE" << EOF

${TLS_DOMAIN} {
    reverse_proxy 127.0.0.1:${SYNC_PORT}
    
    log {
        output file /var/log/anki/caddy.log
        format console
    }
}
EOF
        if [ -n "$DASHBOARD_TLS_DOMAIN" ]; then
            cat >> "$CADDYFILE" << EOF

${DASHBOARD_TLS_DOMAIN} {
    reverse_proxy 127.0.0.1:${DASHBOARD_PORT}
}
EOF
        fi
    elif [ -n "$TLS_CERT" ] && [ -n "$TLS_KEY" ] && [ -f "$TLS_CERT" ] && [ -f "$TLS_KEY" ]; then
        log_info "Using provided TLS certificates"
        log_info "Generating Caddyfile for manual certificates"
        cat > "$CADDYFILE" << EOF
{
    admin off
    auto_https disable_redirects
}

https://:${TLS_PORT} {
    tls ${TLS_CERT} ${TLS_KEY}

    reverse_proxy localhost:${SYNC_PORT}

    log {
        output file /var/log/anki/caddy.log
        format console
    }
}
EOF
    else
        log_info "Using self-signed certificate (set TLS_DOMAIN for Let's Encrypt)"
        log_info "Generating Caddyfile for self-signed certificate"
        cat > "$CADDYFILE" << EOF
{
    admin off
    auto_https disable_redirects
}

https://:${TLS_PORT} {
    tls internal {
        on_demand
    }

    reverse_proxy localhost:${SYNC_PORT}

    log {
        output file /var/log/anki/caddy.log
        format console
    }
}
EOF
    fi

    log_debug "Caddyfile created at $CADDYFILE"

    log_info "Starting Caddy on port $TLS_PORT..."
    XDG_DATA_HOME=/config/caddy caddy run --config "$CADDYFILE" --adapter caddyfile &
    CADDY_PID=$!

    sleep 2

    if kill -0 "$CADDY_PID" 2>/dev/null; then
        log_info "Caddy started successfully (PID: $CADDY_PID)"
    else
        log_error "Caddy failed to start"
        TLS_ENABLED="false"
    fi
}

if [ -n "$DASHBOARD_TLS_DOMAIN" ]; then
    if [ "$TLS_ENABLED" != "true" ] || [ -z "$TLS_DOMAIN" ] || [ "$DASHBOARD_TLS_DOMAIN" = "$TLS_DOMAIN" ]; then
        log_error "DASHBOARD_TLS_DOMAIN requires TLS_ENABLED=true and a separate TLS_DOMAIN."
        exit 1
    fi
    export DASHBOARD_COOKIE_SECURE=true
fi
if [ "$TLS_ENABLED" = "true" ]; then
    setup_tls
fi

# -----------------------------------------------------------------------------
# Setup fail2ban
# -----------------------------------------------------------------------------
if [ "$FAIL2BAN_ENABLED" = "true" ]; then
    if command -v fail2ban-server > /dev/null 2>&1; then
        log_info "Setting up fail2ban (max retries: $FAIL2BAN_MAX_RETRIES, ban time: ${FAIL2BAN_BAN_TIME}s)"

        cat > /etc/fail2ban/jail.d/anki.local << EOF
[anki-auth]
enabled = true
filter = anki-auth
logpath = /var/log/anki/auth.log
maxretry = ${FAIL2BAN_MAX_RETRIES}
bantime = ${FAIL2BAN_BAN_TIME}
findtime = ${FAIL2BAN_FIND_TIME}
ignoreip = 127.0.0.1/8 ::1
action = iptables-allports[name=anki, protocol=all]
EOF

        if fail2ban-server -b -x > /dev/null 2>&1; then
            log_info "Fail2ban started"
        else
            log_error "Fail2ban failed to start (container may need NET_ADMIN capability)"
        fi
    else
        log_warn "FAIL2BAN_ENABLED=true but fail2ban is not installed in this image"
    fi
fi

# -----------------------------------------------------------------------------
# Start the backup scheduler regardless of the initial backup setting.
run_as_anki python3 /usr/local/bin/service.py backups &
BACKUP_PID=$!

if [ "$DASHBOARD_ENABLED" = "true" ]; then
    log_info "Starting dashboard on port $DASHBOARD_PORT"
    run_as_anki python3 /usr/local/bin/dashboard.py &
    DASHBOARD_PID=$!
fi

# -----------------------------------------------------------------------------
# Setup metrics endpoint
# -----------------------------------------------------------------------------
if [ "$METRICS_ENABLED" = "true" ]; then
    log_info "Starting metrics server on port $METRICS_PORT"
    ANKI_VERSION="$ANKI_VERSION" run_as_anki python3 /usr/local/bin/metrics.py &
    METRICS_PID=$!
fi

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

workers=("$SYNC_PID" "$BACKUP_PID")
[ -z "$DASHBOARD_PID" ] || workers+=("$DASHBOARD_PID")
send_notification "Server started" "Anki Sync Server" &
wait -n "${workers[@]}" && EXIT_CODE=0 || EXIT_CODE=$?
log_error "A required worker stopped (exit code: $EXIT_CODE)"
shutdown_handler "$(( EXIT_CODE == 0 ? 1 : EXIT_CODE ))"
