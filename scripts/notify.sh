#!/bin/bash
exec python3 /usr/local/bin/service.py notify \
    "${1:-Test notification from Anki Sync Server}" "${2:-Anki Sync Server}"
