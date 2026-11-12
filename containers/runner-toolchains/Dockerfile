# syntax=docker/dockerfile:1
# Enterprise Pre-Cached CI/CD Toolchain Runner Image (runner-toolchains)
# Provides:
# - Ubuntu 24.04 LTS (Noble) + Playwright v1.65.0 browsers (/ms-playwright) & OS deps
# - Node.js LTS & npm
# - Pinned Bun runtime (/opt/bun/bin/bun -> /usr/local/bin/bun)
# - Pinned Astral uv + pre-installed Python 3.13 (/opt/uv & /opt/uv-python)
# - Rustup + Cargo + Rustc with pre-baked stable & nightly toolchains (rustfmt, clippy)
# - Dpkg force-unsafe-io & internal CA trust pre-configured

ARG PLAYWRIGHT_VERSION=1.65.0
ARG PLAYWRIGHT_IMAGE_DIGEST=sha256:9beb546099e11f52d62e505537914870e01a67e0e6b00ae41da4775324e73dbe
ARG PLAYWRIGHT_BASE_IMAGE=mcr.microsoft.com/playwright:v1.65.0-noble@sha256:9beb546099e11f52d62e505537914870e01a67e0e6b00ae41da4775324e73dbe
FROM ${PLAYWRIGHT_BASE_IMAGE}

ARG RUNNER_TOOLCHAINS_VERSION=1.0.0
ARG PLAYWRIGHT_VERSION=1.65.0
ARG BUN_VERSION=1.4.4
ARG UV_VERSION=0.10.9
ARG PYTHON_VERSION=3.13
ARG RUST_DEFAULT_TOOLCHAIN=stable
ARG RUST_NIGHTLY_TOOLCHAIN=nightly

ENV DEBIAN_FRONTEND=noninteractive \
    NEEDRESTART_MODE=a \
    CI=true \
    GT_PREBAKED_CONTAINER=1 \
    PLAYWRIGHT_BROWSERS_PATH=/ms-playwright \
    PLAYWRIGHT_VERSION=${PLAYWRIGHT_VERSION} \
    BUN_INSTALL=/opt/bun \
    UV_INSTALL_DIR=/opt/uv \
    UV_PYTHON_INSTALL_DIR=/opt/uv-python \
    RUSTUP_HOME=/opt/rust/rustup \
    CARGO_HOME=/opt/rust/cargo \
    PATH="/opt/rust/cargo/bin:/opt/uv:/opt/bun/bin:${PATH}"

RUN --mount=type=secret,id=internal_ca,required=false \
    --mount=type=cache,id=toolchains-apt-cache,target=/var/cache/apt,sharing=locked \
    echo "force-unsafe-io" > /etc/dpkg/dpkg.cfg.d/force-unsafe-io && \
    apt-get update -qq && \
    apt-get install -y --no-install-recommends \
      build-essential \
      pkg-config \
      libssl-dev \
      curl \
      ca-certificates \
      unzip \
      zip \
      xz-utils \
      jq \
      git \
      patchelf \
      python3 \
      python3-venv && \
    if [ -s /run/secrets/internal_ca ]; then \
      cp /run/secrets/internal_ca /usr/local/share/ca-certificates/gt-internal-ca.crt && \
      update-ca-certificates; \
    fi && \
    mkdir -p /opt/bun /opt/uv /opt/uv-python /opt/rust/rustup /opt/rust/cargo && \
    curl -fsSL https://bun.sh/install | BUN_INSTALL=/opt/bun bash -s "bun-v${BUN_VERSION}" && \
    ln -sf /opt/bun/bin/bun /usr/local/bin/bun && \
    ln -sf /opt/bun/bin/bun /usr/local/bin/bunx && \
    curl -LsSf "https://astral.sh/uv/${UV_VERSION}/install.sh" | env UV_INSTALL_DIR=/opt/uv INSTALLER_NO_MODIFY_PATH=1 sh && \
    ln -sf /opt/uv/uv /usr/local/bin/uv && \
    ln -sf /opt/uv/uvx /usr/local/bin/uvx && \
    /opt/uv/uv python install "${PYTHON_VERSION}" && \
    PY_BIN="$(/opt/uv/uv python find "${PYTHON_VERSION}")" && \
    ln -sf "${PY_BIN}" /usr/local/bin/python3 && \
    ln -sf "${PY_BIN}" /usr/local/bin/python && \
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y \
      --no-modify-path \
      --profile minimal \
      --default-toolchain "${RUST_DEFAULT_TOOLCHAIN}" \
      --component rustfmt,clippy && \
    /opt/rust/cargo/bin/rustup toolchain install "${RUST_NIGHTLY_TOOLCHAIN}" --profile minimal --component rustfmt,clippy && \
    /opt/rust/cargo/bin/rustup default "${RUST_DEFAULT_TOOLCHAIN}" && \
    for bin in /opt/rust/cargo/bin/*; do \
      ln -sf "$bin" "/usr/local/bin/$(basename "$bin")"; \
    done && \
    printf 'GT_PREBAKED_CONTAINER=1\nRUNNER_TOOLCHAINS_VERSION=%s\nPLAYWRIGHT_VERSION=%s\nBUN_VERSION=%s\nUV_VERSION=%s\nPYTHON_VERSION=%s\nRUST_DEFAULT_TOOLCHAIN=%s\nRUST_NIGHTLY_TOOLCHAIN=%s\n' \
      "${RUNNER_TOOLCHAINS_VERSION}" "${PLAYWRIGHT_VERSION}" "${BUN_VERSION}" "${UV_VERSION}" "${PYTHON_VERSION}" "${RUST_DEFAULT_TOOLCHAIN}" "${RUST_NIGHTLY_TOOLCHAIN}" \
      > /etc/gt-runner-toolchains && \
    chmod 0644 /etc/gt-runner-toolchains && \
    chmod -R a+rX /opt/bun /opt/uv /opt/uv-python /opt/rust && \
    chmod -R 777 /ms-playwright && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/*

ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt \
    CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt

RUN bun --version && \
    node --version && \
    uv --version && \
    python3 --version && \
    rustc --version && \
    cargo --version && \
    rustup toolchain list

LABEL org.opencontainers.image.title="Enterprise CI Toolchain Runner" \
      org.opencontainers.image.description="Pre-baked Bun, Rust (stable/nightly), uv, Python, Node.js, and Playwright CI runner image" \
      org.opencontainers.image.version="${RUNNER_TOOLCHAINS_VERSION}" \
      org.opencontainers.image.vendor="gt-dev" \
      org.opencontainers.image.source="https://git.gt-web-dev.com/gt-dev/actions"

WORKDIR /workspace
CMD ["/bin/bash"]
