# =============================================================================
# Anki Sync Server Enhanced - Comprehensive Docker Image
# =============================================================================
# Matches the toolchain Anki pins in rust-toolchain.toml
FROM rust:1.97.1-slim-trixie AS builder
RUN apt-get update && apt-get install -y \
    git \
    pkg-config \
    libssl-dev \
    protobuf-compiler \
    && rm -rf /var/lib/apt/lists/*
ARG ANKI_VERSION=26.09.4
RUN printf '%s\n' "$ANKI_VERSION" > /anki_version.txt \
    && cargo install --locked --git https://github.com/ankitects/anki.git \
       --tag "$ANKI_VERSION" anki-sync-server

# Build dashboard assets once and serve them locally at runtime.
FROM debian:trixie-slim AS dashboard-assets
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*
ARG TARGETARCH
WORKDIR /build
RUN set -eu; \
    case "$TARGETARCH" in \
        amd64) tailwind_arch=x64; sha=e47695cee3f0d90623a91f3939b08bdee610eb5ad99340adff9d4145b284d6cc ;; \
        arm64) tailwind_arch=arm64; sha=ffcd0d21dbd7c605dc12743ff0c0b47debc963c86b399674084c1c8f2c96ecad ;; \
        *) echo "Unsupported dashboard build architecture: $TARGETARCH" >&2; exit 1 ;; \
    esac; \
    curl -fsSL "https://github.com/tailwindlabs/tailwindcss/releases/download/v4.3.5/tailwindcss-linux-$tailwind_arch" -o /usr/local/bin/tailwindcss; \
    echo "$sha  /usr/local/bin/tailwindcss" | sha256sum -c -; \
    chmod +x /usr/local/bin/tailwindcss; \
    mkdir /assets; \
    curl -fsSL https://cdn.jsdelivr.net/npm/chart.js@4.6.1/dist/chart.umd.js -o /assets/chart.umd.js; \
    echo "338399fb5bafe598d21cfc471b0590b61ceb321a985fade4f68499b151f67fbf  /assets/chart.umd.js" | sha256sum -c -; \
    curl -fsSL https://raw.githubusercontent.com/caddyserver/caddy/v2.11.9/LICENSE -o /caddy-LICENSE
COPY dashboard.css ./
COPY scripts/dashboard.py ./scripts/
COPY scripts/templates/ ./scripts/templates/
RUN tailwindcss -i dashboard.css -o /assets/dashboard.css --minify

# Runtime shares the builder's Debian and glibc generation.
FROM debian:trixie-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates wget bash tzdata sqlite3 \
    python3 python3-pip pigz util-linux \
    && rm -rf /var/lib/apt/lists/*

RUN pip3 install --break-system-packages --no-cache-dir \
    'Flask==3.1.3' 'Werkzeug==3.1.9' 'croniter==7.0.0' 'waitress==3.0.2'

COPY --from=caddy:2.11.9-alpine /usr/bin/caddy /usr/bin/caddy
COPY --from=dashboard-assets /caddy-LICENSE /usr/local/share/licenses/caddy/LICENSE
COPY --from=dashboard-assets /assets/ /usr/local/share/anki-dashboard/

# Create user and directories
RUN useradd -m -s /bin/bash -u 1000 anki \
    && mkdir -p /var/log/anki /var/lib/anki /data /backups /config /config/caddy \
    && touch /var/log/anki/sync.log /var/log/anki/auth.log /var/log/anki/backup.log /var/log/anki/server.log \
    && chown -R anki:anki /var/log/anki /var/lib/anki /data /backups /config /home/anki

# Copy binary and version info
COPY --from=builder /usr/local/cargo/bin/anki-sync-server /usr/local/bin/
COPY --from=builder /anki_version.txt /anki_version.txt

# Copy all scripts
COPY scripts/ /usr/local/bin/
COPY entrypoint.sh /usr/local/bin/
COPY healthcheck.sh /usr/local/bin/
COPY backup.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/*.sh /usr/local/bin/*.py 2>/dev/null || true

# Anki, dashboard and optional TLS
EXPOSE 8080 8081 80 443 8443

VOLUME ["/data", "/backups", "/config"]

HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD /usr/local/bin/healthcheck.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
