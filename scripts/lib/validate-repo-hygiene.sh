#!/usr/bin/env bash

validate_containers_and_ignores() {
  echo "--> [3/7] Validating container SSoT versions, immutable digests & .dockerignore..."
  if [ ! -f ".dockerignore" ]; then
    echo "::error file=.dockerignore::Missing repository root .dockerignore"
    FAILED=1
  fi

  local pw_ver_file="containers/playwright/PLAYWRIGHT_VERSION"
  local pw_digest_file="containers/playwright/PLAYWRIGHT_DIGEST"
  if [ ! -f "$pw_ver_file" ] || [ ! -f "$pw_digest_file" ]; then
    echo "::error::Missing $pw_ver_file or $pw_digest_file"
    FAILED=1
  else
    local pw_ver pw_digest pw_dockerfile
    pw_ver="$(tr -d ' \r\n' < "$pw_ver_file")"
    pw_digest="$(tr -d ' \r\n' < "$pw_digest_file")"
    if ! echo "$pw_ver" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
      echo "::error file=$pw_ver_file::Invalid semver in $pw_ver_file: '$pw_ver'"
      FAILED=1
    fi
    if ! echo "$pw_digest" | grep -qE '^sha256:[0-9a-f]{64}$'; then
      echo "::error file=$pw_digest_file::Invalid sha256 digest in $pw_digest_file: '$pw_digest'"
      FAILED=1
    fi
    pw_dockerfile="containers/playwright/Dockerfile"
    check_dockerfile_invariants "$pw_dockerfile"
    if [ -f "$pw_dockerfile" ]; then
      if ! grep -q "ARG PLAYWRIGHT_VERSION=${pw_ver}" "$pw_dockerfile"; then
        echo "::error file=$pw_dockerfile::Dockerfile default ARG PLAYWRIGHT_VERSION does not match $pw_ver"
        FAILED=1
      fi
      if ! grep -q "ARG PLAYWRIGHT_IMAGE_DIGEST=${pw_digest}" "$pw_dockerfile"; then
        echo "::error file=$pw_dockerfile::Dockerfile default ARG PLAYWRIGHT_IMAGE_DIGEST does not match $pw_digest"
        FAILED=1
      fi
      if ! grep -q "force-unsafe-io" "$pw_dockerfile"; then
        echo "::error file=$pw_dockerfile::Dockerfile must configure dpkg force-unsafe-io"
        FAILED=1
      fi
      echo "    Verified Playwright SSoT (${pw_ver} @ ${pw_digest})."
    fi
  fi

  local alpine_versions="containers/bun-node-alpine/VERSIONS"
  local alpine_dockerfile="containers/bun-node-alpine/Dockerfile"
  if [ ! -f "$alpine_versions" ]; then
    echo "::error file=$alpine_versions::Missing $alpine_versions"
    FAILED=1
  else
    # shellcheck source=containers/bun-node-alpine/VERSIONS
    source "$alpine_versions"
    if [ "${DEFAULT_NODE_MAJOR:-}" != "26" ]; then
      echo "::error file=$alpine_versions::DEFAULT_NODE_MAJOR must track active LTS major '26' (found '${DEFAULT_NODE_MAJOR:-unset}')"
      FAILED=1
    fi
    if ! printf '%s\n' "${NODE26_IMAGE:-}" | grep -qE '@sha256:[0-9a-f]{64}$'; then
      echo "::error file=$alpine_versions::NODE26_IMAGE must be pinned to an immutable @sha256: digest"
      FAILED=1
    fi
    if ! printf '%s\n' "${NODE24_IMAGE:-}" | grep -qE '@sha256:[0-9a-f]{64}$'; then
      echo "::error file=$alpine_versions::NODE24_IMAGE must be pinned to an immutable @sha256: digest"
      FAILED=1
    fi
    if grep -rnE "node:(16|18|20|22|23|25)-alpine|NODE(16|18|20|22|23|25)_" containers examples .gitea/workflows 2>/dev/null; then
      echo "::error::Outdated or EOL Node.js version reference detected (allowed LTS majors: 26 Active LTS, 24 Maintenance LTS)"
      FAILED=1
    fi
    check_dockerfile_invariants "$alpine_dockerfile"
    if [ -f "$alpine_dockerfile" ]; then
      if ! grep -q "ARG NODE_IMAGE=${NODE26_IMAGE}" "$alpine_dockerfile"; then
        echo "::error file=$alpine_dockerfile::Default ARG NODE_IMAGE does not match NODE26_IMAGE in VERSIONS"
        FAILED=1
      fi
      if ! grep -q "ARG BUN_IMAGE=${BUN_IMAGE}" "$alpine_dockerfile"; then
        echo "::error file=$alpine_dockerfile::Default ARG BUN_IMAGE does not match BUN_IMAGE in VERSIONS"
        FAILED=1
      fi
      if ! grep -q "AS runner" "$alpine_dockerfile" || ! grep -q "AS builder" "$alpine_dockerfile"; then
        echo "::error file=$alpine_dockerfile::Dockerfile must define both 'runner' and 'builder' stages"
        FAILED=1
      fi
      echo "    Verified Alpine builder/runner SSoT (Node ${NODE26_VERSION} Active LTS/${NODE24_VERSION} LTS + Bun ${BUN_VERSION})."
    fi
  fi

  local rt_versions="containers/runner-toolchains/VERSIONS"
  local rt_dockerfile="containers/runner-toolchains/Dockerfile"
  if [ ! -f "$rt_versions" ] || [ ! -f "$rt_dockerfile" ]; then
    echo "::error::Missing $rt_versions or $rt_dockerfile"
    FAILED=1
  else
    # shellcheck source=containers/runner-toolchains/VERSIONS
    source "$rt_versions"
    check_dockerfile_invariants "$rt_dockerfile"
    if ! printf '%s\n' "${PLAYWRIGHT_BASE_IMAGE:-}" | grep -qE '@sha256:[0-9a-f]{64}$'; then
      echo "::error file=$rt_versions::PLAYWRIGHT_BASE_IMAGE must be pinned to an immutable @sha256: digest"
      FAILED=1
    fi
    if ! grep -q "ARG PLAYWRIGHT_BASE_IMAGE=${PLAYWRIGHT_BASE_IMAGE}" "$rt_dockerfile"; then
      echo "::error file=$rt_dockerfile::Default ARG PLAYWRIGHT_BASE_IMAGE does not match PLAYWRIGHT_BASE_IMAGE in $rt_versions"
      FAILED=1
    fi
    if ! grep -q "force-unsafe-io" "$rt_dockerfile"; then
      echo "::error file=$rt_dockerfile::Dockerfile must configure dpkg force-unsafe-io"
      FAILED=1
    fi
    if ! grep -q "gt-runner-toolchains" "$rt_dockerfile"; then
      echo "::error file=$rt_dockerfile::Dockerfile must write /etc/gt-runner-toolchains manifest"
      FAILED=1
    fi
    echo "    Verified Enterprise Toolchain Runner SSoT (v${RUNNER_TOOLCHAINS_VERSION}, Bun ${BUN_VERSION}, uv ${UV_VERSION}, Python ${PYTHON_VERSION}, Rust ${RUST_DEFAULT_TOOLCHAIN}/${RUST_NIGHTLY_TOOLCHAIN})."
  fi
}

validate_workflows_and_examples() {
  echo "--> [4/7] Validating workflows, CDDM rules, and examples/nextjs reference templates..."
  local workflow_files
  workflow_files="$(find .gitea/workflows examples -type f \( -name "*.yaml" -o -name "*.yml" \) 2>/dev/null | sort)"
  for wf in $workflow_files; do
    echo "    Checking $wf..."
    check_no_template_injection_in_run "$wf" "error"
    check_yaml_block_scalar_indentation "$wf"

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

  if [ ! -f ".cddmrules.toml" ]; then
    echo "::error file=.cddmrules.toml::Missing repository root .cddmrules.toml"
    FAILED=1
  fi

  if [ -f ".gitea/workflows/validate.yaml" ]; then
    if awk '/^on:/,/^[a-zA-Z0-9_-]+:/ { if ($1 == "push:") found=1 } END { exit !found }' ".gitea/workflows/validate.yaml"; then
      echo "::error file=.gitea/workflows/validate.yaml::validate.yaml must not have redundant push trigger on branch-protected main"
      FAILED=1
    fi
    if ! grep -q "./setup-cddm" ".gitea/workflows/validate.yaml" || \
       ! grep -q "cddm rules check" ".gitea/workflows/validate.yaml" || \
       ! grep -q "\-\-enforce-policies" ".gitea/workflows/validate.yaml"; then
      echo "::error file=.gitea/workflows/validate.yaml::validate.yaml must invoke ./setup-cddm and enforce CDDM policies (--enforce-policies)"
      FAILED=1
    fi
  fi

  for req_file in \
    "examples/nextjs/Dockerfile" \
    "examples/nextjs/.dockerignore" \
    "examples/nextjs/next.config.ts" \
    "examples/nextjs/.cddmrules.toml" \
    "examples/nextjs/.gitea/workflows/ci.yaml" \
    "examples/nextjs/.gitea/workflows/deploy.yaml"; do
    if [ ! -f "$req_file" ]; then
      echo "::error file=$req_file::Missing required reference template file: $req_file"
      FAILED=1
    fi
  done

  local example_ci="examples/nextjs/.gitea/workflows/ci.yaml"
  if [ -f "$example_ci" ]; then
    if ! grep -q "setup-cddm@v1" "$example_ci"; then
      echo "::error file=$example_ci::Example CI must use self:gt-dev/actions/setup-cddm@v1"
      FAILED=1
    fi
    if ! grep -qE "cddm rules check.*--enforce-policies" "$example_ci"; then
      echo "::error file=$example_ci::Example CI cddm rules check must pass --enforce-policies"
      FAILED=1
    fi
    if ! grep -qE "cddm scan .*--no-ignore-tests.*--enforce-policies.*--fail-threshold" "$example_ci"; then
      echo "::error file=$example_ci::Example CI must demonstrate cddm scan with --no-ignore-tests, --enforce-policies, and --fail-threshold"
      FAILED=1
    fi
  fi

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
}

validate_ascii_and_modularity() {
  echo "--> [5/7] Checking for non-ASCII / emoji characters in workflows, actions, containers & scripts..."
  local text_targets
  text_targets="$(find .gitea/workflows scripts examples containers -type f 2>/dev/null ; find . -maxdepth 2 \( -name "action.yaml" -o -name "action.yml" \) ; ls -1 .cddmrules.toml README.md 2>/dev/null || true)"
  text_targets="$(printf '%s\n' "$text_targets" | sort -u)"
  for tf in $text_targets; do
    if [ -f "$tf" ] && LC_ALL=C grep -n '[^[:print:][:space:]]' "$tf" >/dev/null 2>&1; then
      echo "::error file=$tf::Non-ASCII or emoji character detected in $tf"
      FAILED=1
    fi
  done

  echo "--> [6/7] Checking forbidden file extensions & <= 500 line modularity ceiling..."
  local forbidden_files
  forbidden_files="$(find . -not -path "*/.git/*" \( -name "*.js" -o -name "*.cjs" -o -name "*.mjs" \) 2>/dev/null || true)"
  if [ -n "$forbidden_files" ]; then
    echo "::error::Forbidden JavaScript files detected: $forbidden_files"
    FAILED=1
  else
    echo "    Zero raw JavaScript files detected."
  fi

  local mod_targets
  mod_targets="$(find scripts .gitea/workflows examples containers -type f 2>/dev/null | sort ; printf '%s\n' "setup-cddm/action.yaml" ".cddmrules.toml" "README.md")"
  for mf in $mod_targets; do
    if [ -f "$mf" ]; then
      local line_count
      line_count="$(wc -l < "$mf" | tr -d ' ')"
      if [ "$line_count" -gt 500 ]; then
        echo "::error file=$mf::File exceeds 500-line modularity ceiling (${line_count} lines > 500)"
        FAILED=1
      fi
    fi
  done
}
