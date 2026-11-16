#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ACTION_FILE="${REPO_ROOT}/setup-cddm/action.yaml"

if [ ! -f "$ACTION_FILE" ]; then
  echo "[FAIL] Missing ${ACTION_FILE}"
  exit 1
fi

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

INSTALL_SCRIPT="${TMP_ROOT}/install-cddm.sh"
awk '
  BEGIN { in_step = 0; in_run = 0 }
  /^    - name: Install Latest or Pinned Verified CDDM Binary/ { in_step = 1; next }
  in_step && /^    - name: / { exit }
  in_step && /^      run: \|/ { in_run = 1; next }
  in_step && in_run {
    sub(/\r$/, "")
    if ($0 ~ /^    - name: / || $0 ~ /^      [a-zA-Z0-9_-]+:/) {
      exit
    }
    sub(/^        /, "")
    print
  }
' "$ACTION_FILE" > "$INSTALL_SCRIPT"

if [ ! -s "$INSTALL_SCRIPT" ]; then
  echo "[FAIL] Failed to extract install script from ${ACTION_FILE}"
  exit 1
fi

FIXTURES_DIR="${TMP_ROOT}/fixtures"
mkdir -p "$FIXTURES_DIR"

build_mock_release() {
  local tag="$1"
  local semver="${tag#v}"
  local rel_dir="${FIXTURES_DIR}/${tag}"
  mkdir -p "${rel_dir}/payload"

  cat > "${rel_dir}/payload/cddm" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "--version" ]; then
  printf 'cddm %s\n' "${semver}"
  exit 0
fi
exit 0
EOF
  chmod +x "${rel_dir}/payload/cddm"
  printf '#!/usr/bin/env bash\nexit 0\n' > "${rel_dir}/payload/cddm-mcp"
  chmod +x "${rel_dir}/payload/cddm-mcp"

  local arch_name="cddm-${tag}-x86_64-unknown-linux-gnu.tar.gz"
  tar -czf "${rel_dir}/${arch_name}" -C "${rel_dir}/payload" cddm cddm-mcp
  local sha
  sha="$(sha256sum "${rel_dir}/${arch_name}" | awk '{print tolower($1)}')"
  if [ "${MOCK_ZERO_HASH:-false}" = "true" ]; then
    sha="0000000000000000000000000000000000000000000000000000000000000000"
  fi
  printf '%s  %s\n' "$sha" "$arch_name" > "${rel_dir}/SHA256SUMS.txt"
  printf '%s' "$sha" > "${rel_dir}/sha256"
}

PINNED_VER="$(grep 'PINNED_VERSION="' "$ACTION_FILE" | head -n1 | awk -F'"' '{print $2}')"
PINNED_SHA="$(grep 'PINNED_SHA256="' "$ACTION_FILE" | head -n1 | awk -F'"' '{print $2}')"

build_mock_release "v4.12.0"
build_mock_release "v4.10.5"
build_mock_release "$PINNED_VER"

MOCK_BIN="${TMP_ROOT}/mock-bin"
mkdir -p "$MOCK_BIN"

cat > "${MOCK_BIN}/uname" << 'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-m" ]; then
  printf 'x86_64\n'
  exit 0
fi
printf 'Linux\n'
EOF
chmod +x "${MOCK_BIN}/uname"

cat > "${MOCK_BIN}/curl" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [ -n "${MOCK_CURL_ARGS_LOG:-}" ]; then
  printf '%s\n' "$*" >> "$MOCK_CURL_ARGS_LOG"
fi

out=""
url=""
has_cfg="false"
while [ $# -gt 0 ]; do
  case "$1" in
    -o)
      out="$2"
      shift 2
      ;;
    -K)
      has_cfg="true"
      if [ -n "${MOCK_CURL_CFG_PERM_LOG:-}" ] && [ -f "$2" ]; then
        cat "$2" > "$MOCK_CURL_CFG_PERM_LOG"
      fi
      shift 2
      ;;
    -*)
      shift
      ;;
    *)
      url="$1"
      shift
      ;;
  esac
done

if [[ "$url" == */releases/latest ]]; then
  if [ "${MOCK_LATEST_FAIL:-false}" = "true" ]; then
    exit 22
  fi
  if [[ "$url" == *"/wrong-org/cddm/"* ]]; then
    exit 22
  fi
  printf '{"id":999,"tag_name":"%s","name":"Release %s"}\n' "${MOCK_LATEST_TAG:-v4.12.0}" "${MOCK_LATEST_TAG:-v4.12.0}" > "$out"
  exit 0
fi

for tag in v4.12.0 v4.10.5 "${PINNED_VER:-v4.11.0}"; do
  if [[ "$url" == *"/releases/download/${tag}/SHA256SUMS.txt" ]]; then
    if [ "${MOCK_ZERO_SHA256SUMS:-false}" = "true" ]; then
      printf '0000000000000000000000000000000000000000000000000000000000000000  cddm-%s-x86_64-unknown-linux-gnu.tar.gz\n' "$tag" > "$out"
    else
      cp "${MOCK_FIXTURES}/${tag}/SHA256SUMS.txt" "$out"
    fi
    exit 0
  fi
  arch_file="cddm-${tag}-x86_64-unknown-linux-gnu.tar.gz"
  if [[ "$url" == *"/releases/download/${tag}/${arch_file}" ]]; then
    cp "${MOCK_FIXTURES}/${tag}/${arch_file}" "$out"
    exit 0
  fi
done

echo "Mock curl unhandled URL: $url (has_cfg=$has_cfg)" >&2
exit 22
EOF
chmod +x "${MOCK_BIN}/curl"

# Provide minimal jq override check: test POSIX fallback too by masking jq when requested
run_case() {
  local case_dir="${TMP_ROOT}/case-${RANDOM}-${RANDOM}"
  mkdir -p "${case_dir}/tmp" "${case_dir}/dest" "${case_dir}/prebin"
  : > "${case_dir}/output"
  : > "${case_dir}/path"
  LAST_CASE_DIR="$case_dir"

  local extra_path=""
  if [ -n "${PREINSTALLED_CDDM_VER:-}" ]; then
    cat > "${case_dir}/prebin/cddm" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "--version" ]; then
  printf 'cddm %s\n' "${PREINSTALLED_CDDM_VER}"
  exit 0
fi
exit 0
EOF
    chmod +x "${case_dir}/prebin/cddm"
    extra_path="${case_dir}/prebin:"
  fi

  local rc=0
  (
    export PATH="${MOCK_BIN}:${extra_path}/usr/bin:/bin"
    export MOCK_FIXTURES="$FIXTURES_DIR"
    export PINNED_VER="$PINNED_VER"
    export RUNNER_TEMP="${case_dir}/tmp"
    export GITHUB_OUTPUT="${case_dir}/output"
    export GITHUB_PATH="${case_dir}/path"
    export GITHUB_SERVER_URL="https://example.invalid"
    export GITHUB_REPOSITORY_OWNER="${MOCK_REPO_OWNER:-gt-dev}"
    export GITHUB_ACTION_REPOSITORY="${MOCK_ACTION_REPO:-gt-dev/actions}"
    export INPUT_VERSION="${INPUT_VERSION:-latest}"
    export INPUT_SHA256="${INPUT_SHA256:-}"
    export INPUT_REPOSITORY="${INPUT_REPOSITORY:-${MOCK_REPO_OWNER:-gt-dev}/cddm}"
    export INPUT_SERVER_URL="${INPUT_SERVER_URL:-https://example.invalid}"
    export INPUT_DESTINATION="${case_dir}/dest"
    export INPUT_TOKEN="${INPUT_TOKEN:-}"
    export MOCK_LATEST_TAG="${MOCK_LATEST_TAG:-v4.12.0}"
    export MOCK_LATEST_FAIL="${MOCK_LATEST_FAIL:-false}"
    export MOCK_ZERO_SHA256SUMS="${MOCK_ZERO_SHA256SUMS:-false}"
    export MOCK_CURL_ARGS_LOG="${case_dir}/curl-args.log"
    export MOCK_CURL_CFG_PERM_LOG="${case_dir}/curl-cfg.log"
    bash "$INSTALL_SCRIPT"
  ) > "${case_dir}/log" 2>&1 || rc=$?
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

echo "--> Running setup-cddm unit test suite..."

# Case 1: Default latest resolves newest release (v4.12.0), verifies SHA256SUMS.txt, and installs
PREINSTALLED_CDDM_VER="" MOCK_LATEST_TAG="v4.12.0" INPUT_VERSION="latest" run_case
assert_eq "$(grep '^version=' "${LAST_CASE_DIR}/output" | cut -d= -f2)" "4.12.0" "Case 1 resolved version"
assert_eq "$(grep '^tag=' "${LAST_CASE_DIR}/output" | cut -d= -f2)" "v4.12.0" "Case 1 resolved tag"
assert_eq "$(grep '^cached=' "${LAST_CASE_DIR}/output" | cut -d= -f2)" "false" "Case 1 cached=false"
assert_eq "$("${LAST_CASE_DIR}/dest/cddm" --version)" "cddm 4.12.0" "Case 1 installed binary version"
echo "    [PASS] Case 1: version=latest resolves newest release and verifies SHA256SUMS.txt"

# Case 2: Pre-installed older version (4.9.2) upgrades cleanly to latest (4.12.0)
PREINSTALLED_CDDM_VER="4.9.2" MOCK_LATEST_TAG="v4.12.0" INPUT_VERSION="latest" run_case
assert_eq "$(grep '^version=' "${LAST_CASE_DIR}/output" | cut -d= -f2)" "4.12.0" "Case 2 upgraded version"
assert_eq "$(grep '^cached=' "${LAST_CASE_DIR}/output" | cut -d= -f2)" "false" "Case 2 does not false-hit cache"
echo "    [PASS] Case 2: outdated pre-installed binary is upgraded to latest"

# Case 3: Pre-installed matching latest (4.12.0) hits fast-path without download
PREINSTALLED_CDDM_VER="4.12.0" MOCK_LATEST_TAG="v4.12.0" INPUT_VERSION="latest" run_case
assert_eq "$(grep '^version=' "${LAST_CASE_DIR}/output" | cut -d= -f2)" "4.12.0" "Case 3 fast-path version"
assert_eq "$(grep '^cached=' "${LAST_CASE_DIR}/output" | cut -d= -f2)" "true" "Case 3 cached=true"
echo "    [PASS] Case 3: up-to-date binary hits fast-path"

# Case 4: /releases/latest outage fails loudly (refuses silent downgrade)
if PREINSTALLED_CDDM_VER="" MOCK_LATEST_FAIL="true" INPUT_VERSION="latest" run_case; then
  echo "[FAIL] Case 4: expected failure when /releases/latest fails"
  exit 1
fi
if ! grep -q "Refusing silent version downgrade" "${LAST_CASE_DIR}/log"; then
  echo "[FAIL] Case 4: expected silent downgrade error guard"
  cat "${LAST_CASE_DIR}/log"
  exit 1
fi
echo "    [PASS] Case 4: /releases/latest failure refuses silent version downgrade"

# Case 5: Zeroed 0{64} digest in SHA256SUMS.txt is rejected
if PREINSTALLED_CDDM_VER="" MOCK_LATEST_TAG="v4.12.0" MOCK_ZERO_SHA256SUMS="true" INPUT_VERSION="latest" run_case; then
  echo "[FAIL] Case 5: expected zeroed SHA256SUMS.txt digest to be rejected"
  exit 1
fi
if ! grep -q "forbidden all-zero SHA-256" "${LAST_CASE_DIR}/log"; then
  echo "[FAIL] Case 5: expected all-zero checksum error message"
  cat "${LAST_CASE_DIR}/log"
  exit 1
fi
echo "    [PASS] Case 5: all-zero 0{64} SHA-256 checksum rejected"

# Case 6: Explicit pinned version override (4.10.5) installs requested version
PREINSTALLED_CDDM_VER="" INPUT_VERSION="4.10.5" run_case
assert_eq "$(grep '^version=' "${LAST_CASE_DIR}/output" | cut -d= -f2)" "4.10.5" "Case 6 explicit version"
assert_eq "$(grep '^tag=' "${LAST_CASE_DIR}/output" | cut -d= -f2)" "v4.10.5" "Case 6 explicit tag"
echo "    [PASS] Case 6: explicit semver override installs requested version"

# Case 7: Optional token passed via curl -K config file, never in CLI args or URLs
PREINSTALLED_CDDM_VER="" MOCK_LATEST_TAG="v4.12.0" INPUT_VERSION="latest" INPUT_TOKEN="super-secret-token" run_case
if grep -q "super-secret-token" "${LAST_CASE_DIR}/curl-args.log"; then
  echo "[FAIL] Case 7: token leaked into curl CLI arguments"
  exit 1
fi
if ! grep -q 'Authorization: token super-secret-token' "${LAST_CASE_DIR}/curl-cfg.log"; then
  echo "[FAIL] Case 7: expected Authorization header in curl -K config"
  exit 1
fi
echo "    [PASS] Case 7: token transmitted strictly via curl -K config (zero CLI/URL leak)"

# Case 8: Cross-org consumer (wrong-org/cddm) falls back to action owner repository (gt-dev/cddm)
PREINSTALLED_CDDM_VER="" MOCK_REPO_OWNER="wrong-org" MOCK_ACTION_REPO="gt-dev/actions" INPUT_REPOSITORY="wrong-org/cddm" INPUT_VERSION="latest" MOCK_LATEST_TAG="v4.12.0" run_case
assert_eq "$(grep '^version=' "${LAST_CASE_DIR}/output" | cut -d= -f2)" "4.12.0" "Case 8 fallback version"
echo "    [PASS] Case 8: cross-org consumer falls back cleanly to action owner cddm repo"

# Case 9: Explicit SHA-256 override accepts matching digest and rejects mismatched digest
V4105_SHA="$(cat "${FIXTURES_DIR}/v4.10.5/sha256")"
PREINSTALLED_CDDM_VER="" INPUT_VERSION="v4.10.5" INPUT_SHA256="$V4105_SHA" run_case
assert_eq "$(grep '^version=' "${LAST_CASE_DIR}/output" | cut -d= -f2)" "4.10.5" "Case 9 matching override version"
if PREINSTALLED_CDDM_VER="" INPUT_VERSION="v4.10.5" INPUT_SHA256="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" run_case; then
  echo "[FAIL] Case 9: expected mismatched SHA-256 override to fail"
  exit 1
fi
echo "    [PASS] Case 9: explicit sha256 override validates match and rejects mismatch"

echo "[PASS] All setup-cddm unit tests passed!"
