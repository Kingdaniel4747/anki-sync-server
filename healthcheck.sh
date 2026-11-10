#!/bin/bash
# =============================================================================
# Anki Sync Server - Health Check
# =============================================================================

SYNC_PORT="${SYNC_PORT:-8080}"

wget -q -O /dev/null --timeout=3 "http://127.0.0.1:${DASHBOARD_PORT:-8081}/health" || exit 1
# A new installation can be healthy while waiting for its first sync user.
[ ! -f /var/lib/anki/sync-idle ] || exit 0

# Check the /health endpoint (available since Anki 24.06)
if wget -q -O /dev/null --timeout=5 "http://localhost:${SYNC_PORT}/health" 2>/dev/null; then
    exit 0
else
    # Fallback to root endpoint for older versions
    if wget -q --spider --timeout=5 "http://localhost:${SYNC_PORT}/" 2>/dev/null; then
        exit 0
    fi
    exit 1
fi
