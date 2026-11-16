#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ACTION_FILE="${REPO_ROOT}/publish-release/action.yaml"

if [ ! -f "$ACTION_FILE" ]; then
  echo "[FAIL] Missing ${ACTION_FILE}"
  exit 1
fi

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

DISPATCH_SCRIPT="${TMP_ROOT}/dispatch.sh"
awk '
  BEGIN { in_dispatch = 0; in_run = 0 }
  /^    - name: Verify Binary Asset URLs & Dispatch Package Manager Manifests/ { in_dispatch = 1; next }
  in_dispatch && /^    - name: / { exit }
  in_dispatch && /^      run: \|/ { in_run = 1; next }
  in_dispatch && in_run {
    sub(/\r$/, "")
    if ($0 ~ /^    - name: / || $0 ~ /^      [a-zA-Z0-9_-]+:/) {
      exit
    }
    sub(/^        /, "")
    print
  }
' "$ACTION_FILE" > "$DISPATCH_SCRIPT"

if [ ! -s "$DISPATCH_SCRIPT" ]; then
  echo "[FAIL] Failed to extract dispatch script from ${ACTION_FILE}"
  exit 1
fi

get_gh_output() {
  local file="$1"
  local key="$2"
  awk -v target="$key" '
    $0 ~ ("^" target "=") {
      val = substr($0, length(target) + 2)
      printf "%s", val
      exit
    }
  ' "$file"
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
    echo "[FAIL] ${label}: expected content to contain '${needle}', got:"
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
    echo "[FAIL] ${label}: expected content NOT to contain '${needle}', got:"
    printf '%s\n' "$haystack"
    exit 1
  fi
}

run_dispatch_case() {
  local case_dir="${TMP_ROOT}/case-${RANDOM}-${RANDOM}"
  mkdir -p "${case_dir}/tmp" "${case_dir}/work"
  : > "${case_dir}/output"
  LAST_CASE_DIR="$case_dir"

  local sums_file="${case_dir}/SHA256SUMS.txt"
  cat > "$sums_file" << 'EOF'
a111111111111111111111111111111111111111111111111111111111111111  cddm-v4.10.2-aarch64-apple-darwin.tar.gz
b222222222222222222222222222222222222222222222222222222222222222  cddm-v4.10.2-x86_64-unknown-linux-gnu.tar.gz
c333333333333333333333333333333333333333333333333333333333333333  cddm-v4.10.2-x86_64-pc-windows-msvc.zip
EOF

  local rc=0
  RUNNER_TEMP="${case_dir}/tmp" \
  PKG_DISPATCH_WORK_ROOT="${case_dir}/work" \
  GITHUB_OUTPUT="${case_dir}/output" \
  GITHUB_ACTOR="release-bot" \
  CHECKSUMS_PATH="$sums_file" \
  APP_NAME="${APP_NAME:-cddm}" \
  SEMVER="${SEMVER:-4.10.2}" \
  TAG_NAME="${TAG_NAME:-v4.10.2}" \
  SERVER_URL="${SERVER_URL:-https://example.invalid}" \
  REPO_OWNER="${REPO_OWNER:-org}" \
  REPO_NAME="${REPO_NAME:-cddm}" \
  INPUT_DISPATCH_HOMEBREW="${INPUT_DISPATCH_HOMEBREW:-true}" \
  INPUT_HOMEBREW_MODE="${INPUT_HOMEBREW_MODE:-both}" \
  INPUT_HOMEBREW_COMPLETIONS="${INPUT_HOMEBREW_COMPLETIONS:-true}" \
  INPUT_DISPATCH_SCOOP="${INPUT_DISPATCH_SCOOP:-true}" \
  INPUT_SCOOP_AUTOUPDATE="${INPUT_SCOOP_AUTOUPDATE:-true}" \
  INPUT_SCOOP_CHECKVER="${INPUT_SCOOP_CHECKVER:-github}" \
  INPUT_DISPATCH_WINGET="${INPUT_DISPATCH_WINGET:-true}" \
  INPUT_VERIFY_URLS="${INPUT_VERIFY_URLS:-false}" \
  INPUT_PUBLISHER="${INPUT_PUBLISHER:-org}" \
  INPUT_PUBLISHER_NAME="${INPUT_PUBLISHER_NAME:-Example Org}" \
  INPUT_DESCRIPTION="${INPUT_DESCRIPTION:-Polyglot Code De-Duplication Meister}" \
  INPUT_HOMEPAGE="${INPUT_HOMEPAGE:-https://example.invalid/org/cddm}" \
  INPUT_LICENSE="${INPUT_LICENSE:-MIT}" \
  INPUT_BINARY_NAME="${INPUT_BINARY_NAME:-}" \
  INPUT_EXTRA_BINARIES="${INPUT_EXTRA_BINARIES:-}" \
  INPUT_HOMEBREW_TAP_REPO="${INPUT_HOMEBREW_TAP_REPO:-}" \
  INPUT_SCOOP_BUCKET_REPO="${INPUT_SCOOP_BUCKET_REPO:-}" \
  INPUT_WINGET_REPO="${INPUT_WINGET_REPO:-}" \
  INPUT_DISTRIBUTION_BRANCH="${INPUT_DISTRIBUTION_BRANCH:-main}" \
  INPUT_SSH_PORT="${INPUT_SSH_PORT:-30009}" \
  INPUT_DRY_RUN="true" \
  bash "$DISPATCH_SCRIPT" > "${case_dir}/log" 2>&1 || rc=$?

  if [ "$rc" -ne 0 ]; then
    cat "${case_dir}/log"
  fi
  return "$rc"
}

echo "--> Running publish-release multi-binary manifest test suite..."

# Case 1: Multi-binary via extra-binaries (cddm, cddm-mcp, cddm-lsp)
INPUT_BINARY_NAME="cddm" INPUT_EXTRA_BINARIES="cddm-mcp,cddm-lsp" \
  run_dispatch_case
out_file="${LAST_CASE_DIR}/output"
work_dir="${LAST_CASE_DIR}/work"
assert_eq "$(get_gh_output "$out_file" "binaries")" "cddm,cddm-mcp,cddm-lsp" "Case 1 binaries output"
assert_eq "$(get_gh_output "$out_file" "dispatched-targets")" "homebrew,scoop,winget" "Case 1 dispatched-targets"

formula_text="$(cat "${work_dir}/homebrew-tap/Formula/cddm.rb")"
assert_contains "$formula_text" 'bin.install "cddm"' "Case 1 formula primary bin"
assert_contains "$formula_text" 'bin.install "cddm-mcp" if File.exist?("cddm-mcp")' "Case 1 formula cddm-mcp"
assert_contains "$formula_text" 'bin.install "cddm-lsp" if File.exist?("cddm-lsp")' "Case 1 formula cddm-lsp"
assert_contains "$formula_text" 'generate_completions_from_executable(bin/"cddm", "completions")' "Case 1 formula completions"

cask_text="$(cat "${work_dir}/homebrew-tap/Casks/cddm.rb")"
assert_contains "$cask_text" 'binary "cddm"' "Case 1 cask cddm"
assert_contains "$cask_text" 'binary "cddm-mcp"' "Case 1 cask cddm-mcp"
assert_contains "$cask_text" 'binary "cddm-lsp"' "Case 1 cask cddm-lsp"

scoop_text="$(cat "${work_dir}/scoop-bucket/bucket/cddm.json")"
assert_contains "$scoop_text" '"cddm.exe",' "Case 1 scoop cddm.exe"
assert_contains "$scoop_text" '"cddm-mcp.exe",' "Case 1 scoop cddm-mcp.exe"
assert_contains "$scoop_text" '"cddm-lsp.exe"' "Case 1 scoop cddm-lsp.exe"
assert_contains "$scoop_text" '"checkver": "github"' "Case 1 scoop checkver"
assert_contains "$scoop_text" '"url": "https://example.invalid/org/cddm/releases/download/v$version/cddm-v$version-x86_64-pc-windows-msvc.zip"' "Case 1 scoop autoupdate url"
assert_contains "$scoop_text" '"url": "$baseurl/SHA256SUMS.txt"' "Case 1 scoop autoupdate hash url"

winget_inst="${work_dir}/winget-pkgs/manifests/o/org/cddm/4.10.2/org.cddm.installer.yaml"
winget_text="$(cat "$winget_inst")"
assert_contains "$winget_text" "RelativeFilePath: cddm.exe" "Case 1 winget cddm.exe"
assert_contains "$winget_text" "PortableCommandAlias: cddm" "Case 1 winget cddm alias"
assert_contains "$winget_text" "RelativeFilePath: cddm-mcp.exe" "Case 1 winget cddm-mcp.exe"
assert_contains "$winget_text" "PortableCommandAlias: cddm-mcp" "Case 1 winget cddm-mcp alias"
assert_contains "$winget_text" "RelativeFilePath: cddm-lsp.exe" "Case 1 winget cddm-lsp.exe"
assert_contains "$winget_text" "PortableCommandAlias: cddm-lsp" "Case 1 winget cddm-lsp alias"
echo "    [PASS] Case 1: extra-binaries emits multi-binary Homebrew, Scoop, and WinGet v1.9.0 entries"

# Case 2: Multi-value binary-name with newline/comma separation, .exe normalization, deduplication, and scoop-autoupdate=false
INPUT_BINARY_NAME=$'cddm.exe, cddm-mcp.EXE\ncddm-lsp, cddm' INPUT_EXTRA_BINARIES="" \
  INPUT_SCOOP_AUTOUPDATE="false" \
  run_dispatch_case
out_file="${LAST_CASE_DIR}/output"
work_dir="${LAST_CASE_DIR}/work"
assert_eq "$(get_gh_output "$out_file" "binaries")" "cddm,cddm-mcp,cddm-lsp" "Case 2 deduplicated binaries output"
scoop_text="$(cat "${work_dir}/scoop-bucket/bucket/cddm.json")"
assert_contains "$scoop_text" '"cddm.exe",' "Case 2 scoop cddm.exe"
assert_contains "$scoop_text" '"cddm-mcp.exe",' "Case 2 scoop cddm-mcp.exe"
assert_contains "$scoop_text" '"cddm-lsp.exe"' "Case 2 scoop cddm-lsp.exe"
assert_not_contains "$scoop_text" '"checkver"' "Case 2 scoop checkver omitted when autoupdate=false"
assert_not_contains "$scoop_text" '"autoupdate"' "Case 2 scoop autoupdate omitted when autoupdate=false"
echo "    [PASS] Case 2: multi-value binary-name normalizes .exe suffixes, deduplicates, and respects scoop-autoupdate=false"

# Case 3: Default single binary fallback to app name
APP_NAME="forge-cli" INPUT_BINARY_NAME="" INPUT_EXTRA_BINARIES="" \
  run_dispatch_case
out_file="${LAST_CASE_DIR}/output"
work_dir="${LAST_CASE_DIR}/work"
assert_eq "$(get_gh_output "$out_file" "binaries")" "forge-cli" "Case 3 default binary fallback"
formula_text="$(cat "${work_dir}/homebrew-tap/Formula/forge-cli.rb")"
assert_contains "$formula_text" 'bin.install "forge-cli"' "Case 3 formula single bin"
assert_not_contains "$formula_text" 'if File.exist?' "Case 3 formula no extra bin lines"
scoop_text="$(cat "${work_dir}/scoop-bucket/bucket/forge-cli.json")"
assert_contains "$scoop_text" '"forge-cli.exe"' "Case 3 scoop single bin array"
echo "    [PASS] Case 3: default single binary fallback to app name works cleanly"

# Case 4: Regression guard for #47 (no unindented heredocs in publish-release/action.yaml & valid WinGet version/defaultLocale manifests)
winget_ver="${work_dir}/winget-pkgs/manifests/o/org/forge-cli/4.10.2/org.forge-cli.yaml"
winget_loc="${work_dir}/winget-pkgs/manifests/o/org/forge-cli/4.10.2/org.forge-cli.locale.en-US.yaml"
assert_contains "$(cat "$winget_ver")" "# yaml-language-server: \$schema=https://aka.ms/winget-manifest.version.1.9.0.schema.json" "Case 4 winget version schema header"
assert_contains "$(cat "$winget_ver")" "ManifestType: version" "Case 4 winget version ManifestType"
assert_contains "$(cat "$winget_loc")" "# yaml-language-server: \$schema=https://aka.ms/winget-manifest.defaultLocale.1.9.0.schema.json" "Case 4 winget locale schema header"
assert_contains "$(cat "$winget_loc")" "ManifestType: defaultLocale" "Case 4 winget locale ManifestType"
if grep -qE "EOF_WG_VER|EOF_WG_LOC|cat[[:space:]].*<<" "$ACTION_FILE"; then
  echo "[FAIL] Case 4: Forbidden unindented cat << heredoc found in ${ACTION_FILE}"
  exit 1
fi
echo "    [PASS] Case 4: zero unindented heredocs in publish-release/action.yaml and valid WinGet version/locale manifests"

echo "[PASS] All publish-release multi-binary manifest tests passed!"
