#!/usr/bin/env bash
set -euo pipefail

echo "========================================================"
echo "      Gitea Actions Repository Quality & SSoT Validation"
echo "========================================================"

FAILED=0

check_no_template_injection_in_run() {
  local target_file="$1"
  local mode="${2:-error}"
  local matches
  matches="$(awk '
    BEGIN { in_run = 0; run_indent = -1 }
    {
      line = $0
      sub(/\r$/, "", line)
      # Compute leading spaces
      match(line, /^[ ]*/)
      indent = RLENGTH
      trimmed = substr(line, indent + 1)

      if (in_run == 1) {
        if (trimmed == "") {
          next
        }
        if (indent > run_indent) {
          if (index(line, "${{") > 0) {
            printf "%d:%s\n", NR, line
          }
          next
        } else {
          in_run = 0
          run_indent = -1
        }
      }

      if (trimmed ~ /^-[[:space:]]+run:[[:space:]]*[|>]/ || trimmed ~ /^run:[[:space:]]*[|>]/) {
        in_run = 1
        run_indent = indent
        next
      }

      if (trimmed ~ /^-[[:space:]]+run:[[:space:]]+/ || trimmed ~ /^run:[[:space:]]+/) {
        if (index(line, "${{") > 0) {
          printf "%d:%s\n", NR, line
        }
      }
    }
  ' "$target_file")"

  if [ -n "$matches" ]; then
    while IFS= read -r m; do
      if [ "$mode" = "warn" ]; then
        echo "::warning file=${target_file}::Legacy CWE-78 template expression inside run block (${m}) - tracked in gt-dev/actions#31"
      else
        echo "::error file=${target_file}::Unsafe template expression inside run block (CWE-78): ${m}"
        FAILED=1
      fi
    done <<< "$matches"
  fi
}

check_dockerfile_invariants() {
  local dockerfile="$1"
  local dir_name
  dir_name="$(dirname "$dockerfile")"

  if [ ! -f "$dockerfile" ]; then
    echo "::error file=${dockerfile}::Missing Dockerfile: ${dockerfile}"
    FAILED=1
    return
  fi

  if [ ! -f "${dir_name}/.dockerignore" ] && [ ! -f "${dockerfile}.dockerignore" ]; then
    echo "::error file=${dockerfile}::Missing sibling .dockerignore for ${dockerfile}"
    FAILED=1
  fi

  local first_line
  first_line="$(head -n1 "$dockerfile" | tr -d '\r')"
  if [ "$first_line" != "# syntax=docker/dockerfile:1" ]; then
    echo "::error file=${dockerfile}::Dockerfile must start with '# syntax=docker/dockerfile:1'"
    FAILED=1
  fi

  if grep -vE '^[[:space:]]*#' "$dockerfile" | grep -q "NODE_TLS_REJECT_UNAUTHORIZED"; then
    echo "::error file=${dockerfile}::Forbidden NODE_TLS_REJECT_UNAUTHORIZED detected in ${dockerfile}"
    FAILED=1
  fi

  # Collect declared stage aliases so internal stage references (FROM node-base AS ...) are allowed
  local stage_aliases
  stage_aliases="$(awk 'toupper($1) == "FROM" { for (i=1; i<=NF; i++) if (toupper($i) == "AS" && i < NF) print $(i+1) }' "$dockerfile")"

  while IFS= read -r from_line; do
    local image_ref
    image_ref="$(printf '%s\n' "$from_line" | awk '{for (i=2; i<=NF; i++) { if ($i !~ /^--/) { print $i; exit } }}')"

    # Skip internal multi-stage alias references
    local is_alias="false"
    for alias in $stage_aliases; do
      if [ "$image_ref" = "$alias" ]; then
        is_alias="true"
        break
      fi
    done
    if [ "$is_alias" = "true" ]; then
      continue
    fi

    # Allow parameterized ARG references ONLY if defaults in the Dockerfile are digest-pinned
    if [[ "$image_ref" =~ ^\$\{([A-Za-z_][A-Za-z0-9_]*)\}$ ]]; then
      local arg_name="${BASH_REMATCH[1]}"
      if ! grep -E "^ARG ${arg_name}=.*@sha256:[0-9a-f]{64}$" "$dockerfile" >/dev/null 2>&1; then
        echo "::error file=${dockerfile}::Parameterized FROM '${image_ref}' must default to an immutable @sha256: digest"
        FAILED=1
      fi
      continue
    fi

    if [[ "$image_ref" =~ @\$\{([A-Za-z_][A-Za-z0-9_]*)\}$ ]]; then
      local digest_arg="${BASH_REMATCH[1]}"
      if ! grep -E "^ARG ${digest_arg}=sha256:[0-9a-f]{64}$" "$dockerfile" >/dev/null 2>&1; then
        echo "::error file=${dockerfile}::Parameterized digest FROM '${image_ref}' must default ${digest_arg} to sha256:<64-hex>"
        FAILED=1
      fi
      continue
    fi

    if ! printf '%s\n' "$image_ref" | grep -qE '@sha256:[0-9a-f]{64}$'; then
      echo "::error file=${dockerfile}::FROM image '${image_ref}' must be pinned to an immutable @sha256: digest"
      FAILED=1
    fi
  done < <(grep -E '^[[:space:]]*FROM[[:space:]]+' "$dockerfile" | tr -d '\r')
}

# 1. Validate composite action manifests
echo "--> [1/6] Validating composite action manifests..."
ACTION_FILES="$(find . -maxdepth 2 \( -name "action.yaml" -o -name "action.yml" \) | sort)"

for action_file in $ACTION_FILES; do
  echo "    Checking $action_file..."

  if ! grep -q "^name:" "$action_file"; then
    echo "::error file=$action_file::Missing required top-level 'name' key in $action_file"
    FAILED=1
  fi

  if ! grep -q "^description:" "$action_file"; then
    echo "::error file=$action_file::Missing required top-level 'description' key in $action_file"
    FAILED=1
  fi

  if ! grep -q "^runs:" "$action_file"; then
    echo "::error file=$action_file::Missing required top-level 'runs' key in $action_file"
    FAILED=1
  fi

  if grep -E "(NODE_NO_WARNINGS|--no-deprecation)" "$action_file" >/dev/null 2>&1; then
    echo "::error file=$action_file::Warning suppression variable detected in $action_file (violates zero-warning standard)"
    FAILED=1
  fi

  if grep -q "NODE_TLS_REJECT_UNAUTHORIZED" "$action_file"; then
    echo "::error file=$action_file::Forbidden NODE_TLS_REJECT_UNAUTHORIZED detected in $action_file"
    FAILED=1
  fi

  if grep -E "^\s*set\s+-[a-z]*x" "$action_file" >/dev/null 2>&1; then
    echo "::error file=$action_file::Unsafe shell tracing 'set -x' detected in $action_file (security violation: exposes secrets)"
    FAILED=1
  fi

  if [[ "$action_file" == *"setup-playwright"* ]] && ! grep -q "force-unsafe-io" "$action_file"; then
    echo "::error file=$action_file::setup-playwright must configure dpkg force-unsafe-io to prevent fsync stalls"
    FAILED=1
  fi

  if grep -q "git\.gt-web-dev\.com" "$action_file"; then
    echo "::error file=$action_file::Hardcoded internal hostname detected in $action_file; derive dynamically from GITHUB_SERVER_URL"
    FAILED=1
  fi

  while IFS= read -r uses_line; do
    uses_ref="$(printf '%s\n' "$uses_line" | sed -E 's/^[[:space:]]*-?[[:space:]]*uses:[[:space:]]*//; s/[[:space:]]+#.*$//' | tr -d "\"'\r ")"
    case "$uses_ref" in
      builtin:*|self:*|./*)
        continue
        ;;
    esac
    if ! printf '%s\n' "$uses_ref" | grep -qE '@[0-9a-f]{40}$'; then
      echo "::error file=$action_file::Third-party action '${uses_ref}' must be pinned to an immutable 40-character commit SHA"
      FAILED=1
    fi
  done < <(grep -E '^[[:space:]]*-?[[:space:]]*uses:[[:space:]]+' "$action_file" | tr -d '\r')

  if [[ "$action_file" == *"upload-artifact"* || "$action_file" == *"download-artifact"* ]]; then
    if ! grep -q "setup-tls-ca" "$action_file" && ! grep -q "NODE_EXTRA_CA_CERTS" "$action_file"; then
      echo "::error file=$action_file::$action_file must configure TLS CA trust via setup-tls-ca or NODE_EXTRA_CA_CERTS"
      FAILED=1
    fi
  fi

  if [[ "$action_file" == *"setup-toolchains"* ]]; then
    if grep -E "astral-sh/setup-uv@v(8|9|10)$" "$action_file" >/dev/null 2>&1; then
      echo "::error file=$action_file::setup-toolchains references invalid floating setup-uv tag without semver patch"
      FAILED=1
    fi
    if ! grep -q "setup-tls-ca" "$action_file"; then
      echo "::error file=$action_file::setup-toolchains must delegate internal CA setup to setup-tls-ca"
      FAILED=1
    fi
    if ! grep -q "nextjs-cache:" "$action_file"; then
      echo "::error file=$action_file::setup-toolchains must expose nextjs-cache input"
      FAILED=1
    fi
    if ! grep -q "detect-bun" "$action_file"; then
      echo "::error file=$action_file::setup-toolchains must detect pre-installed Bun fast-path"
      FAILED=1
    fi
    if ! grep -q "detect-python-uv" "$action_file"; then
      echo "::error file=$action_file::setup-toolchains must detect pre-installed Python and Astral uv fast-path"
      FAILED=1
    fi
    if ! grep -q "detect-rust" "$action_file"; then
      echo "::error file=$action_file::setup-toolchains must detect pre-installed Rust toolchain fast-path"
      FAILED=1
    fi
  elif [[ "$action_file" == *"docker-build-push"* ]]; then
    if ! grep -q "DOCKER_BUILD_SUMMARY" "$action_file" || ! grep -q "DOCKER_BUILD_RECORD_UPLOAD" "$action_file"; then
      echo "::error file=$action_file::docker-build-push must configure DOCKER_BUILD_SUMMARY and DOCKER_BUILD_RECORD_UPLOAD"
      FAILED=1
    fi
    if ! grep -q "docker-container" "$action_file"; then
      echo "::error file=$action_file::docker-build-push must guard against docker-container builders on native DinD"
      FAILED=1
    fi
    if ! grep -q "BUILDKIT_INLINE_CACHE=1" "$action_file"; then
      echo "::error file=$action_file::docker-build-push must support BUILDKIT_INLINE_CACHE=1"
      FAILED=1
    fi
  elif [[ "$action_file" == *"publish-release"* ]]; then
    if ! grep -q "setup-tls-ca" "$action_file"; then
      echo "::error file=$action_file::publish-release must configure TLS CA trust via setup-tls-ca"
      FAILED=1
    fi
    if ! grep -q "0{64}" "$action_file"; then
      echo "::error file=$action_file::publish-release must guard against zeroed 0{64} SHA-256 digests"
      FAILED=1
    fi
    if ! grep -q "GIT_TERMINAL_PROMPT=0" "$action_file" || ! grep -q "GCM_INTERACTIVE=never" "$action_file"; then
      echo "::error file=$action_file::publish-release must enforce headless Git execution flags (GIT_TERMINAL_PROMPT=0, GCM_INTERACTIVE=never)"
      FAILED=1
    fi
    if ! grep -q "dispatch-homebrew" "$action_file" || ! grep -q "dispatch-scoop" "$action_file" || ! grep -q "dispatch-winget" "$action_file"; then
      echo "::error file=$action_file::publish-release must expose dispatch-homebrew, dispatch-scoop, and dispatch-winget inputs"
      FAILED=1
    fi
  fi

  check_no_template_injection_in_run "$action_file" "error"
done

# 2. Validate pinned binary installers & TLS CA action
echo "--> [2/6] Validating pinned binary installer checksums..."
if [ ! -f "setup-tls-ca/action.yaml" ]; then
  echo "::error file=setup-tls-ca/action.yaml::Missing required setup-tls-ca composite action"
  FAILED=1
fi

CDDM_ACTION="setup-cddm/action.yaml"
if [ -f "$CDDM_ACTION" ]; then
  DEFAULT_CDDM_VER="$(grep -A 5 "^  version:" "$CDDM_ACTION" | grep "default:" | head -n1 | awk -F'"' '{print $2}')"
  PINNED_CDDM_SHA="$(grep 'PINNED_SHA256="' "$CDDM_ACTION" | head -n1 | awk -F'"' '{print $2}')"
  if [ -z "$DEFAULT_CDDM_VER" ] || ! printf '%s\n' "$DEFAULT_CDDM_VER" | grep -qE '^v?[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "::error file=$CDDM_ACTION::setup-cddm default version must be a valid semver tag (found '${DEFAULT_CDDM_VER:-unset}')"
    FAILED=1
  fi
  if [ -z "$PINNED_CDDM_SHA" ] || ! printf '%s\n' "$PINNED_CDDM_SHA" | grep -qE '^[0-9a-f]{64}$'; then
    echo "::error file=$CDDM_ACTION::setup-cddm PINNED_SHA256 must be a valid 64-character hexadecimal digest"
    FAILED=1
  else
    echo "    Verified setup-cddm SSoT (${DEFAULT_CDDM_VER} -> ${PINNED_CDDM_SHA})."
  fi
fi

GITLEAKS_ACTION="gitleaks-scan/action.yaml"
if [ -f "$GITLEAKS_ACTION" ]; then
  PINNED_GL_SHA="$(grep 'PINNED_SHA256="' "$GITLEAKS_ACTION" | head -n1 | awk -F'"' '{print $2}')"
  if [ -z "$PINNED_GL_SHA" ] || ! printf '%s\n' "$PINNED_GL_SHA" | grep -qE '^[0-9a-f]{64}$'; then
    echo "::error file=$GITLEAKS_ACTION::gitleaks-scan PINNED_SHA256 must be a valid 64-character hexadecimal digest"
    FAILED=1
  else
    echo "    Verified gitleaks-scan SSoT digest (${PINNED_GL_SHA})."
  fi
fi

# 3. Validate Container SSoTs, Digests & .dockerignore
echo "--> [3/6] Validating container SSoT versions, immutable digests & .dockerignore..."
if [ ! -f ".dockerignore" ]; then
  echo "::error file=.dockerignore::Missing repository root .dockerignore"
  FAILED=1
fi

PW_VER_FILE="containers/playwright/PLAYWRIGHT_VERSION"
PW_DIGEST_FILE="containers/playwright/PLAYWRIGHT_DIGEST"
if [ ! -f "$PW_VER_FILE" ] || [ ! -f "$PW_DIGEST_FILE" ]; then
  echo "::error::Missing $PW_VER_FILE or $PW_DIGEST_FILE"
  FAILED=1
else
  PW_VER="$(tr -d ' \r\n' < "$PW_VER_FILE")"
  PW_DIGEST="$(tr -d ' \r\n' < "$PW_DIGEST_FILE")"
  if ! echo "$PW_VER" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "::error file=$PW_VER_FILE::Invalid semver in $PW_VER_FILE: '$PW_VER'"
    FAILED=1
  fi
  if ! echo "$PW_DIGEST" | grep -qE '^sha256:[0-9a-f]{64}$'; then
    echo "::error file=$PW_DIGEST_FILE::Invalid sha256 digest in $PW_DIGEST_FILE: '$PW_DIGEST'"
    FAILED=1
  fi
  PW_DOCKERFILE="containers/playwright/Dockerfile"
  check_dockerfile_invariants "$PW_DOCKERFILE"
  if [ -f "$PW_DOCKERFILE" ]; then
    if ! grep -q "ARG PLAYWRIGHT_VERSION=${PW_VER}" "$PW_DOCKERFILE"; then
      echo "::error file=$PW_DOCKERFILE::Dockerfile default ARG PLAYWRIGHT_VERSION does not match $PW_VER"
      FAILED=1
    fi
    if ! grep -q "ARG PLAYWRIGHT_IMAGE_DIGEST=${PW_DIGEST}" "$PW_DOCKERFILE"; then
      echo "::error file=$PW_DOCKERFILE::Dockerfile default ARG PLAYWRIGHT_IMAGE_DIGEST does not match $PW_DIGEST"
      FAILED=1
    fi
    if ! grep -q "force-unsafe-io" "$PW_DOCKERFILE"; then
      echo "::error file=$PW_DOCKERFILE::Dockerfile must configure dpkg force-unsafe-io"
      FAILED=1
    fi
    echo "    Verified Playwright SSoT (${PW_VER} @ ${PW_DIGEST})."
  fi
fi

ALPINE_VERSIONS="containers/bun-node-alpine/VERSIONS"
ALPINE_DOCKERFILE="containers/bun-node-alpine/Dockerfile"
if [ ! -f "$ALPINE_VERSIONS" ]; then
  echo "::error file=$ALPINE_VERSIONS::Missing $ALPINE_VERSIONS"
  FAILED=1
else
  # shellcheck source=containers/bun-node-alpine/VERSIONS
  source "$ALPINE_VERSIONS"
  if [ "${DEFAULT_NODE_MAJOR:-}" != "26" ]; then
    echo "::error file=$ALPINE_VERSIONS::DEFAULT_NODE_MAJOR must track active LTS major '26' (found '${DEFAULT_NODE_MAJOR:-unset}')"
    FAILED=1
  fi
  if ! printf '%s\n' "${NODE26_IMAGE:-}" | grep -qE '@sha256:[0-9a-f]{64}$'; then
    echo "::error file=$ALPINE_VERSIONS::NODE26_IMAGE must be pinned to an immutable @sha256: digest"
    FAILED=1
  fi
  if ! printf '%s\n' "${NODE24_IMAGE:-}" | grep -qE '@sha256:[0-9a-f]{64}$'; then
    echo "::error file=$ALPINE_VERSIONS::NODE24_IMAGE must be pinned to an immutable @sha256: digest"
    FAILED=1
  fi
  if grep -rnE "node:(16|18|20|22|23|25)-alpine|NODE(16|18|20|22|23|25)_" containers examples .gitea/workflows 2>/dev/null; then
    echo "::error::Outdated or EOL Node.js version reference detected (allowed LTS majors: 26 Active LTS, 24 Maintenance LTS)"
    FAILED=1
  fi
  check_dockerfile_invariants "$ALPINE_DOCKERFILE"
  if [ -f "$ALPINE_DOCKERFILE" ]; then
    if ! grep -q "ARG NODE_IMAGE=${NODE26_IMAGE}" "$ALPINE_DOCKERFILE"; then
      echo "::error file=$ALPINE_DOCKERFILE::Default ARG NODE_IMAGE does not match NODE26_IMAGE in VERSIONS"
      FAILED=1
    fi
    if ! grep -q "ARG BUN_IMAGE=${BUN_IMAGE}" "$ALPINE_DOCKERFILE"; then
      echo "::error file=$ALPINE_DOCKERFILE::Default ARG BUN_IMAGE does not match BUN_IMAGE in VERSIONS"
      FAILED=1
    fi
    if ! grep -q "AS runner" "$ALPINE_DOCKERFILE" || ! grep -q "AS builder" "$ALPINE_DOCKERFILE"; then
      echo "::error file=$ALPINE_DOCKERFILE::Dockerfile must define both 'runner' and 'builder' stages"
      FAILED=1
    fi
    echo "    Verified Alpine builder/runner SSoT (Node ${NODE26_VERSION} Active LTS/${NODE24_VERSION} LTS + Bun ${BUN_VERSION})."
  fi
fi

RT_VERSIONS="containers/runner-toolchains/VERSIONS"
RT_DOCKERFILE="containers/runner-toolchains/Dockerfile"
if [ ! -f "$RT_VERSIONS" ] || [ ! -f "$RT_DOCKERFILE" ]; then
  echo "::error::Missing $RT_VERSIONS or $RT_DOCKERFILE"
  FAILED=1
else
  # shellcheck source=containers/runner-toolchains/VERSIONS
  source "$RT_VERSIONS"
  check_dockerfile_invariants "$RT_DOCKERFILE"
  if ! printf '%s\n' "${PLAYWRIGHT_BASE_IMAGE:-}" | grep -qE '@sha256:[0-9a-f]{64}$'; then
    echo "::error file=$RT_VERSIONS::PLAYWRIGHT_BASE_IMAGE must be pinned to an immutable @sha256: digest"
    FAILED=1
  fi
  if ! grep -q "ARG PLAYWRIGHT_BASE_IMAGE=${PLAYWRIGHT_BASE_IMAGE}" "$RT_DOCKERFILE"; then
    echo "::error file=$RT_DOCKERFILE::Default ARG PLAYWRIGHT_BASE_IMAGE does not match PLAYWRIGHT_BASE_IMAGE in $RT_VERSIONS"
    FAILED=1
  fi
  if ! grep -q "force-unsafe-io" "$RT_DOCKERFILE"; then
    echo "::error file=$RT_DOCKERFILE::Dockerfile must configure dpkg force-unsafe-io"
    FAILED=1
  fi
  if ! grep -q "gt-runner-toolchains" "$RT_DOCKERFILE"; then
    echo "::error file=$RT_DOCKERFILE::Dockerfile must write /etc/gt-runner-toolchains manifest"
    FAILED=1
  fi
  echo "    Verified Enterprise Toolchain Runner SSoT (v${RUNNER_TOOLCHAINS_VERSION}, Bun ${BUN_VERSION}, uv ${UV_VERSION}, Python ${PYTHON_VERSION}, Rust ${RUST_DEFAULT_TOOLCHAIN}/${RUST_NIGHTLY_TOOLCHAIN})."
fi

# 4. Validate Workflows & Reference Next.js Templates
echo "--> [4/6] Validating workflows and examples/nextjs reference templates..."
WORKFLOW_FILES="$(find .gitea/workflows examples -type f \( -name "*.yaml" -o -name "*.yml" \) 2>/dev/null | sort)"
for wf in $WORKFLOW_FILES; do
  echo "    Checking $wf..."
  check_no_template_injection_in_run "$wf" "error"

  if grep -q "NODE_TLS_REJECT_UNAUTHORIZED" "$wf"; then
    echo "::error file=$wf::Forbidden NODE_TLS_REJECT_UNAUTHORIZED detected in $wf"
    FAILED=1
  fi
  if grep -q "docker/setup-buildx-action" "$wf" || grep -q "docker:dind" "$wf"; then
    echo "::error file=$wf::Forbidden setup-buildx-action or docker:dind sidecar detected in $wf"
    FAILED=1
  fi
  if grep -E "^\s*set\s+-[a-z]*x" "$wf" >/dev/null 2>&1; then
    echo "::error file=$wf::Unsafe shell tracing 'set -x' detected in $wf"
    FAILED=1
  fi
done

if [ -f ".gitea/workflows/validate.yaml" ]; then
  if awk '/^on:/,/^[a-zA-Z0-9_-]+:/ { if ($1 == "push:") found=1 } END { exit !found }' ".gitea/workflows/validate.yaml"; then
    echo "::error file=.gitea/workflows/validate.yaml::validate.yaml must not have redundant push trigger on branch-protected main"
    FAILED=1
  fi
fi

for req_file in \
  "examples/nextjs/Dockerfile" \
  "examples/nextjs/.dockerignore" \
  "examples/nextjs/next.config.ts" \
  "examples/nextjs/.gitea/workflows/ci.yaml" \
  "examples/nextjs/.gitea/workflows/deploy.yaml"; do
  if [ ! -f "$req_file" ]; then
    echo "::error file=$req_file::Missing required reference template file: $req_file"
    FAILED=1
  fi
done

if [ -f "examples/nextjs/Dockerfile" ]; then
  check_dockerfile_invariants "examples/nextjs/Dockerfile"
  if grep -vE '^[[:space:]]*#' "examples/nextjs/Dockerfile" | grep -qE 'COPY[[:space:]]+--from=deps'; then
    echo "::error file=examples/nextjs/Dockerfile::Cross-stage node_modules copy is forbidden; use unified builder"
    FAILED=1
  fi
  if ! grep -q "mount=type=cache" "examples/nextjs/Dockerfile"; then
    echo "::error file=examples/nextjs/Dockerfile::Reference Dockerfile must demonstrate BuildKit cache mounts"
    FAILED=1
  fi
  if [ -n "${NODE26_IMAGE:-}" ] && ! grep -q "FROM ${NODE26_IMAGE}" "examples/nextjs/Dockerfile"; then
    echo "::error file=examples/nextjs/Dockerfile::Reference Dockerfile must use Active LTS NODE26_IMAGE (${NODE26_IMAGE})"
    FAILED=1
  fi
fi

if [ -f "examples/nextjs/next.config.ts" ] && ! grep -q "turbopackFileSystemCacheForBuild" "examples/nextjs/next.config.ts"; then
  echo "::error file=examples/nextjs/next.config.ts::next.config.ts must enable turbopackFileSystemCacheForBuild"
  FAILED=1
fi

# 5. Enforce pure ASCII (zero emojis) in actions, workflows, scripts, containers, and examples
echo "--> [5/6] Checking for non-ASCII / emoji characters in workflows, actions, containers & scripts..."
TEXT_TARGETS="$(find .gitea/workflows scripts examples containers -type f 2>/dev/null ; find . -maxdepth 2 \( -name "action.yaml" -o -name "action.yml" \))"
TEXT_TARGETS="$(printf '%s\n' "$TEXT_TARGETS" | sort -u)"
for tf in $TEXT_TARGETS; do
  if LC_ALL=C grep -n '[^[:print:][:space:]]' "$tf" >/dev/null 2>&1; then
    echo "::error file=$tf::Non-ASCII or emoji character detected in $tf"
    FAILED=1
  fi
done

# 6. Check for forbidden raw JavaScript files
echo "--> [6/6] Checking for forbidden file extensions..."
FORBIDDEN_FILES="$(find . -not -path "*/.git/*" \( -name "*.js" -o -name "*.cjs" -o -name "*.mjs" \) 2>/dev/null || true)"
if [ -n "$FORBIDDEN_FILES" ]; then
  echo "::error::Forbidden JavaScript files detected: $FORBIDDEN_FILES"
  FAILED=1
else
  echo "    Zero raw JavaScript files detected."
fi

if [ "$FAILED" -ne 0 ]; then
  echo "========================================================"
  echo "Validation FAILED! Please resolve the errors above."
  echo "========================================================"
  exit 1
fi

echo "========================================================"
echo "All validation checks PASSED successfully!"
echo "========================================================"
exit 0
