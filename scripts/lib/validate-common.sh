#!/usr/bin/env bash

print_banner() {
  local title="$1"
  echo "========================================================"
  echo "${title}"
  echo "========================================================"
}

check_no_template_injection_in_run() {
  local target_file="$1"
  local mode="${2:-error}"
  local matches
  matches="$(awk '
    BEGIN { in_run = 0; run_indent = -1 }
    {
      line = $0
      sub(/\r$/, "", line)
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

check_yaml_block_scalar_indentation() {
  local target_file="$1"
  local violations
  violations="$(awk '
    BEGIN { in_run = 0; run_indent = -1; in_steps = 0 }
    {
      line = $0
      sub(/\r$/, "", line)
      match(line, /^[ ]*/)
      indent = RLENGTH
      trimmed = substr(line, indent + 1)

      if (trimmed == "") {
        next
      }

      if (indent == 0 && (trimmed ~ /^runs:/ || trimmed ~ /^jobs:/)) {
        in_steps = 1
      } else if (indent == 0 && in_steps == 1 && trimmed !~ /^(name|description|author|inputs|outputs|runs|branding|on|env|defaults|concurrency|permissions|jobs):/ && trimmed !~ /^#/) {
        printf "%d:Unindented line at column 0 after runs/jobs section (%s)\n", NR, line
      }

      if (in_run == 1) {
        if (indent > run_indent) {
          if (trimmed ~ /(^|[[:space:]])cat[[:space:]].*<</ && trimmed !~ /<<-/) {
            printf "%d:Unindented cat << heredoc inside run block risks breaking YAML block scalar parsing (%s)\n", NR, line
          }
          next
        }
        if (trimmed ~ /^#/ && indent == 0) {
          printf "%d:Unindented comment at column 0 inside run block breaks YAML block scalar parsing (%s)\n", NR, line
          next
        }
        if (trimmed !~ /^-[[:space:]]+(name|id|if|uses|run|shell|env|with|working-directory|continue-on-error|timeout-minutes):/ &&
            trimmed !~ /^(name|id|if|uses|run|shell|env|with|working-directory|continue-on-error|timeout-minutes|runs-on|needs|permissions|concurrency|outputs|strategy|container|services|steps|defaults):/ &&
            trimmed !~ /^[a-zA-Z0-9_-]+:$/) {
          printf "%d:Under-indented line breaks YAML run block scalar (%s)\n", NR, line
        }
        in_run = 0
        run_indent = -1
      }

      if (trimmed ~ /^-[[:space:]]+run:[[:space:]]*[|>]/ || trimmed ~ /^run:[[:space:]]*[|>]/) {
        in_run = 1
        run_indent = indent
        next
      }
    }
  ' "$target_file")"

  if [ -n "$violations" ]; then
    while IFS= read -r v; do
      echo "::error file=${target_file}::YAML block scalar indentation violation: ${v}"
      FAILED=1
    done <<< "$violations"
  fi
}

validate_arg_pinned_digest() {
  local dockerfile="$1"
  local image_ref="$2"
  local arg_name="$3"
  local expected_regex="$4"
  local error_msg="$5"
  if ! grep -E "^ARG ${arg_name}=${expected_regex}$" "$dockerfile" >/dev/null 2>&1; then
    echo "::error file=${dockerfile}::${error_msg} ('${image_ref}')"
    FAILED=1
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

  local stage_aliases
  stage_aliases="$(awk 'toupper($1) == "FROM" { for (i=1; i<=NF; i++) if (toupper($i) == "AS" && i < NF) print $(i+1) }' "$dockerfile")"

  while IFS= read -r from_line; do
    local image_ref
    image_ref="$(printf '%s\n' "$from_line" | awk '{for (i=2; i<=NF; i++) { if ($i !~ /^--/) { print $i; exit } }}')"

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

    if [[ "$image_ref" =~ ^\$\{([A-Za-z_][A-Za-z0-9_]*)\}$ ]]; then
      validate_arg_pinned_digest "$dockerfile" "$image_ref" "${BASH_REMATCH[1]}" ".*@sha256:[0-9a-f]{64}" "Parameterized FROM must default to an immutable @sha256: digest"
      continue
    fi

    if [[ "$image_ref" =~ @\$\{([A-Za-z_][A-Za-z0-9_]*)\}$ ]]; then
      validate_arg_pinned_digest "$dockerfile" "$image_ref" "${BASH_REMATCH[1]}" "sha256:[0-9a-f]{64}" "Parameterized digest FROM must default to sha256:<64-hex>"
      continue
    fi

    if ! printf '%s\n' "$image_ref" | grep -qE '@sha256:[0-9a-f]{64}$'; then
      echo "::error file=${dockerfile}::FROM image '${image_ref}' must be pinned to an immutable @sha256: digest"
      FAILED=1
    fi
  done < <(grep -E '^[[:space:]]*FROM[[:space:]]+' "$dockerfile" | tr -d '\r')
}

verify_installer_action_ssot() {
  local action_file="$1"
  local action_label="$2"
  local version_policy="$3"

  if [ ! -f "$action_file" ]; then
    return 0
  fi

  local default_ver pinned_ver pinned_sha
  default_ver="$(grep -A 5 "^  version:" "$action_file" | grep "default:" | head -n1 | awk -F'"' '{print $2}')"
  pinned_ver="$(grep 'PINNED_VERSION="' "$action_file" | head -n1 | awk -F'"' '{print $2}')"
  pinned_sha="$(grep 'PINNED_SHA256="' "$action_file" | head -n1 | awk -F'"' '{print $2}')"

  if [ -z "$pinned_ver" ] || ! printf '%s\n' "$pinned_ver" | grep -qE '^v?[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "::error file=$action_file::${action_label} PINNED_VERSION must be a valid semver tag (found '${pinned_ver:-unset}')"
    FAILED=1
  fi

  if [ "$version_policy" = "latest" ]; then
    if [ "$default_ver" != "latest" ]; then
      echo "::error file=$action_file::${action_label} inputs.version.default must be 'latest' to stay on latest release (found '${default_ver:-unset}')"
      FAILED=1
    fi
    if ! grep -qE "releases\?limit=|releases/latest" "$action_file" || ! grep -q "SHA256SUMS.txt" "$action_file"; then
      echo "::error file=$action_file::${action_label} must resolve latest ready release metadata and verify SHA256SUMS.txt"
      FAILED=1
    fi
  else
    if [ -z "$default_ver" ] || ! printf '%s\n' "$default_ver" | grep -qE '^v?[0-9]+\.[0-9]+\.[0-9]+$'; then
      echo "::error file=$action_file::${action_label} default version must be a valid semver tag (found '${default_ver:-unset}')"
      FAILED=1
    fi
    if [ "$default_ver" != "$pinned_ver" ]; then
      echo "::error file=$action_file::${action_label} inputs.version.default ('${default_ver:-unset}') does not match PINNED_VERSION ('${pinned_ver:-unset}')"
      FAILED=1
    fi
  fi

  if [ -z "$pinned_sha" ] || ! printf '%s\n' "$pinned_sha" | grep -qE '^[0-9a-f]{64}$' || printf '%s\n' "$pinned_sha" | grep -qE '^0+$'; then
    echo "::error file=$action_file::${action_label} PINNED_SHA256 must be a valid non-zero 64-character hexadecimal digest"
    FAILED=1
  else
    echo "    Verified ${action_label} SSoT (default=${default_ver}, pinned=${pinned_ver} -> ${pinned_sha})."
  fi
}
