# syntax=docker/dockerfile:1.6
#
# Bamboo Valley WhatsApp Bridge — Fly.io image
#
# Single-process Go binary that:
#   1. maintains a WhatsApp multi-device WebSocket via whatsmeow
#   2. writes the whatsmeow session store to Supabase Postgres
#   3. writes all incoming messages to whatsapp_messages / whatsapp_chats / whatsapp_media
#   4. exposes a localhost-only REST API on 127.0.0.1:8080 for send/download/sync
#
# The only env var the container needs at runtime is DATABASE_URL.

# ---------- Build stage ----------
FROM golang:1.26-bookworm AS build

WORKDIR /src

# Cache dependencies first for faster rebuilds
COPY whatsapp-bridge/go.mod whatsapp-bridge/go.sum ./whatsapp-bridge/
WORKDIR /src/whatsapp-bridge
RUN go mod download

# Copy source
COPY whatsapp-bridge/ ./

# Static-ish build (CGO required for go-sqlite3 as an indirect dep, so we
# keep CGO enabled but link against glibc. The runtime image uses the same
# Debian base, so glibc versions match.)
ENV CGO_ENABLED=1
RUN go build -ldflags="-s -w" -o /out/whatsapp-bridge .

# ---------- Runtime stage ----------
FROM debian:bookworm-slim

# tini for correct signal handling (Fly sends SIGINT on shutdown),
# ca-certificates for outbound TLS to WhatsApp + Supabase,
# ffmpeg for voice-note transcoding (upstream feature; leave in for parity).
RUN apt-get update && apt-get install -y --no-install-recommends \
      tini \
      ca-certificates \
      ffmpeg \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=build /out/whatsapp-bridge /app/whatsapp-bridge

# The bridge needs a writable working dir for downloaded media
# (ephemeral — media is re-downloadable from WhatsApp servers via
# whatsmeow any time we still hold the media_key).
RUN mkdir -p /app/store && chmod 755 /app/store

ENV BIND_ADDR=127.0.0.1
ENV REST_PORT=8080

# Not exposing a port to Fly's public edge — REST API is localhost-only
# by design. If you ever need to hit it from outside the machine, use
# `fly ssh console` and curl against 127.0.0.1:8080, or use Fly private
# networking / flycast from another Fly app.

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/app/whatsapp-bridge"]
