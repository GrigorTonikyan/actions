#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ACTION_FILE="${REPO_ROOT}/docker-build-push/action.yaml"

if [ ! -f "$ACTION_FILE" ]; then
  echo "[FAIL] Missing ${ACTION_FILE}"
  exit 1
fi

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PREP_SCRIPT="${TMP_ROOT}/prep.sh"
awk '
  BEGIN { in_prep = 0; in_run = 0 }
  /^    - name: Prepare Native DinD/ { in_prep = 1; next }
  in_prep && /^    - name: / { exit }
  in_prep && /^      run: \|/ { in_run = 1; next }
  in_prep && in_run {
    sub(/\r$/, "")
    if ($0 ~ /^    - name: / || $0 ~ /^      [a-zA-Z0-9_-]+:/) {
      exit
    }
    sub(/^        /, "")
    print
  }
' "$ACTION_FILE" > "$PREP_SCRIPT"

if [ ! -s "$PREP_SCRIPT" ]; then
  echo "[FAIL] Failed to extract prep script from ${ACTION_FILE}"
  exit 1
fi

MOCK_BIN="${TMP_ROOT}/bin"
mkdir -p "$MOCK_BIN"

cat > "${MOCK_BIN}/docker" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

cmd="${1:-}"
shift || true

case "$cmd" in
  info)
    if [ "${1:-}" = "--format" ]; then
      printf '%s\n' "${MOCK_DRIVER_STATUS:-}"
    else
      printf 'Server Version: 29.9.3\n'
    fi
    ;;
  buildx)
    sub="${1:-}"
    shift || true
    case "$sub" in
      version)
        printf 'github.com/docker/buildx v0.38.1\n'
        ;;
      ls)
        printf '%s*\t%s\n' "${MOCK_BUILDER_NAME:-default}" "${MOCK_DRIVER:-docker}"
        if [ -n "${MOCK_EXTRA_CONTAINER_BUILDER:-}" ]; then
          printf '%s\tdocker-container\n' "${MOCK_EXTRA_CONTAINER_BUILDER}"
        fi
        ;;
      inspect)
        bname="${1:-${MOCK_BUILDER_NAME:-default}}"
        bdriver="${MOCK_DRIVER:-docker}"
        cat <<OUT
Name:          ${bname}
Driver:        ${bdriver}
Last Activity: 2026-11-16 14:16:58 +0000 UTC

Nodes:
Name:                  ${bname}
Endpoint:              ${bname}
Status:                running
BuildKit version:      v0.34.2
Platforms:             linux/amd64
OUT
        if [ "${DEBUG:-}" != "" ] && [ "${MOCK_CACHE_EXPORT_FEATURE:-false}" != "omit" ]; then
          cat <<FEAT
Features:
	Automatically load images to the Docker Engine image store:	true
	Cache export:	${MOCK_CACHE_EXPORT_FEATURE:-false}
	Direct push:	${MOCK_CACHE_EXPORT_FEATURE:-false}
FEAT
        fi
        echo "Labels:"
        echo "	org.mobyproject.buildkit.worker.moby.host-gateway-ip:	172.17.0.1"
        if [ -n "${MOCK_SNAPSHOTTER_LABEL:-}" ]; then
          echo "	org.mobyproject.buildkit.worker.snapshotter:	${MOCK_SNAPSHOTTER_LABEL}"
        fi
        ;;
      *)
        exit 0
        ;;
    esac
    ;;
  *)
    exit 0
    ;;
esac
EOF
chmod +x "${MOCK_BIN}/docker"

get_gh_output() {
  local file="$1"
  local key="$2"
  awk -v target="$key" '
    BEGIN { mode = 0; delim = ""; first = 1 }
    mode == 1 {
      if ($0 == delim) { exit }
      if (!first) { printf "\n" }
      printf "%s", $0
      first = 0
      next
    }
    $0 ~ ("^" target "=") {
      val = substr($0, length(target) + 2)
      printf "%s", val
      exit
    }
    $0 ~ ("^" target "<<") {
      delim = substr($0, length(target) + 3)
      mode = 1
      next
    }
  ' "$file"
}

run_prep_case() {
  local case_dir="${TMP_ROOT}/case-${RANDOM}-${RANDOM}"
  mkdir -p "${case_dir}/tmp"
  : > "${case_dir}/output"
  : > "${case_dir}/env"
  LAST_CASE_DIR="$case_dir"

  local rc=0
  PATH="${MOCK_BIN}:${PATH}" \
  RUNNER_TEMP="${case_dir}/tmp" \
  GITHUB_OUTPUT="${case_dir}/output" \
  GITHUB_ENV="${case_dir}/env" \
  GITHUB_SERVER_URL="${GITHUB_SERVER_URL:-https://example.invalid}" \
  GITHUB_REPOSITORY="${GITHUB_REPOSITORY:-org/app}" \
  GITHUB_REPOSITORY_OWNER="${GITHUB_REPOSITORY_OWNER:-org}" \
  GITHUB_ACTOR="${GITHUB_ACTOR:-org}" \
  GITHUB_SHA="${GITHUB_SHA:-0123456789abcdef}" \
  GITHUB_REF_NAME="${GITHUB_REF_NAME:-main}" \
  INPUT_BUILDER="${INPUT_BUILDER:-}" \
  INPUT_ALLOW_CUSTOM_BUILDER="${INPUT_ALLOW_CUSTOM_BUILDER:-false}" \
  INPUT_PUSH="${INPUT_PUSH:-false}" \
  INPUT_LOGIN="${INPUT_LOGIN:-auto}" \
  INPUT_REGISTRY="${INPUT_REGISTRY:-}" \
  INPUT_USERNAME="${INPUT_USERNAME:-org}" \
  INPUT_PASSWORD="${INPUT_PASSWORD:-}" \
  INPUT_TAGS="${INPUT_TAGS:-}" \
  INPUT_BUILD_ARGS="${INPUT_BUILD_ARGS:-}" \
  INPUT_INLINE_CACHE="${INPUT_INLINE_CACHE:-true}" \
  INPUT_CACHE_FROM="${INPUT_CACHE_FROM:-}" \
  INPUT_CACHE_TO="${INPUT_CACHE_TO:-}" \
  INPUT_CACHE_MODE="${INPUT_CACHE_MODE:-}" \
  INPUT_CACHE_REF="${INPUT_CACHE_REF:-}" \
  INPUT_CACHE_SCOPE="${INPUT_CACHE_SCOPE:-}" \
  INPUT_LABELS="${INPUT_LABELS:-}" \
  INPUT_OCI_LABELS="${INPUT_OCI_LABELS:-true}" \
  INPUT_SECRET_FILES="${INPUT_SECRET_FILES:-}" \
  INPUT_PASS_INTERNAL_CA="${INPUT_PASS_INTERNAL_CA:-true}" \
  INPUT_BUILD_SUMMARY="${INPUT_BUILD_SUMMARY:-false}" \
  INPUT_BUILD_RECORD_UPLOAD="${INPUT_BUILD_RECORD_UPLOAD:-false}" \
  bash "$PREP_SCRIPT" > "${case_dir}/log" 2>&1 || rc=$?

  return "$rc"
}

assert_eq() {
  local actual="$1"
  local expected="$2"
  local label="$3"
  if [ "$actual" != "$expected" ]; then
    echo "[FAIL] ${label}: expected '${expected}', got '${actual}'"
    cat "${LAST_CASE_DIR}/log"
    exit 1
  fi
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if ! printf '%s\n' "$haystack" | grep -qF "$needle"; then
    echo "[FAIL] ${label}: expected output to contain '${needle}', got:"
    printf '%s\n' "$haystack"
    cat "${LAST_CASE_DIR}/log"
    exit 1
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local label="$3"
  if printf '%s\n' "$haystack" | grep -qF "$needle"; then
    echo "[FAIL] ${label}: expected output NOT to contain '${needle}', got:"
    printf '%s\n' "$haystack"
    exit 1
  fi
}

echo "--> Running docker-build-push prep test suite..."

# Case 1: Native DinD docker driver without containerd image store + cache-mode=registry
MOCK_DRIVER="docker" MOCK_CACHE_EXPORT_FEATURE="false" MOCK_BUILDER_NAME="default" \
  MOCK_SNAPSHOTTER_LABEL="" MOCK_DRIVER_STATUS="" \
  INPUT_PUSH="true" INPUT_CACHE_MODE="registry" \
  INPUT_TAGS="example.invalid/org/app:v1.2.3,example.invalid/org/app:latest" \
  INPUT_CACHE_REF="example.invalid/org/app:buildcache" \
  run_prep_case
out_file="${LAST_CASE_DIR}/output"
log_text="$(cat "${LAST_CASE_DIR}/log")"
assert_eq "$(get_gh_output "$out_file" "builder")" "default" "Case 1 builder"
assert_eq "$(get_gh_output "$out_file" "cache-to")" "" "Case 1 downgraded cache-to should be empty with BUILDKIT_INLINE_CACHE=1"
assert_contains "$(get_gh_output "$out_file" "build-args")" "BUILDKIT_INLINE_CACHE=1" "Case 1 build-args inline cache"
assert_contains "$(get_gh_output "$out_file" "cache-from")" "type=registry,ref=example.invalid/org/app:buildcache" "Case 1 retains cache-ref"
assert_contains "$(get_gh_output "$out_file" "cache-from")" "type=registry,ref=example.invalid/org/app:latest" "Case 1 adds latest inline cache fallback"
assert_contains "$log_text" "::warning::" "Case 1 emits downgrade warning"
assert_contains "$log_text" "cache-export='false'" "Case 1 logs cache-export=false"
echo "    [PASS] Case 1: registry mode downgrades cleanly on native DinD docker driver"

# Case 2: Native DinD docker driver without containerd + inline-cache=false + cache-mode=registry
MOCK_DRIVER="docker" MOCK_CACHE_EXPORT_FEATURE="false" MOCK_BUILDER_NAME="default" \
  MOCK_SNAPSHOTTER_LABEL="" \
  INPUT_PUSH="true" INPUT_INLINE_CACHE="false" INPUT_CACHE_MODE="registry" \
  INPUT_TAGS="example.invalid/org/app:v1.0.0" \
  run_prep_case
out_file="${LAST_CASE_DIR}/output"
assert_eq "$(get_gh_output "$out_file" "cache-to")" "type=inline" "Case 2 cache-to downgraded to type=inline when inline-cache=false"
assert_not_contains "$(get_gh_output "$out_file" "build-args")" "BUILDKIT_INLINE_CACHE=1" "Case 2 does not inject build-arg when inline-cache=false"
assert_contains "$(get_gh_output "$out_file" "cache-from")" "type=registry,ref=example.invalid/org/app:buildcache" "Case 2 default cache-ref retained"
assert_contains "$(get_gh_output "$out_file" "cache-from")" "type=registry,ref=example.invalid/org/app:v1.0.0" "Case 2 first tag fallback retained"
echo "    [PASS] Case 2: inline-cache=false downgrades to --cache-to type=inline"

# Case 3: Native DinD docker driver WITH containerd image store preserves registry cache-to
MOCK_DRIVER="docker" MOCK_CACHE_EXPORT_FEATURE="true" MOCK_BUILDER_NAME="default" \
  MOCK_SNAPSHOTTER_LABEL="overlayfs" \
  INPUT_PUSH="true" INPUT_CACHE_MODE="registry" \
  INPUT_TAGS="example.invalid/org/app:latest" \
  INPUT_CACHE_REF="example.invalid/org/app:buildcache" \
  run_prep_case
out_file="${LAST_CASE_DIR}/output"
log_text="$(cat "${LAST_CASE_DIR}/log")"
assert_eq "$(get_gh_output "$out_file" "cache-to")" "type=registry,ref=example.invalid/org/app:buildcache,mode=max" "Case 3 preserves registry cache-to"
assert_eq "$(get_gh_output "$out_file" "cache-from")" "type=registry,ref=example.invalid/org/app:buildcache" "Case 3 preserves single cache-from"
assert_not_contains "$log_text" "::warning::" "Case 3 emits no warning"
assert_contains "$log_text" "cache-export='true'" "Case 3 logs cache-export=true"
echo "    [PASS] Case 3: containerd-enabled docker driver keeps full registry cache export"

# Case 4: gha and local cache modes omit unsupported --cache-to without containerd
MOCK_DRIVER="docker" MOCK_CACHE_EXPORT_FEATURE="false" MOCK_BUILDER_NAME="default" \
  MOCK_SNAPSHOTTER_LABEL="" \
  INPUT_PUSH="true" INPUT_CACHE_MODE="gha" INPUT_CACHE_SCOPE="ci" \
  run_prep_case
out_file="${LAST_CASE_DIR}/output"
assert_eq "$(get_gh_output "$out_file" "cache-to")" "" "Case 4a gha cache-to omitted"
assert_contains "$(cat "${LAST_CASE_DIR}/log")" "::warning::" "Case 4a gha emits warning"

MOCK_DRIVER="docker" MOCK_CACHE_EXPORT_FEATURE="false" MOCK_BUILDER_NAME="default" \
  MOCK_SNAPSHOTTER_LABEL="" \
  INPUT_PUSH="false" INPUT_CACHE_MODE="local" \
  run_prep_case
out_file="${LAST_CASE_DIR}/output"
assert_eq "$(get_gh_output "$out_file" "cache-to")" "" "Case 4b local cache-to omitted"
assert_contains "$(cat "${LAST_CASE_DIR}/log")" "::warning::" "Case 4b local emits warning"
echo "    [PASS] Case 4: gha and local modes omit unsupported --cache-to on docker driver"

# Case 5: explicit cache-to filters unsupported entries while preserving type=inline
MOCK_DRIVER="docker" MOCK_CACHE_EXPORT_FEATURE="false" MOCK_BUILDER_NAME="default" \
  MOCK_SNAPSHOTTER_LABEL="" \
  INPUT_PUSH="true" INPUT_CACHE_MODE="" \
  INPUT_CACHE_TO=$'type=registry,ref=example.invalid/org/app:buildcache,mode=max\ntype=inline' \
  run_prep_case
out_file="${LAST_CASE_DIR}/output"
assert_eq "$(get_gh_output "$out_file" "cache-to")" "type=inline" "Case 5 preserves explicit type=inline and drops type=registry"
assert_contains "$(cat "${LAST_CASE_DIR}/log")" "::warning::" "Case 5 emits warning for dropped entry"
echo "    [PASS] Case 5: explicit cache-to filters unsupported exports and keeps type=inline"

# Case 6: cache-mode=registry with push=false emits no downgrade warning
MOCK_DRIVER="docker" MOCK_CACHE_EXPORT_FEATURE="false" MOCK_BUILDER_NAME="default" \
  MOCK_SNAPSHOTTER_LABEL="" \
  INPUT_PUSH="false" INPUT_CACHE_MODE="registry" \
  INPUT_TAGS="example.invalid/org/app:latest" \
  INPUT_CACHE_REF="example.invalid/org/app:buildcache" \
  run_prep_case
out_file="${LAST_CASE_DIR}/output"
log_text="$(cat "${LAST_CASE_DIR}/log")"
assert_eq "$(get_gh_output "$out_file" "cache-to")" "" "Case 6 push=false cache-to empty"
assert_contains "$(get_gh_output "$out_file" "cache-from")" "type=registry,ref=example.invalid/org/app:buildcache" "Case 6 retains cache-from"
assert_not_contains "$log_text" "::warning::" "Case 6 emits no warning when push=false"
echo "    [PASS] Case 6: cache-mode=registry with push=false retains cache-from without warnings"

# Case 7: custom docker-container builder keeps full registry cache export
MOCK_DRIVER="docker-container" MOCK_CACHE_EXPORT_FEATURE="true" MOCK_BUILDER_NAME="mybuilder" \
  MOCK_SNAPSHOTTER_LABEL="" \
  INPUT_ALLOW_CUSTOM_BUILDER="true" INPUT_BUILDER="mybuilder" \
  INPUT_PUSH="true" INPUT_CACHE_MODE="registry" \
  INPUT_TAGS="example.invalid/org/app:latest" \
  run_prep_case
out_file="${LAST_CASE_DIR}/output"
assert_eq "$(get_gh_output "$out_file" "builder")" "mybuilder" "Case 7 custom builder output"
assert_eq "$(get_gh_output "$out_file" "cache-to")" "type=registry,ref=example.invalid/org/app:buildcache,mode=max" "Case 7 docker-container keeps registry cache-to"
echo "    [PASS] Case 7: custom docker-container builder preserves registry cache-to"

# Case 8: fallback when Features section is omitted on older buildx CLI
MOCK_DRIVER="docker" MOCK_CACHE_EXPORT_FEATURE="omit" MOCK_BUILDER_NAME="default" \
  MOCK_SNAPSHOTTER_LABEL="" MOCK_DRIVER_STATUS="[[Backing Filesystem zfs]]" \
  INPUT_PUSH="true" INPUT_CACHE_MODE="registry" \
  INPUT_TAGS="example.invalid/org/app:latest" \
  run_prep_case
out_file="${LAST_CASE_DIR}/output"
log_text="$(cat "${LAST_CASE_DIR}/log")"
assert_eq "$(get_gh_output "$out_file" "cache-to")" "" "Case 8 fallback downgrades cache-to"
assert_contains "$log_text" "cache-export='false'" "Case 8 fallback detects cache-export=false"
assert_contains "$log_text" "::warning::" "Case 8 fallback emits warning"
echo "    [PASS] Case 8: older buildx CLI fallback safely detects lack of containerd store"

# Case 9: non-docker driver still rejected unless allow-custom-builder=true
if MOCK_DRIVER="docker-container" MOCK_CACHE_EXPORT_FEATURE="true" MOCK_BUILDER_NAME="mybuilder" \
  INPUT_ALLOW_CUSTOM_BUILDER="false" \
  run_prep_case; then
  echo "[FAIL] Case 9: expected docker-container builder without allow-custom-builder to fail"
  exit 1
fi
assert_contains "$(cat "${LAST_CASE_DIR}/log")" "::error::Active Buildx builder" "Case 9 emits expected error"
echo "    [PASS] Case 9: docker-container builder blocked unless allow-custom-builder=true"

echo "[PASS] All docker-build-push prep tests passed!"
