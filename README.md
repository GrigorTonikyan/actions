# Gitea Actions Composite Action Library (`gt-dev/actions`)

Centralized Single Source of Truth (SSoT) repository housing reusable, modular composite actions and container images for **Gitea Actions** pipelines across all private organization repositories.

---

## Architecture & Gitea Runner 5.0.0 Native Resolution

This repository leverages the **Gitea Runner 5.0.0 native `self:` action resolution engine**:

```yaml
- name: Setup Toolchains
  uses: self:gt-dev/actions/setup-toolchains@v1
  with:
    bun: "true"
    uv: "true"
```

### Key Operational Tenets:
1. **Zero External Network Egress**: The runner resolves actions directly against the local Gitea instance (`https://git.gt-web-dev.com`) over internal loopback (`172.16.12.100`), guaranteeing zero WAN bandwidth usage and physical SSD/RAM bus speeds.
2. **Zero URL Credentials**: No tokens, passwords, or personal access tokens (PATs) are embedded in action URLs. The runner authenticates automatically using its active job credentials.
3. **No Hardcoded Hostnames**: Workflows across repositories reference actions cleanly via `self:gt-dev/actions/<action>@<ref>`, preserving repository portability.
4. **Resilient Local Loopback TLS**: Artifact actions automatically configure Node.js with the internal Gitea CA certificates (`/etc/docker/certs.d/git.gt-web-dev.com/ca.crt` and system CAs), eliminating self-signed certificate errors without compromising TLS security.

---

## Available Actions

### 1. `setup-toolchains`
Comprehensive workspace environment setup for Bun, Python, uv (v10), and dependency caching.

```yaml
- name: Setup Toolchains
  uses: self:gt-dev/actions/setup-toolchains@v1
  with:
    bun: "true"
    bun-version: "latest"
    uv: "true"
    uv-version: "latest" # or pin specific uv version, defaults to pyproject.toml / latest
    python-version: "3.13"
    cache: "true"
```

### 2. `gitleaks-scan`
Cryptographically pinned Gitleaks secret scanner.

```yaml
- name: Scan Secrets
  uses: self:gt-dev/actions/gitleaks-scan@v1
  with:
    version: "8.30.1"
    redact: "true"
    source: "."
```

### 3. `setup-cddm`
Cryptographically pinned binary installer and verifier for CDDM (Code Duplication Detection & Metrics) CLI with elevation support and container detection.

```yaml
- name: Setup CDDM
  uses: self:gt-dev/actions/setup-cddm@v1
  with:
    version: "v4.8.0"
    destination: "/usr/local/bin"
```

- **Universal Version Normalization**: Accepts both `v4.8.0` and `4.8.0` formats seamlessly.
- **SHA-256 Checksum Verification**: Automatically verifies the downloaded binary archive against cryptographic digests.
- **Smart Idempotency Check**: Skips downloading if the requested version is already present in PATH.

### 4. `setup-playwright`
Playwright browser binaries and operating system dependency installer with automated caching and container detection.

```yaml
- name: Setup Playwright
  uses: self:gt-dev/actions/setup-playwright@v1
  with:
    cache: "true"
    install-deps: "true"
    browser: "chromium"
    only-shell: "true"
```

- **Container Detection with Revision Probe**: Automatically discovers pre-baked browser revisions in `/ms-playwright` and skips downloads entirely. If a container lacks the required browser revision, it issues a notice and performs a targeted download.
- **Complete Runtime OS Dependency Probe**: Probes all 16 Linux OS shared libraries required by headless Chromium via bulk `dpkg -s`. Skips `apt-get` entirely when pre-installed.
- **Automated Dpkg I/O Acceleration (`force-unsafe-io`)**: Automatically configures `/etc/dpkg/dpkg.cfg.d/force-unsafe-io` before provisioning, eliminating `fsync()` synchronous flush stalls across copy-on-write filesystems (ZFS / overlayfs) and delivering 5x–10x faster package extraction.
- **Intelligent Package.json Version Discovery**: Probes `@playwright/test` from `package.json` before cache key generation to prevent fallback invalidations.
- **Root & Non-Root Runner Compatibility**: Dynamically resolves privilege escalation (`$SUDO`) to function seamlessly in both root containers and standard non-root runner environments.
- **Version-Keyed Caching**: Caches binaries keyed by resolved `@playwright/test` version rather than entire lockfiles, eliminating invalidation churn from unrelated dependencies.

### 5. `docker-login`
Secure, zero-warning composite action for authenticating with private or public container registries without plaintext credential warnings.

```yaml
- name: Log in to Private Registry
  uses: self:gt-dev/actions/docker-login@v1
  with:
    registry: git.gt-web-dev.com
    username: ${{ github.repository_owner }}
    password: ${{ secrets.REGISTRY_TOKEN }}
```

### 6. `download-artifact`
Zero-deprecation composite action for retrieving build artifacts across workflow jobs with automated internal loopback TLS trust.

```yaml
- name: Download Prebuilt Binaries
  uses: self:gt-dev/actions/download-artifact@v1
  with:
    name: prebuilt-binaries
    path: target/release
```

**Outputs:**
- `download-path`: Path where the artifact was downloaded.

### 7. `upload-artifact`
Zero-deprecation composite action for uploading pipeline artifacts with automated retention and internal loopback TLS trust.

```yaml
- name: Upload Release Binaries
  uses: self:gt-dev/actions/upload-artifact@v1
  with:
    name: prebuilt-binaries
    path: target/release/*
```

**Outputs:**
- `artifact-id`: Unique numeric identifier of the uploaded artifact.
- `artifact-url`: Direct URL to download the uploaded artifact.
- `artifact-digest`: SHA256 digest of the uploaded artifact bundle.

---

## Container Images

### `playwright-runner` Container Image
Dedicated enterprise Single Source of Truth container image built on Ubuntu 24.04 Noble with Playwright browsers, Node.js LTS, Bun, and `/etc/dpkg/dpkg.cfg.d/force-unsafe-io` pre-baked in `/ms-playwright`. Completely eliminates runtime `apt-get` package downloads, browser installs, and disk sync stalls in CI.

- **Registry Image Tags**:
  - `git.gt-web-dev.com/gt-dev/playwright-runner:v1.65.0` (Recommended: exact Playwright version pinning)
  - `git.gt-web-dev.com/gt-dev/playwright-runner:1.65.0`
  - `git.gt-web-dev.com/gt-dev/playwright-runner:latest`
- **SSoT Versioning**: Version is centrally declared in `containers/playwright/PLAYWRIGHT_VERSION` and enforced during image builds and workflow validation.

```yaml
jobs:
  frontend-quality:
    runs-on: ubuntu-latest
    container:
      image: git.gt-web-dev.com/gt-dev/playwright-runner:v1.65.0
    steps:
      - uses: builtin:checkout
      - run: bun test:e2e
```

---

## Quality Gates & Validation

Every pull request and push to `main` undergoes automated validation via `.gitea/workflows/validate.yaml`:
1. **Gitleaks Secret Scan**: Enforces zero credentials or tokens in repository code.
2. **Action Manifest & SSoT Validation** (`scripts/validate-actions.sh`): Verifies required keys, zero-warning compliance, version file semver integrity, TLS trust configuration, and Dockerfile ARG parity.
3. **PR Quality & Merge Gate**: Required status check blocking merges until all checks pass.

---

## Zero-Warning & Deprecation Policy

In accordance with enterprise development standards, this repository enforces a strict **Zero-Warning and Zero-Suppression Policy**:
- Environment variables that silence warnings (such as `NODE_NO_WARNINGS="1"` or `NODE_OPTIONS="--no-deprecation"`) are strictly banned across all actions.
- All actions are implemented using modern, officially supported action primitives (`@v4`, `@v5`, `@v10`) or native binaries to eliminate deprecation notices at the root.

---

## Release & Versioning Policy

- Changes to action definitions are tagged with semantic versions (`v1.0.0`, `v1.9.0`) and major aliases (`v1`).
- Workflows reference the major release tag `@v1` to receive non-breaking improvements automatically.
- Both `refs/tags/v1` and `refs/heads/v1` are synchronized upon release to ensure deterministic Gitea runner resolution.
