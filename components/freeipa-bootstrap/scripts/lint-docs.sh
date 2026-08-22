#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
cd -- "$ROOT_DIR"

if command -v markdownlint-cli2 >/dev/null 2>&1; then
    markdownlint-cli2 '**/*.md'
elif command -v npx >/dev/null 2>&1; then
    npx --yes markdownlint-cli2@0.23.2 '**/*.md'
else
    printf '%s\n' 'markdownlint-cli2 or npx is required to lint Markdown documentation.' >&2
    exit 127
fi
