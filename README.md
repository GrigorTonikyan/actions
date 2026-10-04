# Gitea Actions Composite Action Library (`gt-dev/actions`)

Centralized Single Source of Truth (SSoT) repository housing reusable, modular composite actions for **Gitea Actions** pipelines across all private organization repositories.

---

## Architecture & Gitea Runner 4.0.0 Native Resolution

This repository leverages the **Gitea Runner 4.0.0 native `self:` action resolution engine** (PR #1233):

```yaml
- name: Setup Toolchains
  uses: self:gt-dev/actions/setup-toolchains@v1
  with:
    bun: true
    uv: true
```

### Key Operational Tenets:
1. **Zero External Network Egress**: The runner resolves actions directly against the local Gitea instance (`https://git.gt-web-dev.com`) over internal loopback (`172.16.12.100`), guaranteeing zero WAN bandwidth usage and physical SSD/RAM bus speeds.
2. **Zero URL Credentials**: No tokens, passwords, or personal access tokens (PATs) are embedded in action URLs. The runner authenticates automatically using its active job credentials.
3. **No Hardcoded Hostnames**: Workflows across repositories reference actions cleanly via `self:gt-dev/actions/<action>@<ref>`, preserving repository portability.

---

## Available Actions

### 1. `setup-toolchains`
Comprehensive workspace environment setup for Bun, Python, uv, and dependency caching.

```yaml
- name: Setup Toolchains
  uses: self:gt-dev/actions/setup-toolchains@v1
  with:
    bun: "true"
    bun-version: "latest"
    uv: "true"
    python-version: "3.13"
    cache: "true"
```

### 2. `gitleaks-scan`
Cryptographically pinned Gitleaks secret scanner.

```yaml
- name: Scan Secrets
  uses: self:gt-dev/actions/gitleaks-scan@v1
  with:
    version: "8.24.0"
    redact: "true"
    source: "."
```

### 3. `setup-playwright`
Playwright browser binaries and operating system dependency installer with automated caching.

```yaml
- name: Setup Playwright
  uses: self:gt-dev/actions/setup-playwright@v1
  with:
    cache: "true"
    install-deps: "true"
    browser: "chromium"
```

### 4. `docker-login`
Secure, zero-warning composite action for authenticating with private or public container registries without plaintext credential warnings.

```yaml
- name: Log in to Private Registry
  uses: self:gt-dev/actions/docker-login@v1
  with:
    registry: git.gt-web-dev.com
    username: ${{ github.repository_owner }}
    password: ${{ secrets.REGISTRY_TOKEN }}
```

### 5. `download-artifact`
Zero-deprecation composite action for retrieving build artifacts across workflow jobs.

```yaml
- name: Download Prebuilt Binaries
  uses: self:gt-dev/actions/download-artifact@v1
  with:
    name: prebuilt-binaries
    path: target/release
```

### 6. `upload-artifact`
Zero-deprecation composite action for uploading pipeline artifacts with automated retention.

```yaml
- name: Upload Release Binaries
  uses: self:gt-dev/actions/upload-artifact@v1
  with:
    name: prebuilt-binaries
    path: target/release/*
```

---

## Release & Versioning Policy

- Changes to action definitions are tagged with semantic versions (`v1.0.0`, `v1.1.0`) and major aliases (`v1`).
- Workflows reference the major release tag `@v1` to receive non-breaking improvements automatically.