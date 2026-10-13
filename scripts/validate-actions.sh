#!/usr/bin/env bash
set -euo pipefail

echo "========================================================"
echo "      Gitea Actions Repository Quality & SSoT Validation"
echo "========================================================"

FAILED=0

# 1. Validate composite action manifests
echo "--> [1/3] Validating composite action manifests..."
ACTION_FILES=$(find . -maxdepth 2 \( -name "action.yaml" -o -name "action.yml" \) | sort)

for action_file in $ACTION_FILES; do
  echo "    Checking $action_file..."

  # Check required keys in action manifest
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

  # Check zero-warning policy: forbid warning suppression variables
  if grep -E "(NODE_NO_WARNINGS|--no-deprecation)" "$action_file" >/dev/null 2>&1; then
    echo "::error file=$action_file::Warning suppression variable detected in $action_file (violates zero-warning standard)"
    FAILED=1
  fi

  # Enforce security standard: forbid set -x which risks secret leakage into runner logs
  if grep -E "^\s*set\s+-[a-z]*x" "$action_file" >/dev/null 2>&1; then
    echo "::error file=$action_file::Unsafe shell tracing 'set -x' detected in $action_file (security violation: exposes secrets)"
    FAILED=1
  fi

  # Check setup-playwright force-unsafe-io configuration
  if [[ "$action_file" == *"setup-playwright"* ]] && ! grep -q "force-unsafe-io" "$action_file"; then
    echo "::error file=$action_file::setup-playwright must configure dpkg force-unsafe-io to prevent fsync stalls"
    FAILED=1
  fi
done

# 2. Validate PLAYWRIGHT_VERSION SSoT & Dockerfile Optimizations
echo "--> [2/3] Validating Playwright container version SSoT & Dockerfile..."
PW_VER_FILE="containers/playwright/PLAYWRIGHT_VERSION"
if [ ! -f "$PW_VER_FILE" ]; then
  echo "::error file=$PW_VER_FILE::Missing $PW_VER_FILE file!"
  FAILED=1
else
  PW_VER=$(tr -d ' \r\n' < "$PW_VER_FILE")
  if ! echo "$PW_VER" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' >/dev/null; then
    echo "::error file=$PW_VER_FILE::Invalid semver in $PW_VER_FILE: '$PW_VER'"
    FAILED=1
  else
    echo "    SSoT Playwright Version: $PW_VER"

    DOCKERFILE="containers/playwright/Dockerfile"
    if [ ! -f "$DOCKERFILE" ]; then
      echo "::error file=$DOCKERFILE::Missing $DOCKERFILE!"
      FAILED=1
    elif ! grep -q "ARG PLAYWRIGHT_VERSION=${PW_VER}" "$DOCKERFILE"; then
      echo "::error file=$DOCKERFILE::Dockerfile default ARG PLAYWRIGHT_VERSION does not match $PW_VER!"
      FAILED=1
    else
      echo "    Dockerfile default ARG matches $PW_VER."
    fi

    if [ -f "$DOCKERFILE" ] && ! grep -q "force-unsafe-io" "$DOCKERFILE"; then
      echo "::error file=$DOCKERFILE::Dockerfile must configure dpkg force-unsafe-io for build acceleration!"
      FAILED=1
    else
      echo "    Dockerfile dpkg force-unsafe-io speedup verified."
    fi
  fi
fi

# 3. Check for forbidden file types (.js/.cjs/.mjs)
echo "--> [3/3] Checking for forbidden file extensions..."
FORBIDDEN_FILES=$(find . -not -path "*/.git/*" \( -name "*.js" -o -name "*.cjs" -o -name "*.mjs" \) 2>/dev/null || true)
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
