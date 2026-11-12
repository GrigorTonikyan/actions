# syntax=docker/dockerfile:1
# Enterprise Alpine Application Builder & Runtime Base Images
# Targets:
# - runner:  Minimal Node.js LTS Alpine runtime (libc6-compat, CA trust, non-root nextjs:nodejs 1001:1001)
# - builder: Unified Node.js LTS + pinned Bun Alpine image (eliminates cross-stage node_modules copy on ZFS/overlay2)

ARG NODE_IMAGE=node:24-alpine@sha256:116b800c3754b440ee0aa3ed2f20f5bf3d99a554bfd9adeea09ea8017f6e85f5
ARG BUN_IMAGE=oven/bun:1.4.4-alpine@sha256:4cf82f5686b196504fe119db3fcd9185b191f82ece82c40680e597228ec6070a

FROM ${BUN_IMAGE} AS bun-source

FROM ${NODE_IMAGE} AS node-base

WORKDIR /app

RUN --mount=type=secret,id=internal_ca,required=false \
    apk add --no-cache libc6-compat ca-certificates && \
    if [ -s /run/secrets/internal_ca ]; then \
      cp /run/secrets/internal_ca /usr/local/share/ca-certificates/gt-internal-ca.crt && \
      update-ca-certificates; \
    fi

ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt \
    CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt

FROM node-base AS runner

RUN addgroup --system --gid 1001 nodejs && \
    adduser --system --uid 1001 --ingroup nodejs nextjs && \
    mkdir -p /app/.next && \
    chown -R nextjs:nodejs /app

ENV NODE_ENV=production \
    NEXT_TELEMETRY_DISABLED=1 \
    PORT=3000 \
    HOSTNAME="0.0.0.0"

LABEL org.opencontainers.image.title="Node Alpine Production Runner" \
      org.opencontainers.image.description="Pre-baked Node.js Alpine production runner with libc6-compat, CA trust, and nextjs:nodejs user" \
      org.opencontainers.image.vendor="gt-dev" \
      org.opencontainers.image.source="https://git.gt-web-dev.com/gt-dev/actions"

FROM node-base AS builder

COPY --from=bun-source /usr/local/bin/bun /usr/local/bin/bun

RUN ln -sf /usr/local/bin/bun /usr/local/bin/bunx && \
    chmod 0755 /usr/local/bin/bun && \
    node --version && \
    bun --version

LABEL org.opencontainers.image.title="Bun + Node Alpine Unified Builder" \
      org.opencontainers.image.description="Pre-baked Node.js LTS + Bun Alpine image with libc6-compat and internal CA trust" \
      org.opencontainers.image.vendor="gt-dev" \
      org.opencontainers.image.source="https://git.gt-web-dev.com/gt-dev/actions"
