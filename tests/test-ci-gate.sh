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
grep -Eq '^          persist-credentials: false$' "${WORKFLOW}"
grep -Fq 'case "${shebang}" in' "${WORKFLOW}"
grep -Fq '*bash*) bash -n "${script_path}" ;;' "${WORKFLOW}"
grep -Fq '*sh*) sh -n "${script_path}" ;;' "${WORKFLOW}"
grep -Fq 'shellcheck -e SC1091' "${WORKFLOW}"
grep -Fq 'for test_path in tests/test-*.sh; do' "${WORKFLOW}"

for script_path in "${REPO_ROOT}/build.sh" "${REPO_ROOT}"/scripts/*.sh; do
    shebang=$(head -n 1 "${script_path}")
    case "${shebang}" in
        *bash*) bash -n "${script_path}" ;;
        *sh*) sh -n "${script_path}" ;;
        *)
            echo "unsupported script interpreter: ${script_path}: ${shebang}" >&2
            exit 1
            ;;
    esac
done

printf 'CI gate tests passed\n'
