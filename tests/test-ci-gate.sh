#!/bin/bash
set -Eeuo pipefail

REPO_ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORKFLOW="${REPO_ROOT}/.github/workflows/test.yml"

if [ ! -f "${WORKFLOW}" ]; then
    echo "fast-check workflow is missing" >&2
    exit 1
fi

grep -Eq '^  push:$' "${WORKFLOW}"
grep -Eq '^  pull_request:$' "${WORKFLOW}"
grep -Eq '^permissions:$' "${WORKFLOW}"
grep -Eq '^  contents: read$' "${WORKFLOW}"
grep -Fq 'shellcheck -e SC1091' "${WORKFLOW}"
grep -Fq 'for test_path in tests/test-*.sh; do' "${WORKFLOW}"

printf 'CI gate tests passed\n'
