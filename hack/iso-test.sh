#!/usr/bin/env bash

# Compatibility entry point. Canonical implementation lives under tests/iso.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec bash "$repo_root/tests/iso/suite.sh" "$@"
