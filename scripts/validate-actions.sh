#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$REPO_ROOT"

FAILED=0

# shellcheck source=scripts/lib/validate-common.sh
source "${SCRIPT_DIR}/lib/validate-common.sh"
# shellcheck source=scripts/lib/validate-manifests.sh
source "${SCRIPT_DIR}/lib/validate-manifests.sh"
# shellcheck source=scripts/lib/validate-repo-hygiene.sh
source "${SCRIPT_DIR}/lib/validate-repo-hygiene.sh"

print_banner "      Gitea Actions Repository Quality & SSoT Validation"

validate_composite_manifests
validate_installer_checksums
validate_containers_and_ignores
validate_workflows_and_examples
validate_ascii_and_modularity

echo "--> [7/7] Running setup-cddm, docker-build-push, and publish-release unit test suites..."
for suite in \
  "./scripts/test-setup-cddm.sh" \
  "./scripts/test-docker-build-push.sh" \
  "./scripts/test-publish-release.sh"; do
  if ! bash "$suite"; then
    echo "::error::Unit test suite failed: ${suite}"
    FAILED=1
  fi
done

if [ "$FAILED" -ne 0 ]; then
  print_banner "Validation FAILED! Please resolve the errors above."
  exit 1
fi

print_banner "All validation checks PASSED successfully!"
exit 0
