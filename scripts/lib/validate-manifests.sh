#!/usr/bin/env bash

validate_composite_manifests() {
  echo "--> [1/7] Validating composite action manifests..."
  local action_files
  action_files="$(find . -maxdepth 2 \( -name "action.yaml" -o -name "action.yml" \) | sort)"

  for action_file in $action_files; do
    echo "    Checking $action_file..."

    for req_key in name description runs; do
      if ! grep -q "^${req_key}:" "$action_file"; then
        echo "::error file=$action_file::Missing required top-level '${req_key}' key in $action_file"
        FAILED=1
      fi
    done

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
      local uses_ref
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
      for req_token in "setup-tls-ca" "nextjs-cache:" "detect-bun" "detect-python-uv" "detect-rust"; do
        if ! grep -q "$req_token" "$action_file"; then
          echo "::error file=$action_file::setup-toolchains missing required fast-path/input marker '${req_token}'"
          FAILED=1
        fi
      done
    elif [[ "$action_file" == *"docker-build-push"* ]]; then
      for req_token in "DOCKER_BUILD_SUMMARY" "DOCKER_BUILD_RECORD_UPLOAD" "docker-container" "BUILDKIT_INLINE_CACHE=1" "SUPPORTS_CACHE_EXPORT"; do
        if ! grep -q "$req_token" "$action_file"; then
          echo "::error file=$action_file::docker-build-push missing required marker '${req_token}'"
          FAILED=1
        fi
      done
    elif [[ "$action_file" == *"publish-release"* ]]; then
      for req_token in "setup-tls-ca" "0{64}" "GIT_TERMINAL_PROMPT=0" "GCM_INTERACTIVE=never" "dispatch-homebrew" "dispatch-scoop" "dispatch-winget" "extra-binaries" "scoop-autoupdate"; do
        if ! grep -q "$req_token" "$action_file"; then
          echo "::error file=$action_file::publish-release missing required marker '${req_token}'"
          FAILED=1
        fi
      done
    fi

    check_no_template_injection_in_run "$action_file" "error"
    check_yaml_block_scalar_indentation "$action_file"
  done
}

validate_installer_checksums() {
  echo "--> [2/7] Validating binary installer checksums & latest resolution..."
  if [ ! -f "setup-tls-ca/action.yaml" ]; then
    echo "::error file=setup-tls-ca/action.yaml::Missing required setup-tls-ca composite action"
    FAILED=1
  fi

  verify_installer_action_ssot "setup-cddm/action.yaml" "setup-cddm" "latest"
  verify_installer_action_ssot "gitleaks-scan/action.yaml" "gitleaks-scan" "pinned"
}
