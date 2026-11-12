# syntax=docker/dockerfile:1
# Enterprise Single Source of Truth Playwright CI/CD Container Image
# Strictly adheres to https://playwright.dev/docs/ci and enterprise zero-warning standards.
#
# Provides:
# - Ubuntu 24.04 LTS (Noble Numbat)
# - Playwright with pre-baked Chromium, Firefox, and WebKit browsers in /ms-playwright
# - All Linux OS audio, video, font, and X11/Wayland runtime dependencies
# - Node.js LTS & npm
# - Latest Bun runtime (/usr/local/bin/bun)
# - xvfb and headless shell pre-configured

ARG PLAYWRIGHT_VERSION=1.65.0
ARG PLAYWRIGHT_IMAGE_DIGEST=sha256:9beb546099e11f52d62e505537914870e01a67e0e6b00ae41da4775324e73dbe
FROM mcr.microsoft.com/playwright:v${PLAYWRIGHT_VERSION}-noble@${PLAYWRIGHT_IMAGE_DIGEST}

ARG PLAYWRIGHT_VERSION=1.65.0

# Set environment variables for noninteractive CI execution
ENV DEBIAN_FRONTEND=noninteractive \
    NEEDRESTART_MODE=a \
    PLAYWRIGHT_BROWSERS_PATH=/ms-playwright \
    PLAYWRIGHT_VERSION=${PLAYWRIGHT_VERSION} \
    CI=true \
    BUN_INSTALL=/opt/bun \
    PATH="/opt/bun/bin:${PATH}"

# Configure dpkg force-unsafe-io to eliminate fsync stalls on CoW/overlay filesystems,
# optionally trust internal CA certificate via BuildKit secret, and install Bun
RUN --mount=type=secret,id=internal_ca,required=false \
    --mount=type=cache,id=pw-apt-cache,target=/var/cache/apt,sharing=locked \
    echo "force-unsafe-io" > /etc/dpkg/dpkg.cfg.d/force-unsafe-io && \
    apt-get update -qq && \
    apt-get install -y --no-install-recommends curl ca-certificates unzip git && \
    if [ -s /run/secrets/internal_ca ]; then \
      cp /run/secrets/internal_ca /usr/local/share/ca-certificates/gt-internal-ca.crt && \
      update-ca-certificates; \
    fi && \
    mkdir -p /opt/bun && \
    curl -fsSL https://bun.sh/install | BUN_INSTALL=/opt/bun bash && \
    ln -sf /opt/bun/bin/bun /usr/local/bin/bun && \
    chmod 755 /opt/bun/bin/bun && \
    chmod -R 777 /ms-playwright && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/*

ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt \
    CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt

# Verify installations
RUN bun --version && \
    node --version && \
    npm --version && \
    ls -la /ms-playwright

LABEL org.opencontainers.image.title="Playwright CI SSoT Runner" \
      org.opencontainers.image.description="Dedicated enterprise Playwright CI container image for Gitea Actions" \
      org.opencontainers.image.version="${PLAYWRIGHT_VERSION}" \
      org.opencontainers.image.vendor="gt-dev" \
      org.opencontainers.image.source="https://git.gt-web-dev.com/gt-dev/actions"

WORKDIR /workspace
CMD ["/bin/bash"]
